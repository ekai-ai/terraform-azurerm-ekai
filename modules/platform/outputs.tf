output "cluster_secret_store_name" {
  description = "ClusterSecretStore name used by ExternalSecret resources in the cicd submodule"
  value       = module.external_secrets.cluster_secret_store_name
}

output "argocd_ingress_host" {
  description = "ArgoCD ingress hostname"
  value       = var.argocd_ingress_host
}

output "argocd_admin_password_plaintext" {
  description = "Plaintext ArgoCD admin password, self-service only (the cicd submodule's argocd provider needs it to authenticate). Null otherwise -- non-self-service envs still get this from the master Key Vault secret."
  sensitive   = true
  value       = local.self_service ? random_password.argocd_admin[0].result : null
}

output "redis_credentials" {
  description = "Redis connection details merged into app secrets by the cicd submodule."
  sensitive   = true
  value = {
    REDIS_HOST     = module.redis.redis_host
    REDIS_PORT     = tostring(module.redis.redis_port)
    REDIS_USERNAME = "default"
    REDIS_PASSWORD = module.redis.redis_password
    REDIS_URL      = module.redis.redis_url
  }
}

output "tls_name" {
  value = var.tls_name
}
