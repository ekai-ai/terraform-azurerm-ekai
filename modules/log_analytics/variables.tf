variable "resource_group_name" {
  description = "Resource group that owns the Log Analytics workspace."
  type        = string
}

variable "region" {
  description = "Azure region for the Log Analytics workspace."
  type        = string
}

variable "name" {
  description = "Name of the Log Analytics workspace."
  type        = string
}

variable "tags" {
  description = "Tags applied to the workspace and solutions."
  type        = map(string)
  default     = {}
}
