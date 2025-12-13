data "http" "skh_auth_token" {
  count = var.perform_skyhawk_registration ? 1 : 0

  url    = var.auth_endpoint
  method = "POST"

  request_headers = {
    Accept         = "*/*"
    "Content-Type" = "application/json"
  }

  request_body = jsonencode({
    accessKeyId = var.skh_api_access_key_id
    secretKey   = var.skh_api_secret_key
  })
}

data "http" "tenant_registration" {
  count = var.perform_skyhawk_registration && local.tenant_registration_enabled ? 1 : 0

  url    = var.skh_azure_tenant_endpoint
  method = "POST"

  request_headers = {
    Accept         = "*/*"
    "Content-Type" = "application/json"
    Authorization  = local.tenant_registration_authorization
  }

  request_body = jsonencode({
    "tenantId"       = var.tenant_id
    "subscriptionId" = local.tenant_application_source_config.subscription_id
    "applicationId"  = azuread_application.tenant.client_id
    "applicationKey" = azuread_application_password.tenant.value
    "importance"     = var.subscription_importance
  })
  depends_on = [
    azuread_application.tenant,
    azuread_application_password.tenant,
    azapi_resource.subscription_reader,
    time_sleep.delay_after_subscription_reader,
  ]
  retry {
    attempts     = 4
    min_delay_ms = 20000
  }
}

data "http" "account_registration" {
  for_each = (
    var.perform_skyhawk_registration && local.tenant_registration_authorization != null && length(var.subscription_ids) > 1
    ) ? {
    for subscription_id, cfg in local.normalized_subscription_configs :
    subscription_id => cfg
    if subscription_id != local.tenant_application_source_config.subscription_id
  } : {}

  url    = var.skh_azure_account_endpoint
  method = "POST"

  request_headers = {
    Accept         = "*/*"
    "Content-Type" = "application/json"
    Authorization  = local.tenant_registration_authorization
  }

  request_body = jsonencode({
    "tenantId"       = var.tenant_id
    "subscriptionId" = each.value.subscription_id
    "importance"     = var.subscription_importance
  })

  depends_on = [
    data.http.tenant_registration,
    azuread_application.tenant,
    azuread_application_password.tenant,
    azapi_resource.subscription_reader,
  ]
  retry {
    attempts     = 4
    min_delay_ms = 20000
  }

}
