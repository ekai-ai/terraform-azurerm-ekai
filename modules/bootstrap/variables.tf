variable "env_name" {
  description = "Environment slug (e.g. client1, qa, prod). Used in tags."
  type        = string
}

variable "resource_group_name" {
  description = "Pre-existing RG (created out-of-band by scripts/init-state-backend.sh)."
  type        = string
}

variable "dns_zone" {
  description = "DNS zone for this env (e.g. client1.ekai.ai). Created here when manage_dns_zone = true."
  type        = string
}

variable "manage_dns_zone" {
  type        = bool
  default     = true
  description = "If true, this submodule creates the DNS zone. Set false when the zone is managed externally."
}

variable "rbac_principal_ids" {
  type        = list(string)
  default     = []
  description = "Extra objectIds (additional admins) that should be granted DNS Zone Contributor on top of the deploying caller, which always gets it."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Common tags. Layer-specific tags are merged on top."
}
