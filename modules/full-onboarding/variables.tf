variable "tenant_id" {
  description = "Azure AD tenant ID associated with the created applications."
  type        = string
}

variable "skh_api_url" {
  description = "Webhook endpoint used by Event Grid to deliver storage account events."
  type        = string
}

variable "skh_api_access_key_id" {
  description = "Skyhawk API access key identifier used to authenticate webhook delivery."
  type        = string
}

variable "skh_api_secret_key" {
  description = "Skyhawk API secret key used to authenticate webhook delivery."
  type        = string
  sensitive   = true
}

variable "auth_endpoint" {
  description = "Authentication endpoint used to exchange API credentials for a JWT token."
  type        = string
  default     = "https://api-x.us-east-1.skyhawk.security/api/v1/accesskeys/authentication"
}

variable "subscription_ids" {
  description = "List of subscription IDs that should receive the Reader role assignment."
  type        = list(string)
  default     = []
}

variable "resource_group_location" {
  description = "Azure region where resource groups should be created."
  type        = string
  default     = "eastus"
}

variable "resource_group_locations" {
  description = "Optional map of subscription ID to Azure region; overrides resource_group_location for matching subscriptions."
  type        = map(string)
  default     = {}
}

variable "application_display_name" {
  description = "Base display name used when generating application names."
  type        = string
  default     = "skh-onboarder-1"
}

variable "application_homepage_url" {
  description = "Homepage URL applied to generated applications."
  type        = string
  default     = "https://www.skyhawksecurity.com"
}

variable "application_password_validity" {
  description = "How long the generated client secret stays valid (Go duration, e.g., 17520h = 2 years)."
  type        = string
  default     = "17520h"
}

variable "msgraph_roles" {
  description = "Default Microsoft Graph application roles granted to each generated service principal."
  type        = list(string)
  default = [
    "Directory.Read.All",
    "AuditLog.Read.All",
    "UserAuthenticationMethod.Read.All",
  ]
}

variable "msgraph_delegated_permissions" {
  description = "Default Microsoft Graph delegated permissions (OAuth2 scopes) granted to each generated service principal."
  type        = list(string)
  default     = ["User.Read"]
}

variable "skh_azure_tenant_endpoint" {
  description = "Skyhawk endpoint used to register Azure tenant metadata."
  type        = string
  default     = "https://api-x.us-east-1.skyhawk.security/api/v1/accounts/azure/tenant"
}

variable "skh_azure_account_endpoint" {
  description = "Skyhawk endpoint used to register Azure subscription metadata."
  type        = string
  default     = "https://api-x.us-east-1.skyhawk.security/api/v1/accounts/azure/account"
}

variable "subscription_importance" {
  description = "Importance value reported alongside each onboarded subscription."
  type        = string
  default     = "Low"
}

variable "perform_skyhawk_registration" {
  description = "Set true (typically only during terraform apply) to execute Skyhawk authentication and registration HTTP calls."
  type        = bool
  default     = false
}
