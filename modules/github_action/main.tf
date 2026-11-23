locals {
  # Per-service map — keyed by service name. Used for resources that ARE
  # per-service (workflow file, manifest patcher) where each service needs
  # its own copy.
  cd_repos_map = { for r in var.cd_repos : r.name => r }

  # Per-(reponame, repo_env) map — keyed by the unique combo. Used for
  # resources that live at the GitHub-environment level (federated identity
  # credentials, env-scoped Action secrets like AZURE_CLIENT_ID,
  # AZURE_ACR_LOGIN_SERVER, etc.). Without dedup, multiple services in the
  # same repo+env would create duplicate Terraform resources pointing to the
  # SAME underlying GitHub secret — first destroy succeeds, the rest 404.
  # Federated creds have a stricter version of the same constraint: Azure
  # rejects `(issuer, subject)` collisions with 400 "InvalidFederated…".
  federated_cred_map = {
    for combo in distinct([for r in var.cd_repos : "${r.reponame}::${r.repo_env}"]) :
    combo => {
      reponame = split("::", combo)[0]
      repo_env = split("::", combo)[1]
    }
  }

  # Image prefix used when updating the manifest file. Priority:
  # Azure ACR > AWS ECR > DockerHub. Whichever is the first enabled is the one
  # the manifest points to; the build/push steps still push to *every* enabled
  # registry so mirrors stay in sync.
  primary_image_prefix = (
    var.registries.azure.enabled && var.external_acr_login_server != null ? var.external_acr_login_server :
    var.registries.azure.enabled && length(azurerm_container_registry.acr) > 0 ? azurerm_container_registry.acr[0].login_server :
    var.registries.aws_ecr.enabled ? var.registries.aws_ecr.registry_url :
    var.registries.dockerhub.enabled ? var.registries.dockerhub.namespace :
    ""
  )
}

data "azurerm_client_config" "current" {}

# AzureAD client config — provides the deploying SP's object_id so we can
# register it as an explicit owner of the Apps Terraform creates. With the
# deploying SP marked as owner, the minimal `Application.ReadWrite.OwnedBy`
# Graph permission is sufficient — we do NOT need `Application.ReadWrite.All`
# (which is over-privileged for client subscriptions and fails SOC2/PCI review).
data "azuread_client_config" "current" {}

data "azurerm_kubernetes_cluster" "aks" {
  name                = var.aks_name
  resource_group_name = var.resource_group_name
}

# ═════════════════════════════════════════════════════════════════════════════
# AZURE ACR
# In the layered architecture, Layer 02 creates the ACR and grants AcrPull to
# the AKS kubelet identity. This module receives `var.external_acr_id` from
# Layer 04 and only manages AcrPush for the github-actions SP.
#
# The fallback `var.external_acr_id == null` branch (creating ACR here) is
# retained so this module remains usable in standalone test fixtures.
# ═════════════════════════════════════════════════════════════════════════════

resource "azurerm_container_registry" "acr" {
  count               = var.registries.azure.enabled && var.external_acr_id == null ? 1 : 0
  name                = "ekai${var.env_name}acr"
  resource_group_name = var.resource_group_name
  location            = var.region
  sku                 = "Standard"
  admin_enabled       = false
}

resource "azurerm_role_assignment" "acr_pull_for_aks" {
  count                            = var.registries.azure.enabled && var.external_acr_id == null ? 1 : 0
  scope                            = azurerm_container_registry.acr[0].id
  role_definition_name             = "AcrPull"
  principal_id                     = data.azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}

locals {
  # Single source of truth for ACR ID + login server, regardless of mode.
  acr_id           = var.external_acr_id != null ? var.external_acr_id : try(azurerm_container_registry.acr[0].id, "")
  acr_login_server = var.external_acr_login_server != null ? var.external_acr_login_server : try(azurerm_container_registry.acr[0].login_server, "")
}

# ═════════════════════════════════════════════════════════════════════════════
# Entra ID service principal federated with GitHub OIDC — used for ACR push.
# Created only when Azure is a target registry.
# ═════════════════════════════════════════════════════════════════════════════

resource "azuread_application" "github_actions" {
  count        = var.registries.azure.enabled ? 1 : 0
  display_name = "ekai-github-actions-${var.env_name}"
  # Explicit owner so the deploying SP can manage this app via the minimal
  # `Application.ReadWrite.OwnedBy` Graph permission (no need for the broader
  # `Application.ReadWrite.All`).
  owners = [data.azuread_client_config.current.object_id]
}

