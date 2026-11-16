data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "app" {
  name = var.app_resource_group
}

data "azurerm_container_registry" "acr" {
  name                = var.acr_name
  resource_group_name = var.shared_resource_group
}

locals {
  rg  = data.azurerm_resource_group.app.name
  loc = data.azurerm_resource_group.app.location
  # PostgreSQL may need its own region: new/free subscriptions are often blocked from provisioning
  # it in busy regions (e.g. eastus2) while everything else works there.
  pg_loc = var.pg_location != "" ? var.pg_location : local.loc
  # Deterministic suffix so every resource name is known at PLAN time. That lets reviewers and the
  # Checkov plan gate verify names before apply (a random suffix is "known after apply").
  # Same scheme as scripts/bootstrap-azure.sh (first 6 hex chars of sha256(subscription id)).
  suffix = var.name_suffix != "" ? var.name_suffix : substr(sha256(data.azurerm_client_config.current.subscription_id), 0, 6)
}

# ---------- Identities: no secrets anywhere ----------
# app:      the API. Database role limited to SELECT/INSERT/UPDATE on app.users (app/migrations).
# migrator: database Entra admin, attached ONLY to the migration job, never to the API.
resource "azurerm_user_assigned_identity" "app" {
  name                = "id-dkm-health-app"
  resource_group_name = local.rg
  location            = local.loc
  tags                = local.tags
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = data.azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

resource "azurerm_user_assigned_identity" "migrator" {
  name                = "id-dkm-health-migrator"
  resource_group_name = local.rg
  location            = local.loc
  tags                = local.tags
}

resource "azurerm_role_assignment" "migrator_acr_pull" {
  scope                = data.azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.migrator.principal_id
}

# ---------- Logging (SOC2 CC7 / HIPAA 164.312(b) audit controls) ----------
resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-dkm-health-${local.suffix}"
  resource_group_name = local.rg
  location            = local.loc
  sku                 = "PerGB2018"
  retention_in_days   = local.p.log_retention_days
  tags                = local.tags
}

# ---------- Blob storage (audit trail) ----------
resource "azurerm_storage_account" "data" {
  name                              = "stdkmhealth${local.suffix}"
  resource_group_name               = local.rg
  location                          = local.loc
  account_tier                      = "Standard"
  account_replication_type          = local.p.storage_replication
  min_tls_version                   = "TLS1_2"
  https_traffic_only_enabled        = true
  shared_access_key_enabled         = false # Entra ID only: no account keys / SAS
  allow_nested_items_to_be_public   = false
  infrastructure_encryption_enabled = true
  local_user_enabled                = false
  tags                              = local.tags

  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = local.p.blob_retention_days
    }
    container_delete_retention_policy {
      days = local.p.blob_retention_days
    }
  }
}

resource "azurerm_storage_container" "audit" {
  name                  = "audit"
  storage_account_id    = azurerm_storage_account.data.id
  container_access_type = "private"
}

