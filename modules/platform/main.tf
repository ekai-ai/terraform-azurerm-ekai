# ──────────────────────────────────────────────────────────────────────────
# platform submodule — Helm releases + cluster manifests
# Depends on the cluster submodule (wired by the root module — module
# outputs instead of terraform_remote_state reads, since this is now one
# apply/one state).
# ──────────────────────────────────────────────────────────────────────────

locals {
  self_service = var.cicd_provider == "none"

  common_tags = {
    env       = var.env_name
    layer     = "platform"
    managedBy = "terraform"
  }
}

# ── ArgoCD admin password — self-service generates it directly; otherwise
#    read from the master Key Vault secret (var.argocd_admin_password_hashed,
#    passed in from tfvars). Read from terraform_data below, not bcrypt()
#    directly -- bcrypt() generates a fresh random salt on every single call,
#    so a plain local would produce a DIFFERENT hash on every plan/apply even
#    though the underlying password never changes, making ArgoCD's admin
#    secret look "modified" forever. ─────────────────────────────────────
resource "random_password" "argocd_admin" {
  count   = local.self_service ? 1 : 0
  length  = 24
  special = false
}

resource "terraform_data" "argocd_admin_password_hashed" {
  count = local.self_service ? 1 : 0
  input = bcrypt(random_password.argocd_admin[0].result, 10)

  lifecycle {
    ignore_changes = [input]
  }
}

locals {
  argocd_admin_password_hashed = local.self_service ? terraform_data.argocd_admin_password_hashed[0].output : var.argocd_admin_password_hashed
}

# ── nginx-ingress (provides cluster LB IP for everything else) ──────────────
module "nginx_ingress" {
  source = "../nginx_ingress"
}

# ── cert-manager (DNS01 via Azure DNS Contributor UAMI) ─────────────────────
module "cert-manager" {
  source              = "../cert-manager"
  resource_group_name = var.resource_group_name
  subscription_id     = var.subscription_id
  client_id           = var.cert_manager_uami_client_id
  dns_zone            = var.dns_zone
  tls_name            = var.tls_name
  namespace           = var.namespace
  acme_email          = var.acme_email
  cluster_issuer_name = var.cluster_issuer_name
  depends_on          = [module.nginx_ingress]
}

# ── Reloader — auto-restart pods when their Secret/ConfigMap changes ───────
# Without this, env-var updates pushed to Azure KV → ESO-synced K8s Secrets
# wouldn't propagate to running pods until manual `kubectl rollout restart`.
# Reloader watches Secret changes globally and triggers rollouts on
# Deployments annotated with `reloader.stakater.com/auto: "true"`.
module "reloader" {
  source        = "../reloader"
  chart_version = var.reloader_chart_version
  depends_on    = [module.nginx_ingress]
}

# ── External Secrets Operator (Helm + ClusterSecretStore) ───────────────────
module "external_secrets" {
  source                      = "../external_secrets"
  workload_identity_client_id = var.eso_app_client_id
  key_vault_uri               = "https://${var.key_vault_name}.vault.azure.net/"
  tenant_id                   = var.tenant_id
  chart_version               = var.eso_chart_version
  depends_on                  = [module.nginx_ingress]
}

# ── ArgoCD ──────────────────────────────────────────────────────────────────
module "argocd" {
  source                       = "../argocd"
  argocd_admin_password_hashed = local.argocd_admin_password_hashed
  argocd_ingress_host          = var.argocd_ingress_host
  argocd_namespace             = var.argocd_namespace
  tls_name                     = var.tls_name
  depends_on                   = [module.nginx_ingress, module.cert-manager]
}

# ── Redis (Bitnami's own image -- no ACR mirror needed, see modules/redis's
#    file header for why the redis-stack-server image-swap approach this
#    used to need mirroring for was dropped entirely) ───────────────────────
module "redis" {
  source                 = "../redis"
  redis_namespace        = var.redis_namespace
  chart_version          = var.redis_chart_version
  replica_count          = var.redis_replica_count
  persistence_size       = var.redis_persistence_size
  storage_class          = var.redis_storage_class
  metrics_enabled        = var.redis_metrics_enabled
  network_policy_enabled = var.redis_network_policy_enabled
  depends_on             = [module.nginx_ingress]
}

