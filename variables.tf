# ──────────────────────────────────────────────────────────────────────────────
# Root variables — bootstrap + cluster + platform only (the cicd submodule is
# a separate apply/state at ./cicd/ — see main.tf's file header for why).
# Mirrors terraform-aws-ekai/terraform-google-ekai's root variables.tf shape:
# variables shared across submodules are declared once here and passed into
# every module block that needs them (see main.tf); the ones also needed
# directly by ./cicd/ are declared again there too — same name, same meaning,
# separate Terraform config, both fed by the same tfvars file.
# ──────────────────────────────────────────────────────────────────────────────

# ═══════════════════════════════════════════════════════════════════════════
# Shared across layers (also redeclared in cicd/variables.tf where cicd
# needs its own copy)
# ═══════════════════════════════════════════════════════════════════════════

variable "subscription_id" {
  description = "Azure subscription ID. Same subscription for every submodule."
  type        = string
}

variable "purge_vault_on_destroy" {
  description = <<-EOT
    Purge a soft-deleted Key Vault immediately on destroy instead of leaving
    it in Azure's normal 7-day soft-delete retention window.
      false (default) — self-service/customer deployments. Destroy leaves the
                         vault soft-deleted for 7 days, Azure's own safe
                         default. Needs no extra Azure permission from the
                         customer.
      true             — internal fast destroy/reapply test loops only. Also
                         requires granting the deployer SP a subscription-
                         scoped custom RBAC role for the purge action (see
                         scripts/self-deploy.sh) — that Azure resource type
                         has no resource-group-scoped equivalent.
  EOT
  type        = bool
  default     = false
}

variable "region" {
  description = "Azure region (e.g. northeurope). Must match the resource group's region."
  type        = string
}

variable "env_name" {
  description = "Environment slug (e.g. client1, qa, prod). Used in resource names and tags."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]+$", var.env_name))
    error_message = "env_name must be lowercase letters and numbers only -- it's baked into the ACR name (alphanumeric only, no hyphens/underscores) and the Terraform state storage account name (lowercase alphanumeric only) via scripts/init-state-backend.sh."
  }
}

variable "resource_group_name" {
  description = "Pre-existing resource group (created out-of-band by scripts/init-state-backend.sh)."
  type        = string
}

variable "dns_zone" {
  description = "DNS zone for this env (e.g. client1.ekai.ai). Created by the bootstrap submodule when manage_dns_zone = true."
  type        = string
}

variable "secrets_name" {
  description = "Master Key Vault secret name holding DB credentials + (non-self-service only) argocd_admin_password_plain/github_token/username/email. Defaults to \"ekai-<env_name>\"."
  type        = string
  default     = null
}

variable "key_vault_name" {
  description = "Key Vault name to create. Globally unique within Azure, max 24 chars. Defaults to a name folding in env_name + the subscription ID (truncated to fit) so two self-service subscriptions never collide on the same name."
  type        = string
  default     = null
}

variable "namespace" {
  description = "K8s namespace where app workloads run."
  type        = string
  default     = "ekai-saas"
}

variable "argocd_ingress_host" {
  description = "Hostname for the ArgoCD ingress / the ArgoCD Terraform provider's connection target. Defaults to \"argocd.<dns_zone>\" when omitted."
  type        = string
  default     = null
}

variable "tls_name" {
  description = "Name of the Kubernetes Secret holding the wildcard TLS certificate, reflected across namespaces by the cert-manager submodule's reflector release. Defaults to \"<env_name>-ekai-wildcard-tls\"."
  type        = string
  default     = null
}

variable "rbac_principal_ids" {
  description = "Extra objectIds (additional admins/SPs) granted Key Vault Secrets Officer + DNS Zone Contributor on top of the deploying caller, which always gets both."
  type        = list(string)
  default     = []
}

