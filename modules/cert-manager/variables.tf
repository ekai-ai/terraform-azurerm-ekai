variable "subscription_id" {
  description = "Azure subscription ID that owns the DNS zone cert-manager manages."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group that contains the DNS zone cert-manager updates for ACME DNS-01 challenges."
  type        = string
}

variable "client_id" {
  description = "Client ID of the AKS workload-identity user-assigned identity cert-manager uses to update DNS."
  type        = string
}

variable "dns_zone" {
  description = "DNS zone cert-manager issues wildcard certificates for (e.g. knowledge.ekai.ai)."
  type        = string
}

variable "tls_name" {
  description = "Name of the Kubernetes Secret where the issued wildcard certificate is stored."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace where the wildcard TLS secret is created for application ingresses."
  type        = string
}

variable "acme_email" {
  description = "Email address registered with Let's Encrypt for certificate expiry notifications, for both the staging and prod ClusterIssuer."
  type        = string

  validation {
    condition     = var.acme_email != "" && var.acme_email != "REPLACE_ME" && can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.acme_email))
    error_message = "acme_email must be a real email address -- got empty, the literal placeholder \"REPLACE_ME\", or something that doesn't look like an email."
  }
}

variable "cluster_issuer_name" {
  description = "Which ClusterIssuer the wildcard Certificate actually uses — \"letsencrypt-staging\" (default, avoids Let's Encrypt's production rate limit during repeated apply/destroy cycles) or \"letsencrypt-prod\" for a real cutover. Both issuers are always created regardless of this value."
  type        = string
  default     = "letsencrypt-staging"
  validation {
    condition     = contains(["letsencrypt-staging", "letsencrypt-prod"], var.cluster_issuer_name)
    error_message = "cluster_issuer_name must be \"letsencrypt-staging\" or \"letsencrypt-prod\"."
  }
}
