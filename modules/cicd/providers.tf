# Submodule note: provider "azurerm" {}, provider "kubernetes" {}, provider
# "kubectl" {}, and provider "argocd" {} configuration blocks now live only
# in the root module's providers.tf (a submodule cannot declare a provider
# configuration block of its own) — see ../../providers.tf. Those blocks
# used to be configured here from `data "terraform_remote_state"` reads
# against the cluster/platform states; root now gets the same values
# directly from module.cluster's / module.platform's outputs.
#
# provider "github" is intentionally NOT declared here (or at root):
# modules/github_action uses the `github` provider internally -- its own
# versions.tf/providers.tf declares and the ROOT configures it, same
# pattern as every other provider. (Unlike terraform-aws-ekai's distribution,
# which omits the github_actions module entirely, Azure's github_action
# module is simple/generic enough to ship fully functional here.)
#
# required_providers is kept here too — harmless, and documents this
# submodule's own provider requirements independent of root.

terraform {
  required_version = ">= 1.5"
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
