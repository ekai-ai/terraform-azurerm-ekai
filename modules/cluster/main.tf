# ──────────────────────────────────────────────────────────────────────────
# cluster submodule — VNet, AKS, PostgreSQL, Key Vault, ACR
# ──────────────────────────────────────────────────────────────────────────
# Ported from devops/azure-terraform's 02-cluster. Key differences from the
# source codebase:
#   • Key Vault is now CREATED here (module.key_vault owns the resource) —
#     not read via a data source against a client-pre-seeded vault. See
#     modules/key_vault's file header.
#   • DB credentials: self-service (cicd_provider = "none") generates them
#     directly via random_password, matching terraform-aws-ekai/terraform-
#     google-ekai's self_service branch exactly. Non-self-service still
#     reads them from the master Key Vault secret (var.secrets_name) — since
#     the vault is now created in THIS SAME apply rather than pre-existing,
#     a non-self-service deploy needs a two-step apply: first apply creates
#     the empty vault (e.g. `terraform apply -target=module.cluster.module.key_vault`),
#     the client seeds var.secrets_name with DB creds + github_token/
#     username/email, then a full `terraform apply` proceeds normally. This
#     mirrors the original codebase's own manual pre-seeding step (see
#     docs/CLIENT-ONBOARDING-AZURE.md in devops/azure-terraform) -- just
#     shifted one step later now that bootstrap+cluster+platform share a
#     state instead of Key Vault being client-managed infrastructure.
# ──────────────────────────────────────────────────────────────────────────

locals {
  common_tags = merge(var.tags, {
    env       = var.env_name
    layer     = "cluster"
    managedBy = "terraform"
  })
  self_service = var.cicd_provider == "none"
}

# ── Networking ──────────────────────────────────────────────────────────────
module "log_analytics_workspace" {
  source              = "../log_analytics"
  name                = var.log_analytics_workspace_name
  region              = var.region
  resource_group_name = var.resource_group_name
  solution_plan_map   = var.solution_plan_map
  tags                = local.common_tags
}

module "vnet" {
  source              = "../vnet"
  region              = var.region
  cluster_name        = var.cluster_name
  resource_group_name = var.resource_group_name
  vnet_cidr           = var.vnet_cidr
  pub_sub_1_a_cidr    = var.pub_sub_1_a_cidr
  pri_sub_1_cidr      = var.pri_sub_1_cidr
  pri_sub_2_cidr      = var.pri_sub_2_cidr
  pri_sub_3_cidr      = var.pri_sub_3_cidr
  tags                = local.common_tags
}

# Wait for the Log Analytics workspace to fully propagate through Azure ARM
# before AKS tries to attach its `oms_agent` to it. Without this, AKS's
# OperationalInsights lookup races the LA workspace's regional replication
# and fails with `ResourceNotFound: Microsoft.OperationalInsights/workspaces/...`
# even though the workspace was successfully created seconds earlier.
# 60s is empirically safe; 30s is borderline in some regions.
resource "time_sleep" "wait_for_la_workspace_propagation" {
  depends_on      = [module.log_analytics_workspace]
  create_duration = "60s"
}

# ── AKS ─────────────────────────────────────────────────────────────────────
module "aks" {
  source                     = "../aks"
  cluster_name               = var.cluster_name
  region                     = var.region
  vm_size                    = var.vm_size
  cluster_version            = var.cluster_version
  sku_tier                   = var.sku_tier
  zones                      = var.zones
  vnet_subnet_id             = module.vnet.private_subnet_ids
  resource_group_name        = var.resource_group_name
  log_analytics_workspace_id = module.log_analytics_workspace.id
  system_node_pool_min_count = var.system_node_pool_min_count
  system_node_pool_max_count = var.system_node_pool_max_count
  app_vm_size                = var.app_vm_size
  app_node_pool_min_count    = var.app_node_pool_min_count
  app_node_pool_max_count    = var.app_node_pool_max_count
  dns_zone                   = var.dns_zone
  env_name                   = var.env_name
  workspace_name             = module.log_analytics_workspace.workspace_name
  tags                       = local.common_tags
  # Explicit dependency on the propagation wait — the implicit one via
  # `log_analytics_workspace_id` isn't enough; Terraform considers the value
  # known as soon as the LA workspace resource returns, but Azure's AKS RP
  # can't query it for ~60s after that.
  depends_on = [time_sleep.wait_for_la_workspace_propagation]
}

# Wait for AKS's API server to actually become reliably reachable before the
# platform submodule's kubernetes/helm/kubectl-backed resources hammer it --
# confirmed live: right after azurerm_kubernetes_cluster reports Succeeded,
# the API server can still answer the first wave of real calls (Helm's
# pre-install OpenAPI schema discovery is a heavy one) with "context deadline
# exceeded" / "http2: client connection lost" for a short window, even though
# module.cluster's outputs (aks_host, certs, ...) are already known -- same
# class of race as the LA workspace sleep above, just at the control-plane
# level instead of a specific RP lookup. Non-deterministic: doesn't reproduce
# on every apply, which is exactly why it needs a sleep rather than being
# "probably fine." module.platform's root-level `depends_on = [module.cluster]`
# (see ../../main.tf) already waits for every resource in this module,
# including this one, before touching anything Helm/kubectl-based.
resource "time_sleep" "wait_for_aks_api_propagation" {
  depends_on      = [module.aks]
  create_duration = "60s"
}

