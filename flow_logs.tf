locals {
  # BUG-5: Azure Storage networkAcls.ipRules require a bare IPv4 or CIDR, and it REJECTS a "/32"
  # suffix (a single host must be given without the mask). Strip a trailing /32 while keeping real
  # CIDR ranges intact. Used by both storage accounts to allow-list the Skyhawk collector egress IPs
  # under defaultAction = "Deny".
  collector_ip_rules = [
    for cidr in var.collector_egress_ips : {
      value  = endswith(cidr, "/32") ? trimsuffix(cidr, "/32") : cidr
      action = "Allow"
    }
  ]

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
    # BUG-1 fix: region was previously truncated to 6 chars (substr(...,0,6)), which collapsed
    # region variants like "eastus" and "eastus2" to the same name "eastus" and caused a global
    # StorageAccountAlreadyTaken (409) collision. We now derive a deterministic, fixed-length,
    # collision-free suffix from a hash of the full "subscription_id|location" key. This guarantees
    # a unique name per subscription+region while staying within the 3-24 char, lowercase-alnum
    # storage account naming rules.
    #   "skhflow" (7) + 17 hex chars = 24 chars exactly.
    key => format(
      "skhflow%s",
      substr(sha1(format("%s|%s", item.subscription_id, item.location)), 0, 17),
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
    tags     = local.merged_tags
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
    tags = local.merged_tags
    properties = {
      allowBlobPublicAccess    = false
      minimumTlsVersion        = "TLS1_2"
      supportsHttpsTrafficOnly = true
      networkAcls = {
        bypass = "AzureServices"
        # BUG-5 fix (CIS Azure 3.7): was "Allow" (storage account reachable from the whole internet).
        # Now "Deny" by default. First-party Azure writers (Network Watcher, Event Grid, diagnostic
        # settings) reach it via bypass = "AzureServices"; the Skyhawk collectors reach it via the
        # explicit ipRules allow-list below.
        defaultAction       = "Deny"
        ipRules             = local.collector_ip_rules
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
    tags = local.merged_tags
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
      # BUG-2 fix: previously this block was omitted entirely. On a re-apply against a flow log that
      # already had Traffic Analytics enabled (FlowAnalysisEnabled = true), Azure rejected the PUT
      # with "FlowLogConfigurationCannotBeUpdated" because the value would transition from true to
      # unspecified. We now always send an explicit flowAnalyticsConfiguration so the desired state
      # is unambiguous and re-applies are idempotent. Skyhawk does not use Azure Traffic Analytics
      # (we ingest raw flow logs via Event Grid), so we explicitly disable it here.
      flowAnalyticsConfiguration = {
        networkWatcherFlowAnalyticsConfiguration = {
          enabled = false
        }
      }
    }
  }

  depends_on = [
    azapi_resource_action.register_network_provider,
    azapi_resource.vnet_flow_log_storage_account,
  ]
}
