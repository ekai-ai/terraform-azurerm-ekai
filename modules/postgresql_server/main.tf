

resource "azurerm_private_dns_zone" "ekai-db" {
  name                = "ekai-${var.env_name}.postgres.database.azure.com"
  resource_group_name = var.resource_group_name

  tags = var.tags
}
resource "azurerm_private_dns_zone_virtual_network_link" "ekai" {
  name                  = "ekaiVnetZone.com"
  private_dns_zone_name = azurerm_private_dns_zone.ekai-db.name
  virtual_network_id    = var.vnet_id
  resource_group_name   = var.resource_group_name
  tags                  = var.tags

}
resource "azurerm_postgresql_flexible_server" "ekai-db" {
  # env_name folded in -- without it, two self-service envs in the same
  # region collide on the same server name (confirmed: the original
  # "ekai-saas-db-<region>" name has no per-env component at all).
  name     = "ekai-${var.env_name}-db-${var.region}"
  location = var.region

  resource_group_name = var.resource_group_name
  delegated_subnet_id = var.subnet_id
  private_dns_zone_id = azurerm_private_dns_zone.ekai-db.id
  sku_name            = var.postgres_flexible_server_sku_name
  zone                = var.enable_ha ? "1" : null
  # "ZoneRedundant" (not "SameZone"): the standby lives in a DIFFERENT zone
  # from the primary (standby_availability_zone = "2" vs. primary zone "1"
  # above), so a single zone outage doesn't take out both. "SameZone" HA
  # only protects against hardware/VM failure within one zone -- it does
  # nothing for a zone-wide outage, which defeats the point of paying for HA
  # on something described as production infrastructure. Only General
  # Purpose/Memory Optimized SKUs support either HA mode -- the Burstable
  # tier (postgres_flexible_server_sku_name's cheaper options) supports
  # neither, so enable_ha = true requires a non-Burstable SKU (see
  # env/customer.tfvars's own postgres_flexible_server_sku_name comment).
  dynamic "high_availability" {
    for_each = var.enable_ha ? [1] : []
    content {
      mode                      = "ZoneRedundant"
      standby_availability_zone = "2"
    }
  }
  storage_mb            = var.postgres_flexible_server_storage_mb
  backup_retention_days = 7
  # Cross-region copy of backups -- protects against the whole PRIMARY
  # REGION being unavailable, not just a zone within it (ZoneRedundant HA
  # above only covers the latter). Roughly doubles backup storage cost, same
  # tradeoff class as HA itself -- default false, set true for a real
  # production deployment (see env/customer.tfvars).
  geo_redundant_backup_enabled = var.geo_redundant_backup_enabled
  auto_grow_enabled            = true
  administrator_login          = var.backend_db_username
  administrator_password       = var.backend_db_password
  version                      = var.postgresql_version

  public_network_access_enabled = false

  tags = var.tags

  # Azure auto-assigns a zone when one isn't specified, and refuses to change
  # zone independently of `high_availability.standby_availability_zone`. Once
  # the server is created, we let Azure keep whatever zone it picked — this
  # avoids "zone can only be changed when exchanged with..." errors when HA
  # toggles or when re-applying after a partial failure.
  lifecycle {
    ignore_changes = [zone]
  }

  # private_dns_zone_id above only references the zone itself -- Terraform
  # has no implicit edge to the zone's VNet link, but Azure needs that link
  # to already exist when it starts provisioning a delegated-subnet server,
  # documented azurerm provider gotcha (intermittent failure without it).
  depends_on = [azurerm_private_dns_zone_virtual_network_link.ekai]
}
resource "azurerm_postgresql_flexible_server_database" "ekai-database" {
  name      = var.backend_db_name
  server_id = azurerm_postgresql_flexible_server.ekai-db.id
  collation = "en_US.utf8"
  charset   = "utf8"

}
# pgvector allowlist + the semantics database that was its only consumer
# (created by the now-removed modules/postgresql_db_init Job) were removed
# together -- the semantics service has been removed from the product
# entirely, matching the same outright removal already done in
# devops/aws-terraform, devops/gcp-terraform, and terraform-google-ekai.

#resource "azurerm_postgresql_flexible_server" "ekai-db-replica" {
#  name                          = "ekai-db-replica"
#  resource_group_name           = var.resource_group_name
#  location                      = var.region
#  create_mode                   = "Replica"
#  source_server_id              = azurerm_postgresql_flexible_server.ekai-db.id
#  version                       = var.postgresql_version
#  public_network_access_enabled = false
#  zone                          = "1"
#  storage_mb                    = var.postgress_storage_mb
#  storage_tier                  = "P30"
#
#  sku_name = var.postgress_sku_name
#}
#resource "azurerm_postgresql_flexible_server_virtual_endpoint" "example" {
#  name              = "ekai-db-endpoint"
#  source_server_id  = azurerm_postgresql_flexible_server.ekai-db.id
#  replica_server_id = azurerm_postgresql_flexible_server.ekai-db-replica.id
#  type              = "ReadWrite"
#}