# ── CI/CD provider ─────────────────────────────────────────────────────────────
variable "cicd_provider" {
  description = <<-EOT
    CI/CD provider for building and pushing Docker images.
      github_actions — GitHub Actions workflows with OIDC → Entra app. Client
                       must pre-seed the master Key Vault secret (see
                       modules/cluster's file header for the two-step apply
                       this now requires).
      none           — self-service client mode: no CI at all. This is the
                       primary mode this repo is built for.
  EOT
  type        = string
  default     = "none"
  validation {
    condition     = contains(["github_actions", "none"], var.cicd_provider)
    error_message = "cicd_provider must be 'github_actions' or 'none'."
  }
}

variable "tags" {
  description = "Common tags. Layer-specific tags are merged on top."
  type        = map(string)
  default     = {}
}

# ═══════════════════════════════════════════════════════════════════════════
# bootstrap submodule (DNS zone + RBAC)
# ═══════════════════════════════════════════════════════════════════════════

variable "manage_dns_zone" {
  description = "If true, the bootstrap submodule creates the DNS zone. Set false when the zone already exists."
  type        = bool
  default     = true
}

# ═══════════════════════════════════════════════════════════════════════════
# cluster submodule (VNet, AKS, PostgreSQL, Key Vault, ACR)
# ═══════════════════════════════════════════════════════════════════════════

variable "vnet_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "pub_sub_1_a_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "pri_sub_1_cidr" {
  type    = string
  default = "10.0.4.0/22"
}

variable "pri_sub_2_cidr" {
  type    = string
  default = "10.0.8.0/22"
}

variable "pri_sub_3_cidr" {
  type    = string
  default = "10.0.16.0/22"
}

variable "cluster_name" {
  type        = string
  description = "AKS cluster name."
}

variable "cluster_version" {
  type = string
}

variable "sku_tier" {
  description = "AKS pricing tier -- \"Standard\" (99.95% financially-backed SLA, recommended for production) or \"Free\" (no SLA, cheaper for short-lived dev/test clusters)."
  type        = string
  default     = "Standard"
}

variable "zones" {
  description = "Availability zones for both AKS node pools -- spreads nodes so a single zone outage doesn't take the whole pool down. Defaults to all three; not every Azure region supports availability zones -- set to [] for one that doesn't (an unsupported zone number fails the apply outright, it does not silently fall back)."
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "vm_size" {
  type = string
}

variable "system_node_pool_min_count" {
  type    = number
  default = 1
}

variable "system_node_pool_max_count" {
  type    = number
  default = 3
}

variable "app_vm_size" {
  type        = string
  description = "VM SKU for the app (user) node pool where all workloads run."
}

variable "app_node_pool_min_count" {
  type = number
}

variable "app_node_pool_max_count" {
  type = number
}

variable "log_analytics_workspace_name" {
  type = string
}

variable "solution_plan_map" {
  type = map(object({
    product   = string
    publisher = string
  }))
  default = {
    ContainerInsights = {
      product   = "OMSGallery/ContainerInsights"
      publisher = "Microsoft"
    }
  }
}

variable "postgresql_version" {
  type    = string
  default = "15"
}

variable "postgres_flexible_server_sku_name" {
  # GP (General Purpose), not Burstable -- Burstable doesn't support HA at
  # all, and this repo defaults enable_ha = true below. Override to a
  # Burstable SKU only for a non-prod env, alongside enable_ha = false.
  type    = string
  default = "GP_Standard_D2s_v3"
}

variable "postgres_flexible_server_storage_mb" {
  type    = number
  default = 65536
}

variable "enable_ha" {
  description = "Enable PostgreSQL zone-redundant HA (standby in a different availability zone). Requires a General Purpose/Memory Optimized SKU -- not available on Burstable. Defaults to true -- this repo is for production client deployments; set false for a cheaper non-prod env (alongside a Burstable postgres_flexible_server_sku_name)."
  type        = bool
  default     = true
}

variable "geo_redundant_backup_enabled" {
  description = "Copy PostgreSQL backups to the paired region, protecting against a full primary-region outage. Roughly doubles backup storage cost. Defaults to true for the same reason as enable_ha."
  type        = bool
  default     = true
}

variable "create_acr" {
  type    = bool
  default = true
}

variable "existing_acr_name" {
  type    = string
  default = null
}

# ═══════════════════════════════════════════════════════════════════════════
# platform submodule (nginx-ingress, cert-manager, ESO, ArgoCD, Redis, MinIO)
# ═══════════════════════════════════════════════════════════════════════════

variable "argocd_namespace" {
  type    = string
  default = "argocd"
}

variable "argocd_admin_password_hashed" {
  description = "Bcrypt-hashed ArgoCD admin password. Ignored when cicd_provider = \"none\" — generated directly instead."
  type        = string
  sensitive   = true
  default     = ""
}

variable "acme_email" {
  description = "Email address registered with Let's Encrypt for certificate expiry notifications."
  type        = string

  validation {
    condition     = var.acme_email != "" && var.acme_email != "REPLACE_ME" && can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.acme_email))
    error_message = "acme_email must be a real email address -- got empty, the literal placeholder \"REPLACE_ME\", or something that doesn't look like an email."
  }
}

