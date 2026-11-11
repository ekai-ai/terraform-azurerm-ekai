# Self-service client template — "customer" stands in for a real customer
# name. Unlike dev/qa/staging/prod (Ekai's own environments), a self-service
# deployment isn't a tier — it's one client's own Azure subscription. Copy
# this file, rename it to the client's actual name, fill in the values below.
#
# The repo root and cicd/ are reusable Terraform modules (no backend block of
# their own) — this ONE tfvars file feeds the two ACTUAL state-holding root
# configs that wrap them, examples/self-deploy/root and
# examples/self-deploy/cicd (exactly like the original 4-layer design, where
# one tfvars file already served all 4 layers; each config simply ignores
# the tfvars keys it doesn't declare a variable for):
#   examples/self-deploy/root  — wraps the repo root (bootstrap + cluster +
#      platform, combined into one apply/state, down from 3 separate ones in
#      the original design)
#   examples/self-deploy/cicd  — wraps cicd/, kept as its own separate
#      apply/state, same as the original 04-cicd layer, because the ArgoCD
#      Terraform provider can only be configured from a value read from an
#      ALREADY-COMPLETED apply's state (a remote_state read), never from a
#      resource this SAME apply also creates — see cicd/main.tf's file
#      header for the full reasoning.
#
# So: 2 backend config files, 2 inits, 2 applies (in order — cicd depends on
# the root's state). Run scripts/init-state-backend.sh <name> to generate
# both (it also creates the resource group this all lives in), then:
#   cd examples/self-deploy/root
#   terraform init -backend-config=../../../env/backend-<name>.tfbackend
#   terraform apply -var-file=../../../env/<name>.tfvars
#   cd ../cicd
#   terraform init -backend-config=../../../env/backend-<name>-cicd.tfbackend
#   terraform apply -var-file=../../../env/<name>.tfvars
# (scripts/self-deploy.sh does all of this for you, in order.)

# ─── Identity ──────────────────────────────────────────────────────────────────
subscription_id = "00000000-0000-0000-0000-000000000000" # a real client's own Azure subscription
region          = "northeurope"
# Unique per deployment -- gets embedded in every resource name this creates
# (AKS cluster, Key Vault, Postgres server, the state storage account, ...).
# Re-running with the same value modifies THIS deployment, not a new one.
env_name = "customer"
# Pre-existing resource group -- created out-of-band by
# scripts/init-state-backend.sh (same script that creates the tfstate storage
# account). Terraform reads it via data source, never creates it itself.
resource_group_name = "ekai-saas-customer"

# ─── Networking / AKS ──────────────────────────────────────────────────────────
vnet_cidr        = "10.0.0.0/16"
pub_sub_1_a_cidr = "10.0.1.0/24"
pri_sub_1_cidr   = "10.0.4.0/22"
pri_sub_2_cidr   = "10.0.8.0/22"
pri_sub_3_cidr   = "10.0.16.0/22"

cluster_name    = "ekai-saas-aks-customer"
cluster_version = "1.34.1"
# Dsv5 family (AMD), not a B-series Burstable size -- Burstable is CPU-credit
# based and not appropriate for a continuously-loaded production node pool
# (Microsoft's own guidance scopes B-series to dev/test and intermittent
# workloads). Dsv5 also has a genuine self-service quota path; some
# Burstable families are flagged by Azure as legacy and refuse quota
# increases outright (confirmed live against a real subscription).
vm_size         = "Standard_D2as_v5"

# zones defaults to ["1", "2", "3"] (all node pools spread across all three)
# -- not every Azure region (or every individual subscription within a
# region that otherwise supports zones) has capacity for a given VM size in
# all three zones. Verify the target region/subscription does before
# applying (an unsupported zone fails the apply outright, see
# Troubleshooting); set zones = ["1"] (or whichever single zone is
# available) if it doesn't -- confirmed live on a capacity-constrained
# subscription where this affected every VM size tried, not just one.

system_node_pool_min_count = 1
system_node_pool_max_count = 3
# VM SKU + scaling for the app (user) node pool where all workloads run.
# Needs enough CPU/memory for the whole app stack (backend/frontend/erd/
# workers/profile) plus Redis and cluster addons.
#
# Check your subscription's vCPU quota BEFORE the first apply, not after it
# fails partway through: steady state alone already needs 10 vCPUs --
# system_node_pool_min_count (1) x Standard_D2as_v5 (2 vCPU) + app_node_pool_min_count
# (2) x Standard_D4as_v5 (4 vCPU) -- and AKS node-image upgrades temporarily run
# extra nodes on top of that (upgrade_settings.max_surge in modules/aks/main.tf),
# so budget noticeably more than 10. A fresh/trial subscription's default
# "Total Regional vCPUs" quota is commonly as low as ~10 -- request an
# increase in the Azure Portal (Service Quotas) well before deploying.
# Usually self-service/fast, but not guaranteed -- confirmed live that a
# constrained subscription can reject even a modest increase outright,
# needing an Azure support ticket instead. See the README's Troubleshooting
# section if you hit InsufficientVCPUQuota mid-apply.
app_vm_size             = "Standard_D4as_v5"
app_node_pool_min_count = 2
app_node_pool_max_count = 6

