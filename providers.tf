# ──────────────────────────────────────────────────────────────────────────────
# Root providers (bootstrap + cluster + platform) — required_providers is the
# union of what THESE 3 submodules' trees actually use. Provider
# *configuration* blocks (provider "azurerm" {}, "kubernetes" {}, "helm" {},
# "kubectl" {}) live here — the bootstrap/cluster/platform submodules cannot
# declare their own provider config, only require providers via their own
# required_providers block (kept in each modules/<name>/providers.tf for
# documentation).
#
# provider "argocd" / "github" / "azuread" are intentionally NOT declared
# here (moved to ./cicd/providers.tf instead): nothing under
# bootstrap/cluster/platform's module tree creates an
# argocd_*/github_*/azuread_* resource — only modules/cicd does (via
# modules/microservices_CD and modules/github_action), and that module is not
# part of this root anymore. See main.tf's file header for the full reasoning
# on why cicd stays a separate apply.
#
# required_version — >= 1.7, the minimum README.md lists. The submodules
# only need 1.5; the 1.7 comes from examples/self-deploy/root (the config this
# module is applied through), whose import block uses for_each. CI validates
# with 1.7.5 so this stays true.
# ──────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.7"

  # No backend block here — this directory is a reusable Terraform module
  # (a plain relative `source` for anyone using this repo directly), not a
  # state-holding root config. The actual root config that DOES declare a
  # backend and gets applied is examples/self-deploy/root/ — see that
  # directory's main.tf, and scripts/init-state-backend.sh for how its
  # backend config is generated.
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.9.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.1.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14.0"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      # Auto-recover any soft-deleted KV with the same name in the same
      # subscription/region. Without this, re-applying after a destroy fails
      # with "Vault name already in use" until the 7-day retention expires.
      recover_soft_deleted_key_vaults = true
      # If a previous destroy soft-deleted the KV, purge it immediately
      # instead of leaving it in the 7-day retention window — needed for
      # self-deploy.sh/self-deploy-destroy.sh's destroy-then-reapply-same-name
      # loop used in internal testing. Defaults to false: a real customer's
      # destroy should just leave the vault soft-deleted for Azure's normal
      # 7-day window, since the purge action can only ever be granted at
      # subscription scope (see var.purge_vault_on_destroy's description).
      purge_soft_delete_on_destroy = var.purge_vault_on_destroy
    }
  }
  subscription_id = var.subscription_id
}

# No provider "azuread" {} here — nothing under bootstrap/cluster/platform's
# module tree creates an azuread_* resource anymore (modules/key_vault's ESO
# identity moved to a plain azurerm_user_assigned_identity). Only
# modules/github_action still does, and that's part of ./cicd/'s separate
# apply (see ./cicd/providers.tf), not this root.

# Kubernetes/Helm/kubectl providers — configured from the cluster submodule's
# own outputs. This is a same-apply "provider configured from a resource this
# apply also creates" pattern, using AKS's STATIC kube_config cert fields
# (client_certificate/client_key/cluster_ca_certificate), not a deferred-auth
# escape hatch like AWS's `exec` block. This is the standard, documented
# pattern for a single-apply AKS + in-cluster-workloads Terraform config
# (Microsoft's own AKS + Terraform tutorials configure the kubernetes/helm
# providers this exact way) — Terraform defers actually connecting until the
# first kubernetes/helm/kubectl resource is planned/applied (all of which
# live inside the cluster/platform submodules), by which time AKS already
# exists.
provider "kubernetes" {
  host                   = module.cluster.aks_host
  client_certificate     = base64decode(module.cluster.aks_client_certificate)
  client_key             = base64decode(module.cluster.aks_client_key)
  cluster_ca_certificate = base64decode(module.cluster.aks_cluster_ca_certificate)
}

provider "helm" {
  kubernetes = {
    host                   = module.cluster.aks_host
    client_certificate     = base64decode(module.cluster.aks_client_certificate)
    client_key             = base64decode(module.cluster.aks_client_key)
    cluster_ca_certificate = base64decode(module.cluster.aks_cluster_ca_certificate)
  }
}

provider "kubectl" {
  host                   = module.cluster.aks_host
  client_certificate     = base64decode(module.cluster.aks_client_certificate)
  client_key             = base64decode(module.cluster.aks_client_key)
  cluster_ca_certificate = base64decode(module.cluster.aks_cluster_ca_certificate)
  load_config_file       = false
}