resource "azuread_service_principal" "github_actions" {
  count     = var.registries.azure.enabled ? 1 : 0
  client_id = azuread_application.github_actions[0].client_id
}

resource "azuread_application_federated_identity_credential" "github_actions" {
  # ONE credential per (reponame, repo_env) — shared across services that live
  # in the same repo. See `local.federated_cred_map` comment above for the why.
  for_each = var.registries.azure.enabled ? local.federated_cred_map : {}

  application_id = azuread_application.github_actions[0].id
  display_name   = "github-${each.value.reponame}-${each.value.repo_env}"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${var.github_owner}/${each.value.reponame}:environment:${each.value.repo_env}"
}

resource "azurerm_role_assignment" "github_actions_acr_push" {
  count                = var.registries.azure.enabled ? 1 : 0
  scope                = local.acr_id
  role_definition_name = "AcrPush"
  principal_id         = azuread_service_principal.github_actions[0].object_id
  # Newly-created SP needs ~30-60s for Entra replication.
  skip_service_principal_aad_check = true
}

# ═════════════════════════════════════════════════════════════════════════════
# GitHub Environments — must exist before pushing env-scoped secrets.
# (Without this, github_actions_environment_secret hits 404 /public-key.)
# Reuses federated_cred_map (already dedup'd by repo+env).
# ═════════════════════════════════════════════════════════════════════════════

resource "github_repository_environment" "deploy" {
  for_each = local.federated_cred_map

  repository  = each.value.reponame
  environment = each.value.repo_env
}

# ═════════════════════════════════════════════════════════════════════════════
# Per-repo GitHub Actions environment secrets
# ═════════════════════════════════════════════════════════════════════════════

# All env-scoped secrets are keyed by `(reponame, repo_env)` (federated_cred_map),
# NOT by service name. GitHub's secret store has only one slot per
# (repo, environment, secret_name); creating multiple Terraform resources
# pointing to the same slot causes duplicate-write races on apply and
# 404-on-second-delete races on destroy.

# --- Azure (ACR + OIDC) ---
resource "github_actions_environment_secret" "acr_login_server" {
  depends_on = [github_repository_environment.deploy]
  for_each   = var.registries.azure.enabled ? local.federated_cred_map : {}

  repository      = each.value.reponame
  secret_name     = "AZURE_ACR_LOGIN_SERVER"
  environment     = each.value.repo_env
  plaintext_value = local.acr_login_server
}

resource "github_actions_environment_secret" "azure_client_id" {
  depends_on = [github_repository_environment.deploy]
  for_each   = var.registries.azure.enabled ? local.federated_cred_map : {}

  repository      = each.value.reponame
  secret_name     = "AZURE_CLIENT_ID"
  environment     = each.value.repo_env
  plaintext_value = azuread_application.github_actions[0].client_id
}

resource "github_actions_environment_secret" "azure_tenant_id" {
  depends_on = [github_repository_environment.deploy]
  for_each   = var.registries.azure.enabled ? local.federated_cred_map : {}

  repository      = each.value.reponame
  secret_name     = "AZURE_TENANT_ID"
  environment     = each.value.repo_env
  plaintext_value = data.azurerm_client_config.current.tenant_id
}

resource "github_actions_environment_secret" "azure_subscription_id" {
  depends_on = [github_repository_environment.deploy]
  for_each   = var.registries.azure.enabled ? local.federated_cred_map : {}

  repository      = each.value.reponame
  secret_name     = "AZURE_SUBSCRIPTION_ID"
  environment     = each.value.repo_env
  plaintext_value = data.azurerm_client_config.current.subscription_id
}

# --- DockerHub (external registry) ---
resource "github_actions_environment_secret" "dockerhub_username" {
  depends_on = [github_repository_environment.deploy]
  for_each   = var.registries.dockerhub.enabled ? local.federated_cred_map : {}

  repository      = each.value.reponame
  secret_name     = "DOCKERHUB_USERNAME"
  environment     = each.value.repo_env
  plaintext_value = var.dockerhub_username
}

resource "github_actions_environment_secret" "dockerhub_token" {
  depends_on = [github_repository_environment.deploy]
  for_each   = var.registries.dockerhub.enabled ? local.federated_cred_map : {}

  repository      = each.value.reponame
  secret_name     = "DOCKERHUB_TOKEN"
  environment     = each.value.repo_env
  plaintext_value = var.dockerhub_token
}