# ── Neo4j (community edition, in-cluster) ───────────────────────────────────
# The ekai-saas chart's ERD/KEDA features need this (same as Redis above) --
# ported from terraform-google-ekai's modules/neo4j per explicit instruction
# to match GCP. Always deployed, no enable/disable toggle, same as Redis
# already behaves in this repo (AWS/GCP gate both behind separate
# enable_redis/enable_neo4j variables; this repo never had that toggle for
# Redis either, so Neo4j follows the same existing convention instead of
# introducing a new one).
module "neo4j" {
  source = "../neo4j"

  namespace      = var.neo4j_namespace
  chart_version  = var.neo4j_chart_version
  storage_size   = var.neo4j_storage_size
  storage_class  = var.neo4j_storage_class
  memory_request = var.neo4j_memory_request
  memory_limit   = var.neo4j_memory_limit
  cpu_request    = var.neo4j_cpu_request
  cpu_limit      = var.neo4j_cpu_limit

  depends_on = [module.nginx_ingress]
}

# ── KEDA ──────────────────────────────────────────────────────────────────
# NOT installed here, unlike terraform-aws-ekai/terraform-google-ekai's
# platform modules (which both install their own helm_release.keda) --
# confirmed LIVE (real apply against a real AKS cluster) that AKS already
# runs KEDA as a native managed add-on whenever
# workload_autoscaler_profile.keda_enabled = true is set on the cluster
# (see modules/aks/main.tf -- already true in the original
# devops/azure-terraform source, before this repo existed). A second,
# separately-Helm-installed KEDA collides with AKS's own
# "aks-managed-keda" release over cluster-scoped CRDs
# (cloudeventsources.eventing.keda.sh, etc.) and fails outright:
# "CustomResourceDefinition ... exists and cannot be imported ... current
# value is 'aks-managed-keda'". EKS/GKE have no equivalent native
# integration, which is why AWS/GCP's self-service distros need to install
# KEDA themselves -- Azure's own managed add-on already covers the same
# ekai-saas chart ScaledObject use case with nothing further needed here.

# ── MinIO (distributed mode + bucket Job, images mirrored to ACR) ──────────
module "minio" {
  source           = "../minio"
  tls_name         = var.tls_name
  minio_namespace  = var.minio_namespace
  minio_host       = var.minio_host
  chart_version    = var.minio_chart_version
  minio_mode       = var.minio_mode
  minio_replicas   = var.minio_replicas
  persistence_size = var.minio_persistence_size
  storage_class    = var.minio_storage_class
  default_buckets  = var.minio_default_buckets
  enable_ingress   = var.minio_enable_ingress
  resources        = var.minio_resources
  tags             = local.common_tags
  # Pull all 3 MinIO images (server, client, console) from client's ACR
  # — mirrored at cluster-submodule apply time. No Docker Hub dependency at
  # runtime. Tags come from the cluster submodule's mirrored_image_tags
  # output so chart-default and ACR-mirrored tags can never drift apart.
  image_registry           = var.acr_login_server
  image_repository_main    = "bitnami/minio"
  image_repository_client  = "bitnami/minio-client"
  image_repository_console = "bitnami/minio-object-browser"
  image_tag_main           = var.mirrored_image_tags["minio"]
  image_tag_client         = var.mirrored_image_tags["minio_client"]
  image_tag_console        = var.mirrored_image_tags["minio_object_browser"]
  depends_on               = [module.nginx_ingress, module.cert-manager]
}

