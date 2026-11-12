# ──────────────────────────────────────────────────────────────────────────────
# Root outputs — two audiences:
#
#   1. End-state values a client actually wants to see after `terraform apply`
#      (argocd_url/admin creds, DNS info, aks_cluster_name, region).
#
#   2. Values ./cicd/'s `data "terraform_remote_state" "combined"` block
#      reads (aks_host/aks_client_certificate/..., key_vault_id, oidc_issuer_url,
#      acr_id/acr_login_server, cluster_secret_store_name,
#      argocd_admin_password_plaintext) — these exist here ONLY because
#      ./cicd/ needs them; a human applying this config alone wouldn't
#      otherwise care.
# ──────────────────────────────────────────────────────────────────────────────

output "argocd_url" {
  description = "ArgoCD's public URL."
  value       = "https://${local.argocd_ingress_host}"
}

output "argocd_admin_username" {
  description = "ArgoCD admin username — always literally \"admin\"."
  value       = "admin"
}

output "argocd_admin_password" {
  description = "ArgoCD admin plaintext password (cicd_provider = \"none\" only — self-service generates this directly; non-self-service envs get it from their master Key Vault secret instead, not exposed here)."
  value       = module.platform.argocd_admin_password_plaintext
  sensitive   = true
}

output "dns_zone_name" {
  description = "DNS zone name actually in use (whichever the bootstrap submodule created or was pointed at)."
  value       = module.bootstrap.dns_zone_name
}

output "dns_zone_name_servers" {
  description = "NS records to delegate from the parent zone (e.g. ekai.ai). Empty when manage_dns_zone = false."
  value       = module.bootstrap.dns_zone_name_servers
}

output "aks_cluster_name" {
  description = "AKS cluster name — use with: az aks get-credentials --name <this> --resource-group <resource_group_name>"
  value       = module.cluster.aks_cluster_name
}

output "region" {
  description = "Azure region this was deployed into."
  value       = var.region
}

output "key_vault_name" {
  description = "Key Vault name actually used (whichever var.key_vault_name was set to, or the generated default)."
  value       = module.cluster.key_vault_name
}

output "tls_name" {
  description = "Name of the wildcard TLS Certificate/Secret actually used (whichever var.tls_name was set to, or the generated default). scripts/self-deploy.sh polls `kubectl get certificate <this> -n cert-manager` to confirm issuance."
  value       = local.tls_name
}

output "argocd_namespace" {
  description = "Namespace ArgoCD is installed into. scripts/self-deploy.sh uses this to verify the reflected wildcard cert secret actually landed there and that the ArgoCD Ingress's TLS secretName wasn't drifted away from it."
  value       = var.argocd_namespace
}

# ═══════════════════════════════════════════════════════════════════════════
# Consumed by ./cicd/'s data "terraform_remote_state" "combined" block only
# ═══════════════════════════════════════════════════════════════════════════

output "aks_host" {
  description = "AKS API server endpoint. Read by ./cicd/providers.tf's kubernetes/kubectl provider config."
  value       = module.cluster.aks_host
  sensitive   = true
}

output "aks_client_certificate" {
  value     = module.cluster.aks_client_certificate
  sensitive = true
}

output "aks_client_key" {
  value     = module.cluster.aks_client_key
  sensitive = true
}

output "aks_cluster_ca_certificate" {
  value     = module.cluster.aks_cluster_ca_certificate
  sensitive = true
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL of the AKS cluster. Read by ./cicd/'s app_workload_identity module for the shared app identity's federated credential."
  value       = module.cluster.aks_oidc_issuer_url
}

output "key_vault_id" {
  description = "Key Vault resource ID. Read by ./cicd/ for the master secret read + the shared app identity's Key Vault role assignment."
  value       = module.cluster.key_vault_id
}

output "acr_id" {
  value = module.cluster.acr_id
}

output "acr_login_server" {
  value = module.cluster.acr_login_server
}

output "cluster_secret_store_name" {
  description = "ClusterSecretStore name. Read by ./cicd/'s ExternalSecret resource."
  value       = module.platform.cluster_secret_store_name
}

output "argocd_admin_password_plaintext" {
  description = "Plaintext ArgoCD admin password (self-service only). Read by ./cicd/providers.tf's argocd provider config — this is the value that makes a same-apply provider \"argocd\" configuration unsafe here, which is exactly why cicd is a separate apply reading it via remote_state instead."
  value       = module.platform.argocd_admin_password_plaintext
  sensitive   = true
}

output "argocd_ingress_host" {
  description = "ArgoCD ingress hostname. Read by ./cicd/providers.tf's argocd provider config."
  value       = local.argocd_ingress_host
}