variable "cluster_issuer_name" {
  description = "Which ClusterIssuer the wildcard Certificate uses — \"letsencrypt-prod\" (default, a real browser-trusted cert) or \"letsencrypt-staging\" to avoid Let's Encrypt's production rate limit during repeated apply/destroy test cycles."
  type        = string
  default     = "letsencrypt-prod"
}

variable "redis_namespace" {
  type    = string
  default = "redis"
}

variable "redis_chart_version" {
  # 24.1.0 -- see modules/redis's file header: the redis/redis-stack-server
  # image-swap approach (what 21.2.13 was originally pinned for) silently
  # drops every RediSearch/RedisJSON/etc. module under Bitnami's chart.
  type    = string
  default = "24.1.0"
}

variable "reloader_chart_version" {
  type    = string
  default = "1.2.0"
}

variable "eso_chart_version" {
  description = "External Secrets Operator Helm chart version."
  type        = string
  default     = "0.10.7"
}

variable "redis_replica_count" {
  type    = number
  default = 3
}

variable "redis_persistence_size" {
  type    = string
  default = "8Gi"
}

variable "redis_storage_class" {
  type    = string
  default = "managed-premium"
}

variable "redis_metrics_enabled" {
  type    = bool
  default = false
}

variable "redis_network_policy_enabled" {
  type    = bool
  default = true
}

# --- Neo4j (always deployed, same as Redis above -- see modules/platform's
# file header for why this repo doesn't use AWS/GCP's enable_neo4j toggle) ---
variable "neo4j_namespace" {
  type    = string
  default = "neo4j"
}

variable "neo4j_chart_version" {
  type    = string
  default = "5.26.0"
}

variable "neo4j_storage_size" {
  type    = string
  default = "20Gi"
}

variable "neo4j_storage_class" {
  type    = string
  default = "managed-premium"
}

variable "neo4j_memory_request" {
  type    = string
  default = "2Gi"
}

variable "neo4j_memory_limit" {
  type    = string
  default = "4Gi"
}

variable "neo4j_cpu_request" {
  type    = string
  default = "500m"
}

variable "neo4j_cpu_limit" {
  type    = string
  default = "2"
}

variable "minio_namespace" {
  type    = string
  default = "minio"
}

variable "minio_chart_version" {
  type    = string
  default = "17.0.21"
}

variable "minio_persistence_size" {
  type    = string
  default = "50Gi"
}

variable "minio_storage_class" {
  type    = string
  default = "managed-premium"
}

variable "minio_replicas" {
  type    = number
  default = 4
}

variable "minio_mode" {
  type    = string
  default = "distributed"
}

variable "minio_default_buckets" {
  type    = list(string)
  default = ["ekai-files"]
}

variable "minio_host" {
  description = "Hostname for the MinIO ingress. Defaults to \"minio.<dns_zone>\"."
  type        = string
  default     = null
}

variable "minio_enable_ingress" {
  type    = bool
  default = true
}

variable "minio_resources" {
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "100m", memory = "256Mi" }
    limits   = { cpu = "1", memory = "1Gi" }
  }
}

variable "secret_value_overrides" {
  description = "Escape hatch for any key in the master Key Vault secret (cicd_provider = \"none\" only) that doesn't have its own dedicated variable — merged on top of every computed/default value, so it wins on conflicts."
  type        = map(string)
  default     = {}
}
