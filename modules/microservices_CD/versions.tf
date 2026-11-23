# `argocd` provider lives in the argoproj-labs namespace, not hashicorp.
# Required so Terraform can resolve the source address for child-module use.
terraform {
  required_version = ">= 1.5"

  required_providers {
    argocd = {
      source  = "argoproj-labs/argocd"
      version = "~> 7.11.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 3.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.9.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}
