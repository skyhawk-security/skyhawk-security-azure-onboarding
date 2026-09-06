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

  # Storage accounts default to network defaultAction = "Deny" (CIS Azure 3.7). The Skyhawk
  # collector egress IP(s) are allow-listed so log blobs can still be read. The default already
  # includes the Skyhawk prod collector NAT IP; override ONLY if Skyhawk instructs you to (e.g.,
  # a different collection region). Must be non-empty.
  # collector_egress_ips = ["3.227.150.87/32"]
}

# terraform {
#   backend "azurerm" {
#     resource_group_name  = "rg-tfstate"
#     storage_account_name = "skhtfonboard"
#     container_name       = "tfstate"
#     key                  = "skyhawk-infra.tfstate"
#   }
# }