resource "azurerm_role_assignment" "app_blob" {
  scope                = azurerm_storage_container.audit.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

resource "azurerm_monitor_diagnostic_setting" "blob" {
  name                       = "to-log-analytics"
  target_resource_id         = "${azurerm_storage_account.data.id}/blobServices/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  enabled_log { category = "StorageRead" }
  enabled_log { category = "StorageWrite" }
  enabled_log { category = "StorageDelete" }
}

# ---------- PostgreSQL (user accounts) ----------
resource "azurerm_postgresql_flexible_server" "db" {
  name                          = "psql-dkm-health-${local.suffix}"
  resource_group_name           = local.rg
  location                      = local.pg_loc
  version                       = "16"
  sku_name                      = local.p.pg_sku
  storage_mb                    = 32768
  backup_retention_days         = local.p.pg_backup_days
  geo_redundant_backup_enabled  = local.p.pg_geo_backup
  public_network_access_enabled = true # until Sprint 3 private networking; see .checkov.yaml
  tags                          = local.tags

  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = false # no database passwords exist at all
    tenant_id                     = data.azurerm_client_config.current.tenant_id
  }

  dynamic "high_availability" {
    for_each = local.p.pg_high_availability ? [1] : []
    content {
      mode = "ZoneRedundant"
    }
  }

  lifecycle {
    # Azure picks/swaps zones on failover; don't fight it on every plan.
    ignore_changes = [zone, high_availability[0].standby_availability_zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "app" {
  name      = "dkmhealth"
  server_id = azurerm_postgresql_flexible_server.db.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# The migrator identity is the only Entra admin. The migration job uses it to apply app/migrations and
# to create the app's non-admin role. Backlog: add a human break-glass admin group.
resource "azurerm_postgresql_flexible_server_active_directory_administrator" "migrator" {
  server_name         = azurerm_postgresql_flexible_server.db.name
  resource_group_name = local.rg
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = azurerm_user_assigned_identity.migrator.principal_id
  principal_name      = azurerm_user_assigned_identity.migrator.name
  principal_type      = "ServicePrincipal"
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "azure" {
  name             = "allow-azure-services"
  server_id        = azurerm_postgresql_flexible_server.db.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_postgresql_flexible_server_configuration" "log_connections" {
  name      = "log_connections"
  server_id = azurerm_postgresql_flexible_server.db.id
  value     = "on"
}

resource "azurerm_postgresql_flexible_server_configuration" "log_disconnections" {
  name      = "log_disconnections"
  server_id = azurerm_postgresql_flexible_server.db.id
  value     = "on"
}

resource "azurerm_monitor_diagnostic_setting" "db" {
  name                       = "to-log-analytics"
  target_resource_id         = azurerm_postgresql_flexible_server.db.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  enabled_log { category = "PostgreSQLLogs" }
}

# ---------- Compute: Azure Container Apps ----------
resource "azurerm_container_app_environment" "main" {
  name                       = "cae-dkm-health"
  resource_group_name        = local.rg
  location                   = local.loc
  logs_destination           = "log-analytics" # required alongside the workspace ID since azurerm 5
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  tags                       = local.tags

  # Azure now creates every environment with this serverless profile. Declared so Terraform
  # doesn't try to strip it on every plan. It is pay-per-use and scales to zero; no dedicated nodes.
  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

# ---------- Schema migrations (run inside Azure, before the new app revision rolls out) ----------
resource "azurerm_container_app_job" "migrate" {
  name                         = "caj-dkm-health-migrate"
  resource_group_name          = local.rg
  location                     = local.loc
  container_app_environment_id = azurerm_container_app_environment.main.id
  workload_profile_name        = "Consumption"
  replica_timeout_in_seconds   = 600
  replica_retry_limit          = 0
  tags                         = local.tags

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.migrator.id]
  }

  registry {
    server   = data.azurerm_container_registry.acr.login_server
    identity = azurerm_user_assigned_identity.migrator.id
  }

  template {
    container {
      name    = "migrate"
      image   = var.image # same signed image as the API
      command = ["python", "-m", "app.migrate"]
      cpu     = 0.25
      memory  = "0.5Gi"

      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.migrator.client_id
      }
      env {
        name  = "PGHOST"
        value = azurerm_postgresql_flexible_server.db.fqdn
      }
      env {
        name  = "PGDATABASE"
        value = azurerm_postgresql_flexible_server_database.app.name
      }
      env {
        name  = "PGUSER"
        value = azurerm_user_assigned_identity.migrator.name
      }
      env {
        name  = "APP_DB_ROLE"
        value = azurerm_user_assigned_identity.app.name
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.migrator_acr_pull,
    azurerm_postgresql_flexible_server_active_directory_administrator.migrator,
  ]
}

# Starts the job and waits for it during `terraform apply` (CD runner, CD identity). The API below
# depends on this, so a new image never serves traffic before its migrations have succeeded.
resource "terraform_data" "migrate" {
  triggers_replace = [var.image]

  provisioner "local-exec" {
    command     = "bash run-migrations.sh"
    working_dir = path.module
    environment = {
      JOB = azurerm_container_app_job.migrate.name
      RG  = local.rg
    }
  }

  depends_on = [azurerm_container_app_job.migrate]
}

resource "azurerm_container_app" "api" {
  name                         = "ca-dkm-health-app"
  resource_group_name          = local.rg
  container_app_environment_id = azurerm_container_app_environment.main.id
  workload_profile_name        = "Consumption" # Azure assigns it; declared to avoid plan drift
  revision_mode                = "Single"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  registry {
    server   = data.azurerm_container_registry.acr.login_server
    identity = azurerm_user_assigned_identity.app.id
  }

  ingress {
    external_enabled           = true
    target_port                = 8000
    allow_insecure_connections = false
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = local.p.min_replicas
    max_replicas = local.p.max_replicas

    container {
      name   = "api"
      image  = var.image
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.app.client_id
      }
      env {
        name  = "PGHOST"
        value = azurerm_postgresql_flexible_server.db.fqdn
      }
      env {
        name  = "PGDATABASE"
        value = azurerm_postgresql_flexible_server_database.app.name
      }
      env {
        name  = "PGUSER"
        value = azurerm_user_assigned_identity.app.name
      }
      env {
        name  = "STORAGE_ACCOUNT_URL"
        value = azurerm_storage_account.data.primary_blob_endpoint
      }
      env {
        name  = "AUDIT_CONTAINER"
        value = azurerm_storage_container.audit.name
      }

      liveness_probe {
        transport = "HTTP"
        port      = 8000
        path      = "/health"
      }
      readiness_probe {
        transport = "HTTP"
        port      = 8000
        path      = "/ready"
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.app_blob,
    terraform_data.migrate, # schema and the app's database role exist before the app starts
  ]
}

# Break-glass: a human Entra group as a second database admin, for emergencies only.
# Schema changes still go through migrations. See README "Break-glass database access".
resource "azurerm_postgresql_flexible_server_active_directory_administrator" "breakglass" {
  count               = var.db_admin_group_id != "" ? 1 : 0
  server_name         = azurerm_postgresql_flexible_server.db.name
  resource_group_name = local.rg
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = var.db_admin_group_id
  principal_name      = "dkm-health-db-admins"
  principal_type      = "Group"
}
