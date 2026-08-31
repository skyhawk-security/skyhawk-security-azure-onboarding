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

variable "enable_vnet_flow_logs" {
  description = "Enable VNet Flow Logs on all discovered VNets in the subscription. Set false to skip flow log creation."
  type        = bool
  default     = true
}

variable "collector_egress_ips" {
  description = <<-EOT
    Public egress IP addresses (CIDR notation) of the Skyhawk log collectors that read blob content
    from the created storage accounts. These are added to the storage account network ACL ipRules so
    that, with defaultAction = "Deny" (CIS Azure 3.7 compliant), the collectors can still read logs
    while the wider internet is blocked. First-party Azure writers (Network Watcher, Event Grid,
    diagnostic settings) are already permitted via bypass = "AzureServices" and do not need to be
    listed here.

    Must include every region's collector egress IP that may read a given customer's blobs.
    Known values (verify per environment):
      - prod us-east-1 NAT: 3.227.150.87/32
    If left empty, storage accounts still default to Deny but ONLY Azure services can reach them,
    which will break external blob reads — set this before onboarding real customers.
  EOT
  type        = list(string)
  default     = ["3.227.150.87/32"]

  validation {
    condition = alltrue([
      for cidr in var.collector_egress_ips : can(cidrhost(cidr, 0))
    ])
    error_message = "Each entry in collector_egress_ips must be valid CIDR notation (e.g., 3.227.150.87/32)."
  }
}

variable "tags" {
  description = "Map of tags to apply to all taggable resources created by this module. These are merged with default Skyhawk tags; customer-provided tags take precedence on conflicts."
  type        = map(string)
  default     = {}

  validation {
    condition     = length(var.tags) <= 49
    error_message = "Azure allows a maximum of 50 tags per resource. Since the module adds 1 default tag (managed-by), you can provide at most 49 custom tags."
  }

  validation {
    condition     = alltrue([for k, v in var.tags : length(k) <= 512])
    error_message = "Azure tag keys must not exceed 512 characters."
  }

  validation {
    condition     = alltrue([for k, v in var.tags : length(v) <= 256])
    error_message = "Azure tag values must not exceed 256 characters."
  }
}
