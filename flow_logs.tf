locals {
  discovered_vnets = var.enable_vnet_flow_logs ? {
    for item in flatten([
      for sub_id in var.subscription_ids : [
        for vnet in try(data.azapi_resource_list.vnets[sub_id].output.value, []) : {
          key             = format("%s|%s", sub_id, vnet.name)
          subscription_id = sub_id
          vnet_id         = vnet.id
          vnet_name       = vnet.name
          location        = vnet.location
        }
      ]
    ]) : item.key => item
  } : {}

  # Unique subscription+region combinations that have VNets
  vnet_storage_account_keys = var.enable_vnet_flow_logs ? toset([
    for item in flatten([
      for sub_id in var.subscription_ids : [
        for vnet in try(data.azapi_resource_list.vnets[sub_id].output.value, []) : {
          key             = format("%s|%s", sub_id, vnet.location)
          subscription_id = sub_id
          location        = vnet.location
        }
      ]
    ]) : item
  ]) : toset([])

  vnet_storage_accounts = {
    for item in local.vnet_storage_account_keys :
    item.key => item
  }

  vnet_storage_account_names = {
    for key, item in local.vnet_storage_accounts :
    key => substr(
      format(
        "skhflow%s%s",
        substr(replace(item.subscription_id, "-", ""), 0, 10),
        substr(replace(item.location, "-", ""), 0, 6),
      ),
      0,
      24,
    )
  }
}

# List all VNets per subscription
data "azapi_resource_list" "vnets" {
  for_each = var.enable_vnet_flow_logs ? toset(var.subscription_ids) : toset([])

  type      = "Microsoft.Network/virtualNetworks@2024-03-01"
  parent_id = format("/subscriptions/%s", each.value)

  response_export_values = ["value"]
}

# Register Microsoft.Network provider in each subscription
resource "azapi_resource_action" "register_network_provider" {
  for_each = var.enable_vnet_flow_logs ? toset(var.subscription_ids) : toset([])

  type        = "Microsoft.Resources/subscriptions@2021-04-01"
  resource_id = format("/subscriptions/%s", each.value)
  action      = "providers/Microsoft.Network/register"
  method      = "POST"
}

# Resource group per subscription+region for flow log storage accounts
resource "azapi_resource" "vnet_flow_log_resource_group" {
  for_each = local.vnet_storage_accounts

  type      = "Microsoft.Resources/resourceGroups@2021-04-01"
  name      = substr(lower(format("skh-flowlogs-%s-rg", replace(each.value.location, " ", "-"))), 0, 90)
  parent_id = format("/subscriptions/%s", each.value.subscription_id)

  body = {
    location = each.value.location
  }

  depends_on = [azapi_resource_action.register_network_provider]
}

# One storage account per subscription+region to match flow log location requirement
resource "azapi_resource" "vnet_flow_log_storage_account" {
  for_each = local.vnet_storage_accounts

  type      = "Microsoft.Storage/storageAccounts@2023-01-01"
  name      = local.vnet_storage_account_names[each.key]
  parent_id = azapi_resource.vnet_flow_log_resource_group[each.key].id

  body = {
    location = each.value.location
    sku = {
      name = "Standard_LRS"
    }
    kind = "StorageV2"
    properties = {
      allowBlobPublicAccess    = false
      minimumTlsVersion        = "TLS1_2"
      supportsHttpsTrafficOnly = true
      networkAcls = {
        bypass              = "AzureServices"
        defaultAction       = "Allow"
        ipRules             = []
        virtualNetworkRules = []
      }
    }
  }

  depends_on = [azapi_resource.vnet_flow_log_resource_group]
}

# Create VNet Flow Log for each discovered VNet
resource "azapi_resource" "vnet_flow_log" {
  for_each = local.discovered_vnets

  type = "Microsoft.Network/networkWatchers/flowLogs@2024-03-01"
  name = format("skyhawk-%s", each.value.vnet_name)
  parent_id = format(
    "/subscriptions/%s/resourceGroups/NetworkWatcherRG/providers/Microsoft.Network/networkWatchers/NetworkWatcher_%s",
    each.value.subscription_id,
    each.value.location,
  )
  location = each.value.location

  body = {
    properties = {
      enabled          = true
      storageId        = azapi_resource.vnet_flow_log_storage_account[format("%s|%s", each.value.subscription_id, each.value.location)].id
      targetResourceId = each.value.vnet_id
      format = {
        type    = "JSON"
        version = 2
      }
      retentionPolicy = {
        days    = 0
        enabled = false
      }
    }
  }

  depends_on = [
    azapi_resource_action.register_network_provider,
    azapi_resource.vnet_flow_log_storage_account,
  ]
}
