# ---------- Private networking ----------
# PostgreSQL and Blob Storage have NO public endpoint. They are reachable only through private endpoints in this
# VNet, which the Container Apps environment (API + migration job) is injected into. Private DNS zones make the
# normal hostnames (psql-....postgres.database.azure.com, st....blob.core.windows.net) resolve to private IPs
# inside the VNet, so the app needs no code or config change.
# Not covered: the container registry stays public (private endpoints need the Premium SKU); pulls are
# authenticated with a managed identity and every image is signature-verified before deploy.

resource "azurerm_virtual_network" "main" {
  name                = "vnet-dkm-health"
  resource_group_name = local.rg
  location            = local.loc
  address_space       = ["10.40.0.0/16"]
  tags                = local.tags
}

# Container Apps (workload profiles) needs a dedicated, delegated subnet of at least /27.
resource "azurerm_subnet" "container_apps" {
  name                 = "snet-container-apps"
  resource_group_name  = local.rg
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.40.0.0/23"]
  # The apps need outbound internet for Entra ID, Log Analytics and the (public) registry. Production would
  # use a NAT gateway (~$32/month) for a fixed, auditable egress IP; Azure's default outbound is fine here.
  default_outbound_access_enabled = true

  delegation {
    name = "container-apps"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "private_endpoints" {
  name                              = "snet-private-endpoints"
  resource_group_name               = local.rg
  virtual_network_name              = azurerm_virtual_network.main.name
  address_prefixes                  = ["10.40.2.0/27"]
  default_outbound_access_enabled   = false     # private endpoints never initiate outbound traffic
  private_endpoint_network_policies = "Enabled" # let the NSG below apply to the endpoints
}

resource "azurerm_network_security_group" "container_apps" {
  name                = "nsg-dkm-health-container-apps"
  resource_group_name = local.rg
  location            = local.loc
  tags                = local.tags
}

# Only the Container Apps subnet may reach the endpoints, and only on the two ports in use.
resource "azurerm_network_security_group" "private_endpoints" {
  name                = "nsg-dkm-health-private-endpoints"
  resource_group_name = local.rg
  location            = local.loc
  tags                = local.tags

  security_rule {
    name                       = "allow-apps-to-postgres-and-blob"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefixes    = azurerm_subnet.container_apps.address_prefixes
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_ranges    = ["5432", "443"]
  }

  security_rule {
    name                       = "deny-everything-else"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_address_prefix      = "*"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "container_apps" {
  subnet_id                 = azurerm_subnet.container_apps.id
  network_security_group_id = azurerm_network_security_group.container_apps.id
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  subnet_id                 = azurerm_subnet.private_endpoints.id
  network_security_group_id = azurerm_network_security_group.private_endpoints.id
}

# ---------- Private DNS: normal hostnames resolve to the private endpoints inside the VNet ----------
resource "azurerm_private_dns_zone" "postgres" {
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = local.rg
  tags                = local.tags
}

resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = local.rg
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                = "vnet-dkm-health"
  private_dns_zone_id = azurerm_private_dns_zone.postgres.id
  virtual_network_id  = azurerm_virtual_network.main.id
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  name                = "vnet-dkm-health"
  private_dns_zone_id = azurerm_private_dns_zone.blob.id
  virtual_network_id  = azurerm_virtual_network.main.id
  tags                = local.tags
}

# ---------- Private endpoints ----------
# The PostgreSQL endpoint lives in this (eastus2) VNet while the server is in PG_LOCATION; Azure supports
# cross-region private endpoints, so no second VNet or peering is needed.
resource "azurerm_private_endpoint" "postgres" {
  name                = "pe-dkm-health-postgres"
  resource_group_name = local.rg
  location            = local.loc
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "postgres"
    private_connection_resource_id = azurerm_postgresql_flexible_server.db.id
    subresource_names              = ["postgresqlServer"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "postgres"
    private_dns_zone_ids = [azurerm_private_dns_zone.postgres.id]
  }
}

resource "azurerm_private_endpoint" "blob" {
  name                = "pe-dkm-health-blob"
  resource_group_name = local.rg
  location            = local.loc
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "blob"
    private_connection_resource_id = azurerm_storage_account.data.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob.id]
  }
}
