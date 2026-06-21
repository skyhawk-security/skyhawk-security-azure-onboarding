provider "azuread" {
  tenant_id = var.tenant_id
}

provider "azapi" {}

module "tenant_permissions" {
  source = "../../"

  tenant_id             = var.tenant_id
  skh_api_access_key_id = var.skh_api_access_key_id
  skh_api_secret_key    = var.skh_api_secret_key
  skh_api_url           = var.skh_api_url
  subscription_ids      = var.subscription_ids

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
