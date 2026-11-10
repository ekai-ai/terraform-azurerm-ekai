#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# init-state-backend.sh  —  Azure Terraform state bootstrap
#
# Usage:  ./scripts/init-state-backend.sh <ENV>
#
# What it does:
#   1. Creates (or verifies) the resource group everything in this env lives
#      in: ekai-saas-<ENV> -- the one piece of infrastructure Terraform never
#      creates itself (every module reads it via a data source).
#   2. Creates (or verifies) a storage account: ekaiterraform<ENV>
#      (lowercase letters + digits only, 3-24 chars total -- Azure's hard
#      limit on storage account names. The "ekaiterraform" prefix is 13
#      chars, so ENV can be at most 11 chars, no hyphens/underscores/
#      uppercase).
#   3. Creates (or verifies) a blob container inside it: ekaitfstate
#   4. Grants the deploying principal (current `az account show` identity)
#      Storage Blob Data Contributor on the storage account -- the azurerm
#      backend authenticates via Azure AD by default (not an access key), so
#      without this RBAC grant `terraform init` fails with 403 reading/
#      writing the state blob.
#   5. Writes two backend config files:
#        env/backend-<ENV>.tfbackend       (combined: bootstrap+cluster+platform)
#        env/backend-<ENV>-cicd.tfbackend
#
# Idempotent — safe to run multiple times; existing resources are not modified.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Args ──────────────────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <ENV>"
  echo "  ENV  environment slug (e.g. customer, dev, qa, prod). Max 11 chars,"
  echo "       lowercase letters + digits only -- embedded in the storage"
  echo "       account name (ekaiterraform<ENV>, Azure's 24-char limit)."
  exit 1
fi
ENV="$1"

if [[ ! "${ENV}" =~ ^[a-z0-9]{1,11}$ ]]; then
  echo "ERROR: ENV must be 1-11 lowercase letters/digits only (got '${ENV}')."
  echo "  Storage account name 'ekaiterraform${ENV}' must fit in Azure's"
  echo "  24-char, lowercase-alphanumeric-only limit."
  exit 1
fi

TFVARS="${REPO_ROOT}/env/${ENV}.tfvars"
if [[ ! -f "${TFVARS}" ]]; then
  echo "ERROR: ${TFVARS} not found. Copy env/customer.tfvars to ${TFVARS} and fill it in first."
  exit 1
fi

