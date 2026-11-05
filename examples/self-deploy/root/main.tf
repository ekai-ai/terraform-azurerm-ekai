# ──────────────────────────────────────────────────────────────────────────────
# examples/self-deploy/root — the actual state-holding root config for the
# "infra" module (../../.. = the repo root — bootstrap+cluster+platform,
# combined into one apply). This is what scripts/self-deploy.sh runs
# `terraform init`/`apply` against; the repo root itself is a pure module now
# (no backend block — see ../../../providers.tf) and cannot be applied
# directly.
#
# required_providers here matches ../../../providers.tf's exactly — the repo
# root module already declares (and configures) these providers internally,
# but re-declaring the same versions at the true root pins them at the entry
# point too, which is what actually determines what `terraform init`
# installs and locks in .terraform.lock.hcl.
# ──────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.7"

  # Partial backend config — provide per-environment via -backend-config flag.
  # Example:
  #   terraform init -backend-config=../../../env/backend-<env>.tfbackend
  #
  # The storage account + container MUST exist before terraform init can
  # succeed. Create them first with: scripts/init-state-backend.sh <env>
  # (from the repo root — it writes backend files into env/, not here).
  #
  # This is one of TWO separate states in this repo — this one holds
  # bootstrap+cluster+platform ("combined"); examples/self-deploy/cicd/ holds
  # its own, reading this state's outputs via `data "terraform_remote_state"`
  # (inside the cicd module itself).
  backend "azurerm" {}

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.9.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.1.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14.0"
    }
  }
}

module "infra" {
  source = "../../.."

  subscription_id                     = var.subscription_id
  purge_vault_on_destroy              = var.purge_vault_on_destroy
  region                              = var.region
  env_name                            = var.env_name
  resource_group_name                 = var.resource_group_name
  dns_zone                            = var.dns_zone
  secrets_name                        = var.secrets_name
  key_vault_name                      = var.key_vault_name
  namespace                           = var.namespace
  argocd_ingress_host                 = var.argocd_ingress_host
  tls_name                            = var.tls_name
  rbac_principal_ids                  = var.rbac_principal_ids
  cicd_provider                       = var.cicd_provider
  tags                                = var.tags
  manage_dns_zone                     = var.manage_dns_zone
  vnet_cidr                           = var.vnet_cidr
  pub_sub_1_a_cidr                    = var.pub_sub_1_a_cidr
  pri_sub_1_cidr                      = var.pri_sub_1_cidr
  pri_sub_2_cidr                      = var.pri_sub_2_cidr
  pri_sub_3_cidr                      = var.pri_sub_3_cidr
  cluster_name                        = var.cluster_name
  cluster_version                     = var.cluster_version
  sku_tier                            = var.sku_tier
  zones                               = var.zones
  vm_size                             = var.vm_size
  system_node_pool_min_count          = var.system_node_pool_min_count
  system_node_pool_max_count          = var.system_node_pool_max_count
  app_vm_size                         = var.app_vm_size
  app_node_pool_min_count             = var.app_node_pool_min_count
  app_node_pool_max_count             = var.app_node_pool_max_count
  log_analytics_workspace_name        = var.log_analytics_workspace_name
  solution_plan_map                   = var.solution_plan_map
  postgresql_version                  = var.postgresql_version
  postgres_flexible_server_sku_name   = var.postgres_flexible_server_sku_name
  postgres_flexible_server_storage_mb = var.postgres_flexible_server_storage_mb
  enable_ha                           = var.enable_ha
  geo_redundant_backup_enabled        = var.geo_redundant_backup_enabled
  create_acr                          = var.create_acr
  existing_acr_name                   = var.existing_acr_name
  argocd_namespace                    = var.argocd_namespace
  argocd_admin_password_hashed        = var.argocd_admin_password_hashed
  acme_email                          = var.acme_email
  cluster_issuer_name                 = var.cluster_issuer_name
  redis_namespace                     = var.redis_namespace
  redis_chart_version                 = var.redis_chart_version
  reloader_chart_version              = var.reloader_chart_version
  eso_chart_version                   = var.eso_chart_version
  redis_replica_count                 = var.redis_replica_count
  redis_persistence_size              = var.redis_persistence_size
  redis_storage_class                 = var.redis_storage_class
  redis_metrics_enabled               = var.redis_metrics_enabled
  redis_network_policy_enabled        = var.redis_network_policy_enabled
  neo4j_namespace                     = var.neo4j_namespace
  neo4j_chart_version                 = var.neo4j_chart_version
  neo4j_storage_size                  = var.neo4j_storage_size
  neo4j_storage_class                 = var.neo4j_storage_class
  neo4j_memory_request                = var.neo4j_memory_request
  neo4j_memory_limit                  = var.neo4j_memory_limit
  neo4j_cpu_request                   = var.neo4j_cpu_request
  neo4j_cpu_limit                     = var.neo4j_cpu_limit
  minio_namespace                     = var.minio_namespace
  minio_chart_version                 = var.minio_chart_version
  minio_persistence_size              = var.minio_persistence_size
  minio_storage_class                 = var.minio_storage_class
  minio_replicas                      = var.minio_replicas
  minio_mode                          = var.minio_mode
  minio_default_buckets               = var.minio_default_buckets
  minio_host                          = var.minio_host
  minio_enable_ingress                = var.minio_enable_ingress
  minio_resources                     = var.minio_resources
  secret_value_overrides              = var.secret_value_overrides
}
