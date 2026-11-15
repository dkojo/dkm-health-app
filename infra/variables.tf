variable "location" {
  type    = string
  default = "eastus2"
}

variable "app_resource_group" {
  description = "Created by scripts/bootstrap-azure.sh; the CD identity is scoped to it."
  type        = string
  default     = "rg-dkm-health-prod"
}

variable "shared_resource_group" {
  type    = string
  default = "rg-dkm-health-shared"
}

variable "acr_name" {
  description = "Container registry (the artifact repository) created by the bootstrap script."
  type        = string
}

variable "image" {
  description = "Full image reference, pinned by digest, e.g. myacr.azurecr.io/dkm-health-app@sha256:..."
  type        = string
}

variable "deployment_profile" {
  description = "Cost/resilience profile, see profiles.tf. Defaults to production (safe by default); set the DEPLOYMENT_PROFILE repo variable to 'sandbox' for learning environments."
  type        = string
  default     = "production"
  validation {
    condition     = contains(["sandbox", "production"], var.deployment_profile)
    error_message = "deployment_profile must be 'sandbox' or 'production'."
  }
}

variable "name_suffix" {
  description = "Override for the globally-unique name suffix (default: derived from the subscription ID). Only needed if a name is taken, e.g. right after a destroy."
  type        = string
  default     = ""
  validation {
    condition     = can(regex("^[a-z0-9]{0,6}$", var.name_suffix))
    error_message = "name_suffix must be up to 6 lowercase letters/digits (storage account names allow only [a-z0-9], max 24 chars)."
  }
}

variable "tags" {
  type = map(string)
  default = {
    app        = "dkm-health-app"
    compliance = "hipaa-soc2"
    data_class = "confidential"
    managed_by = "terraform"
  }
}
