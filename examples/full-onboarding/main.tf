variable "tenant_id" {
  description = "Azure AD tenant ID"
  type        = string
  default     = ""
}

provider "azuread" {
  tenant_id = var.tenant_id
}

provider "azapi" {}

module "tenant_permissions" {
  source = "../../modules/full-onboarding/"

  tenant_id                    = var.tenant_id
  skh_api_access_key_id        = ""
  skh_api_secret_key           = ""
  skh_api_url                  = ""
  subscription_ids             = [
    "",
    "",
  ]
  resource_group_location      = "eastus"
  perform_skyhawk_registration = true
  # resource_group_locations = {
  #   "" = ""
  # }
}

# terraform {
#   backend "azurerm" {
#     resource_group_name  = "rg-tfstate"
#     storage_account_name = "skhtfonboard"
#     container_name       = "tfstate"
#     key                  = "skyhawk-infra.tfstate"
#   }
# }

