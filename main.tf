locals {
  default_tags = {
    "managed-by" = "skyhawk-security"
  }
  merged_tags = merge(local.default_tags, var.tags)

  application_password_display_name = "client-secret"

  multi_subscription_context = length(var.subscription_ids) > 1
  required_provider_namespaces = [
    "Microsoft.Storage",
    "Microsoft.Insights",
    "Microsoft.EventGrid",
  ]
  provider_registration_targets = {
    for combo in setproduct(toset(var.subscription_ids), toset(local.required_provider_namespaces)) :
    format("%s|%s", combo[0], combo[1]) => {
      subscription_id = combo[0]
      provider        = combo[1]
    }
  }
  subscription_activity_log_categories = [
    "Administrative",
    "Security",
    "ServiceHealth",
    "Alert",
    "Recommendation",
    "Policy",
    "Autoscale",
    "ResourceHealth",
  ]

  normalized_subscription_configs = {
    for subscription_id in var.subscription_ids :
    subscription_id => {
      tenant_id       = var.tenant_id
      subscription_id = subscription_id
      application_display_name = (
        local.multi_subscription_context
        ? format(
          "%s-%s",
          var.application_display_name,
          substr(replace(subscription_id, "-", ""), 0, 6),
        )
        : var.application_display_name
      )
      application_homepage_url      = var.application_homepage_url
      msgraph_roles                 = var.msgraph_roles
      msgraph_delegated_permissions = var.msgraph_delegated_permissions
      resource_group_location       = lookup(var.resource_group_locations, subscription_id, var.resource_group_location)
    }
  }

  application_password_end_date = timeadd(
    time_static.application_password_created.rfc3339,
    var.application_password_validity,
  )
  sanitized_application_display_names = {
    for key, config in local.normalized_subscription_configs :
    key => join("", regexall("[a-z0-9]", lower(config.application_display_name)))
  }
  storage_account_names = {
    for key, config in local.normalized_subscription_configs :
    key => substr(
      format(
        "%s%s",
        (
          length(local.sanitized_application_display_names[key]) > 0
          ? local.sanitized_application_display_names[key]
          : "sta"
        ),
        substr(replace(config.subscription_id, "-", ""), 0, 16),
      ),
      0,
      24,
    )
  }

  event_subscription_names = {
    for key in keys(local.normalized_subscription_configs) :
    key => substr(
      format(
        "%segsub",
        (
          length(local.sanitized_application_display_names[key]) > 0
          ? local.sanitized_application_display_names[key]
          : "subscription"
        ),
      ),
      0,
      64,
    )
  }

  tenant_application_enabled = length(local.normalized_subscription_configs) > 0

  tenant_application_config_fallback = {
    tenant_id                     = var.tenant_id
    subscription_id               = null
    application_display_name      = var.application_display_name
    application_homepage_url      = var.application_homepage_url
    msgraph_roles                 = var.msgraph_roles
    msgraph_delegated_permissions = var.msgraph_delegated_permissions
    resource_group_location       = var.resource_group_location
  }

  tenant_application_source_config = local.tenant_application_enabled ? values(local.normalized_subscription_configs)[0] : local.tenant_application_config_fallback

  tenant_application_display_name = local.tenant_application_source_config.application_display_name

  tenant_application_homepage_url = local.tenant_application_source_config.application_homepage_url

  tenant_msgraph_roles = distinct(flatten([
    for config in(
      local.tenant_application_enabled
      ? values(local.normalized_subscription_configs)
      : [local.tenant_application_source_config]
    ) :
    config.msgraph_roles
  ]))

  tenant_msgraph_delegated_permissions = distinct(flatten([
    for config in(
      local.tenant_application_enabled
      ? values(local.normalized_subscription_configs)
      : [local.tenant_application_source_config]
    ) :
    config.msgraph_delegated_permissions
  ]))

  tenant_registration_authorization = local.skh_jwt_token != null ? (
    startswith(trimspace(local.skh_jwt_token), "Bearer ") ? trimspace(local.skh_jwt_token) : format("Bearer %s", trimspace(local.skh_jwt_token))
  ) : null

  tenant_registration_enabled = local.tenant_registration_authorization != null && local.tenant_application_enabled
}

resource "time_static" "application_password_created" {}

resource "azuread_application" "tenant" {
  display_name = local.tenant_application_display_name

  web {
    homepage_url = local.tenant_application_homepage_url
  }

  lifecycle {
    ignore_changes = [
      required_resource_access,
    ]
  }

  depends_on = [
    time_sleep.wait_for_provider_registration,
  ]
}

resource "azuread_service_principal" "tenant" {
  client_id = azuread_application.tenant.client_id

  depends_on = [
    time_sleep.wait_for_provider_registration,
  ]
}