REGION=$(grep -E '^region[[:space:]]*=' "${TFVARS}" | head -1 | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/')
RESOURCE_GROUP_NAME=$(grep -E '^resource_group_name[[:space:]]*=' "${TFVARS}" | head -1 | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/')
if [[ -z "${REGION}" || -z "${RESOURCE_GROUP_NAME}" ]]; then
  echo "ERROR: could not extract 'region' and/or 'resource_group_name' from ${TFVARS}"
  exit 1
fi

# env_name from tfvars — may differ from the ENV argument (the tfvars
# filename), e.g. env/acmecorp.tfvars containing env_name = "acmecorp-prod".
# cicd/providers.tf's own data "terraform_remote_state" "combined" block
# computes the storage account name and state key from var.env_name alone
# ("ekaiterraform${var.env_name}" / "${var.env_name}/combined.tfstate"),
# with no access to this script's ENV argument -- diverge the two and this
# script creates the storage account under one name while cicd's remote-state
# read looks for a different one that doesn't exist.
ENV_PREFIX=$(grep -E '^env_name[[:space:]]*=' "${TFVARS}" | head -1 | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/' || true)
[[ -z "${ENV_PREFIX}" ]] && ENV_PREFIX="${ENV}"

if [[ ! "${ENV_PREFIX}" =~ ^[a-z0-9]{1,11}$ ]]; then
  echo "ERROR: env_name ('${ENV_PREFIX}') must be 1-11 lowercase letters/digits only --"
  echo "  storage account name 'ekaiterraform${ENV_PREFIX}' must fit in Azure's"
  echo "  24-char, lowercase-alphanumeric-only limit."
  exit 1
fi

STORAGE_ACCOUNT="ekaiterraform${ENV_PREFIX}"
CONTAINER="ekaitfstate"

echo "==> Resource group: ${RESOURCE_GROUP_NAME} (region: ${REGION})"
echo "==> State storage account: ${STORAGE_ACCOUNT}"
echo "==> State container: ${CONTAINER}"

# ── Resource group ────────────────────────────────────────────────────────────
if az group show --name "${RESOURCE_GROUP_NAME}" >/dev/null 2>&1; then
  echo "==> Resource group already exists — skipping creation."
else
  echo "==> Creating resource group..."
  az group create --name "${RESOURCE_GROUP_NAME}" --location "${REGION}" >/dev/null
fi

# ── Storage account ───────────────────────────────────────────────────────────
if az storage account show --name "${STORAGE_ACCOUNT}" --resource-group "${RESOURCE_GROUP_NAME}" >/dev/null 2>&1; then
  echo "==> Storage account already exists — skipping creation."
else
  echo "==> Creating storage account..."
  az storage account create \
    --name "${STORAGE_ACCOUNT}" \
    --resource-group "${RESOURCE_GROUP_NAME}" \
    --location "${REGION}" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --min-tls-version TLS1_2 \
    --allow-blob-public-access false >/dev/null
fi

# ── RBAC: Storage Blob Data Contributor for the deploying principal ──────────
# The azurerm backend authenticates via Azure AD (not an access key) by
# default -- without this role, `terraform init`/`plan`/`apply` fails with a
# 403 reading/writing the state blob. Newly-created SPs can take ~30-60s to
# propagate through Entra, same genre as the role assignments Terraform
# itself makes elsewhere in this repo.
CALLER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || \
  az account show --query user.name -o tsv | xargs -I{} az ad sp show --id {} --query id -o tsv 2>/dev/null || true)
STORAGE_ACCOUNT_ID=$(az storage account show --name "${STORAGE_ACCOUNT}" --resource-group "${RESOURCE_GROUP_NAME}" --query id -o tsv)

if [[ -n "${CALLER_OBJECT_ID}" ]]; then
  echo "==> Granting Storage Blob Data Contributor to ${CALLER_OBJECT_ID}..."
  az role assignment create \
    --assignee-object-id "${CALLER_OBJECT_ID}" \
    --assignee-principal-type $(az ad signed-in-user show >/dev/null 2>&1 && echo "User" || echo "ServicePrincipal") \
    --role "Storage Blob Data Contributor" \
    --scope "${STORAGE_ACCOUNT_ID}" >/dev/null 2>&1 || \
    echo "    (role assignment already exists or is still propagating — safe to ignore if init succeeds)"
else
  echo "WARNING: could not resolve the signed-in principal's object ID -- skipping RBAC grant."
  echo "  Grant 'Storage Blob Data Contributor' on ${STORAGE_ACCOUNT_ID} manually if 'terraform init' gets a 403."
fi

# ── Blob container ────────────────────────────────────────────────────────────
if az storage container show --name "${CONTAINER}" --account-name "${STORAGE_ACCOUNT}" --auth-mode login >/dev/null 2>&1; then
  echo "==> Container already exists — skipping creation."
else
  echo "==> Creating container (retrying briefly for RBAC propagation)..."
  for i in $(seq 1 6); do
    if az storage container create --name "${CONTAINER}" --account-name "${STORAGE_ACCOUNT}" --auth-mode login >/dev/null 2>&1; then
      break
    fi
    echo "    attempt ${i}/6 failed, retrying in 10s..."
    sleep 10
  done
fi

# ── Write backend config files ────────────────────────────────────────────────
ENV_DIR="${REPO_ROOT}/env"

cat > "${ENV_DIR}/backend-${ENV}.tfbackend" <<EOF
resource_group_name  = "${RESOURCE_GROUP_NAME}"
storage_account_name = "${STORAGE_ACCOUNT}"
container_name       = "${CONTAINER}"
key                   = "${ENV_PREFIX}/combined.tfstate"
EOF

cat > "${ENV_DIR}/backend-${ENV}-cicd.tfbackend" <<EOF
resource_group_name  = "${RESOURCE_GROUP_NAME}"
storage_account_name = "${STORAGE_ACCOUNT}"
container_name       = "${CONTAINER}"
key                   = "${ENV_PREFIX}/cicd.tfstate"
EOF

echo ""
echo "✓ Done. Backend files written to ${ENV_DIR}/backend-${ENV}.tfbackend and backend-${ENV}-cicd.tfbackend"
echo ""
echo "Apply order:"
echo "  cd examples/self-deploy/root && terraform init -backend-config=../../../env/backend-${ENV}.tfbackend && terraform apply -var-file=../../../env/${ENV}.tfvars"
echo "  cd ../cicd                   && terraform init -backend-config=../../../env/backend-${ENV}-cicd.tfbackend && terraform apply -var-file=../../../env/${ENV}.tfvars"
echo "(scripts/self-deploy.sh does both of these for you, in order.)"
