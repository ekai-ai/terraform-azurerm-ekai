#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# self-deploy.sh  —  Azure self-deployment, made easy
#
# Usage:  ./scripts/self-deploy.sh <ENV>
#   ENV   environment name — must have a matching env/<ENV>.tfvars
#         (e.g. customer)
#
# What it does, in plain terms:
#   1. Registers the Azure resource providers Terraform needs (under YOUR
#      already-authenticated `az login` identity — this script needs
#      subscription-level rights throughout)
#   2. Creates the resource group everything in this env lives in
#   3. Creates a scoped deployer Service Principal (not your own admin
#      identity) with just the roles Terraform needs -- "Owner" scoped to
#      that one resource group, plus a client secret for it. Only when
#      purge_vault_on_destroy = true in the target env's tfvars (internal
#      fast destroy/reapply test loops, never the customer default) does it
#      also grant a minimal subscription-scoped custom role for purging a
#      soft-deleted Key Vault. No Entra ID directory role is needed at all --
#      ESO's workload identity is a plain user-assigned managed identity
#      (modules/key_vault), not an Entra app registration.
#   4. Initializes the Terraform state backend (storage account + container)
#   5. Optionally runs the actual Terraform deploy — 2 applies (repo root,
#      then cicd/; down from the original 4 separate layers, but not all the
#      way to 1 — see cicd/main.tf's file header for why), after one clear
#      confirmation, since that step creates real cloud resources and costs
#      money
#
# cicd_provider = "none" (self-service, e.g. env/customer.tfvars) generates
# its own DB/Redis/ArgoCD credentials and the app's secret directly in
# Terraform — no master Key Vault secret to pre-seed, no password prompts
# here.
#
# Requires: az (authenticated with subscription-level rights -- no Entra ID
#           directory role needed, only Azure RBAC), kubectl, jq, dig,
#           terraform.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SKIP_DNS_WAIT=0
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --skip-dns-wait) SKIP_DNS_WAIT=1 ;;
    *) ARGS+=("$arg") ;;
  esac
done
set -- "${ARGS[@]}"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 [--skip-dns-wait] <ENV>"
  echo "  ENV              must have a matching env/<ENV>.tfvars (e.g. customer)"
  echo "  --skip-dns-wait  don't poll for DNS propagation -- print the nameservers"
  echo "                   and continue straight to the cicd apply"
  exit 1
fi
ENV="$1"
TFVARS="${REPO_ROOT}/env/${ENV}.tfvars"

if [[ ! -f "${TFVARS}" ]]; then
  echo "ERROR: ${TFVARS} not found."
  exit 1
fi

for bin in az kubectl jq dig terraform; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' is required but not installed."; exit 1; }
done

echo "════════════════════════════════════════════════════════════════"
echo " Ekai Azure self-deploy — environment: ${ENV}"
echo "════════════════════════════════════════════════════════════════"
echo

