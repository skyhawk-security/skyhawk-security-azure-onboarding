output "tenant_permissions" {
  value = {
    for key, config in local.normalized_subscription_configs :
    key => {
      tenant_id       = config.tenant_id
      subscription_id = config.subscription_id
      resource_group = {
        id       = azapi_resource.resource_group[key].id
        name     = azapi_resource.resource_group[key].name
        location = config.resource_group_location
      }
      storage_account = {
        id       = azapi_resource.storage_account[key].id
        name     = azapi_resource.storage_account[key].name
        location = config.resource_group_location
      }
      application = {
        application_id = azuread_application.tenant.id
        display_name   = azuread_application.tenant.display_name
        client_id      = azuread_application.tenant.client_id
      }
      service_principal = {
        object_id = azuread_service_principal.tenant.object_id
        client_id = azuread_service_principal.tenant.client_id
      }
      client_secret_metadata = {
        key_id       = azuread_application_password.tenant.key_id
        display_name = azuread_application_password.tenant.display_name
        start_date   = azuread_application_password.tenant.start_date
        end_date     = azuread_application_password.tenant.end_date
      }
    }
  }
}

output "client_secrets" {
  value = {
    for key, config in local.normalized_subscription_configs :
    key => {
      tenant_id       = config.tenant_id
      subscription_id = config.subscription_id
      client_secret = {
        key_id       = azuread_application_password.tenant.key_id
        display_name = azuread_application_password.tenant.display_name
        start_date   = azuread_application_password.tenant.start_date
        end_date     = azuread_application_password.tenant.end_date
        value        = azuread_application_password.tenant.value
      }
    }
  }
  sensitive = true
}

output "skh_jwt_token" {
  value     = local.skh_jwt_token
  sensitive = true
}

output "tenant_registration_response" {
  value = try({
    status_code      = data.http.tenant_registration[0].status_code
    response_body    = data.http.tenant_registration[0].response_body
    response_headers = data.http.tenant_registration[0].response_headers
  }, null)
  sensitive = true
}

output "tenant_registration_debug" {
  value = {
    tenant_id                              = var.tenant_id
    tenant_registration_enabled            = local.tenant_registration_enabled
    tenant_registration_application_id     = azuread_application.tenant.client_id
    tenant_registration_application_secret = azuread_application_password.tenant.value
    tenant_registration_authorizer         = local.tenant_registration_authorization
    tenant_registration_request_url        = var.skh_azure_tenant_endpoint
    tenant_registration_body = {
      tenantId       = var.tenant_id
      applicationId  = azuread_application.tenant.client_id
      applicationKey = azuread_application_password.tenant.value
      importance     = var.subscription_importance
    }
  }
  sensitive = true
}

output "account_registration_responses" {
  value = {
    for key, config in local.normalized_subscription_configs :
    key => (
      contains(keys(data.http.account_registration), key)
      ? try({
        status_code      = data.http.account_registration[key].status_code
        response_body    = data.http.account_registration[key].response_body
        response_headers = data.http.account_registration[key].response_headers
      }, null)
      : null
    )
  }
  sensitive = true
}

output "account_registration_debug" {
  value = {
    tenant_id                = var.tenant_id
    account_registration_url = var.skh_azure_account_endpoint
    account_registration_headers = {
      Accept        = "*/*"
      Content-Type  = "application/json"
      Authorization = local.tenant_registration_authorization
    }
    requests = {
      for key, config in local.normalized_subscription_configs :
      key => {
        tenantId       = var.tenant_id
        subscriptionId = config.subscription_id
        importance     = var.subscription_importance
      }
    }
  }
  sensitive = true
}
