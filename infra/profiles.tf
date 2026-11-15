# Deployment profiles: one place that holds every setting that trades cost against resilience.
# Security controls (encryption, Entra-only auth, no keys/passwords, TLS, audit logging,
# signed images) are identical in both profiles and are deliberately NOT configurable here.
#
#   sandbox    - learning / demos. Scales to zero, single-region storage, short retention.
#   production - real workloads. Always-on, zone-redundant HA database, geo-redundant data.
#
# WARNING: choose the profile before the first deploy. Switching an existing deployment changes
# geo_redundant_backup_enabled, which forces Azure to RECREATE the PostgreSQL server (data loss
# unless you back up and restore). Treat a profile change as a migration, not a toggle.

locals {
  profiles = {
    sandbox = {
      min_replicas         = 0 # scale to zero when idle; first request after idle has a cold start
      max_replicas         = 2
      storage_replication  = "LRS"
      blob_retention_days  = 7
      pg_sku               = "B_Standard_B1ms" # covered by the Azure free tier (12 months)
      pg_high_availability = false
      pg_geo_backup        = false
      pg_backup_days       = 7
      log_retention_days   = 30
    }
    production = {
      min_replicas         = 1
      max_replicas         = 5
      storage_replication  = "GZRS" # zone + geo redundant
      blob_retention_days  = 30
      pg_sku               = "GP_Standard_D2ds_v5" # General Purpose: required for HA
      pg_high_availability = true                  # zone-redundant standby, automatic failover
      pg_geo_backup        = true
      pg_backup_days       = 35
      log_retention_days   = 90 # hot; archive to storage for HIPAA's 6-year documentation retention
    }
  }

  p    = local.profiles[var.deployment_profile]
  tags = merge(var.tags, { env = var.deployment_profile })
}