SUBSCRIPTION_ID=$(grep -E '^subscription_id[[:space:]]*=' "${TFVARS}" | head -1 | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/')
[[ -z "${SUBSCRIPTION_ID}" || "${SUBSCRIPTION_ID}" == "00000000-0000-0000-0000-000000000000" ]] && { echo "ERROR: set a real subscription_id in ${TFVARS} first."; exit 1; }
REGION=$(grep -E '^region[[:space:]]*=' "${TFVARS}" | head -1 | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/')
[[ -z "${REGION}" ]] && { echo "ERROR: could not read 'region' from ${TFVARS}"; exit 1; }
RESOURCE_GROUP_NAME=$(grep -E '^resource_group_name[[:space:]]*=' "${TFVARS}" | head -1 | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/')
[[ -z "${RESOURCE_GROUP_NAME}" ]] && { echo "ERROR: could not read 'resource_group_name' from ${TFVARS}"; exit 1; }
ACME_EMAIL=$(grep -E '^acme_email[[:space:]]*=' "${TFVARS}" | head -1 | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/')
[[ -z "${ACME_EMAIL}" || "${ACME_EMAIL}" == "REPLACE_ME" ]] && { echo "ERROR: set a real acme_email in ${TFVARS} first -- cert-manager's Let's Encrypt ACME account registration fails without one."; exit 1; }

az account set --subscription "${SUBSCRIPTION_ID}"

# Captured before anything switches it -- restored at the end, same
# reasoning as AWS/GCP's scripts: a second run of this script shouldn't
# start already authenticated as last run's narrowly-scoped deployer SP.
ORIGINAL_ACCOUNT=$(az account show --query user.name -o tsv 2>/dev/null || echo "")
ORIGINAL_ACCOUNT_TYPE=$(az account show --query user.type -o tsv 2>/dev/null || echo "")

# Fail fast here instead of deep into Step 3 with a confusing "Insufficient
# privileges" on `az ad sp create-for-rbac`/`credential reset` -- confirmed
# live: the most common way to land here is a PREVIOUS run of this script
# against a different env, whose exit trap switched the local az CLI to
# that env's scoped deployer SP (Owner on just its one resource group,
# nothing in Entra ID) and the next run was kicked off without logging back
# in first. A legitimate human admin login always shows user.type "user" --
# "servicePrincipal" here means this is almost certainly that leftover
# narrow identity, not a real admin.
if [[ "${ORIGINAL_ACCOUNT_TYPE}" == "servicePrincipal" ]]; then
  echo "ERROR: az is currently authenticated as a service principal (${ORIGINAL_ACCOUNT})."
  echo "This is almost always last run's scoped deployer SP, left active by a"
  echo "previous self-deploy.sh/self-deploy-destroy.sh run on a different env --"
  echo "it only has Owner on that one env's resource group, nothing else."
  echo "Run 'az login' with your own admin account first, then re-run this script."
  exit 1
fi

echo "==> Subscription: ${SUBSCRIPTION_ID}"
echo "==> Region:       ${REGION}"
echo "==> Currently authenticated as: ${ORIGINAL_ACCOUNT:-<unknown>}"
echo "    (this identity needs subscription-level rights to run this script —"
echo "     it is NOT the identity Terraform will use)"
echo

CICD_PROVIDER=$(grep -E '^cicd_provider[[:space:]]*=' "${TFVARS}" | head -1 | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/' || true)
[[ -z "${CICD_PROVIDER}" ]] && CICD_PROVIDER="none"
if [[ "${CICD_PROVIDER}" == "none" ]]; then
  echo "==> cicd_provider = \"none\" (self-service) — the cluster/platform"
  echo "    submodules generate DB/ArgoCD credentials directly, no master secret needed."
fi

OUT_DIR="${REPO_ROOT}/.self-deploy"
mkdir -p "${OUT_DIR}"
SECRETS_FILE="${OUT_DIR}/${ENV}-generated-secrets.txt"
: > "${SECRETS_FILE}"
chmod 600 "${SECRETS_FILE}"
echo "# Generated by self-deploy.sh for env=${ENV} — copy into your password manager, then delete this file" >> "${SECRETS_FILE}"

# ── Step 1 — Register required Azure resource providers ──────────────────────
# Equivalent of GCP's `gcloud services enable`. Most subscriptions already
# have these auto-registered from prior use, but a brand-new subscription
# (exactly what self-service onboards) can have some or all of them
# unregistered, which fails `terraform apply` deep into the run with an
# opaque "MissingSubscriptionRegistration" error instead of failing fast
# here with a clear one.
echo "──── Step 1/5: Register Azure resource providers ───────────────────"
REQUIRED_PROVIDERS=(
  Microsoft.ContainerService
  Microsoft.KeyVault
  Microsoft.DBforPostgreSQL
  Microsoft.Network
  Microsoft.ContainerRegistry
  Microsoft.OperationalInsights
  Microsoft.OperationsManagement
  Microsoft.ManagedIdentity
  Microsoft.Storage
)
for PROVIDER in "${REQUIRED_PROVIDERS[@]}"; do
  STATE=$(az provider show --namespace "${PROVIDER}" --query registrationState -o tsv 2>/dev/null || echo "NotRegistered")
  if [[ "${STATE}" != "Registered" ]]; then
    echo "==> Registering ${PROVIDER} (currently: ${STATE})..."
    az provider register --namespace "${PROVIDER}" >/dev/null
  fi
done
echo "==> Waiting for registration to complete..."
UNREGISTERED_PROVIDERS=()
for PROVIDER in "${REQUIRED_PROVIDERS[@]}"; do
  REGISTERED=0
  for i in $(seq 1 20); do
    STATE=$(az provider show --namespace "${PROVIDER}" --query registrationState -o tsv 2>/dev/null || echo "NotRegistered")
    if [[ "${STATE}" == "Registered" ]]; then
      REGISTERED=1
      break
    fi
    sleep 5
  done
  [[ "${REGISTERED}" -eq 0 ]] && UNREGISTERED_PROVIDERS+=("${PROVIDER}")
done
if [[ ${#UNREGISTERED_PROVIDERS[@]} -eq 0 ]]; then
  echo "✓ Resource providers registered."
else
  echo "⚠ Still not registered after 100s: ${UNREGISTERED_PROVIDERS[*]}"
  echo "  Registration is still processing in the background -- check with:"
  echo "    az provider show --namespace <name> --query registrationState -o tsv"
  echo "  Proceeding anyway; the upcoming terraform apply may fail against"
  echo "  whichever of these isn't actually ready yet. Safe to just re-run"
  echo "  this script if that happens."
fi
echo

# ── Step 2 — Resource group ───────────────────────────────────────────────────
echo "──── Step 2/5: Resource group ───────────────────────────────────────"
if az group show --name "${RESOURCE_GROUP_NAME}" >/dev/null 2>&1; then
  echo "==> ${RESOURCE_GROUP_NAME} already exists — reusing."
else
  echo "==> Creating resource group ${RESOURCE_GROUP_NAME}..."
  az group create --name "${RESOURCE_GROUP_NAME}" --location "${REGION}" >/dev/null
fi
RG_ID=$(az group show --name "${RESOURCE_GROUP_NAME}" --query id -o tsv)
echo

# ── Step 3 — Deployer Service Principal + roles ───────────────────────────────
echo "──── Step 3/5: Deployer Service Principal ──────────────────────────"
SP_NAME="ekai-terraform-${ENV}"

EXISTING_SP_ID=$(az ad sp list --display-name "${SP_NAME}" --query '[0].id' -o tsv 2>/dev/null || echo "")
if [[ -n "${EXISTING_SP_ID}" && "${EXISTING_SP_ID}" != "null" ]]; then
  echo "==> Service principal ${SP_NAME} already exists — reusing (resetting its credential)."
  CRED_JSON=$(az ad sp credential reset --id "${EXISTING_SP_ID}" --years 2 -o json)
  APP_ID=$(echo "${CRED_JSON}" | jq -r .appId)
  CLIENT_SECRET=$(echo "${CRED_JSON}" | jq -r .password)
  TENANT_ID=$(echo "${CRED_JSON}" | jq -r .tenant)
else
  echo "==> Creating service principal ${SP_NAME} (no role yet — granted below, scoped to this one resource group)..."
  CRED_JSON=$(az ad sp create-for-rbac --name "${SP_NAME}" --years 2 -o json)
  APP_ID=$(echo "${CRED_JSON}" | jq -r .appId)
  CLIENT_SECRET=$(echo "${CRED_JSON}" | jq -r .password)
  TENANT_ID=$(echo "${CRED_JSON}" | jq -r .tenant)
  echo "==> Waiting for the new service principal to propagate through Entra..."
  for i in $(seq 1 20); do
    if az ad sp show --id "${APP_ID}" >/dev/null 2>&1; then
      echo "✓ Service principal is visible."
      break
    fi
    sleep 3
  done
fi

{
  echo "ARM_CLIENT_ID=${APP_ID}"
  echo "ARM_CLIENT_SECRET=${CLIENT_SECRET}"
  echo "ARM_TENANT_ID=${TENANT_ID}"
  echo "ARM_SUBSCRIPTION_ID=${SUBSCRIPTION_ID}"
} >> "${SECRETS_FILE}"

# Owner (not Contributor) scoped to just this one resource group: Terraform
# itself creates azurerm_role_assignment resources throughout this repo (Key
# Vault RBAC, ACR AcrPull, DNS Zone Contributor, the shared app identity's
# Key Vault role, ...) -- Contributor alone cannot create or modify role
# assignments in Azure RBAC, only "User Access Administrator"/"Owner" can.
# Scoping Owner to one resource group (not the subscription) keeps the blast
# radius contained to this one deployment, same spirit as AWS/GCP's scoped
# deployer identities even though Azure's RBAC role catalog doesn't offer an
# equivalently narrow predefined role for "can create role assignments."
#
# Captured once here, reused below for the Key Vault purge role grant when
# purge_vault_on_destroy = true.
SP_OBJECT_ID=$(az ad sp show --id "${APP_ID}" --query id -o tsv)

for attempt in $(seq 1 5); do
  if az role assignment create \
    --assignee-object-id "${SP_OBJECT_ID}" \
    --assignee-principal-type ServicePrincipal \
    --role "Owner" \
    --scope "${RG_ID}" >/dev/null 2>&1; then
    break
  fi
  if [[ "${attempt}" -eq 5 ]]; then
    echo "ERROR: failed to grant Owner on ${RG_ID} to ${SP_NAME} after 5 attempts."
    exit 1
  fi
  sleep $((attempt * 3))
done
echo "✓ Owner on ${RESOURCE_GROUP_NAME} granted to ${SP_NAME}."
echo

# Key Vault purge role -- only when purge_vault_on_destroy = true in this
# env's tfvars (internal fast destroy/reapply test loops; see variables.tf's
# description of that variable). Left unset/false, this whole block is
# skipped -- the expected, default customer path, and it asks for nothing
# beyond the resource-group "Owner" grant above.
#
# Why this needs its own role instead of just being covered by "Owner" on
# the resource group: Microsoft.KeyVault/locations/deletedVaults is a
# region-level collection, not a resource-group-scoped one -- its ARM ID
# (/subscriptions/<sub>/providers/Microsoft.KeyVault/locations/<region>/
# deletedVaults/<name>) has no resource-group segment anywhere in it, so
# "purge" can only ever be granted at subscription scope or higher, never
# narrower. Rather than hand the deployer SP subscription-level "Owner" (or
# any built-in role broad enough to cover this), we create the narrowest
# possible custom role -- just the two Actions below, nothing else -- and
# grant only that at subscription scope. This role only needs to exist once
# per subscription, not once per env, so creating it is idempotent across
# repeated runs.
PURGE_VAULT_ON_DESTROY=$(grep -E '^purge_vault_on_destroy[[:space:]]*=' "${TFVARS}" | head -1 | sed 's/.*=[[:space:]]*\(true\|false\).*/\1/' || true)
if [[ "${PURGE_VAULT_ON_DESTROY}" == "true" ]]; then
  echo "==> purge_vault_on_destroy = true -- granting the subscription-scoped Key Vault purge role..."
  PURGE_ROLE_NAME="Ekai Key Vault Purge (self-service)"

  EXISTING_ROLE=$(az role definition list --name "${PURGE_ROLE_NAME}" --scope "/subscriptions/${SUBSCRIPTION_ID}" --query "[0].name" -o tsv 2>/dev/null || echo "")
  if [[ -n "${EXISTING_ROLE}" && "${EXISTING_ROLE}" != "null" ]]; then
    echo "==> Custom role '${PURGE_ROLE_NAME}' already exists in this subscription -- reusing."
  else
    echo "==> Creating custom role '${PURGE_ROLE_NAME}'..."
    az role definition create --role-definition "{
      \"Name\": \"${PURGE_ROLE_NAME}\",
      \"Description\": \"Minimum rights to read and purge a soft-deleted Key Vault -- this Azure resource type has no resource-group-scoped equivalent, only subscription scope or higher.\",
      \"Actions\": [
        \"Microsoft.KeyVault/locations/deletedVaults/read\",
        \"Microsoft.KeyVault/locations/deletedVaults/purge/action\"
      ],
      \"NotActions\": [],
      \"AssignableScopes\": [\"/subscriptions/${SUBSCRIPTION_ID}\"]
    }" >/dev/null
  fi

  ALREADY_ASSIGNED=$(az role assignment list --assignee "${SP_OBJECT_ID}" --role "${PURGE_ROLE_NAME}" --scope "/subscriptions/${SUBSCRIPTION_ID}" --query "[0].id" -o tsv 2>/dev/null || echo "")
  if [[ -n "${ALREADY_ASSIGNED}" ]]; then
    echo "==> Already granted (reusing an existing SP) -- continuing."
  else
    for attempt in $(seq 1 5); do
      if az role assignment create \
        --assignee-object-id "${SP_OBJECT_ID}" \
        --assignee-principal-type ServicePrincipal \
        --role "${PURGE_ROLE_NAME}" \
        --scope "/subscriptions/${SUBSCRIPTION_ID}" >/dev/null 2>&1; then
        break
      fi
      if [[ "${attempt}" -eq 5 ]]; then
        echo "ERROR: failed to grant '${PURGE_ROLE_NAME}' on /subscriptions/${SUBSCRIPTION_ID} to ${SP_NAME} after 5 attempts."
        exit 1
      fi
      sleep $((attempt * 3))
    done
  fi
  echo "✓ Key Vault purge role granted to ${SP_NAME}."
else
  echo "==> purge_vault_on_destroy not set to true -- skipping the subscription-scoped Key Vault purge role (default, expected for customer deployments)."
fi
echo

# ── Step 3 — State backend ────────────────────────────────────────────────────
echo "──── Step 4/5: State backend ───────────────────────────────────────"
"${SCRIPT_DIR}/init-state-backend.sh" "${ENV}"
echo

# ── Step 4 — Deploy (optional) ────────────────────────────────────────────────
echo "──── Step 5/5: Deploy infrastructure ───────────────────────────────"
echo "Everything above is prep — no cluster infrastructure has been created yet."
echo "This next step creates real Azure resources (VNet, AKS, Postgres, ...) and costs money."
echo
read -rp "Run the Terraform deploy now (2 applies — bootstrap+cluster+platform, then cicd)? [y/N] " CONFIRM </dev/tty
if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
  echo
  echo "Skipped. When you're ready, deploy locally:"
  echo "  export ARM_CLIENT_ID=${APP_ID}"
  echo "  export ARM_CLIENT_SECRET=<see ${SECRETS_FILE}>"
  echo "  export ARM_TENANT_ID=${TENANT_ID}"
  echo "  export ARM_SUBSCRIPTION_ID=${SUBSCRIPTION_ID}"
  echo "  cd ${REPO_ROOT}/examples/self-deploy/root"
  echo "  terraform init -backend-config=../../../env/backend-${ENV}.tfbackend"
  echo "  terraform apply -var-file=../../../env/${ENV}.tfvars"
  echo "  cd ../cicd"
  echo "  terraform init -backend-config=../../../env/backend-${ENV}-cicd.tfbackend"
  echo "  terraform apply -var-file=../../../env/${ENV}.tfvars"
  echo
  echo "Generated credentials are saved at: ${SECRETS_FILE}"
  echo "Copy them into your password manager, then delete the file."
  exit 0
fi

export ARM_CLIENT_ID="${APP_ID}"
export ARM_CLIENT_SECRET="${CLIENT_SECRET}"
export ARM_TENANT_ID="${TENANT_ID}"
export ARM_SUBSCRIPTION_ID="${SUBSCRIPTION_ID}"

# `az login --service-principal` below permanently switches the LOCAL az CLI
# session to the deployer SP -- it's not scoped to this script's process, and
# unlike the ARM_* env vars above (which only affect Terraform's own provider
# auth), there's no way to silently restore an interactive human login here
# (ORIGINAL_ACCOUNT for a browser/device-code login isn't a credential this
# script can log back in with -- that needs a real interactive flow, which
# has no business popping up unannounced in an exit trap). All this can
# safely do is select the subscription back and warn clearly that the
# switch happened, on every exit path (success, error, Ctrl-C) -- confirmed
# live: without this, a later `az`/`terraform` command run under the
# assumption of still being the original identity fails with a confusing
# 403 "Insufficient privileges" (the deployer SP has Owner on just this one
# resource group, nothing in Entra ID) instead of a clear "you're logged in
# as the wrong identity" pointer.
restore_subscription_and_warn() {
  az account set --subscription "${SUBSCRIPTION_ID}" >/dev/null 2>&1 || true
  echo ""
  echo "⚠ Your local az CLI is now authenticated as the deployer service principal"
  echo "  (${SP_NAME}), not your original identity (${ORIGINAL_ACCOUNT:-<unknown>})."
  echo "  It only has Owner on this one resource group -- nothing in Entra ID."
  echo "  Run 'az login' again before using az/terraform under your own account."
}
trap restore_subscription_and_warn EXIT

echo "==> Waiting for the new credential to propagate..."
CREDENTIAL_PROPAGATED=0
for i in $(seq 1 20); do
  if ARM_CLIENT_ID="${APP_ID}" ARM_CLIENT_SECRET="${CLIENT_SECRET}" ARM_TENANT_ID="${TENANT_ID}" ARM_SUBSCRIPTION_ID="${SUBSCRIPTION_ID}" \
     az login --service-principal -u "${APP_ID}" -p "${CLIENT_SECRET}" --tenant "${TENANT_ID}" >/dev/null 2>&1; then
    echo "✓ Credential is active."
    az account set --subscription "${SUBSCRIPTION_ID}"
    CREDENTIAL_PROPAGATED=1
    break
  fi
  sleep 5
done
if [[ "${CREDENTIAL_PROPAGATED}" -eq 0 ]]; then
  echo "⚠ Credential still not accepted after 100s -- proceeding anyway, but"
  echo "  the upcoming terraform apply may fail authenticating as the deployer"
  echo "  SP if it's genuinely not propagated yet. Safe to just re-run this"
  echo "  script if that happens."
fi

# 2 applies, in order: bootstrap+cluster+platform first (its state feeds
# cicd's terraform_remote_state read — see cicd/main.tf's file header for why
# cicd can't be folded into this same apply), then cicd. Both run from
# examples/self-deploy/{root,cicd} — the repo root and cicd/ directories are
# pure Terraform modules now (no backend block of their own; see
# providers.tf / cicd/providers.tf), so they can't be applied directly.
echo
echo "════════ terraform apply (bootstrap + cluster + platform) ════════"
cd "${REPO_ROOT}/examples/self-deploy/root"
terraform init -upgrade -reconfigure -backend-config="../../../env/backend-${ENV}.tfbackend"
terraform apply -auto-approve -compact-warnings -var-file="../../../env/${ENV}.tfvars"

# ── DNS delegation — only when Terraform just created a NEW DNS zone.
# Delegating dns_zone to Azure's nameservers at your registrar/parent zone is
# out-of-band and human-timed -- Terraform has no access to do it for you.
# Until it's done, cert-manager's ACME DNS-01 challenge for the wildcard TLS
# cert can never succeed (Let's Encrypt can't find the zone via public DNS to
# verify the challenge record), even though the apply above still succeeds --
# the Certificate resource just sits at READY=False indefinitely, same
# non-blocking-apply behavior as GCP (unlike AWS's synchronous ACM
# validation, which blocks the apply itself).
MANAGE_DNS_ZONE=$(grep -E '^manage_dns_zone[[:space:]]*=' "${TFVARS}" | head -1 | sed 's/.*=[[:space:]]*\(true\|false\).*/\1/')
if [[ "${MANAGE_DNS_ZONE}" == "true" ]]; then
  DNS_ZONE=$(grep -E '^dns_zone[[:space:]]*=' "${TFVARS}" | head -1 | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/')
  ZONE_NS=$(terraform output -json dns_zone_name_servers 2>/dev/null | jq -r '.[]' | sed 's/\.$//' | sort)
  if [[ -n "${ZONE_NS}" ]]; then
    echo
    echo "════════ DNS delegation required ════════"
    echo "Terraform just created a DNS zone for ${DNS_ZONE}. Add an NS record for"
    echo "${DNS_ZONE} at your domain registrar (or your parent DNS zone) pointing"
    echo "at each of these nameservers:"
    echo "${ZONE_NS}" | sed 's/^/  /'
    echo
    if [[ "${SKIP_DNS_WAIT}" -eq 1 ]]; then
      echo "==> DNS wait skipped."
    else
      read -rp "Press Enter once you've added it (Ctrl-C to do this later and re-run) " _ </dev/tty
      echo "==> Checking DNS delegation (this can take several minutes to propagate)..."
      for i in $(seq 1 40); do
        RESOLVED=$(dig +short NS "${DNS_ZONE}" @8.8.8.8 2>/dev/null | sed 's/\.$//' | sort)
        if [[ -n "${RESOLVED}" && "${RESOLVED}" == "${ZONE_NS}" ]]; then
          echo "✓ DNS delegation confirmed."
          break
        fi
        echo "  Not propagated yet (attempt ${i}/40) — waiting 15s..."
        sleep 15
      done
      if [[ "${RESOLVED}" != "${ZONE_NS}" ]]; then
        echo "⚠ Still not resolving after 10 minutes — the ArgoCD/app TLS cert"
        echo "  will keep failing until this delegation is correct. cert-manager"
        echo "  retries automatically in the background once it is; no need to"
        echo "  re-run this script for that."
      fi
    fi
  fi
fi

echo
echo "════════ terraform apply (cicd) ════════"
cd "${REPO_ROOT}/examples/self-deploy/cicd"
terraform init -upgrade -reconfigure -backend-config="../../../env/backend-${ENV}-cicd.tfbackend"
terraform apply -auto-approve -compact-warnings -var-file="../../../env/${ENV}.tfvars"

# ── Wait for the wildcard TLS certificate to actually be issued ──────────────
cd "${REPO_ROOT}/examples/self-deploy/root"
TLS_NAME=$(terraform output -raw tls_name)
AKS_CLUSTER_NAME=$(terraform output -raw aks_cluster_name)
echo
echo "==> Fetching cluster credentials..."
az aks get-credentials --name "${AKS_CLUSTER_NAME}" --resource-group "${RESOURCE_GROUP_NAME}" --overwrite-existing >/dev/null

echo "==> Waiting for the wildcard TLS certificate to be issued..."
CERT_READY=false
for i in $(seq 1 4); do
  if [[ "$(kubectl get certificate "${TLS_NAME}" -n cert-manager -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]]; then
    CERT_READY=true
    break
  fi
  sleep 30
done

if [[ "${CERT_READY}" != "true" ]]; then
  # cert-manager's DNS-01 propagation self-check can get stuck reporting
  # "not yet propagated" indefinitely even once DNS is genuinely fine --
  # same class of stale-cache issue GCP's self-deploy.sh works around.
  echo "⚠ Not ready after 2 minutes -- forcing a fresh cert-manager attempt..."
  kubectl delete order -n cert-manager --all --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete pod -n cert-manager -l app.kubernetes.io/component=controller --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl wait --for=condition=Ready pod -n cert-manager -l app.kubernetes.io/component=controller --timeout=90s >/dev/null 2>&1 || true

  for i in $(seq 1 6); do
    if [[ "$(kubectl get certificate "${TLS_NAME}" -n cert-manager -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]]; then
      CERT_READY=true
      break
    fi
    sleep 30
  done
fi

if [[ "${CERT_READY}" == "true" ]]; then
  echo "✓ TLS certificate issued."
else
  echo "⚠ TLS certificate still not ready -- ArgoCD/app URLs will show cert errors"
  echo "  until it resolves on its own. Check: kubectl get certificate ${TLS_NAME} -n cert-manager"
fi

echo
echo "✓ Deploy complete for env=${ENV}."
echo "Generated credentials are saved at: ${SECRETS_FILE} — copy into your password manager, then delete the file."
