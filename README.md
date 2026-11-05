# terraform-azurerm-ekai

Deploy Ekai into **your own Azure subscription**. One script provisions the
VNet, an AKS cluster, PostgreSQL Flexible Server, in-cluster Redis/Neo4j/MinIO,
ArgoCD, and the `ekai-saas` Helm chart — everything needed for a working Ekai
install.

For how this repo is structured internally (why there are 2 Terraform
applies, the module layout), see [ARCHITECTURE.md](https://github.com/ekai-ai/terraform-azurerm-ekai/blob/main/ARCHITECTURE.md). This
doc only covers deploying it. Prefer consuming it directly as a module
instead of `self-deploy.sh`? See
[Using this as a Terraform Registry module](#using-this-as-a-terraform-registry-module)
below.

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli),
  authenticated (`az login`) — see [PERMISSIONS.md](https://github.com/ekai-ai/terraform-azurerm-ekai/blob/main/PERMISSIONS.md) for
  exactly what this identity needs
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.7
- `kubectl`, `jq`, `dig`
- A domain you can either delegate a subdomain of to Azure DNS, or that
  already has an Azure DNS zone

## Deploy

```bash
git clone https://github.com/ekai-ai/terraform-azurerm-ekai.git
cd terraform-azurerm-ekai
cp env/customer.tfvars env/<name>.tfvars
```

`<name>` is your choice (e.g. client name) — it's both the filename and the
argument to `self-deploy.sh` below. Set `env_name` inside the file to the
same value. Don't edit `env/customer.tfvars` directly — it's the shared
template.

**Required:** edit `env/<name>.tfvars` and set at minimum `subscription_id`,
`region`, `env_name`, `resource_group_name`, `dns_zone`, `acme_email` —
`self-deploy.sh` won't work with placeholder values. Every variable has an
inline comment; worth a second look before your first deploy:

| Variable | What it controls |
|---|---|
| `subscription_id` | Azure subscription everything is created in |
| `region` | Azure region everything is created in — confirm it supports the availability zones you intend to use (see Troubleshooting) |
| `env_name` | Unique name embedded in every resource this creates — must be unique per deployment |
| `resource_group_name` | Resource group everything lives in — created by `scripts/init-state-backend.sh`, not by this script directly |
| `dns_zone` | Domain this deploys under (`portal.<dns_zone>`, `argocd.<dns_zone>`, ...) |
| `acme_email` | Email for Let's Encrypt certificate notifications — cert-manager's ACME account registration fails without a real one |

Full reference (every variable, every default): [ARCHITECTURE.md](https://github.com/ekai-ai/terraform-azurerm-ekai/blob/main/ARCHITECTURE.md),
`variables.tf` and `cicd/variables.tf`.

```bash
./scripts/self-deploy.sh <name>
```

The argument to `self-deploy.sh` must match the tfvars filename in `env/`
(without `.tfvars`) — i.e. whatever you named the copy above. Use a real,
unique `env_name` value if you're deploying more than once — every Azure
resource this creates embeds `env_name` in its name, so re-running with the
same value modifies the *same* infrastructure rather than creating a second
one.

`self-deploy.sh` registers the required Azure resource providers, creates
the resource group, creates the scoped deployer Service Principal Terraform
needs, initializes the Terraform state backend, then runs both
`terraform apply`s for you after one confirmation (it creates real, billable
Azure resources).

## After a successful deploy

The app secret (`ekai-<env_name>` in the deployment's Key Vault, e.g.
`ekai-customer`) ships with a `REPLACE_ME` placeholder for the one thing the
app needs a real value for out of the box: AWS SES credentials for signup
invite emails (used regardless of which cloud hosts the cluster — there's no
Azure-native equivalent in the app). Fill them in with one command — replace
the `...` values below with real ones (an AWS IAM user with SES send access
is enough — self-service uses in-cluster MinIO for file storage, so no S3
access is needed on that IAM user):

```bash
VAULT=<key_vault_name output>
NEW_VALUE=$(az keyvault secret show --vault-name "${VAULT}" --name ekai-customer --query value -o tsv | jq '
    .AWS_ACCESS_KEY_ID = "..." |
    .AWS_SECRET_ACCESS_KEY = "..." |
    .SES_AWS_REGION = "..." |
    .AWS_SES_FROM_EMAIL = "..."
  ')
az keyvault secret set --vault-name "${VAULT}" --name ekai-customer --value "${NEW_VALUE}"
```

(`<key_vault_name output>` is the real vault name — see `terraform output
key_vault_name` below.) The app picks up the new secret automatically within
about a minute (ESO syncs it into the cluster, Reloader restarts the
affected pods) — no `terraform apply` needed for this step.

Optional — check the ArgoCD URL/password, Azure DNS nameservers, portal URL,
and Key Vault name:

```bash
terraform output -C examples/self-deploy/root
terraform output -C examples/self-deploy/cicd
```

## Tearing down

```bash
./scripts/self-deploy-destroy.sh <name>
```

Destroys everything this created, with confirmation prompts at each
destructive stage. Safe to re-run if it fails partway (it retries once
automatically on the first failure).

**Lost `env/<name>.tfvars`?** `self-deploy-destroy.sh` notices it's missing,
asks for the Azure region it was deployed into, and rebuilds it (and its
backend config files) straight from the Terraform state storage account
before continuing — as long as that storage account still exists, nothing
is actually lost. Run `./scripts/recover-tfvars.sh <name> <region>` directly
instead if you want to check the recovered values (with a `terraform plan`)
before trusting them with a destroy.

By default, a destroyed Key Vault is left **soft-deleted** for Azure's
normal 7-day window rather than purged immediately — re-running
`self-deploy.sh` with the same `env_name` inside that window reuses the
existing (empty) soft-deleted vault automatically. If you need the vault
name free again sooner (e.g. a fast destroy/reapply test loop), set
`purge_vault_on_destroy = true` in that env's tfvars before destroying — see
the variable's description in `variables.tf` and
[PERMISSIONS.md](https://github.com/ekai-ai/terraform-azurerm-ekai/blob/main/PERMISSIONS.md) for the extra subscription-scoped role this
requires. Not something to ask a real customer to grant.

## Troubleshooting

**`AvailabilityZoneNotSupported`** — the target region/subscription
combination doesn't have all three availability zones available (common on
smaller or trial subscriptions). Set `zones = ["1"]` (or whichever zone
numbers `az vm list-skus --location <region> --query "[?name=='<vm_size>'].locationInfo[].zones" -o tsv`
actually reports) in that env's tfvars, and `enable_ha = false` — Azure
Postgres Flexible Server's zone-redundant HA needs 2+ zones.

**`InsufficientVCPUQuota` / cluster-autoscaler stuck in `Backoff` with
`exceeding approved Total Regional Cores quota`** — a subscription-wide
vCPU cap, not specific to any one region (the same limit applies across all
regions on a given subscription — switching region does not help). Request
a quota increase for "Total Regional vCPUs" in the Azure Portal (often
auto-approved within minutes on a pay-as-you-go subscription), or lower
`app_vm_size`/`vm_size` and raise `app_node_pool_max_count` in that env's
tfvars so more, smaller nodes fit in the existing budget.

**`context deadline exceeded` / `TLS handshake timeout` on the first
Helm releases (`nginx_ingress`, `argocd`, `minio`, ...) right after a fresh
AKS cluster comes up** — a brief, non-deterministic window where
`azurerm_kubernetes_cluster` reports `Succeeded` but the API server can't
yet reliably answer heavy calls (Helm's pre-install schema discovery is one).
Already worked around in code (`time_sleep.wait_for_aks_api_propagation`,
`modules/cluster/main.tf`) — if it still happens, the Helm release is often
left in `failed` status, which blocks a retry's fresh install with "cannot
re-use a name that is still in use." Clear it first:

```bash
helm uninstall <name> -n <namespace>   # e.g. argocd -n argocd, minio -n minio
```

then re-run `self-deploy.sh`.

**"Insufficient privileges to complete the operation" partway through
`self-deploy.sh`/`self-deploy-destroy.sh`** — your local `az` CLI is almost
always still authenticated as a *previous* run's scoped deployer Service
Principal (it only has `Owner` on that one run's resource group, nothing
else — `az login --service-principal` persists across separate script
invocations). Check with `az account show --query user.type` — if it says
`servicePrincipal` instead of `user`, run `az login` with your own admin
account and retry. `self-deploy.sh` fails fast with this exact diagnosis at
startup; `self-deploy-destroy.sh`'s optional service-principal-deletion step
does the same.

**Let's Encrypt certificate stuck `Ready: False`, even well after deploy
finished** — almost always DNS delegation for a newly-created zone not being
complete yet (`self-deploy.sh` prints the required nameservers and waits up
to 10 minutes, but delegation at your registrar can take longer).
`self-deploy.sh` already retries once in place (clears any stuck ACME Order,
restarts the cert-manager controller) before giving up — if delegation
finishes after that, clear it the same way by hand:

```bash
kubectl delete order -n cert-manager --all
kubectl delete pod -n cert-manager -l app.kubernetes.io/component=controller
```

then check `kubectl get certificate <tls_name output> -n cert-manager`.

**`Error acquiring the state lock`** — a previous apply/destroy crashed or
got interrupted after taking the lock but before releasing it (the state
file itself may already be fully up to date). Confirm nothing is actually
still running, then `terraform force-unlock <lock ID>` (the ID is printed
in the error) from whichever directory the error came from.

**Lost `env/<name>.tfvars`** — see `./scripts/recover-tfvars.sh` under
[Tearing down](#tearing-down).

## Using this as a Terraform Registry module

**Not usably published yet.** The Terraform Registry derives a module's
provider name strictly from its GitHub repo name
(`terraform-<PROVIDER>-<NAME>`, no manual override in the publish flow).
This repo was originally named `terraform-azure-ekai` and got auto-published
under the nonexistent provider `azure` (not `azurerm`, the real Terraform
provider) as a result — that stale listing is live at
[registry.terraform.io/modules/ekai-ai/ekai/azure](https://registry.terraform.io/modules/ekai-ai/ekai/azure)
but unusable, since nothing can actually reference provider `azure`. The
repo has since been renamed to `terraform-azurerm-ekai` to fix this going
forward, but a fresh tag push is still needed to get a correctly-provider-named
`ekai-ai/ekai/azurerm` listing published — the old `azure` one won't migrate
on its own and should be unpublished once the new one exists.

```hcl
module "infra" {
  source  = "registry.terraform.io/ekai-ai/ekai/azurerm"
  version = "~> 0.1"

  subscription_id = "00000000-0000-0000-0000-000000000000"
  region          = "northeurope"
  env_name        = "acme"
  # ...every variable in variables.tf
}

module "cicd" {
  source  = "registry.terraform.io/ekai-ai/ekai/azurerm//cicd"
  version = "~> 0.1"
  # ...every variable in cicd/variables.tf, plus the values module.infra
  # exports that cicd needs (see examples/self-deploy/cicd/main.tf for
  # exactly which — with a registry module you'd normally wire these with
  # module.infra.X directly if both modules live in the same config, instead
  # of examples/self-deploy's terraform_remote_state indirection, which only
  # exists because self-deploy.sh's 2-apply split needs an actual state
  # boundary between them)
}
```

See [ARCHITECTURE.md](https://github.com/ekai-ai/terraform-azurerm-ekai/blob/main/ARCHITECTURE.md) for why this is 2 separate applies
and the full module layout.
