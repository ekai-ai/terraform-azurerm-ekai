# ────────────────────────────────────────────────────────────────────────────
# platform submodule variables. AKS connection details (aks_host,
# aks_client_certificate, ...) are NOT declared here -- the root module's
# kubernetes/helm/kubectl provider blocks are fed directly from
# module.cluster's outputs (see ../../providers.tf); this submodule only
# declares providers via its own versions.tf, matching the cluster/cicd
# submodules.
# ────────────────────────────────────────────────────────────────────────────

variable "subscription_id" {
  type        = string
  description = "Azure subscription ID — cert-manager's DNS01 azureDNS solver needs this embedded directly in its ClusterIssuer manifest."
}

variable "env_name" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "region" {
  type = string
}

# --- Key Vault (sourced from the cluster submodule's output) ---
variable "key_vault_id" {
  type = string
}

variable "key_vault_name" {
  type = string
}

variable "tenant_id" {
  type = string
}

variable "eso_app_client_id" {
  description = "Client ID of the ESO Entra app (sourced from the cluster submodule's key_vault module output)."
  type        = string
}

variable "cert_manager_uami_client_id" {
  description = "Client ID of the cert-manager UAMI (sourced from the cluster submodule's aks module output)."
  type        = string
}

# --- PostgreSQL (sourced from the cluster submodule's output) ---
variable "postgres_fqdn" {
  type = string
}

variable "backend_db_username" {
  type      = string
  sensitive = true
}

variable "backend_db_password" {
  type      = string
  sensitive = true
}

variable "backend_db_name" {
  type = string
}

variable "secrets_name" {
  type        = string
  description = "Master Key Vault secret name. Self-service: Terraform creates it fresh. Non-self-service: client pre-populates DB creds + argocd_admin_password_plain + github_token/username/email; this submodule reads those, deploys the platform, then writes back the merged secret with platform-derived values (DATABASE_URL, REDIS_*) added."
}

variable "cicd_provider" {
  type    = string
  default = "none"
  validation {
    condition     = contains(["github_actions", "none"], var.cicd_provider)
    error_message = "cicd_provider must be 'github_actions' or 'none'."
  }
}

variable "namespace" {
  type        = string
  description = "K8s namespace where app workloads run (e.g. ekai-saas)."
}

# --- ArgoCD ---
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

variable "argocd_ingress_host" {
  type = string
}

# --- DNS / TLS ---
variable "dns_zone" {
  type = string
}

variable "tls_name" {
  type = string
}

variable "acme_email" {
  description = "Email address registered with Let's Encrypt for certificate expiry notifications."
  type        = string
}

variable "cluster_issuer_name" {
  description = "Which ClusterIssuer the wildcard Certificate uses — see modules/cert-manager. Default is staging to avoid Let's Encrypt's production rate limit during repeated apply/destroy cycles."
  type        = string
  default     = "letsencrypt-staging"
}

# --- Redis ---
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
  description = "Stakater Reloader Helm chart version — auto-restarts pods when K8s Secrets change"
  type        = string
  default     = "1.2.0"
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

# --- Neo4j --- (always deployed, same as Redis above -- no enable/disable
# toggle in this repo's existing design; matches terraform-google-ekai's
# module itself, not its optional enable_neo4j wiring)
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

variable "secret_value_overrides" {
  description = "Escape hatch for any key in the master Key Vault secret (cicd_provider = \"none\" only) that doesn't have its own dedicated variable — merged on top of every computed/default value, so it wins on conflicts. Same effect as editing the secret via the Azure CLI after apply, but survives a full destroy/re-apply."
  type        = map(string)
  default     = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}
