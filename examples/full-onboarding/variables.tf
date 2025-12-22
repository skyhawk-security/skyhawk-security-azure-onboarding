variable "tenant_id" {
  description = "Azure AD tenant ID"
  type        = string
}

variable "skh_api_access_key_id" {
  description = "Skyhawk API access key ID"
  type        = string
}

variable "skh_api_secret_key" {
  description = "Skyhawk API secret key"
  type        = string
  sensitive   = true
}

variable "skh_api_url" {
  description = "Skyhawk API URL"
  type        = string
}

variable "subscription_ids" {
  description = "Azure subscription IDs"
  type        = list(string)
}
