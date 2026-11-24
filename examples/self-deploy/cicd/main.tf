# ──────────────────────────────────────────────────────────────────────────────
# examples/self-deploy/cicd — the actual state-holding root config for the
# "cicd" module (../../../cicd = the repo's cicd/ directory). This is what
# scripts/self-deploy.sh runs `terraform init`/`apply` against, AFTER
# examples/self-deploy/root has already applied — cicd/'s own
# `data "terraform_remote_state" "combined"` block (inside ../../../cicd/
# providers.tf) reads that apply's state directly, so this config doesn't
# need to pass any remote-state values itself; the module block below only
# carries genuine tfvars-driven inputs.
# ──────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.5"

  # Partial backend config — provide per-environment via -backend-config flag.
  # Example:
  #   terraform init -backend-config=../../../env/backend-<env>-cicd.tfbackend
  #
  # Second of the 2 states in this repo — see scripts/init-state-backend.sh
  # (run from the repo root — it writes backend files into env/, not here).
  backend "azurerm" {}

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.9.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 3.0"
    }
    argocd = {
      source  = "argoproj-labs/argocd"
      version = "~> 7.11.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.6.0"
    }
  }
}

module "cicd" {
  source = "../../../cicd"

  subscription_id     = var.subscription_id
  region              = var.region
  env_name            = var.env_name
  resource_group_name = var.resource_group_name
  dns_zone            = var.dns_zone
  secrets_name        = var.secrets_name
  namespace           = var.namespace
  tls_name            = var.tls_name
  cicd_provider       = var.cicd_provider
  tags                = var.tags

  github_owner              = var.github_owner
  manifests_reponame        = var.manifests_reponame
  manifests_branch          = var.manifests_branch
  manifests_path            = var.manifests_path
  cd_repos                  = var.cd_repos
  registries                = var.registries
  dockerhub_username        = var.dockerhub_username
  dockerhub_token           = var.dockerhub_token
  aws_ecr_access_key_id     = var.aws_ecr_access_key_id
  aws_ecr_secret_access_key = var.aws_ecr_secret_access_key

  existing_image_registry_base_url = var.existing_image_registry_base_url
  helm_chart_repo_url              = var.helm_chart_repo_url
  helm_chart_version               = var.helm_chart_version
  image_tag                        = var.image_tag
  ingress_class_name               = var.ingress_class_name
  shared_service_account_name      = var.shared_service_account_name
}
