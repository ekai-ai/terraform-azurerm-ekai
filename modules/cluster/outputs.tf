# ────────────────────────────────────────────────────────────────────────────
# cluster submodule outputs — consumed by the platform and cicd submodules.
# ────────────────────────────────────────────────────────────────────────────

output "env_name" {
  value = var.env_name
}

# --- AKS ---
output "aks_cluster_name" {
  value = module.aks.aks_cluster_name
}

output "aks_host" {
  value     = module.aks.aks_host
  sensitive = true
}

output "aks_client_certificate" {
  value     = module.aks.client_certificate
  sensitive = true
}

output "aks_client_key" {
  value     = module.aks.client_key
  sensitive = true
}

output "aks_cluster_ca_certificate" {
  value     = module.aks.cluster_ca_certificate
  sensitive = true
}

output "aks_oidc_issuer_url" {
  value = module.aks.oidc_issuer_url
}

# UAMI client_id used by cert-manager Helm chart's serviceAccount annotation
# (workload identity for DNS01 challenges via Azure DNS Contributor role).
output "cert_manager_uami_client_id" {
  value = module.aks.client_id
}

# --- PostgreSQL ---
output "postgres_fqdn" {
  value = module.postgresql_server.postgresql_server_fqdn_ekai
}

output "backend_db_username" {
  value     = local.backend_db_username
  sensitive = true
}

output "backend_db_password" {
  value     = local.backend_db_password
  sensitive = true
}

output "backend_db_name" {
  value     = local.backend_db_name
  sensitive = true
}

# --- Key Vault / ESO identity ---
output "eso_app_client_id" {
  value = module.key_vault.eso_client_id
}

output "key_vault_id" {
  value = module.key_vault.id
}

output "key_vault_name" {
  value = module.key_vault.name
}

output "key_vault_uri" {
  value = module.key_vault.uri
}

output "tenant_id" {
  value = module.key_vault.tenant_id
}

# --- Networking ---
output "vnet_id" {
  value = module.vnet.vnet_id
}

output "private_subnet_ids" {
  value = module.vnet.private_subnet_ids
}

# --- ACR + image mirror ---
output "acr_id" {
  value = local.acr_id
}

output "acr_name" {
  value = local.acr_name
}

output "acr_login_server" {
  value = local.acr_login_server
}
