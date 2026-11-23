# ──────────────────────────────────────────────────────────────────────────────
# cicd providers — required_providers is the union of what THIS config's own
# resources + module.cicd's tree actually use.
#
# provider "argocd" is THE reason this is a separate apply/state from
# ../ (bootstrap+cluster+platform) — see ../main.tf's file header. Its
# `password` is read from `data.terraform_remote_state.combined.outputs.
# argocd_admin_password_plaintext`: a value from an ALREADY-COMPLETED separate
# apply, which Terraform can treat as known before this apply even starts —
# unlike a same-apply managed resource's computed attribute, which it cannot.
# ──────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.5"

  # No backend block here — this directory is a reusable Terraform module
  # (a plain relative `source` for anyone using this repo directly), not a
  # state-holding root config. The actual root config that DOES declare a
  # backend and gets applied is examples/self-deploy/cicd/ — see that
  # directory's main.tf, and scripts/init-state-backend.sh for how its
  # backend config is generated.
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

data "terraform_remote_state" "combined" {
  backend = "azurerm"
  config = {
    resource_group_name  = var.resource_group_name
    storage_account_name = "ekaiterraform${var.env_name}"
    container_name       = "ekaitfstate"
    key                  = "${var.env_name}/combined.tfstate"
  }
}

locals {
  secrets_name = coalesce(var.secrets_name, "ekai-${var.env_name}")

  aks_host                   = data.terraform_remote_state.combined.outputs.aks_host
  aks_client_certificate     = data.terraform_remote_state.combined.outputs.aks_client_certificate
  aks_client_key             = data.terraform_remote_state.combined.outputs.aks_client_key
  aks_cluster_ca_certificate = data.terraform_remote_state.combined.outputs.aks_cluster_ca_certificate
  key_vault_id               = data.terraform_remote_state.combined.outputs.key_vault_id
  argocd_admin_password      = data.terraform_remote_state.combined.outputs.argocd_admin_password_plaintext

  self_service = var.cicd_provider == "none"
}

provider "azurerm" {
  features {
    key_vault {
      recover_soft_deleted_key_vaults = true
      purge_soft_delete_on_destroy    = true
    }
  }
  subscription_id = var.subscription_id
}

provider "azuread" {}

provider "kubernetes" {
  host                   = local.aks_host
  client_certificate     = base64decode(local.aks_client_certificate)
  client_key             = base64decode(local.aks_client_key)
  cluster_ca_certificate = base64decode(local.aks_cluster_ca_certificate)
}

provider "kubectl" {
  host                   = local.aks_host
  client_certificate     = base64decode(local.aks_client_certificate)
  client_key             = base64decode(local.aks_client_key)
  cluster_ca_certificate = base64decode(local.aks_cluster_ca_certificate)
  load_config_file       = false
}

# Connection mode: `port_forward_with_namespace = true`. The provider opens a
# local port-forward to `svc/argocd-server` in the `argocd` namespace using
# the cluster credentials below. This avoids the public-DNS dependency:
# `server_addr` would require `argocd.<env>.ekai.ai` to be resolvable from
# the runner BEFORE provider init, which races against DNS propagation and
# fails with `no such host` even when the record exists. Port-forward only
# needs AKS to be reachable, which it always is here because the combined
# apply already created it. Matches the original 04-cicd/providers.tf's
# exact reasoning and configuration.
provider "argocd" {
  port_forward_with_namespace = "argocd"
  username                    = "admin"
  password                    = local.argocd_admin_password
  insecure                    = true

  # ArgoCD's Helm chart is installed with `configs.params.server.insecure=true`
  # (see modules/argocd/main.tf), so argocd-server listens on HTTP only.
  # Without this flag the provider tries TLS and fails with `EOF`.
  plain_text = true

  kubernetes {
    host                   = local.aks_host
    client_certificate     = base64decode(local.aks_client_certificate)
    client_key             = base64decode(local.aks_client_key)
    cluster_ca_certificate = base64decode(local.aks_cluster_ca_certificate)
  }
}

# Only needed for cicd_provider = "github_actions" -- modules/github_action
# creates real github_* resources (Environments, env secrets, workflow YAML),
# which this provider configures auth for. Re-reads the master secret here
# (separately from modules/cicd's own internal read) since the provider
# block itself needs github_token/github_owner before module.cicd is even
# evaluated -- a config's provider blocks can't be fed from a value computed
# inside a child module it calls. Harmless for self-service: the provider
# isn't validated eagerly, and github_token is "" with zero github_* resources
# actually created (module.github_action has count = 0).
data "azurerm_key_vault_secret" "master_for_github_provider" {
  count        = local.self_service ? 0 : 1
  name         = local.secrets_name
  key_vault_id = local.key_vault_id
}

locals {
  _github_secret   = local.self_service ? {} : jsondecode(data.azurerm_key_vault_secret.master_for_github_provider[0].value)
  _github_token    = local.self_service ? "" : local._github_secret["github_token"]
  _github_username = local.self_service ? "" : local._github_secret["github_username"]
}

provider "github" {
  token = local._github_token
  # coalesce() only skips null, not "" -- var.github_owner defaults to "",
  # so a plain ternary is used instead of coalesce() here.
  owner = var.github_owner != "" ? var.github_owner : local._github_username
}