# --- AWS ECR (external registry) ---
resource "github_actions_environment_secret" "aws_ecr_access_key_id" {
  depends_on = [github_repository_environment.deploy]
  for_each   = var.registries.aws_ecr.enabled ? local.federated_cred_map : {}

  repository      = each.value.reponame
  secret_name     = "AWS_ECR_ACCESS_KEY_ID"
  environment     = each.value.repo_env
  plaintext_value = var.aws_ecr_access_key_id
}

resource "github_actions_environment_secret" "aws_ecr_secret_access_key" {
  depends_on = [github_repository_environment.deploy]
  for_each   = var.registries.aws_ecr.enabled ? local.federated_cred_map : {}

  repository      = each.value.reponame
  secret_name     = "AWS_ECR_SECRET_ACCESS_KEY"
  environment     = each.value.repo_env
  plaintext_value = var.aws_ecr_secret_access_key
}

# --- Common secrets ---
resource "github_actions_environment_secret" "github_token" {
  depends_on = [github_repository_environment.deploy]
  for_each   = local.federated_cred_map

  repository      = each.value.reponame
  secret_name     = "org_token_github"
  environment     = each.value.repo_env
  plaintext_value = var.github_token
}

# Master Key Vault secret merge happens in Layer 03 (03-platform/main.tf), where
# all platform-derived values (DATABASE_URL, REDIS_*) come together.
# This module focuses on CI/CD (federated identity, GitHub workflow files, repo secrets).
#
# Per-service Key Vault secrets (`<service>-env`) are created MANUALLY by the
# client AFTER infra deploy — see CLIENT-ONBOARDING-AZURE.md and CLIENT-HANDOVER-AZURE.md.
# Client copies DATABASE_URL / REDIS_* from the master secret into
# each per-service secret as needed.

# ═════════════════════════════════════════════════════════════════════════════
# Workflow YAML — pushed into each cd_repo
# ═════════════════════════════════════════════════════════════════════════════

resource "github_repository_file" "deploy_workflow" {
  for_each = local.cd_repos_map

  repository = each.value.reponame
  file       = ".github/workflows/azure-${each.value.name}-deploy-${var.env_name}.yml"
  # Push to a per-env branch (named after `repo_env`, e.g. "client1"), NOT the
  # repo's default branch. Default is typically protected — direct pushes
  # return `409 Repository rule violations: Changes must be made through a pull
  # request`. The env-named branch is short-lived and unprotected.
  # Pre-requisite: the branch (e.g. `client1`) must already exist on every app
  # repo before Terraform applies. Create with:
  #   gh api -X POST "/repos/<owner>/<repo>/git/refs" \
  #     -f ref="refs/heads/<env>" -f sha="$(gh api /repos/<owner>/<repo>/git/refs/heads/main --jq .object.sha)"
  branch              = each.value.repo_env
  commit_message      = "Add/update CICD workflow for Azure ${each.value.name}"
  overwrite_on_create = true

  content = templatefile("${path.module}/workflow_template.tftpl", {
    repo                  = each.value
    github_owner          = var.github_owner
    github_username       = var.github_username
    github_email          = var.github_email
    manifests_reponame    = var.manifests_reponame
    manifests_branch      = var.manifests_branch
    manifests_path        = var.manifests_path
    manifest_checkout_dir = var.manifests_path
    # ↑ same value as manifests_path. Kept as a separate template var so any
    #   references to ${manifest_checkout_dir} in the workflow template still
    #   resolve. Single source of truth = var.manifests_path.
    env_name             = var.env_name
    registries           = var.registries
    primary_image_prefix = local.primary_image_prefix
    dockerhub_namespace  = var.registries.dockerhub.namespace
    aws_ecr_registry_url = var.registries.aws_ecr.registry_url
    aws_ecr_region       = var.registries.aws_ecr.region
  })

  depends_on = [
    github_actions_environment_secret.acr_login_server,
    github_actions_environment_secret.azure_client_id,
    github_actions_environment_secret.azure_tenant_id,
    github_actions_environment_secret.azure_subscription_id,
    github_actions_environment_secret.dockerhub_username,
    github_actions_environment_secret.dockerhub_token,
    github_actions_environment_secret.aws_ecr_access_key_id,
    github_actions_environment_secret.aws_ecr_secret_access_key,
    azuread_application_federated_identity_credential.github_actions,
    azurerm_role_assignment.github_actions_acr_push,
  ]
}
