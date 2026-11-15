terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.14"
    }
  }

  # Partial config: storage_account_name is passed by the pipeline (-backend-config).
  backend "azurerm" {
    resource_group_name = "rg-dkm-health-shared"
    container_name      = "tfstate"
    key                 = "prod.tfstate"
    use_oidc            = true
    use_azuread_auth    = true
  }
}

provider "azurerm" {
  features {}
  # Credentials come from ARM_* env vars set by the pipeline (OIDC, no secrets).
  storage_use_azuread             = true   # storage accounts have shared keys disabled
  resource_provider_registrations = "none" # done once in the bootstrap script
}
