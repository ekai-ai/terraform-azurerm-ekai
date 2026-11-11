# ──────────────────────────────────────────────────────────────────────────────
# examples/self-deploy/root/outputs.tf — re-exports every one of
# ../../../outputs.tf's outputs as module.infra.X. See that file for
# descriptions of what each value is and who consumes it.
# ──────────────────────────────────────────────────────────────────────────────

output "argocd_url" {
  value = module.infra.argocd_url
}

output "argocd_admin_username" {
  value = module.infra.argocd_admin_username
}

output "argocd_namespace" {
  value = module.infra.argocd_namespace
}

output "argocd_admin_password" {
  value     = module.infra.argocd_admin_password
  sensitive = true
}

output "dns_zone_name" {
  value = module.infra.dns_zone_name
}

output "dns_zone_name_servers" {
  value = module.infra.dns_zone_name_servers
}

output "aks_cluster_name" {
  value = module.infra.aks_cluster_name
}

output "region" {
  value = module.infra.region
}

output "key_vault_name" {
  value = module.infra.key_vault_name
}

output "tls_name" {
  value = module.infra.tls_name
}

output "aks_host" {
  value     = module.infra.aks_host
  sensitive = true
}

output "aks_client_certificate" {
  value     = module.infra.aks_client_certificate
  sensitive = true
}

output "aks_client_key" {
  value     = module.infra.aks_client_key
  sensitive = true
}

output "aks_cluster_ca_certificate" {
  value     = module.infra.aks_cluster_ca_certificate
  sensitive = true
}

output "oidc_issuer_url" {
  value = module.infra.oidc_issuer_url
}

output "key_vault_id" {
  value = module.infra.key_vault_id
}

output "acr_id" {
  value = module.infra.acr_id
}

output "acr_login_server" {
  value = module.infra.acr_login_server
}

output "cluster_secret_store_name" {
  value = module.infra.cluster_secret_store_name
}

output "argocd_admin_password_plaintext" {
  value     = module.infra.argocd_admin_password_plaintext
  sensitive = true
}

output "argocd_ingress_host" {
  value = module.infra.argocd_ingress_host
}