# ── Key Vault + ESO identity (creates the vault, admin RBAC, a user-assigned
#    managed identity, federated cred, role) ──────────────────────────────
# Provisioned here (not in the bootstrap submodule) because the ESO
# federated credential needs AKS's oidc_issuer_url, only available once AKS
# exists. The platform submodule consumes the ESO identity's client_id to
# annotate the ESO ServiceAccount it creates via Helm.
module "key_vault" {
  source              = "../key_vault"
  env_name            = var.env_name
  key_vault_name      = var.key_vault_name
  resource_group_name = var.resource_group_name
  region              = var.region
  rbac_principal_ids  = var.rbac_principal_ids
  aks_oidc_issuer_url = module.aks.oidc_issuer_url
  secret_name         = var.secrets_name
}

# ── DB credentials — self-service generates directly; otherwise read from
#    the master Key Vault secret (client pre-seeds it, see this file's
#    header comment for the two-step apply this now requires). ────────────
data "azurerm_key_vault_secret" "db_credentials" {
  count        = local.self_service ? 0 : 1
  name         = var.secrets_name
  key_vault_id = module.key_vault.id
}

resource "random_password" "backend_db" {
  count   = local.self_service ? 1 : 0
  length  = 24
  special = false
}

locals {
  db_creds = local.self_service ? {} : jsondecode(data.azurerm_key_vault_secret.db_credentials[0].value)

  backend_db_username = local.self_service ? "ekai_backend" : local.db_creds["backend_db_username"]
  backend_db_password = local.self_service ? random_password.backend_db[0].result : local.db_creds["backend_db_password"]
  backend_db_name     = local.self_service ? "ekai_backend" : local.db_creds["backend_db_name"]
}

# ── PostgreSQL Flexible Server ──────────────────────────────────────────────
# No semantics database -- semantics service has been removed from the
# product entirely (matches the same outright removal already done in
# devops/aws-terraform, devops/gcp-terraform, and terraform-google-ekai).
module "postgresql_server" {
  source                              = "../postgresql_server"
  region                              = var.region
  vnet_id                             = module.vnet.vnet_id
  subnet_id                           = module.vnet.private_subnet_ids[1]
  postgres_flexible_server_sku_name   = var.postgres_flexible_server_sku_name
  postgres_flexible_server_storage_mb = var.postgres_flexible_server_storage_mb
  resource_group_name                 = var.resource_group_name
  postgresql_version                  = var.postgresql_version
  enable_ha                           = var.enable_ha
  geo_redundant_backup_enabled        = var.geo_redundant_backup_enabled
  env_name                            = var.env_name
  backend_db_username                 = local.backend_db_username
  backend_db_password                 = local.backend_db_password
  backend_db_name                     = local.backend_db_name
  tags                                = local.common_tags
}

# ── ACR + AcrPull for AKS kubelet ───────────────────────────────────────────
# create_acr = true  → creates a new ACR and grants AcrPull to the AKS kubelet.
# create_acr = false → reads the existing ACR via data source; no new registry
#                      is provisioned. Set existing_acr_name in tfvars.
module "acr" {
  count                          = var.create_acr ? 1 : 0
  source                         = "../acr"
  env_name                       = var.env_name
  resource_group_name            = var.resource_group_name
  region                         = var.region
  aks_kubelet_identity_object_id = module.aks.kubelet_identity_object_id
  tags                           = local.common_tags
}

data "azurerm_container_registry" "existing" {
  count               = var.create_acr ? 0 : 1
  name                = var.existing_acr_name
  resource_group_name = var.resource_group_name
}

locals {
  acr_id           = var.create_acr ? module.acr[0].id : data.azurerm_container_registry.existing[0].id
  acr_name         = var.create_acr ? module.acr[0].name : data.azurerm_container_registry.existing[0].name
  acr_login_server = var.create_acr ? module.acr[0].login_server : data.azurerm_container_registry.existing[0].login_server
}

# ── Mirror Bitnami images into the client's ACR ─────────────────────────────
# Skipped when create_acr = false — images are expected to already exist in
# the provided external registry.
module "acr_image_mirror" {
  count    = var.create_acr ? 1 : 0
  source   = "../acr_image_mirror"
  acr_name = local.acr_name

  images = {
    minio = {
      source    = "docker.io/bitnamilegacy/minio:2025.7.23-debian-12-r3"
      dest_repo = "bitnami/minio"
      dest_tag  = "2025.7.23-debian-12-r3"
    }
    minio_client = {
      # Bitnami rotates `bitnamilegacy/*` tags. Verify before bumping:
      #   curl -s 'https://hub.docker.com/v2/repositories/bitnamilegacy/minio-client/tags/?page_size=20&ordering=last_updated' \
      #     | jq -r '.results[].name' | grep -v sha256
      source    = "docker.io/bitnamilegacy/minio-client:2025.7.21-debian-12-r3"
      dest_repo = "bitnami/minio-client"
      dest_tag  = "2025.7.21-debian-12-r3"
    }
    minio_object_browser = {
      source    = "docker.io/bitnamilegacy/minio-object-browser:2.0.2-debian-12-r3"
      dest_repo = "bitnami/minio-object-browser"
      dest_tag  = "2.0.2-debian-12-r3"
    }
    # No redis_stack entry -- modules/redis no longer swaps in the
    # redis/redis-stack-server image (see that module's file header for why:
    # it silently loses every RediSearch/RedisJSON/etc. module under
    # Bitnami's chart), so there's nothing of that kind left to mirror.
  }
}
