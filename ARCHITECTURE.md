# Architecture

For how to actually deploy this, see [README.md](README.md). This doc
covers how the repo is structured and why, for anyone modifying it or
consuming it a different way than `self-deploy.sh`.

## Why 2 Terraform applies, not 1

This repo has 2 layers:

- **The modules** — the repo root (this directory) and `cicd/` are plain,
  reusable Terraform modules: no `backend` block, nothing applied directly.
  The repo root wires up the `bootstrap`, `cluster`, and `platform`
  submodules into one apply's worth of resources; `cicd/` wires up
  `modules/cicd` (ExternalSecrets, the shared app identity, and the ArgoCD
  Application that actually deploys the app).
- **The root configs** — `examples/self-deploy/root/` and
  `examples/self-deploy/cicd/` are the actual state-holding configs that
  call those two modules and get applied. `examples/self-deploy/cicd/`
  reads `examples/self-deploy/root/`'s state via `terraform_remote_state`.

Why 2 applies and not 1: the ArgoCD Terraform provider's `password` field
has to be a value Terraform already knows *before* it starts applying — it
can't be a same-apply resource's computed attribute (unlike the
kubernetes/helm/kubectl providers, whose auth can safely be configured from
AKS's own same-apply `client_certificate`/`client_key` outputs). The root
config generates that password; `cicd/` has to run afterward, as its own
apply, to read it back safely. See `cicd/main.tf`'s header comment for the
full explanation.

Unlike the original `devops/azure-terraform` this was ported from (4
separate layers — `01-bootstrap`/`02-cluster`/`03-platform`/`04-cicd`, each
its own state), `bootstrap`+`cluster`+`platform` are combined into this one
apply. That's possible because self-service generates everything itself
(Key Vault, DB credentials, ArgoCD credentials) in the same apply that needs
them — the original 4-layer split existed to let a human pre-seed a
master Key Vault secret between layers, which self-service has no reason to
do.

## Manual deploy (without self-deploy.sh)

```bash
./scripts/init-state-backend.sh <name>

cd examples/self-deploy/root
terraform init -backend-config=../../../env/backend-<name>.tfbackend
terraform apply -var-file=../../../env/<name>.tfvars

cd ../cicd
terraform init -backend-config=../../../env/backend-<name>-cicd.tfbackend
terraform apply -var-file=../../../env/<name>.tfvars
```

To destroy manually: `terraform destroy` in `examples/self-deploy/cicd/`
first (it needs the cluster/ArgoCD from the root apply still live to clean
up against), then in `examples/self-deploy/root/`.

## Using this as a Terraform Registry module

The repo root and `cicd/` are structured as ordinary Terraform modules, so
once this repo is connected to the Terraform Registry (a one-time manual
step someone with access to the registry/repo settings has to do — publish
the repo, then push a semver tag; **this does not work until that's been
done**), you can consume them directly instead of using
`examples/self-deploy/`:

```hcl
module "infra" {
  source  = "registry.terraform.io/ekai-ai/ekai/azurerm"
  version = "~> 0.1"

  subscription_id = "00000000-0000-0000-0000-000000000000"
  region          = "northeurope"
  env_name        = "<your-name>"
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

`examples/self-deploy/` is the reference implementation of exactly this
pattern (plus the backend/provider wiring a real deployment needs) — read it
before writing your own. Note that `provider "azurerm"/"kubernetes"/etc.`
are configured *inside* root/cicd themselves (not left for the consumer to
supply) — a registry consumer can't override provider configuration via
`providers = {}`.

## Layout

```
main.tf / variables.tf / outputs.tf / providers.tf   # "infra" module (bootstrap+cluster+platform) — no backend, not applied directly
cicd/
  main.tf / variables.tf / outputs.tf / providers.tf  # "cicd" module — no backend, not applied directly
examples/self-deploy/
  root/    # actual root config wrapping the "infra" module — backend + required_providers + module "infra" { source = "../../.." }
  cicd/    # actual root config wrapping the "cicd" module — backend + required_providers + module "cicd" { source = "../../../cicd" }
modules/
  bootstrap/        # DNS zone
  cluster/          # VNet, AKS, PostgreSQL Flexible Server, Key Vault (+ ESO/cert-manager UAMIs), ACR
  platform/         # wires nginx-ingress, cert-manager, external_secrets (ESO controller), redis, neo4j, minio, argocd, reloader together
  cert-manager/     # cert-manager Helm release, ClusterIssuers (DNS-01 via Azure DNS, UAMI-authenticated), wildcard Certificate, reflector
  cicd/             # ExternalSecret (app secret sync), the shared app Workload Identity, wires microservices_CD + github_action
  microservices_CD/ # the ArgoCD Application that deploys the ekai-saas chart, wildcard DNS A record
  key_vault/        # Key Vault resource + RBAC + ESO/cert-manager federated identities — see its own header for why UAMI, not an Entra app
  app_workload_identity/   # per-service Workload Identity (UAMI + federated credential), wired by cicd/
  <shared low-level modules used by the above: vnet, aks, log_analytics, postgresql_server, acr, acr_image_mirror, redis, neo4j, minio, argocd, reloader, nginx_ingress, external_secrets, github_action>
env/
  customer.tfvars   # template — copy and fill in; shared by both applies
scripts/
  self-deploy.sh            # resource-provider registration + SP setup + both terraform applies, guided
  self-deploy-destroy.sh     # both terraform destroys + optional cleanup
  init-state-backend.sh      # creates the Terraform state storage account + both backend configs
  recover-tfvars.sh          # rebuilds a lost env/<name>.tfvars from Terraform state
```

## Why a User-Assigned Managed Identity, not an Entra app registration

ESO's and cert-manager's workload identities (`modules/key_vault`,
`modules/cluster`) are plain `azurerm_user_assigned_identity` +
`azurerm_federated_identity_credential` resources — not an
`azuread_application`/`azuread_service_principal` pair, which is what the
equivalent AKS Workload Identity setup more commonly looks like elsewhere.
This is a deliberate choice for a customer-facing self-service repo: a UAMI
is a plain ARM resource needing only Azure RBAC (the deployer SP's
resource-group `Owner`, already required for everything else this repo
creates) — it asks nothing of the customer's Entra ID tenant. An Entra app
registration would additionally need either the customer's tenant to allow
self-service app registration (a default Entra setting some organizations
turn off) or an explicit Entra directory role grant — a meaningfully bigger,
compliance-sensitive ask for a SaaS install script to make of a new
customer's identity tenant. See `modules/key_vault/main.tf`'s header for the
full reasoning, including why this specifically fails for an app-only
(service-principal) caller even when the app registration setting is
otherwise permissive.

## Known Azure-specific operational realities

- **KEDA is not Helm-installed here**, unlike `terraform-aws-ekai`/
  `terraform-google-ekai`'s platform modules. AKS already runs KEDA as a
  native managed add-on whenever `workload_autoscaler_profile.keda_enabled =
  true` is set on the cluster (`modules/aks/main.tf`). A second,
  separately-Helm-installed KEDA collides with AKS's own `aks-managed-keda`
  release over cluster-scoped CRDs and fails outright — confirmed live.
  EKS/GKE have no equivalent native integration, which is why those two
  self-service distributions install it themselves.
- **Availability zones and regional vCPU quota are subscription-specific,
  not universal.** Not every region/subscription combination offers all
  three zones for every VM size, and vCPU quota (especially on newer or
  trial subscriptions) can be tight enough that even the modest default
  node counts don't fit. Both fail the apply with a clear Azure error
  (`AvailabilityZoneNotSupported`, `InsufficientVCPUQuota`) rather than
  silently degrading — see the README's Troubleshooting section for the
  tfvars knobs to adjust.
- **A freshly-created AKS control plane can briefly reject heavy calls**
  even after `azurerm_kubernetes_cluster` reports `Succeeded` — Helm's
  pre-install OpenAPI schema discovery is a common trigger. Worked around
  with `time_sleep.wait_for_aks_api_propagation` in `modules/cluster/main.tf`
  (60s, non-deterministic — doesn't reproduce on every apply).
- **Key Vault purge of a soft-deleted vault needs subscription scope,
  never narrower** — `Microsoft.KeyVault/locations/deletedVaults` is a
  region-level collection with no resource-group segment in its ARM ID.
  `purge_vault_on_destroy` (default `false`) keeps the deployer SP's
  footprint to resource-group `Owner` only; opting in grants one narrow
  custom role at subscription scope instead of a broad built-in one — see
  [PERMISSIONS.md](PERMISSIONS.md).

## Scope

Only the self-service path (`cicd_provider = "none"`) is supported in this
distribution. `cicd_provider = "github_actions"` is declared (so the
variable still validates against the same values the internal
`devops/azure-terraform` codebase accepts) but not functional here —
`modules/github_action` and the OIDC/manifest-branch variables it needs
aren't wired up for a self-service deploy.

## Variable reference

Every variable in `variables.tf` and `cicd/variables.tf` — the README's
table only covers the handful worth a second look. `subscription_id`/
`region`/`env_name`/`resource_group_name`/`dns_zone` are declared in both
files identically.

### Identity / shared

| Variable | Default | What it controls |
|---|---|---|
| `subscription_id` | — (required) | Azure subscription ID — same for every submodule |
| `region` | — (required) | Azure region — must match the resource group's region |
| `env_name` | — (required) | Environment slug (e.g. `client1`, `qa`, `prod`) — used in resource names and tags |
| `resource_group_name` | — (required) | Pre-existing resource group, created out-of-band by `scripts/init-state-backend.sh` |
| `dns_zone` | — (required) | DNS zone for this env, e.g. `client1.ekai.ai` |
| `manage_dns_zone` | `true` | `true` → the bootstrap submodule creates the DNS zone; `false` to use an existing one |
| `cicd_provider` | `"none"` | `"none"` (supported) / `"github_actions"` (not functional here) |
| `namespace` | `"ekai-saas"` | Kubernetes namespace where app workloads run |
| `secrets_name` | `null` → `"ekai-<env_name>"` | Master Key Vault secret holding every app env var |
| `key_vault_name` | `null` → derived, truncated to 24 chars | Key Vault name — globally unique within Azure |
| `tls_name` | `null` → `"<env_name>-ekai-wildcard-tls"` | K8s Secret name holding the wildcard TLS cert |
| `rbac_principal_ids` | `[]` | Extra object IDs granted Key Vault Secrets Officer + DNS Zone Contributor (e.g. break-glass admin access) |
| `purge_vault_on_destroy` | `false` | See [PERMISSIONS.md](PERMISSIONS.md) — leave `false` for real customers |

### Networking / AKS

| Variable | Default | What it controls |
|---|---|---|
| `vnet_cidr` | `"10.0.0.0/16"` | VNet CIDR |
| `pub_sub_1_a_cidr` / `pri_sub_1_cidr` / `pri_sub_2_cidr` / `pri_sub_3_cidr` | `/24`, three `/22`s | Public + 3 private subnet CIDRs |
| `cluster_name` | — (required) | AKS cluster name |
| `cluster_version` | — (required) | Kubernetes version |
| `sku_tier` | `"Standard"` | AKS pricing tier — `Free` has no uptime SLA |
| `zones` | `["1", "2", "3"]` | Availability zones for both node pools — not every region/subscription supports all three, see Troubleshooting in the README |
| `vm_size` | — (required) | System node pool VM size |
| `system_node_pool_min_count` / `max_count` | `1` / `3` | System node pool autoscaling range |
| `app_vm_size` | — (required) | App (user) node pool VM size — needs enough CPU/memory for the whole app stack |
| `app_node_pool_min_count` / `max_count` | — (required) | App node pool autoscaling range |
| `log_analytics_workspace_name` | — (required) | Log Analytics workspace name for AKS's `oms_agent` |
| `create_acr` | `true` | `true` → create an ACR + grant AcrPull to the AKS kubelet; `false` → use `existing_acr_name` |
| `existing_acr_name` | `null` | Required when `create_acr = false` |

### PostgreSQL Flexible Server

| Variable | Default | What it controls |
|---|---|---|
| `postgresql_version` | `"15"` | PostgreSQL major version |
| `postgres_flexible_server_sku_name` | `"GP_Standard_D2s_v3"` | Must be General Purpose/Memory Optimized for `enable_ha` to be offered at all — Burstable tiers don't support zone-redundant HA |
| `postgres_flexible_server_storage_mb` | `65536` | Allocated storage, MB |
| `enable_ha` | `true` | Zone-redundant standby — roughly doubles cost; needs 2+ available zones |
| `geo_redundant_backup_enabled` | `true` | Cross-region backup copy — roughly doubles backup storage cost |

### Platform submodule (ingress, cert-manager, ESO, Redis, Neo4j, MinIO, ArgoCD)

| Variable | Default | What it controls |
|---|---|---|
| `argocd_namespace` | `"argocd"` | ArgoCD's namespace |
| `argocd_admin_password_hashed` | `""` | Bcrypt hash; ignored for self-service (generated directly instead) |
| `acme_email` | — (required) | Let's Encrypt registration email — ACME account registration fails without a real one |
| `cluster_issuer_name` | `"letsencrypt-prod"` | Switch to `"letsencrypt-staging"` in throwaway test envs to avoid the production rate limit (5 duplicate certs/week per domain) |
| `eso_chart_version` | `"0.10.7"` | External Secrets Operator chart version |
| `redis_namespace` / `redis_chart_version` | `"redis"` / `"24.1.0"` | Redis namespace + Bitnami chart version — always deployed, no toggle (ERD/KEDA need it) |
| `redis_replica_count` | `3` | Redis read-replica pod count |
| `redis_persistence_size` / `redis_storage_class` | `"8Gi"` / `"managed-premium"` | Redis PVC sizing |
| `neo4j_namespace` / `neo4j_chart_version` | `"neo4j"` / `"5.26.0"` | Neo4j namespace + chart version — always deployed, no toggle |
| `neo4j_storage_size` / `neo4j_storage_class` | `"20Gi"` / `"managed-premium"` | Neo4j PVC sizing |
| `neo4j_memory_request` / `_limit`, `neo4j_cpu_request` / `_limit` | `"2Gi"`/`"4Gi"`, `"500m"`/`"2"` | Neo4j pod sizing |
| `minio_namespace` / `minio_chart_version` | `"minio"` / `"17.0.21"` | MinIO namespace + Bitnami chart version |
| `minio_replicas` / `minio_mode` | `4` / `"distributed"` | MinIO replica count + mode — 4 replicas × 50Gi default = 200Gi total storage |
| `minio_persistence_size` / `minio_storage_class` | `"50Gi"` / `"managed-premium"` | MinIO PVC sizing |
| `minio_default_buckets` | `["ekai-files"]` | Buckets created on first install |
| `minio_host` | `null` → `"minio.<dns_zone>"` | MinIO ingress hostname |
| `reloader_chart_version` | `"1.2.0"` | Stakater Reloader chart version — restarts pods when K8s Secrets change |
| `secret_value_overrides` | `{}` | Escape hatch to override any individual key in the master Key Vault secret |

### `cicd/variables.tf` — self-service app config

| Variable | Default | What it controls |
|---|---|---|
| `shared_service_account_name` | `"ekai-app-sa"` | ServiceAccount every service runs as — must match the `ekai-saas` chart's `serviceAccountName` |
| `existing_image_registry_base_url` | `""` | Where container images are pulled from — also the chart's `imageRegistry` |
| `image_tag` | `"latest"` | Image tag deployed — passed through as the chart's `imageTag` |
| `helm_chart_repo_url` | `""` | OCI registry the `ekai-saas` chart is published to — bare host+path, no `oci://` prefix |
| `helm_chart_version` | `"*"` | Chart version — `"*"` auto-tracks latest via ArgoCD, no apply needed per release |
| `ingress_class_name` | `"nginx"` | Ingress controller class |

### `cicd/variables.tf` — not functional in this distribution

Declared (so `cicd_provider` still validates) but inert — `github_owner`,
`manifests_reponame`, `manifests_branch`, `manifests_path`, `cd_repos`,
`registries`, `dockerhub_username`, `dockerhub_token`,
`aws_ecr_access_key_id`, `aws_ecr_secret_access_key`. These back the
`github_actions` CI/CD path, which this distribution doesn't support.