resource "azuread_application_password" "tenant" {
  application_id = azuread_application.tenant.id
  display_name   = local.application_password_display_name
  end_date       = local.application_password_end_date

  depends_on = [
    time_sleep.wait_for_provider_registration,
  ]
}

data "azapi_resource_action" "provider_registration_status" {
  for_each    = local.provider_registration_targets
  type        = "Microsoft.Resources/subscriptions@2021-04-01"
  resource_id = format("/subscriptions/%s", each.value.subscription_id)
  action      = format("providers/%s", each.value.provider)
  method      = "GET"

  response_export_values = ["registrationState"]
}

resource "azapi_resource_action" "register_providers" {
  for_each = {
    for key, value in local.provider_registration_targets :
    key => value
    if !contains(
      ["Registered", "Registering"],
      try(data.azapi_resource_action.provider_registration_status[key].output.registrationState, ""),
    )
  }
  type        = "Microsoft.Resources/subscriptions@2021-04-01"
  resource_id = format("/subscriptions/%s", each.value.subscription_id)
  action      = format("providers/%s/register", each.value.provider)
  method      = "POST"
}

resource "azapi_resource_action" "provider_registration_state" {
  for_each    = local.provider_registration_targets
  type        = "Microsoft.Resources/subscriptions@2021-04-01"
  resource_id = format("/subscriptions/%s", each.value.subscription_id)
  action      = format("providers/%s", each.value.provider)
  method      = "GET"

  response_export_values = ["registrationState"]

  depends_on = [
    azapi_resource_action.register_providers,
  ]

  timeouts {
    read = "5m"
  }

  lifecycle {
    postcondition {
      condition = contains(
        ["Registered", "Registering"],
        try(self.output.registrationState, "")
      )
      error_message = format("Azure provider %s failed to register in subscription %s", each.value.provider, each.value.subscription_id)
    }
  }



}
resource "time_sleep" "wait_for_provider_registration" {
  for_each = local.provider_registration_targets

  depends_on = [
    azapi_resource_action.register_providers,
    azapi_resource_action.provider_registration_state,
  ]

  create_duration = contains(
    keys(azapi_resource_action.register_providers),
    each.key,
  ) ? "120s" : "0s"
}

resource "azapi_resource" "resource_group" {
  for_each = local.normalized_subscription_configs

  type      = "Microsoft.Resources/resourceGroups@2021-04-01"
  name      = substr(lower(replace(format("%s-rg", each.value.application_display_name), " ", "-")), 0, 90)
  parent_id = format("/subscriptions/%s", each.value.subscription_id)

  body = {
    location = each.value.resource_group_location
    tags     = local.merged_tags
  }

  depends_on = [azapi_resource_action.provider_registration_state]
}

resource "azapi_resource" "storage_account" {
  for_each = local.normalized_subscription_configs

  type      = "Microsoft.Storage/storageAccounts@2023-01-01"
  name      = local.storage_account_names[each.key]
  parent_id = azapi_resource.resource_group[each.key].id

  body = {
    location = each.value.resource_group_location
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

  depends_on = [azapi_resource_action.provider_registration_state]
}

resource "azapi_resource" "storage_event_subscription" {
  for_each = local.normalized_subscription_configs

  type      = "Microsoft.EventGrid/eventSubscriptions@2022-06-15"
  name      = local.event_subscription_names[each.key]
  parent_id = azapi_resource.storage_account[each.key].id

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
              "/blobServices/default/containers/insights-activity-logs/blobs/",
              "/blobServices/default/containers/insights-logs-auditlogs/blobs/",
              "/blobServices/default/containers/insights-logs-signinlogs/blobs/",
              "/blobServices/default/containers/insights-logs-storageread/blobs/",
            ]
          }
        ]
      }
    }
  }

  depends_on = [azapi_resource_action.provider_registration_state]
}

resource "azapi_resource" "subscription_diagnostic_settings" {
  for_each = local.normalized_subscription_configs

  type      = "Microsoft.Insights/diagnosticSettings@2021-05-01-preview"
  name      = format("skyhawksecurity-%s", substr(replace(each.value.subscription_id, "-", ""), 0, 16))
  parent_id = format("/subscriptions/%s", each.value.subscription_id)

  body = {
    properties = {
      storageAccountId = azapi_resource.storage_account[each.key].id
      logs = [
        for category in local.subscription_activity_log_categories :
        {
          category = category
          enabled  = true
          retentionPolicy = {
            enabled = false
            days    = 0
          }
        }
      ]
      metrics = []
    }
  }

  depends_on = [azapi_resource_action.provider_registration_state]
}