# ── Master Key Vault secret — self-service: nothing to adopt, Terraform
#    creates it fresh. Non-self-service: the client pre-populates this secret
#    (see modules/cluster's file header for the two-step-apply note this now
#    requires) with DB credentials + argocd_admin_password_plain +
#    github_token/username/email; read those below, deploy the platform,
#    then write back the merged secret with platform-derived values added.
data "azurerm_key_vault_secret" "db_credentials" {
  count        = local.self_service ? 0 : 1
  name         = var.secrets_name
  key_vault_id = var.key_vault_id
}

locals {
  master_creds                = local.self_service ? {} : jsondecode(data.azurerm_key_vault_secret.db_credentials[0].value)
  argocd_admin_password_plain = local.self_service ? random_password.argocd_admin[0].result : local.master_creds["argocd_admin_password_plain"]
}

# Self-service has no pre-existing secret to adopt -- a brand-new vault has
# nothing in it yet. Non-self-service adopts the client's pre-seeded secret
# so Terraform doesn't try to create-and-fail with "already exists". Verified
# empirically (see plan's spike notes) that a for_each import block with a
# FIXED (non-each-indexed) `to` address correctly toggles between "skip this
# import entirely" (empty for_each) and "import this one resource" (single-
# element for_each) -- Terraform does not require `to`/`id` to reference
# each.key/each.value when for_each only ever yields 0 or 1 elements. Targets
# master_non_self_service[0] specifically (see below) -- that resource's own
# count is gated on the identical `local.self_service` condition, so the
# import only ever fires exactly when that instance exists.
import {
  for_each = local.self_service ? [] : [1]
  to       = azurerm_key_vault_secret.master_non_self_service[0]
  id       = data.azurerm_key_vault_secret.db_credentials[0].id
}

# ── Self-service only: every value a fresh install needs that Terraform can
# generate or derive for certain. Mirrors terraform-google-ekai's
# modules/cicd/main.tf generation locals almost exactly -- Azure's
# self-service shape (nginx-ingress, in-cluster MinIO, no native cloud
# object storage path in the app) is architecturally closer to GCP's than to
# AWS's ALB/S3 shape. Field names/values below are the ones verified against
# real ekai-mono source this session (not Azure's own pre-existing
# MINIO_ENDPOINT/MINIO_ROOT_USER/MINIO_ROOT_PASSWORD naming above, which
# predates this and is left untouched for non-self-service fidelity).
resource "random_id" "encryption_key" {
  count       = local.self_service ? 1 : 0
  byte_length = 32
}

# Separate from encryption_key above -- this is a service-to-service
# internal auth secret, not an encryption key, so it gets its own value
# instead of sharing one. .hex (not .b64_url) specifically to match the
# format developers already generate this with by hand: `openssl rand -hex
# 32` -- 32 random bytes as a 64-char lowercase hex string.
resource "random_id" "internal_service_secret" {
  count       = local.self_service ? 1 : 0
  byte_length = 32
}

