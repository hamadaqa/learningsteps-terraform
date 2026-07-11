resource "azurerm_postgresql_flexible_server" "main" {
  name                   = "psql-${var.prefix}"
  location               = azurerm_resource_group.main.location
  resource_group_name    = azurerm_resource_group.main.name
  version                = "16"
  administrator_login    = var.db_admin_username
  administrator_password = var.db_admin_password
  sku_name               = "B_Standard_B1ms"
  storage_mb             = 32768
  zone                   = "1"

  # Netzwerkkonfiguration auf PRIVAT umstellen
  public_network_access_enabled = false
  delegated_subnet_id           = azurerm_subnet.pg_subnet.id
  private_dns_zone_id           = azurerm_private_dns_zone.pg_dns.id

  timeouts {
    create = "60m"
    update = "60m"
    delete = "60m"
  }
}

resource "azurerm_postgresql_flexible_server_database" "app" {
  name      = var.db_name
  server_id = azurerm_postgresql_flexible_server.main.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}