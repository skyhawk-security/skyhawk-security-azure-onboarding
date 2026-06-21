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
      storageId        = azapi_resource.storage_account[each.value.subscription_id].id
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
    azapi_resource.storage_account,
  ]
}
