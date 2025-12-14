output "tenant_permissions" {
  value = module.tenant_permissions.tenant_permissions
}

output "client_secrets" {
  value     = module.tenant_permissions.client_secrets
  sensitive = true
}

output "skh_jwt_token" {
  value     = module.tenant_permissions.skh_jwt_token
  sensitive = true
}

output "tenant_registration_response" {
  value     = module.tenant_permissions.tenant_registration_response
  sensitive = true
}

output "tenant_registration_debug" {
  value     = module.tenant_permissions.tenant_registration_debug
  sensitive = true
}

output "account_registration_responses" {
  value     = module.tenant_permissions.account_registration_responses
  sensitive = true
}

output "account_registration_debug" {
  value     = module.tenant_permissions.account_registration_debug
  sensitive = true
}
