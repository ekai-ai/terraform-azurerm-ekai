variable "cluster_name" {
  description = "Name of the AKS cluster."
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version for the AKS control plane."
  type        = string
}

variable "sku_tier" {
  description = "AKS pricing tier for the control plane -- \"Standard\" (99.95% financially-backed uptime SLA, recommended for production) or \"Free\" (no SLA, best-effort availability -- cheaper, fine for short-lived dev/test clusters)."
  type        = string
  default     = "Standard"
  validation {
    condition     = contains(["Free", "Standard"], var.sku_tier)
    error_message = "sku_tier must be 'Free' or 'Standard' (Premium requires Long Term Support, not relevant here)."
  }
}

variable "region" {
  description = "Azure region where the AKS cluster is deployed."
  type        = string
}

variable "zones" {
  description = "Availability zones for both node pools -- spreads nodes across zones so a single zone outage doesn't take the whole pool down. Defaults to all three, but not every Azure region supports availability zones; set this to [] for a region that doesn't (verify with `az vm list-skus --location <region> --zone --output table` -- applying with a zone number a region doesn't support fails outright, it does not silently fall back)."
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "resource_group_name" {
  description = "Resource group that owns the AKS cluster."
  type        = string
}

variable "env_name" {
  description = "Environment identifier (knowledge, beta, test, ...)."
  type        = string
}

variable "vnet_subnet_id" {
  description = "List of private subnet IDs available to the cluster; the first is used for the default node pool."
  type        = list(string)
}

variable "vm_size" {
  description = "Azure VM SKU for AKS nodes."
  type        = string
}

variable "system_node_pool_min_count" {
  description = "Minimum node count for the system node pool (runs only critical kube-system addons)."
  type        = number
  default     = 1
}

variable "system_node_pool_max_count" {
  description = "Maximum node count for the system node pool."
  type        = number
  default     = 3
}

variable "app_vm_size" {
  description = "Azure VM SKU for the app (user) node pool where all workloads run."
  type        = string
}

variable "app_node_pool_min_count" {
  description = "Minimum node count for the app node pool."
  type        = number
}

variable "app_node_pool_max_count" {
  description = "Maximum node count for the app node pool."
  type        = number
}

variable "log_analytics_workspace_id" {
  description = "Resource ID of the Log Analytics workspace that receives AKS diagnostics and Container Insights data."
  type        = string
}

variable "log_analytics_workspace_location" {
  description = "Override location for the Log Analytics workspace; defaults to the cluster region."
  type        = string
  default     = null
}

variable "workspace_name" {
  description = "Name of the Log Analytics workspace (used for diagnostic setting targeting)."
  type        = string
}

variable "dns_zone" {
  description = "DNS zone that cert-manager uses via the AKS workload identity federated credential."
  type        = string
}

variable "tags" {
  description = "Tags applied to all AKS-related resources."
  type        = map(string)
  default     = {}
}
