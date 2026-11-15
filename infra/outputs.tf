output "app_url" {
  value = "https://${azurerm_container_app.api.ingress[0].fqdn}"
}

output "postgres_fqdn" {
  value = azurerm_postgresql_flexible_server.db.fqdn
}

output "deployment_profile" {
  value = var.deployment_profile
}

output "storage_account" {
  value = azurerm_storage_account.data.name
}
