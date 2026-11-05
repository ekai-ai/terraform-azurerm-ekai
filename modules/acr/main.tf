# ──────────────────────────────────────────────────────────────────────────
# ACR + AcrPull for AKS kubelet identity.
#
# Lives in Layer 02 (cluster) so:
#   - AcrPull role assignment can be created here (kubelet identity exists
#     after AKS module applies)
#   - Layer 03 (platform) Helm releases can reference ACR-mirrored images
# ──────────────────────────────────────────────────────────────────────────

# ACR names are globally unique across every Azure subscription, not just
# this one (unlike Key Vault's own subscription_id-suffixed name, this had
# no such suffix -- two different customers picking the same env_name
# collide). Same fix as Key Vault's name (main.tf's local.key_vault_name):
# fold in the subscription ID, stripped of hyphens since ACR names are
# alphanumeric-only (no hyphens/underscores at all, unlike Key Vault).
data "azurerm_client_config" "current" {}

resource "azurerm_container_registry" "acr" {
  name                = substr("ekai${var.env_name}${substr(replace(data.azurerm_client_config.current.subscription_id, "-", ""), 0, 8)}acr", 0, 50)
  resource_group_name = var.resource_group_name
  location            = var.region
  sku                 = "Standard"
  admin_enabled       = false
  tags                = var.tags
}

# AKS kubelet pulls images via this role assignment. Without it, pods
# referencing ACR images fail with `ImagePullBackOff: unauthorized`.
resource "azurerm_role_assignment" "acr_pull_for_aks_kubelet" {
  scope                            = azurerm_container_registry.acr.id
  role_definition_name             = "AcrPull"
  principal_id                     = var.aks_kubelet_identity_object_id
  skip_service_principal_aad_check = true
}
