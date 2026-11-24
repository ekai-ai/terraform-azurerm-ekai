# Submodule note: provider "azurerm" {}, provider "kubernetes" {}, provider
# "helm" {}, and provider "kubectl" {} configuration blocks now live only in
# the root module's providers.tf (a submodule cannot declare a provider
# configuration block of its own) — see ../../providers.tf. Those blocks
# used to be configured here from `data "terraform_remote_state" "cluster"`
# reads; root now gets the same values directly from module.cluster's
# outputs.
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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
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
      source  = "alekc/kubectl"
      version = "~> 3.0"
    }
  }
}