locals {
  # Self-service only -- non-self-service's github_token/username/email
  # already live in local.master_creds (client-provided), so merge() below
  # preserves them unchanged. A plain object with null fields would encode
  # as literal JSON nulls via jsonencode(), so each group below is its own
  # map instead of inline ternaries in the final merge().
  generated_argocd_creds = local.self_service ? {
    ARGOCD_USERNAME = "admin"
    ARGOCD_PASSWORD = local.argocd_admin_password_plain
  } : {}

  # AI_CORE_ENDPOINT is called by the BACKEND pod itself, server-to-server --
  # the in-cluster Service DNS name, not the public Ingress hostname (that
  # would hairpin the backend's own traffic back through nginx-ingress).
  # FRONTEND__*_URL are read by the *browser-side* JS bundle behind a strict
  # CSP + the frontend's own reverse-proxy -- must be relative paths.
  generated_service_urls = local.self_service ? {
    FRONTEND_URL                   = "https://portal.${var.dns_zone}"
    AI_CORE_ENDPOINT               = "http://ekai-erd:9002"
    PLATFORM__BACKEND_INTERNAL_URL = "http://ekai-backend:3000"
    FRONTEND__BACKEND_URL          = "/api/"
    FRONTEND__AI_CORE_URL          = "/api/ai_core_ms/"
  } : {}

  # Freshly generated per-install, never reused across environments. All
  # three deliberately share the SAME underlying value (not three
  # independent ones) -- ENCRYPTION_KEY and PLATFORM__FERNET_KEY are both
  # fed straight into Fernet, but from DIFFERENT services (ai-core's
  # crypto.py vs backend's encryption-fernet.ts encrypting/decrypting the
  # same data), so they must match or cross-service decryption fails.
  # ENCRYPTION_KEY/PLATFORM__FERNET_KEY get a "=" appended: random_id's
  # b64_url for byte_length=32 is unpadded base64 (43 chars), but both
  # Python's cryptography and the Fernet spec itself require the padded
  # 44-char form. PLATFORM__JWT_SECRET has no such format requirement, so
  # it's used unpadded. Matches terraform-google-ekai's modules/cicd/main.tf
  # exactly (terraform-aws-ekai's copy of this uses three separate random_id
  # resources instead -- not ported here per explicit instruction to match
  # GCP, and GCP's own comment is the one that documents why sharing one
  # value is actually required, not just a simplification).
  generated_crypto_keys = local.self_service ? {
    ENCRYPTION_KEY                    = "${random_id.encryption_key[0].b64_url}="
    PLATFORM__JWT_SECRET              = random_id.encryption_key[0].b64_url
    PLATFORM__FERNET_KEY              = "${random_id.encryption_key[0].b64_url}="
    PLATFORM__INTERNAL_SERVICE_SECRET = random_id.internal_service_secret[0].hex
  } : {}

  # Safe, non-secret, working defaults — same for every install.
  safe_defaults = local.self_service ? {
    DECRYPTED_EKAI_TOKEN        = "EKAI@8008"
    NODE_ENV                    = "production"
    ENVIRONMENT                 = "production"
    PORT                        = "3000"
    PLATFORM__PORT              = "3000"
    CONFIG_ROOT                 = "/app/config"
    PLATFORM__APPLICATION_NAME  = "ekai"
    PLATFORM__DISABLE_SAME_SITE = "false"
    AI_CORE__BASE_PATH          = "/app/workspaces"
    AI_CORE__REDIS_DB           = "0"
    AI_CORE__REDIS_BUFFER_TIME  = "60"
    LOGS_GROUP_NAME             = "ekai/${var.env_name}"
  } : {}

  # Only the client can provide these — real external accounts/keys Terraform
  # has no way to know. Blank for genuinely optional features (GitHub sync);
  # "REPLACE_ME" for ones the app needs to actually function (signup invite
  # emails go through AWS SES regardless of which cloud hosts the cluster --
  # no Azure-native equivalent in the app).
  client_provided_placeholders = local.self_service ? {
    PLATFORM__EKAI_GITHUB_APP_ID          = ""
    PLATFORM__EKAI_GITHUB_APP_PRIVATE_KEY = ""
    FRONTEND__GITHUB_SYNC_APP_URL         = ""

    AWS_ACCESS_KEY_ID     = "REPLACE_ME"
    AWS_SECRET_ACCESS_KEY = "REPLACE_ME"
    SES_AWS_REGION        = "REPLACE_ME"
    AWS_SES_FROM_EMAIL    = "REPLACE_ME"
  } : {}
}

