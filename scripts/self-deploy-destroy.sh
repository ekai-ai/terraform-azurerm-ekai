#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# self-deploy-destroy.sh  —  tear down what self-deploy.sh created
#
# Usage:  ./scripts/self-deploy-destroy.sh <ENV>
#
# The repo root and cicd/ are reusable Terraform modules (no backend block
# of their own — see providers.tf / cicd/providers.tf); the actual
# state-holding root configs that apply/destroy them live at
# examples/self-deploy/{root,cicd} (down from the original 4 layers, but not
# all the way to 1 — see cicd/main.tf's file header for why the cicd apply
# has to stay separate from root's). Destroy runs in reverse dependency order:
#   1. terraform destroy in examples/self-deploy/cicd FIRST — its
#      kubernetes/kubectl/argocd providers are fed directly from the root
#      config's own outputs (static AKS cert fields + the argocd provider's
#      native port_forward_with_namespace — see cicd/providers.tf), so it
#      needs the root config's cluster/ArgoCD still live to clean up
#      ExternalSecrets/the ArgoCD Application against. Unlike AWS/GCP, no
#      separate `kubectl port-forward` process or `az aks get-credentials`
#      step is needed here — Terraform's own provider config handles both.
#   2. terraform destroy in examples/self-deploy/root (bootstrap+cluster+
#      platform, combined) — Terraform sequences this internally in reverse
#      dependency order (platform, then cluster, then bootstrap — see
#      main.tf's module depends_on chain). One defensive retry: Postgres +
#      VNet subnet delegation teardown timing isn't always fully clean on
#      the first attempt (same genre of race AWS/GCP's own destroy scripts
#      retry around, though Azure's AKS/nginx-ingress/cert-manager stack
#      doesn't have AWS's ALB-specific finalizer/webhook bugs — this repo's
#      ingress/autoscaling architecture is structurally like GCP's, not
#      AWS's, so no ALB-style cleanup helpers are needed here either).
#   3. optional: delete the resource group entirely (cascades to the tfstate
#      storage account + container, and anything else left behind)
#   4. optional: delete the deployer Service Principal
#
# Each destructive stage has its own confirmation — say no to any of them and
# the rest still runs. Safe to re-run if it fails partway.
#
# Requires: az, terraform, jq, dig, python3 (the last only if env/<ENV>.tfvars
# needs recovering via recover-tfvars.sh).
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <ENV>"
  exit 1
fi
ENV="$1"
TFVARS="${REPO_ROOT}/env/${ENV}.tfvars"

# Checked before the recovery block below, not after -- recover-tfvars.sh
# (which this script may call next) needs python3 on top of this script's
# own az/terraform/jq/dig, so this has to cover both before either runs.
for bin in az terraform jq dig python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' is required but not installed."; exit 1; }
done

if [[ ! -f "${TFVARS}" ]]; then
  echo "==> ${TFVARS} not found -- attempting to recover it from Terraform state."
  read -rp "Azure region this env was deployed into: " RECOVER_REGION </dev/tty
  if [[ -z "${RECOVER_REGION}" ]]; then
    echo "ERROR: region is required to recover ${TFVARS}."
    exit 1
  fi
  "${SCRIPT_DIR}/recover-tfvars.sh" "${ENV}" "${RECOVER_REGION}"
  if [[ ! -f "${TFVARS}" ]]; then
    echo "ERROR: recovery failed -- ${TFVARS} still doesn't exist."
    exit 1
  fi
  echo
  echo "⚠ Recovered ${TFVARS} from state. Its values weren't verified against a"
  echo "  plan first (see recover-tfvars.sh's own note on why that matters) --"
  echo "  proceeding anyway since this is a destroy, not an apply."
  echo
fi

