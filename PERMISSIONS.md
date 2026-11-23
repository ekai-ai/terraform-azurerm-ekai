# Permissions

`self-deploy.sh` / `self-deploy-destroy.sh` run as two identities.

## 1. Bootstrapping identity (you — `az login`)

Registers resource providers, creates the resource group + Terraform state
storage account, creates the scoped deployer Service Principal, and grants it
its roles. Never runs `terraform apply` itself. Grant it:

```
Owner                              # subscription scope
```

Azure RBAC has no built-in role narrower than Owner that can both create
arbitrary resources (resource group, storage account, resource provider
registration) **and** create role assignments (granting the deployer SP its
Owner-on-one-resource-group, and — only when `purge_vault_on_destroy = true`
— the optional subscription-scoped Key Vault purge role). `Contributor`
cannot create role assignments at all; only `Owner`/`User Access
Administrator` can. `Contributor` + `User Access Administrator` together is
equivalent and works too, if Owner itself is undesirable.

No Entra ID directory role is required for the normal case. `az ad sp
create-for-rbac` (creating the deployer SP) only needs a special Entra role
(e.g. **Application Developer**) if your tenant's default "Users can
register applications" setting has been turned off — by default every Entra
user can register an app and becomes its owner, which is exactly the
delegated, signed-in context this script runs `az login` as (unlike a
service-principal/app-only caller, where that same default setting is NOT
honored — see `modules/key_vault/main.tf`'s header for why ESO's own
identity deliberately avoids an Entra app registration entirely, using a
user-assigned managed identity instead, needing only Azure RBAC).

## 2. Deployer SP (`ekai-terraform-<env>`)

Created by the bootstrapping identity; runs Terraform for everything else.
Auto-granted by `self-deploy.sh` — nothing to configure, reference only:

```
Owner                               # scoped to ONE resource group (this env's)
```

`Owner`, not `Contributor`, because this repo's own Terraform creates
`azurerm_role_assignment` resources (Key Vault RBAC, ACR AcrPull, DNS Zone
Contributor, the ESO/cert-manager managed identities' Key Vault role, ...) —
`Contributor` alone cannot create or modify role assignments. No Entra ID
directory role: ESO's and cert-manager's workload identities are plain
user-assigned managed identities (`modules/key_vault`, `modules/cluster`),
not Entra app registrations/service principals.

Optional, only when `purge_vault_on_destroy = true` in the target env's
tfvars (internal fast destroy/reapply test loops — never the customer
default, see that variable's description in `variables.tf`):

```
Ekai Key Vault Purge (self-service)  # custom role, subscription scope
  Microsoft.KeyVault/locations/deletedVaults/read
  Microsoft.KeyVault/locations/deletedVaults/purge/action
```

This needs subscription scope, not resource-group scope, because
`Microsoft.KeyVault/locations/deletedVaults` is a region-level collection —
its ARM ID has no resource-group segment anywhere in it, so purge rights can
only ever be granted at subscription scope or higher. Rather than hand the
deployer SP a broad built-in role at that scope, `self-deploy.sh` creates
this two-Action custom role and grants only that.

## Where each permission is used

| Permission | Where | Why |
|---|---|---|
| `Owner` (bootstrapping identity, subscription) | `self-deploy.sh` Step 1 | `az provider register` for the resource providers Terraform needs (`Microsoft.ContainerService`, `Microsoft.KeyVault`, `Microsoft.DBforPostgreSQL`, ...) |
| | `self-deploy.sh` Step 2, `init-state-backend.sh` | `az group create` for the env's resource group |
| | `init-state-backend.sh` | `az storage account create` for the Terraform state backend, then `az role assignment create` granting itself `Storage Blob Data Contributor` on that one storage account (the `azurerm` backend authenticates via Azure AD, not an access key) |
| | `self-deploy.sh` Step 3 | `az ad sp create-for-rbac` / `credential reset` for the deployer SP (Entra default setting, not this RBAC role, is what actually gates this — see above) |
| | `self-deploy.sh` Step 3 | `az role assignment create` granting the deployer SP `Owner` on the resource group |
| | `self-deploy.sh` Step 3 (optional) | `az role definition create` + `az role assignment create` for the Key Vault purge role, subscription scope, only when `purge_vault_on_destroy = true` |
| `Owner` (deployer SP, one resource group) | both Terraform applies (`examples/self-deploy/{root,cicd}`) | everything the repo provisions: VNet, AKS, PostgreSQL, Key Vault + its RBAC, ACR + AcrPull, DNS zone, the UAMIs for ESO/cert-manager, ArgoCD, ... |
| Key Vault purge role (deployer SP, subscription, optional) | `terraform destroy` via the `azurerm` provider's `purge_soft_delete_on_destroy` feature flag | purges the soft-deleted vault immediately on destroy instead of leaving it in Azure's normal 7-day soft-delete window |

## Why Owner, not a narrower custom role, for the bootstrapping identity

Unlike AWS/GCP, Azure's RBAC role catalog has no built-in role scoped to
"can create role assignments" without also being `Owner`/`User Access
Administrator`, and no built-in role scoped to just "can register these N
resource providers and create a resource group and a storage account." A
tighter custom role is possible in principle (list the exact `*/write` and
`Microsoft.Authorization/roleAssignments/write` actions this script's `az`
calls actually use), but — unlike AWS's two IAM policies, which `self-
deploy.sh` generates and manages for you — Azure has no equivalent
"create/version a custom role automatically" step in this repo today; it
would need to be hand-authored and kept in sync with this file. Flagged
here rather than silently asking for Owner's full breadth without
explanation.

## `self-deploy-destroy.sh` needs the bootstrapping identity too

Unlike `self-deploy.sh`, the destroy script never switches the local `az`
CLI identity itself — it only sets `ARM_*` env vars for Terraform (reusing
the deployer SP's saved credentials when present). `az group delete` and
`az ad sp delete` at the end are plain `az` CLI calls, so they run as
whatever `az login` identity is already active. Run this script logged in
as the same bootstrapping identity as `self-deploy.sh` (`Owner`,
subscription scope) — not as a leftover deployer SP from a previous run
(confirmed live: `az ad sp delete` fails with "Insufficient privileges" in
that case, since a scoped deployer SP has no Entra role, only `Owner` on one
resource group). `az group delete` would still succeed in that case (Owner
on that one resource group is enough), but `az ad sp delete` needs to be the
app's owner or hold an Entra role like Application Administrator — the
bootstrapping identity already has this by virtue of having created the app
in the first place (see the Entra default-setting note above).
