# ────────────────────────────────────────────────────────────────────────────
# cluster submodule variables.
# ────────────────────────────────────────────────────────────────────────────

# --- Identity ---
variable "region" {
  type        = string
  description = "Azure region for all resources in this submodule."
}

variable "env_name" {
  type        = string
  description = "Env identifier (dev, prod, client1, ...)."
}

variable "resource_group_name" {
  type        = string
  description = "Pre-existing resource group (created out-of-band by scripts/init-state-backend.sh)."
}

# --- Networking ---
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

# --- AKS ---
variable "cluster_name" {
  type = string
}

variable "cluster_version" {
  type = string
}

variable "sku_tier" {
  description = "AKS pricing tier -- \"Standard\" (SLA-backed, production) or \"Free\" (no SLA, dev/test)."
  type        = string
  default     = "Standard"
}

variable "zones" {
  description = "Availability zones for both AKS node pools. Defaults to all three; set to [] for a region with no zone support."
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "vm_size" {
  type = string
}

variable "system_node_pool_min_count" {
  type        = number
  description = "Min nodes for the system pool (critical kube-system addons only)."
  default     = 1
}

variable "system_node_pool_max_count" {
  type        = number
  description = "Max nodes for the system pool."
  default     = 3
}

variable "app_vm_size" {
  type        = string
  description = "VM SKU for the app (user) node pool where all workloads run."
}

variable "app_node_pool_min_count" {
  type        = number
  description = "Min nodes for the app pool."
}

variable "app_node_pool_max_count" {
  type        = number
  description = "Max nodes for the app pool."
}

# --- Observability ---
variable "log_analytics_workspace_name" {
  type = string
}

variable "solution_plan_map" {
  type = map(object({
    product   = string
    publisher = string
  }))
}

# --- PostgreSQL ---
variable "postgresql_version" {
  type = string
}

variable "postgres_flexible_server_sku_name" {
  type = string
}

variable "postgres_flexible_server_storage_mb" {
  type = number
}

variable "enable_ha" {
  type    = bool
  default = true
}

variable "geo_redundant_backup_enabled" {
  type    = bool
  default = true
}

# --- Key Vault ---
variable "key_vault_name" {
  type        = string
  description = "Key Vault name to create. Globally unique within Azure."
}

variable "secrets_name" {
  type        = string
  description = "Master Key Vault secret name holding DB credentials + (non-self-service only) argocd_admin_password_plain/github_token. Ignored for DB credentials when cicd_provider = \"none\" -- self-service generates those directly instead."
}

variable "rbac_principal_ids" {
  type        = list(string)
  default     = []
  description = "Extra objectIds (additional admins) granted Key Vault Secrets Officer on top of the deploying caller, which always gets it."
}

# --- CI/CD provider (same value as the platform/cicd submodules' — the root's
# single tfvars file is shared) — only checked here for whether it's "none"
# (self-service: generate DB credentials directly instead of requiring a
# pre-existing Key Vault secret). ----------------------------------------
variable "cicd_provider" {
  type    = string
  default = "none"
  validation {
    condition     = contains(["github_actions", "none"], var.cicd_provider)
    error_message = "cicd_provider must be 'github_actions' or 'none'."
  }
}

# --- DNS (existing zone, created by the bootstrap submodule — read-only here) ---
variable "dns_zone" {
  type = string
}

# --- ACR ---
variable "create_acr" {
  type        = bool
  default     = true
  description = "When true, creates a new ACR and grants AcrPull to the AKS kubelet. When false, uses the existing registry specified by existing_acr_name — no new registry is created."
}

variable "existing_acr_name" {
  type        = string
  default     = null
  description = "Required when create_acr = false. Name of the existing ACR to use (must be in the same resource group)."
}

# --- Tags ---
variable "tags" {
  type        = map(string)
  default     = {}
  description = "Common tags applied to all resources."
}