log_analytics_workspace_name = "ekaiaksworkspace-customer"

# ─── PostgreSQL Flexible Server ────────────────────────────────────────────────
# GP_Standard_D2s_v3 (General Purpose), not the root default's cheaper
# B_Standard_B1ms (Burstable) -- Azure Postgres Flexible Server's zone-
# redundant HA feature (enable_ha below) is NOT available on the Burstable
# tier at all, only General Purpose/Memory Optimized. A real production
# deployment needs both the HA-capable tier and HA actually turned on --
# matches terraform-aws-ekai's customer.tfvars, which also upgrades off its
# own cheapest default (db.t3.medium, multi_az = true) for the same reason.
postgres_flexible_server_sku_name   = "GP_Standard_D2s_v3"
postgres_flexible_server_storage_mb = 65536
postgresql_version                  = "15"
enable_ha                           = true # zone-redundant standby -- roughly doubles Postgres cost, set false for non-prod envs
geo_redundant_backup_enabled        = true # cross-region backup copy -- also roughly doubles backup storage cost

# ─── ACR ───────────────────────────────────────────────────────────────────────
create_acr = true
# existing_acr_name = "ekaiclientacr"   # required when create_acr = false

# ─── bootstrap submodule (DNS zone) ────────────────────────────────────────────
# manage_dns_zone = true  → Terraform creates the Azure DNS zone below.
# A real client with their own domain already in Azure DNS would instead set
# manage_dns_zone = false and rely on dns_zone alone (no zone_id variable
# needed here -- Azure DNS zones are looked up/created by name, not by ID).
dns_zone        = "customer.ekai.ai" # stand-in — a real client uses their own domain
manage_dns_zone = true

# ─── platform submodule ────────────────────────────────────────────────────────
argocd_namespace = "argocd"
# argocd_admin_password_hashed intentionally omitted — cicd_provider = "none"
# generates its own ArgoCD admin password + hash directly (platform submodule).

# Redis and Neo4j are always deployed (no enable_redis/enable_neo4j toggle in
# this repo) — the ekai-saas chart's ERD/KEDA features need both.

# Let's Encrypt registration email. cluster_issuer_name defaults to
# "letsencrypt-prod" (a real, browser-trusted cert) -- left unset here. Only
# override it to "letsencrypt-staging" in a throwaway test env's own tfvars,
# to avoid burning the production rate limit (5 duplicate certs/week per
# domain) across repeated apply/destroy cycles.
# REPLACE_ME is not a usable address -- it's a loud placeholder, not a
# stand-in Terraform will silently accept. Set this to a real address before
# applying (Terraform's own validation rejects REPLACE_ME/empty/malformed).
acme_email = "REPLACE_ME"

# minio_persistence_size default (50Gi) x minio_replicas default (4) = 200Gi
# total provisioned storage.

# ─── cicd/ (separate apply) — self-service mode ────────────────────────────────
# cicd_provider = "none" is the entire point of this file: no GitHub Actions
# wiring — ArgoCD pulls the ekai-saas Helm chart directly. None of
# manifests_branch/github_owner/cd_repos apply here.
cicd_provider = "none"

namespace = "ekai-saas"

# Real, public, no-login images Ekai publishes to public.ecr.aws — same
# cross-cloud registry AWS/GCP's self-service distributions already pull
# from, proven to work with zero auth friction from a non-AWS cluster.
existing_image_registry_base_url = "public.ecr.aws/s7m9t1b0"
image_tag                        = "latest"

# Chart Terraform installs via ArgoCD — "*" tracks latest automatically.
helm_chart_repo_url = "public.ecr.aws/s7m9t1b0/ekai-helm"
helm_chart_version  = "*"

# secrets_name defaults to "ekai-<env_name>" — left as default.
# key_vault_name defaults to "ekai-<env_name>-<subscription_id>" (truncated
# to 24 chars) — left as default.
# tls_name defaults to "<env_name>-ekai-wildcard-tls" — left as default.
# shared_service_account_name defaults to "ekai-app-sa" — left as default.
# purge_vault_on_destroy defaults to false — left as default. A destroy
# leaves the Key Vault soft-deleted for Azure's normal 7-day window instead
# of purging it immediately, so no extra Azure permission is needed. Only
# set this to true for internal fast destroy/reapply test loops, which also
# requires granting the deployer SP a subscription-scoped custom RBAC role
# (see scripts/self-deploy.sh) — not something to ask a real customer for.
