

resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.cluster_name
  location            = var.region
  resource_group_name = var.resource_group_name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.cluster_version
  # "Free" (the AKS default when this isn't set) carries no SLA on the
  # control plane and is throttled more aggressively under API load --
  # "Standard" gives a financially-backed 99.95% uptime SLA, the expected
  # baseline for anything described as production infrastructure. This repo
  # self-service onboards real client production environments, so this
  # defaults to "Standard" rather than silently inheriting AKS's own
  # cost-optimized-for-dev default.
  sku_tier                = var.sku_tier
  private_cluster_enabled = false
  # Deliberately left unset -- a custom node_resource_group name moves its
  # creation from AKS's own first-party identity onto the identity actually
  # running this apply, which then needs subscription-scope
  # Microsoft.Resources/subscriptions/resourceGroups/write (Azure has to
  # authorize the name against the whole subscription before the resource
  # group exists to scope a narrower check against). The self-service
  # deployer SP only ever gets Owner on the one pre-existing resource group
  # (see scripts/self-deploy.sh) -- leaving this unset keeps AKS's own
  # default auto-named node RG (MC_<resource_group_name>_<cluster_name>_<region>),
  # which AKS creates and manages itself without needing that extra grant.
  workload_identity_enabled        = true
  oidc_issuer_enabled              = true
  open_service_mesh_enabled        = false
  image_cleaner_enabled            = true
  azure_policy_enabled             = false
  http_application_routing_enabled = false
  image_cleaner_interval_hours     = 24



  default_node_pool {
    name    = "system"
    vm_size = var.vm_size
    # Taint: CriticalAddonsOnly=true:NoSchedule — only kube-system core pods
    # (kube-dns, azure-cni, kube-proxy) tolerate this. All other workloads
    # (platform tools + app pods) land on the separate "apps" node pool.
    only_critical_addons_enabled = true
    vnet_subnet_id               = var.vnet_subnet_id[0]
    os_disk_size_gb              = 64
    host_encryption_enabled      = false
    node_public_ip_enabled       = false
    max_count                    = var.system_node_pool_max_count
    min_count                    = var.system_node_pool_min_count
    auto_scaling_enabled         = true
    temporary_name_for_rotation  = "systemtemp"
    # Without this, every node (across the whole min/max autoscaling range)
    # can land in a single availability zone -- an outage of just that one
    # zone takes the entire pool down together. var.zones defaults to all
    # three, but must be set to [] for regions with no zone support (not all
    # Azure regions have them -- verify the target region before applying;
    # an unsupported zone number fails the apply outright, it doesn't
    # silently ignore it).
    zones = var.zones
    upgrade_settings {
      max_surge = "60%"
    }
    tags = var.tags
  }

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags

  network_profile {
    network_plugin    = "azure"
    network_policy    = "calico"
    service_cidr      = "10.1.0.0/16"
    dns_service_ip    = "10.1.0.10"
    load_balancer_sku = "standard"

  }

  oms_agent {
    log_analytics_workspace_id      = var.log_analytics_workspace_id
    msi_auth_for_monitoring_enabled = true

  }

  # Azure File CSI driver -- ERD's shared workspace (erd/erd-worker/
  # document-worker/profile-worker) is backed by an azurefile-csi
  # ReadWriteMany PVC (see terraform-azure-ekai's cicd module's
  # self_service_helm_values), not a ReadWriteOnce Azure Disk PVC, to avoid
  # the single-node-attach deadlock when those pods land on different nodes
  # (same class of bug GCP/AWS hit with their own default storage and fixed
  # with GCS FUSE / EFS respectively). Declared explicitly, not relying on
  # AKS's own default for this, matching GCP's gke module's identical
  # reasoning for its gcs_fuse_csi_driver_config block ("so Terraform
  # doesn't treat this as unmanaged drift and disable it on a future
  # apply") -- not live-verified against a real AKS cluster that omitting
  # this block would behave any differently, but cheap to pin explicitly
  # either way.
  storage_profile {
    file_driver_enabled = true
  }
  workload_autoscaler_profile {
    keda_enabled                    = true
    vertical_pod_autoscaler_enabled = false

  }

  # Cluster autoscaler manages node_count between min/max — Terraform must
  # ignore live changes so plans don't try to "reset" it.
  lifecycle {
    ignore_changes = [
      default_node_pool[0].node_count,
      kubernetes_version,
    ]
  }
}

# App (user) node pool — all workloads land here: platform tools (ArgoCD,
# nginx, ESO, cert-manager, Redis, MinIO) and application pods (ekai-*).
# Kept separate from the system pool so cluster churn never competes with
# business workloads for capacity.
resource "azurerm_kubernetes_cluster_node_pool" "apps" {
  name                   = "apps"
  kubernetes_cluster_id  = azurerm_kubernetes_cluster.aks.id
  mode                   = "User"
  vm_size                = var.app_vm_size
  vnet_subnet_id         = var.vnet_subnet_id[0]
  os_disk_size_gb        = 128
  node_public_ip_enabled = false
  max_count              = var.app_node_pool_max_count
  min_count              = var.app_node_pool_min_count
  auto_scaling_enabled   = true
  zones                  = var.zones
  node_labels = {
    "workload" = "app"
  }
  upgrade_settings {
    max_surge = "50%"
  }
  tags = var.tags

  lifecycle {
    ignore_changes = [node_count]
  }
}
resource "azurerm_monitor_diagnostic_setting" "settings" {
  name                       = "${var.env_name}-aks-DiagnosticsSettings"
  target_resource_id         = azurerm_kubernetes_cluster.aks.id
  log_analytics_workspace_id = var.log_analytics_workspace_id


  enabled_log {
    category = "kube-apiserver"
  }

  enabled_log {
    category = "kube-audit"
  }

  enabled_log {
    category = "cluster-autoscaler"
  }


  # Drop these in dev to save cost
  # enabled_log { category = "kube-audit-admin" }
  # enabled_log { category = "kube-controller-manager" }
  # enabled_log { category = "kube-scheduler" }
  # enabled_log { category = "cluster-autoscaler" }
  # enabled_log { category = "guard" }

  # Disable noisy metrics in dev
  # metric {
  #   category = "AllMetrics"
  # }

  # Azure Monitor adds default `metric` blocks server-side after creation.
  # Without ignore_changes, every plan tries to remove them → noisy diffs.
  lifecycle {
    ignore_changes = [metric, log_analytics_destination_type]
  }
}
data "azurerm_dns_zone" "ekai-saas" {
  name                = var.dns_zone
  resource_group_name = var.resource_group_name
}
resource "azurerm_user_assigned_identity" "cert_manager_uami" {
  name                = "${var.env_name}-cert-uami"
  resource_group_name = var.resource_group_name
  location            = var.region
}
resource "azurerm_federated_identity_credential" "cert_manager" {
  name                = "cert-manager-federation"
  resource_group_name = var.resource_group_name
  issuer              = azurerm_kubernetes_cluster.aks.oidc_issuer_url
  subject             = "system:serviceaccount:cert-manager:cert-manager"
  audience            = ["api://AzureADTokenExchange"]

  parent_id = azurerm_user_assigned_identity.cert_manager_uami.id
}

resource "azurerm_role_assignment" "dns_contributor" {
  scope                = data.azurerm_dns_zone.ekai-saas.id
  role_definition_name = "DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.cert_manager_uami.principal_id
}

