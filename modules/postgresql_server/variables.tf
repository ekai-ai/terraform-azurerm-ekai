variable "resource_group_name" {
  description = "Resource group that owns the PostgreSQL Flexible Server."
  type        = string
}

variable "region" {
  description = "Azure region for the PostgreSQL Flexible Server."
  type        = string
}

variable "env_name" {
  description = "Environment identifier (knowledge, beta, test, ...) used in resource naming."
  type        = string
}

variable "subnet_id" {
  description = "ID of the delegated private subnet where the server is injected."
  type        = string
}

variable "vnet_id" {
  description = "ID of the VNet, used for the private DNS zone VNet link."
  type        = string
}

variable "postgresql_version" {
  description = "PostgreSQL major version (e.g. \"15\")."
  type        = string
}

variable "postgres_flexible_server_sku_name" {
  description = "SKU for the PostgreSQL Flexible Server (e.g. B_Standard_B2ms, GP_Standard_D2s_v3)."
  type        = string
}

variable "postgres_flexible_server_storage_mb" {
  description = "Storage size in MB for the PostgreSQL Flexible Server."
  type        = number
}

variable "enable_ha" {
  description = "Enable PostgreSQL zone-redundant high availability (standby replica in a different availability zone from the primary). Requires a General Purpose or Memory Optimized SKU -- not available on Burstable."
  type        = bool
  default     = true
}

variable "availability_zone" {
  description = "Which zone the primary instance pins to -- independent of enable_ha (a non-HA server can still pin to a specific zone instead of leaving it to Azure's own, unpredictable auto-assignment). Pass the same zone list root module's var.zones resolves to for AKS, e.g. its first element -- confirmed live that leaving this null on a subscription with a restricted zone set can land the server on an unsupported zone (SkuNotAvailable, a misleading error for what's actually a zone placement failure). null falls back to the previous behavior (zone \"1\" when enable_ha, otherwise Azure's own auto-assignment)."
  type        = string
  default     = null
}

variable "geo_redundant_backup_enabled" {
  description = "Copy backups to the paired region, protecting against a full primary-region outage (not just a zone within it, which enable_ha covers). Roughly doubles backup storage cost."
  type        = bool
  default     = true
}

variable "backend_db_name" {
  description = "Database name for the backend service."
  type        = string
}

variable "backend_db_username" {
  description = "Username for the backend database role."
  type        = string
  sensitive   = true
}

variable "backend_db_password" {
  description = "Password for the backend database role."
  type        = string
  sensitive   = true
}

variable "tags" {
  description = "Tags applied to the PostgreSQL server and related resources."
  type        = map(string)
  default     = {}
}
