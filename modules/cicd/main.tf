# ──────────────────────────────────────────────────────────────────────────
# cicd submodule — CI/CD wiring
# Depends on the cluster and platform submodules (wired by the root module —
# module outputs instead of terraform_remote_state reads, since this is now
# one apply/one state).
# ──────────────────────────────────────────────────────────────────────────

locals {
  self_service = var.cicd_provider == "none"

  common_tags = merge(var.tags, {
    env       = var.env_name
    layer     = "cicd"
    managedBy = "terraform"
  })
}

# ── Master credentials from Key Vault — self-service skips this entirely:
# the platform submodule already wrote everything the app needs directly
# into var.secrets_name; this submodule's only use for reading it back is
# github_token/username/email (github_actions path only). ──────────────────
data "azurerm_key_vault_secret" "master" {
  count        = local.self_service ? 0 : 1
  name         = var.secrets_name
  key_vault_id = var.key_vault_id
}

locals {
  _secret         = local.self_service ? {} : jsondecode(data.azurerm_key_vault_secret.master[0].value)
  github_token    = local.self_service ? "" : local._secret["github_token"]
  github_username = local.self_service ? "" : local._secret["github_username"]
  github_email    = local.self_service ? "" : local._secret["github_email"]
}

# ── github_action — OIDC SP, env secrets, workflow YAML ────────────────────
# ACR is provisioned in the cluster submodule. We pass external_acr_id/
# login_server so github_action skips creating its own ACR and uses the
# cluster submodule's instead. AcrPush role is still managed by
# github_action (binds the OIDC SP to that ACR).
module "github_action" {
  count                     = local.self_service ? 0 : 1
  source                    = "../github_action"
  manifests_branch          = var.manifests_branch
  manifests_reponame        = var.manifests_reponame
  manifests_path            = var.manifests_path
  cd_repos                  = var.cd_repos
  region                    = var.region
  resource_group_name       = var.resource_group_name
  github_owner              = var.github_owner
  github_token              = local.github_token
  github_username           = local.github_username
  github_email              = local.github_email
  aks_name                  = var.aks_cluster_name
  env_name                  = var.env_name
  registries                = var.registries
  dockerhub_username        = var.dockerhub_username
  dockerhub_token           = var.dockerhub_token
  aws_ecr_access_key_id     = var.aws_ecr_access_key_id
  aws_ecr_secret_access_key = var.aws_ecr_secret_access_key

  external_acr_id           = var.acr_id
  external_acr_login_server = var.acr_login_server
}

# ArgoCD's own sync (CreateNamespace=true, see module.microservices_CD below)
# would eventually create this namespace too, but only asynchronously once it
# actually syncs -- not in time for the ExternalSecret/ServiceAccount
# resources below, which need it to exist in THIS apply. Idempotent either
# way: ArgoCD's CreateNamespace is a no-op once this already exists.
resource "kubernetes_namespace" "ekai_app" {
  metadata {
    name = var.namespace
  }
}

# ── ExternalSecret — ONE shared secret for every service, matching
# var.secrets_name's single-JSON-blob shape (the master Key Vault secret
# already holds everything every service needs, self-service or not -- see
# modules/platform's file header). Net new: zero ExternalSecret resources
# exist anywhere in the source codebase today, a documented manual client
# step instead. ──────────────────────────────────────────────────────────
resource "kubectl_manifest" "external_secret" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = var.secrets_name
      namespace = var.namespace
    }
    spec = {
      refreshInterval = "1m"
      secretStoreRef = {
        name = var.cluster_secret_store_name
        kind = "ClusterSecretStore"
      }
      target = {
        name           = var.secrets_name
        creationPolicy = "Owner"
      }
      dataFrom = [{
        extract = {
          key = var.secrets_name
        }
      }]
    }
  })

  depends_on = [kubernetes_namespace.ekai_app]
}

# ── Shared app Workload Identity — every ekai-saas pod runs as one shared
# ServiceAccount, matching the ekai-saas Helm chart's shared
# serviceAccountName model (AWS/GCP's self-service also collapse to a single
# shared identity rather than one per microservice -- see
# modules/app_workload_identity's caller comment). Called with ONE synthetic
# key so the module's existing per-service `for_each` shape produces exactly
# the SA name var.shared_service_account_name expects
# ("${each.key}-sa" = "ekai-app-sa" for key "ekai-app") -- no module changes
# needed. Unconditional (not self-service only): gives every deployment of
# this repo a real workload identity instead of the documented-but-unbuilt
# per-service identity story.
module "app_workload_identity" {
  source              = "../app_workload_identity"
  env_name            = var.env_name
  resource_group_name = var.resource_group_name
  location            = var.region
  pipelines           = [trimsuffix(var.shared_service_account_name, "-sa")]
  oidc_issuer_url     = var.oidc_issuer_url
  key_vault_id        = var.key_vault_id
  ekai_namespace      = var.namespace
  secret_name         = var.secrets_name

  depends_on = [kubernetes_namespace.ekai_app]
}

# ── Self-service Helm values — every field the ekai-saas chart's
# example-values.yaml exposes, sourced from what this layer already knows.
locals {
  self_service_helm_values = local.self_service ? yamlencode({
    namespace          = var.namespace
    dnsZone            = var.dns_zone
    imageRegistry      = var.existing_image_registry_base_url
    imageTag           = var.image_tag
    secretName         = var.secrets_name
    serviceAccountName = var.shared_service_account_name
    erd = {
      # AKS's built-in azurefile-csi StorageClass is ReadWriteMany-capable
      # (unlike the managed-premium/default Azure Disk classes, which are
      # ReadWriteOnce-only) -- erd/erd-worker/document-worker/profile-worker
      # share one scratch workspace and can land on different nodes, so an
      # RWO PVC deadlocks with Multi-Attach errors the same way AWS/GCP's
      # own comments describe for their RWO-by-default storage. The
      # ekai-saas chart's generic "pvc" type hardcodes ReadWriteOnce
      # regardless of storageClassName though -- its dedicated "azureFile"
      # type (>= chart 0.1.16) is what actually requests ReadWriteMany, no
      # EFS/GCS-FUSE-equivalent Terraform module needed since Azure Files
      # supports dynamic RWX provisioning out of the box.
      workspace = {
        type             = "azureFile"
        storageClassName = "azurefile-csi"
      }
    }
    ingress = {
      className = var.ingress_class_name
      annotations = {
        "nginx.ingress.kubernetes.io/ssl-redirect" = "true"
      }
      tls = {
        enabled    = true
        secretName = var.tls_name
      }
    }
  }) : ""
}

# ── ArgoCD application + wildcard DNS A record ───────────────────────────────
module "microservices_CD" {
  source              = "../microservices_CD"
  env                 = var.env_name
  source_type         = local.self_service ? "helm" : "git"
  dns_zone            = var.dns_zone
  resource_group_name = var.resource_group_name
  manifests_branch    = var.manifests_branch
  manifests_path      = var.manifests_path
  github_owner        = var.github_owner
  github_username     = local.github_username
  github_token        = local.github_token
  manifests_reponame  = var.manifests_reponame
  namespace           = var.namespace
  tags                = local.common_tags

  # source_type = "helm" only
  helm_repo_url      = var.helm_chart_repo_url
  helm_chart_version = var.helm_chart_version
  helm_values        = local.self_service_helm_values

  depends_on = [
    module.github_action,
    kubectl_manifest.external_secret,
    module.app_workload_identity,
  ]
}