SUBSCRIPTION_ID=$(grep -E '^subscription_id[[:space:]]*=' "${TFVARS}" | head -1 | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/')
REGION=$(grep -E '^region[[:space:]]*=' "${TFVARS}" | head -1 | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/')
RESOURCE_GROUP_NAME=$(grep -E '^resource_group_name[[:space:]]*=' "${TFVARS}" | head -1 | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/')
[[ -z "${SUBSCRIPTION_ID}" || -z "${REGION}" || -z "${RESOURCE_GROUP_NAME}" ]] && { echo "ERROR: could not read subscription_id/region/resource_group_name from ${TFVARS}"; exit 1; }

echo "════════════════════════════════════════════════════════════════"
echo " Ekai Azure self-deploy DESTROY — environment: ${ENV} (resource group: ${RESOURCE_GROUP_NAME})"
echo "════════════════════════════════════════════════════════════════"
echo
echo "This will permanently destroy the VNet, AKS cluster, PostgreSQL server,"
echo "Key Vault, ArgoCD, and DNS zone for '${ENV}'. This cannot be undone."
echo
read -rp "Type the environment name (${ENV}) to confirm: " CONFIRM_ENV </dev/tty
if [[ "${CONFIRM_ENV}" != "${ENV}" ]]; then
  echo "Did not match — aborted. Nothing was touched."
  exit 1
fi

az account set --subscription "${SUBSCRIPTION_ID}"

# ── Deployer identity — reuse self-deploy.sh's credentials if present, else
# authenticate as whatever `az login` identity is already active (it just
# needs Owner on this one resource group, same as self-deploy.sh granted the
# deployer SP -- if that SP still exists, prefer it so this destroy sees
# exactly what the apply saw). ────────────────────────────────────────────
SP_NAME="ekai-terraform-${ENV}"
OUT_DIR="${REPO_ROOT}/.self-deploy"
SECRETS_FILE="${OUT_DIR}/${ENV}-generated-secrets.txt"

if [[ -f "${SECRETS_FILE}" ]] && grep -q '^ARM_CLIENT_ID=' "${SECRETS_FILE}" 2>/dev/null; then
  echo "==> Reusing the deployer credentials saved by self-deploy.sh (${SECRETS_FILE})."
  export ARM_CLIENT_ID=$(grep '^ARM_CLIENT_ID=' "${SECRETS_FILE}" | cut -d= -f2-)
  export ARM_CLIENT_SECRET=$(grep '^ARM_CLIENT_SECRET=' "${SECRETS_FILE}" | cut -d= -f2-)
  export ARM_TENANT_ID=$(grep '^ARM_TENANT_ID=' "${SECRETS_FILE}" | cut -d= -f2-)
  export ARM_SUBSCRIPTION_ID=$(grep '^ARM_SUBSCRIPTION_ID=' "${SECRETS_FILE}" | cut -d= -f2-)
else
  echo "==> No saved deployer credentials at ${SECRETS_FILE} -- using the currently"
  echo "    logged-in az identity instead (must have Owner on ${RESOURCE_GROUP_NAME})."
fi

# ── 1. Terraform destroy — examples/self-deploy/cicd FIRST ───────────────────
echo
echo "════════ terraform destroy (cicd) ════════"
cd "${REPO_ROOT}/examples/self-deploy/cicd"
terraform init -upgrade -reconfigure -backend-config="../../../env/backend-${ENV}-cicd.tfbackend" 1>/dev/null
terraform destroy -auto-approve -compact-warnings -var-file="../../../env/${ENV}.tfvars"

echo
echo "✓ cicd destroyed for env=${ENV}."

# ── 2. Terraform destroy — examples/self-deploy/root (bootstrap+cluster+platform)
echo
echo "════════ terraform destroy (bootstrap + cluster + platform) ════════"
cd "${REPO_ROOT}/examples/self-deploy/root"
terraform init -upgrade -reconfigure -backend-config="../../../env/backend-${ENV}.tfbackend" 1>/dev/null
if ! terraform destroy -auto-approve -compact-warnings -var-file="../../../env/${ENV}.tfvars"; then
  echo "First destroy attempt failed — waiting 60s then retrying once..."
  sleep 60
  terraform refresh -compact-warnings -var-file="../../../env/${ENV}.tfvars" 2>/dev/null || true
  terraform destroy -auto-approve -compact-warnings -var-file="../../../env/${ENV}.tfvars"
fi

echo
echo "✓ Terraform infrastructure destroyed for env=${ENV}."

# ── Optional: resource group (cascades to the tfstate storage account) ───────
echo
read -rp "Also delete the resource group ${RESOURCE_GROUP_NAME} (tfstate storage account included)? [y/N] " CLEAN_RG </dev/tty
if [[ "${CLEAN_RG}" =~ ^[Yy]$ ]]; then
  echo "==> Deleting ${RESOURCE_GROUP_NAME}..."
  az group delete --name "${RESOURCE_GROUP_NAME}" --yes --no-wait
  # Poll instead of returning right away -- a same-day redeploy of this env
  # name re-runs self-deploy.sh's own `az group create`/`az group show`
  # against this exact resource group, which fails or silently no-ops
  # against one Azure still has mid-delete (provisioningState: Deleting) if
  # we return here before it's actually gone.
  echo "  Waiting for deletion to finish (can take several minutes for a full AKS + networking + Postgres env)..."
  # The deployer SP's own "Owner" grant is scoped to exactly this resource
  # group. Once Azure's delete operation reaches the point of tearing down
  # the RG's own RBAC scope, THIS identity loses the ability to even check
  # `az group exists` on it -- well before the underlying resources are
  # actually gone. Confirmed live: polling as the scoped SP hits a wall of
  # repeated AuthorizationFailed mid-delete, which is a sign the deletion is
  # progressing (it just outran this identity's own visibility), not a
  # stuck/failed deletion. Treat that specific error as success for polling
  # purposes instead of hammering the API with it 60 times.
  DELETED=false
  for i in $(seq 1 60); do
    EXISTS_OUTPUT=$(az group exists --name "${RESOURCE_GROUP_NAME}" 2>&1)
    if [[ "${EXISTS_OUTPUT}" == "false" ]]; then
      echo "  ✓ ${RESOURCE_GROUP_NAME} deleted."
      DELETED=true
      break
    elif echo "${EXISTS_OUTPUT}" | grep -qi "AuthorizationFailed"; then
      echo "  ✓ Lost visibility into ${RESOURCE_GROUP_NAME} -- its own RBAC scope is"
      echo "    being torn down as part of the deletion, which confirms it's actively"
      echo "    progressing (not stuck). Stopping polling here; Azure finishes the"
      echo "    rest in the background regardless of this script watching it."
      DELETED=true
      break
    fi
    sleep 15
  done
  if [[ "${DELETED}" != "true" ]]; then
    echo "  ⚠ Still deleting after 15 minutes -- Azure is still processing it in the"
    echo "    background. Check status: az group show --name ${RESOURCE_GROUP_NAME}"
    echo "    (run that as your own admin account, not the scoped deployer SP, which"
    echo "    may have already lost visibility into this RG per above)."
    echo "    Wait for it to finish before re-running self-deploy.sh with this env name."
  fi
else
  echo "Skipped — the env name (${ENV}) is not reusable until this is run, since the state storage account still exists."
fi

# ── Optional: the deployer Service Principal ──────────────────────────────────
echo
read -rp "Also delete the deployer service principal ${SP_NAME}? [y/N] " CLEAN_SP </dev/tty
if [[ "${CLEAN_SP}" =~ ^[Yy]$ ]]; then
  # az ad sp delete removes an Entra directory object -- it needs an Entra
  # role (e.g. Application Administrator), which a scoped deployer SP never
  # has (it only has Azure RBAC Owner on one resource group). The ARM_*
  # vars above only steer Terraform's own auth; this is a plain `az` CLI
  # call, so it uses whatever identity `az login` is currently on. If that's
  # still a leftover deployer SP from an earlier run (this script's local
  # az CLI identity isn't switched anywhere, so nothing catches this until
  # now), the call fails with a bare "Insufficient privileges" -- confirmed
  # live, 2026-10. Check up front and give an actionable message instead.
  CURRENT_ACCOUNT_TYPE=$(az account show --query user.type -o tsv 2>/dev/null || echo "")
  if [[ "${CURRENT_ACCOUNT_TYPE}" == "servicePrincipal" ]]; then
    echo "  ⚠ az is currently authenticated as a service principal -- it can't delete"
    echo "    Entra app registrations (needs an Entra role, e.g. Application"
    echo "    Administrator, which a scoped deployer SP never has)."
    echo "    Run 'az login' with your admin account, then remove it with:"
    echo "      az ad sp delete --id \$(az ad sp list --display-name ${SP_NAME} --query '[0].appId' -o tsv)"
    echo "    (leaving ${SECRETS_FILE} in place until then)"
  else
    SP_ID=$(az ad sp list --display-name "${SP_NAME}" --query '[0].appId' -o tsv 2>/dev/null || echo "")
    if [[ -n "${SP_ID}" && "${SP_ID}" != "null" ]]; then
      az ad sp delete --id "${SP_ID}"
      echo "  Removed ${SP_NAME}."
    else
      echo "  ${SP_NAME} not found — already removed?"
    fi
    rm -f "${SECRETS_FILE}"
  fi
else
  echo "Skipped."
fi

echo
echo "✓ Done."
