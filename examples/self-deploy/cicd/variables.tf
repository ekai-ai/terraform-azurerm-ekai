# ──────────────────────────────────────────────────────────────────────────────
# cicd variables — the subset of modules/cicd's variables that are genuine
# human/tfvars inputs. Everything modules/cicd needs that used to come from
# `data "terraform_remote_state" "cluster"` / "platform" in the original
# 04-cicd/main.tf is NOT declared here — main.tf reads those directly from
# `data.terraform_remote_state.combined.outputs.*` instead and passes them
# straight into the module "cicd" call.
#
# This file is read from the SAME env/<env>.tfvars file the combined root
# (../variables.tf) reads — subscription_id/region/env_name/resource_group_name/
# dns_zone/secrets_name/namespace/tls_name/cicd_provider are declared again
# here (same name, same meaning) because this is a separate Terraform config
# with its own variable namespace, not because the value differs.
# ──────────────────────────────────────────────────────────────────────────────

variable "subscription_id" {
  type = string
}

variable "region" {
  type = string
}

variable "env_name" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "dns_zone" {
  type = string
}

variable "secrets_name" {
  description = "Master Key Vault secret name. Must match ../variables.tf's own derivation (coalesce(var.secrets_name, \"ekai-<env_name>\")) exactly -- the combined root already created this secret; this config only reads and extends it."
  type        = string
  default     = null
}

variable "namespace" {
  type    = string
  default = "ekai-saas"
}

variable "tls_name" {
  description = "Must match ../variables.tf's own derivation (coalesce(var.tls_name, \"<env_name>-ekai-wildcard-tls\")) exactly."
  type        = string
  default     = null
}

variable "cicd_provider" {
  type    = string
  default = "none"
  validation {
    condition     = contains(["github_actions", "none"], var.cicd_provider)
    error_message = "cicd_provider must be 'github_actions' or 'none'."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ═══════════════════════════════════════════════════════════════════════════
# github_actions path only (cicd_provider = "github_actions")
# ═══════════════════════════════════════════════════════════════════════════

variable "github_owner" {
  type    = string
  default = ""
}

variable "manifests_reponame" {
  type    = string
  default = "deployment-files"
}

variable "manifests_branch" {
  type    = string
  default = ""
}

variable "manifests_path" {
  type    = string
  default = "manifest-files"
}

variable "cd_repos" {
  type = list(object({
    name            = string
    reponame        = string
    repo_env        = string
    image_path      = optional(string, ".")
    dockerfile      = optional(string, "Dockerfile")
    deployment_yaml = string
  }))
  default = []
}

variable "registries" {
  type = object({
    azure = object({ enabled = bool })
    dockerhub = object({
      enabled   = bool
      namespace = string
    })
    aws_ecr = object({
      enabled      = bool
      registry_url = string
      region       = string
    })
  })
  default = {
    azure     = { enabled = true }
    dockerhub = { enabled = false, namespace = "" }
    aws_ecr   = { enabled = false, registry_url = "", region = "" }
  }
}

variable "dockerhub_username" {
  type      = string
  default   = ""
  sensitive = true
}

variable "dockerhub_token" {
  type      = string
  default   = ""
  sensitive = true
}

variable "aws_ecr_access_key_id" {
  type      = string
  default   = ""
  sensitive = true
}

variable "aws_ecr_secret_access_key" {
  type      = string
  default   = ""
  sensitive = true
}

# ═══════════════════════════════════════════════════════════════════════════
# cicd_provider = "none" (self-service) only
# ═══════════════════════════════════════════════════════════════════════════

variable "existing_image_registry_base_url" {
  type    = string
  default = ""
}

variable "helm_chart_repo_url" {
  type    = string
  default = ""
}

variable "helm_chart_version" {
  type    = string
  default = "*"
}

variable "image_tag" {
  type    = string
  default = "latest"
}

variable "ingress_class_name" {
  type    = string
  default = "nginx"
}

variable "shared_service_account_name" {
  type    = string
  default = "ekai-app-sa"
}
