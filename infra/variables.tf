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

variable "tags" {
  type = map(string)
  default = {
    app        = "dkm-health-app"
    env        = "prod"
    compliance = "hipaa-soc2"
    data_class = "confidential"
    managed_by = "terraform"
  }
}
