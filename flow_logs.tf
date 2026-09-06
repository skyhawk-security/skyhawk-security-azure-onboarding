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

  # BUG-5 (dedupe per review): single source of truth for the hardened storage networkAcls,
  # referenced by BOTH the activity-log storage account (main.tf) and the flow-log storage
  # accounts (this file). defaultAction = Deny (CIS 3.7), AzureServices bypass for first-party
  # writers, collector egress IPs allow-listed for reads.
  hardened_network_acls = {
    bypass              = "AzureServices"
    defaultAction       = "Deny"
    ipRules             = local.collector_ip_rules
    virtualNetworkRules = []
  }

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

  # Single source of truth for the per-subscription+region hash (review #5). Both the storage
  # account name and its Event Grid subscription name derive from this, so the hash input only
  # lives in one place.
  vnet_storage_account_hashes = {
    for key, item in local.vnet_storage_accounts :
    key => sha1(format("%s|%s", item.subscription_id, item.location))
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
    key => format("skhflow%s", substr(local.vnet_storage_account_hashes[key], 0, 17))
  }

  # BUG-7 fix: name for the Event Grid subscription created on each flow-log storage account.
  # Must be <= 64 chars, alphanumeric + hyphens. Derived from the same sub+region hash so it is
  # deterministic and unique per flow-log account.
  vnet_flow_log_event_subscription_names = {
    for key, item in local.vnet_storage_accounts :
    key => format(
      "skhflow-%s-egsub",
      substr(local.vnet_storage_account_hashes[key], 0, 12),
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

  depends_on = [
    azapi_resource_action.register_network_provider,
  ]
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
      networkAcls              = local.hardened_network_acls
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

# BUG-7 fix: The flow-log storage account previously had NO Event Grid subscription, so flow-log
# blobs were written but never delivered to the Skyhawk collector (only the activity-log storage
# account had a subscription). This creates an event subscription on EACH flow-log storage account
# (one per subscription+region), filtered to the flow-log containers, pointing at the same Skyhawk
# webhook. Without this, VNet/NSG flow logs are collected in Azure but never ingested by Skyhawk.
resource "azapi_resource" "vnet_flow_log_storage_event_subscription" {
  for_each = local.vnet_storage_accounts

  type      = "Microsoft.EventGrid/eventSubscriptions@2022-06-15"
  name      = local.vnet_flow_log_event_subscription_names[each.key]
  parent_id = azapi_resource.vnet_flow_log_storage_account[each.key].id

  body = {
    properties = {
      destination = {
        endpointType = "WebHook"
        properties = {
          endpointUrl                   = var.skh_api_url
          maxEventsPerBatch             = 200
          preferredBatchSizeInKilobytes = 1024
        }
      }
      eventDeliverySchema = "EventGridSchema"
      retryPolicy = {
        eventTimeToLiveInMinutes = 1440
        maxDeliveryAttempts      = 30
      }
      filter = {
        advancedFilters = [
          {
            key          = "subject"
            operatorType = "StringBeginsWith"
            values = [
              "/blobServices/default/containers/insights-logs-networksecuritygroupflowevent/blobs/",
              "/blobServices/default/containers/insights-logs-flowlogflowevent/blobs/",
            ]
          }
        ]
      }
    }
  }

  depends_on = [
    azapi_resource.vnet_flow_log_storage_account,
    azapi_resource_action.provider_registration_state,
  ]
}
