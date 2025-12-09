data "azuread_application_published_app_ids" "well_known" {}

data "azuread_service_principal" "msgraph" {
  client_id = data.azuread_application_published_app_ids.well_known.result["MicrosoftGraph"]
}

locals {
  subscription_role_assignments = {
    for key, config in local.normalized_subscription_configs :
    key => config
    if try(config.subscription_id, null) != null
  }

  reader_role_definition_id                   = "acdd72a7-3385-48ef-bd42-f606fba81ae7"
  storage_blob_data_reader_role_definition_id = "2a2b9908-6ea1-4ae2-8e65-a410df84e7d1"
  skyhawk_role_definition_guid                = uuidv5("url", format("%s|skyhawk-role-definition", local.root_management_group_scope))
  skyhawk_role_definition_id = format(
    "%s/providers/Microsoft.Authorization/roleDefinitions/%s",
    local.root_management_group_scope,
    local.skyhawk_role_definition_guid,
  )

  root_management_group_scope = format(
    "/providers/Microsoft.Management/managementGroups/%s",
    var.tenant_id,
  )

  skh_auth_token_response_body = var.perform_skyhawk_registration ? try(data.http.skh_auth_token[0].response_body, null) : null

  skh_jwt_token = var.perform_skyhawk_registration && local.skh_auth_token_response_body != null ? try(
    jsondecode(local.skh_auth_token_response_body).token,
    local.skh_auth_token_response_body,
  ) : null
}

resource "azapi_resource" "skyhawk_role_definition" {
  type      = "Microsoft.Authorization/roleDefinitions@2022-04-01"
  name      = local.skyhawk_role_definition_guid
  parent_id = local.root_management_group_scope

  body = {
    properties = {
      roleName    = "skyhawk"
      description = "Allow Get Flow Log Status on a Resource."
      permissions = [
        {
          actions        = ["Microsoft.Network/networkWatchers/queryFlowLogStatus/action"]
          notActions     = []
          dataActions    = []
          notDataActions = []
        }
      ]
      assignableScopes = [
        local.root_management_group_scope
      ]
    }
  }
}

resource "azuread_application_api_access" "tenant" {
  count = local.tenant_application_enabled && (length(local.tenant_msgraph_roles) > 0 || length(local.tenant_msgraph_delegated_permissions) > 0) ? 1 : 0

  application_id = azuread_application.tenant.id
  api_client_id  = data.azuread_application_published_app_ids.well_known.result["MicrosoftGraph"]

  role_ids = [
    for role in local.tenant_msgraph_roles :
    data.azuread_service_principal.msgraph.app_role_ids[role]
  ]

  scope_ids = [
    for scope in local.tenant_msgraph_delegated_permissions :
    data.azuread_service_principal.msgraph.oauth2_permission_scope_ids[scope]
  ]
}

resource "azuread_app_role_assignment" "tenant" {
  for_each = toset(local.tenant_msgraph_roles)

  principal_object_id = azuread_service_principal.tenant.object_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
  app_role_id         = data.azuread_service_principal.msgraph.app_role_ids[each.key]
}

resource "azuread_service_principal_delegated_permission_grant" "tenant" {
  count = length(local.tenant_msgraph_delegated_permissions) > 0 ? 1 : 0

  service_principal_object_id          = azuread_service_principal.tenant.object_id
  resource_service_principal_object_id = data.azuread_service_principal.msgraph.object_id
  claim_values                         = local.tenant_msgraph_delegated_permissions
}

resource "azapi_resource" "subscription_reader" {
  for_each = local.subscription_role_assignments

  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", format("%s|%s|subscription-reader", each.value.subscription_id, azuread_service_principal.tenant.object_id))
  parent_id = format("/subscriptions/%s", each.value.subscription_id)

  body = {
    properties = {
      principalId   = azuread_service_principal.tenant.object_id
      principalType = "ServicePrincipal"
      roleDefinitionId = format(
        "/subscriptions/%s/providers/Microsoft.Authorization/roleDefinitions/%s",
        each.value.subscription_id,
        local.reader_role_definition_id,
      )
    }
  }
}

resource "time_sleep" "delay_after_subscription_reader" {
  count = length(local.subscription_role_assignments) > 0 ? 1 : 0

  create_duration = "60s"

  depends_on = [
    azapi_resource.subscription_reader,
  ]
}

resource "azapi_resource" "management_group_reader" {
  count = local.tenant_application_enabled ? 1 : 0

  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", format("%s|%s|management-group-reader", local.root_management_group_scope, azuread_service_principal.tenant.object_id))
  parent_id = local.root_management_group_scope

  body = {
    properties = {
      principalId   = azuread_service_principal.tenant.object_id
      principalType = "ServicePrincipal"
      roleDefinitionId = format(
        "/providers/Microsoft.Authorization/roleDefinitions/%s",
        local.reader_role_definition_id,
      )
    }
  }
}

resource "azapi_resource" "subscription_skyhawk_role" {
  for_each = local.subscription_role_assignments

  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", format("%s|%s|subscription-skyhawk", each.value.subscription_id, azuread_service_principal.tenant.object_id))
  parent_id = format("/subscriptions/%s", each.value.subscription_id)

  body = {
    properties = {
      principalId   = azuread_service_principal.tenant.object_id
      principalType = "ServicePrincipal"
      roleDefinitionId = format(
        "/subscriptions/%s/providers/Microsoft.Authorization/roleDefinitions/%s",
        each.value.subscription_id,
        local.skyhawk_role_definition_guid,
      )
    }
  }

  depends_on = [
    azapi_resource.skyhawk_role_definition,
    azuread_service_principal.tenant,
  ]
}

resource "azapi_resource" "storage_blob_data_reader" {
  for_each = local.subscription_role_assignments

  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("url", format("%s|%s|subscription-blob-data-reader", each.value.subscription_id, azuread_service_principal.tenant.object_id))
  parent_id = format("/subscriptions/%s", each.value.subscription_id)

  body = {
    properties = {
      principalId   = azuread_service_principal.tenant.object_id
      principalType = "ServicePrincipal"
      roleDefinitionId = format(
        "/subscriptions/%s/providers/Microsoft.Authorization/roleDefinitions/%s",
        each.value.subscription_id,
        local.storage_blob_data_reader_role_definition_id,
      )
    }
  }

  depends_on = [
    azuread_service_principal.tenant,
  ]
}
