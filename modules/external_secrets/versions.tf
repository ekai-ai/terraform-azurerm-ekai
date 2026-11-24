# Required because the kubectl provider is not in the default registry namespace.
# Terraform must know to fetch `alekc/kubectl` (not `hashicorp/kubectl`).
terraform {
  required_version = ">= 1.5"

  required_providers {
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.1.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}
