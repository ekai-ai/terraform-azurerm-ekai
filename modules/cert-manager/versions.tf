terraform {
  required_version = ">= 1.5"

  required_providers {
    kubectl = {
      source  = "alekc/kubectl" # Explicit source
      version = "~> 3.0"        # Match root module's version
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
  }
}
