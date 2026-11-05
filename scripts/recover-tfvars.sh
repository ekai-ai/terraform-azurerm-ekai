#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# recover-tfvars.sh  —  rebuild a lost env/<ENV>.tfvars + backend files from state
#
# Usage:  ./scripts/recover-tfvars.sh <ENV> <REGION>
#   ENV     — environment name whose env/<ENV>.tfvars was lost
#   REGION  — Azure region it was deployed into (you already know this -- the
#             state storage account's own name embeds the env but not the
#             region, so there's no way to look the region up without it,
#             similar to AWS's version of this script needing the region as
#             an argument).
#
# What it does:
#   1. Reads the env's combined.tfstate directly from its storage account
#      (ekaiterraform<ENV>) -- if that's gone too, there's nothing left to
#      recover from and this can't help.
#   2. Pulls the one value that can't just come from env/customer.tfvars's
#      own defaults: dns_zone -- subscription_id/region/env_name/
#      resource_group_name are already known (the resource group name is
#      recoverable from the state's own resources too, see below), and
#      everything else in the template (node size, redis toggles,
#      cicd_provider, acme_email, ...) is already a sensible default.
#   3. Writes env/<ENV>.tfvars (starting from customer.tfvars, the values
#      above substituted in) and both backend config files.
#
# You still need to verify the result before trusting it with a destroy --
# run a terraform plan first (see the printed instructions at the end):
# expect no replacements, no large add/destroy counts.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

for bin in az python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' is required but not installed."; exit 1; }
done

ENV="${1:?Usage: $0 <ENV> <REGION>}"
REGION="${2:?Usage: $0 <ENV> <REGION>}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORAGE_ACCOUNT="ekaiterraform${ENV}"
CONTAINER="ekaitfstate"
STATE_FILE="/tmp/${ENV}-combined.tfstate"

echo "==> Fetching ${STORAGE_ACCOUNT}/${CONTAINER}/${ENV}/combined.tfstate ..."
az storage blob download \
  --account-name "${STORAGE_ACCOUNT}" \
  --container-name "${CONTAINER}" \
  --name "${ENV}/combined.tfstate" \
  --file "${STATE_FILE}" \
  --auth-mode login \
  --only-show-errors >/dev/null

echo "==> Extracting values from state..."
VALUES=$(python3 << PYEOF
import json

with open("${STATE_FILE}") as f:
    state = json.load(f)

def find(mod, typ, name):
    for r in state["resources"]:
        if r.get("module", "") == mod and r["type"] == typ and r["name"] == name and r.get("instances"):
            return r["instances"][0]["attributes"]
    return None

dnszone = find("module.infra.module.bootstrap", "azurerm_dns_zone", "main")
dns_zone = dnszone["name"] if dnszone else ""

rg = None
for r in state["resources"]:
    if r["type"] == "azurerm_resource_group" or (r["type"] == "azurerm_dns_zone" and r.get("instances")):
        attrs = r["instances"][0]["attributes"]
        if "resource_group_name" in attrs:
            rg = attrs["resource_group_name"]
            break
if not rg and dnszone:
    rg = dnszone.get("resource_group_name", "")

subscription_id = ""
for r in state["resources"]:
    inst = r.get("instances", [{}])[0]
    provider_key = r.get("provider_config_key", "")
    # Any azurerm-managed resource's id embeds /subscriptions/<id>/...
    rid = inst.get("attributes", {}).get("id", "")
    if rid.startswith("/subscriptions/"):
        subscription_id = rid.split("/")[2]
        break

print(f"{dns_zone}|{rg or ''}|{subscription_id}")
PYEOF
)

IFS='|' read -r DNS_ZONE RESOURCE_GROUP_NAME SUBSCRIPTION_ID <<< "${VALUES}"

if [[ -z "${DNS_ZONE}" ]]; then
  echo "ERROR: couldn't find a managed DNS zone in state -- either this env"
  echo "used manage_dns_zone = false (an existing zone, not Terraform-created),"
  echo "or the state file is from an older layout. Recover dns_zone manually"
  echo "and fill it into a copy of env/customer.tfvars instead."
  exit 1
fi

echo "  region:              ${REGION}"
echo "  dns_zone:            ${DNS_ZONE}"
echo "  resource_group_name: ${RESOURCE_GROUP_NAME:-<not found, left as template default>}"
echo "  subscription_id:     ${SUBSCRIPTION_ID:-<not found, left as template default>}"

TFVARS_OUT="${REPO_ROOT}/env/${ENV}.tfvars"
if [[ -f "${TFVARS_OUT}" ]]; then
  echo "ERROR: ${TFVARS_OUT} already exists -- not overwriting. Delete it first if you want to regenerate."
  exit 1
fi

echo "==> Writing ${TFVARS_OUT}..."
sed \
  -e "s|^subscription_id[[:space:]]*=.*|subscription_id = \"${SUBSCRIPTION_ID:-00000000-0000-0000-0000-000000000000}\"|" \
  -e "s|^region[[:space:]]*=.*|region = \"${REGION}\"|" \
  -e "s|^env_name[[:space:]]*=.*|env_name = \"${ENV}\"|" \
  -e "s|^resource_group_name[[:space:]]*=.*|resource_group_name = \"${RESOURCE_GROUP_NAME:-ekai-saas-${ENV}}\"|" \
  -e "s|^dns_zone[[:space:]]*=.*|dns_zone = \"${DNS_ZONE}\"|" \
  "${REPO_ROOT}/env/customer.tfvars" > "${TFVARS_OUT}"
echo "# Reconstructed from live Terraform state by recover-tfvars.sh -- verify" \
  "with a terraform plan before trusting it with a destroy." \
  | cat - "${TFVARS_OUT}" > "${TFVARS_OUT}.tmp" && mv "${TFVARS_OUT}.tmp" "${TFVARS_OUT}"

echo "==> Writing backend config files..."
cat > "${REPO_ROOT}/env/backend-${ENV}.tfbackend" << EOF
resource_group_name  = "${RESOURCE_GROUP_NAME:-ekai-saas-${ENV}}"
storage_account_name = "${STORAGE_ACCOUNT}"
container_name       = "${CONTAINER}"
key                   = "${ENV}/combined.tfstate"
EOF
cat > "${REPO_ROOT}/env/backend-${ENV}-cicd.tfbackend" << EOF
resource_group_name  = "${RESOURCE_GROUP_NAME:-ekai-saas-${ENV}}"
storage_account_name = "${STORAGE_ACCOUNT}"
container_name       = "${CONTAINER}"
key                   = "${ENV}/cicd.tfstate"
EOF

rm -f "${STATE_FILE}"

echo
echo "✓ Recovered env/${ENV}.tfvars + backend files."
echo "  Now verify before trusting it with a destroy:"
echo "    cd examples/self-deploy/root"
echo "    terraform init -reconfigure -backend-config=../../../env/backend-${ENV}.tfbackend"
echo "    terraform plan -var-file=../../../env/${ENV}.tfvars"
echo "  Expect no '# forces replacement' and no large add/destroy counts."