locals {
  # Shared by both resources below -- the always-fresh, platform-derived
  # values every apply recomputes regardless of self_service.
  #
  # MINIO_ENDPOINT_URL/MINIO_ACCESS_KEY/MINIO_SECRET_ACCESS_KEY/EKAI_BUCKET/
  # AWS_REGION are the REAL keys the app reads -- confirmed directly against
  # ekai-mono source (services/platform/apps/backend/src/{aws,s3}/*.service.ts,
  # services/ai-core/ekai/aws/s3/handlers.py all read exactly these). The
  # devops/azure-terraform original this was ported from instead wrote
  # MINIO_ENDPOINT/MINIO_ROOT_USER/MINIO_ROOT_PASSWORD, which no app code
  # anywhere reads -- a pre-existing latent bug in that repo, fixed here to
  # match terraform-google-ekai's verified-correct naming. Same for
  # REDIS_URI (not REDIS_URL -- also unread by any app code either way,
  # confirmed via ekai-mono, so purely a naming-consistency fix, not a
  # functional one). AWS_REGION is a hardcoded dummy, not var.region: the
  # AWS SDK's S3Client requires a syntactically valid AWS region string
  # before it'll even construct (even though MinIO itself never checks it),
  # and an Azure region name like "northeurope" doesn't pass that format
  # check -- same reasoning as terraform-google-ekai's identical hardcode.
  platform_derived_values = {
    DATABASE_URL            = "postgresql://${var.backend_db_username}:${var.backend_db_password}@${var.postgres_fqdn}:5432/${var.backend_db_name}"
    REDIS_HOST              = module.redis.redis_host
    REDIS_PORT              = tostring(module.redis.redis_port)
    REDIS_USERNAME          = "default"
    REDIS_PASSWORD          = module.redis.redis_password
    REDIS_URI               = module.redis.redis_url
    USE_MINIO               = "true"
    MINIO_ENDPOINT_URL      = module.minio.minio_internal_endpoint
    MINIO_ACCESS_KEY        = module.minio.minio_root_user
    MINIO_SECRET_ACCESS_KEY = module.minio.minio_root_password
    EKAI_BUCKET             = var.minio_default_buckets[0]
    AWS_REGION              = "us-east-1"
    NEO4J_URI               = module.neo4j.bolt_uri
    NEO4J_USERNAME          = "neo4j"
    NEO4J_PASSWORD          = module.neo4j.neo4j_password
  }
}

# Self-service: nothing is ever read back from the vault (local.master_creds
# is always {} -- the data source above is skipped), so WITHOUT
# ignore_changes every apply would reset client_provided_placeholders
# (AWS_ACCESS_KEY_ID, etc.) back to "REPLACE_ME" even after the client has
# filled them in for real. Matches AWS/GCP's self-service customer secret
# exactly (both use `ignore_changes` on their equivalent resource for the
# same reason) -- Terraform sets this content once, at creation, and never
# overwrites whatever the client puts there afterward.
#
# lifecycle blocks can't take a conditional expression, so this has to be a
# separate resource (count-gated on local.self_service) from the
# non-self-service one below rather than one resource with a ternary
# ignore_changes list.
resource "azurerm_key_vault_secret" "master_self_service" {
  count        = local.self_service ? 1 : 0
  name         = var.secrets_name
  key_vault_id = var.key_vault_id
  content_type = "application/json"

  value = jsonencode(merge(
    local.client_provided_placeholders,
    local.safe_defaults,
    local.generated_service_urls,
    local.generated_crypto_keys,
    local.generated_argocd_creds,
    local.platform_derived_values,
    var.secret_value_overrides,
  ))

  lifecycle {
    ignore_changes = [value]
  }

  tags = local.common_tags

  depends_on = [module.redis, module.minio, module.neo4j]
}

# Non-self-service: re-reads the client's current secret every apply
# (local.master_creds, via the data source above) and merges fresh
# platform-derived values on top -- client-provided keys (github_token,
# argocd_admin_password_plain, ...) are preserved unchanged via merge(), no
# manual re-entry needed on subsequent applies, no ignore_changes needed
# since this never resets anything the client hasn't already set.
resource "azurerm_key_vault_secret" "master_non_self_service" {
  count        = local.self_service ? 0 : 1
  name         = var.secrets_name
  key_vault_id = var.key_vault_id
  content_type = "application/json"

  value = jsonencode(merge(local.master_creds, local.platform_derived_values))

  tags = local.common_tags

  depends_on = [module.redis, module.minio, module.neo4j]
}
