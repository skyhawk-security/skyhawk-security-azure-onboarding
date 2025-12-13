# Skyhawk Security Azure Onboarding (Terraform Module)

## Overview
Terraform module that onboards one or more Azure subscriptions to Skyhawk Security. It creates an Azure AD application/service principal with Microsoft Graph permissions, assigns Reader/Storage Blob Data Reader and a custom Skyhawk role, provisions a storage account for logs, wires Activity Logs to that storage account, and sets an Event Grid subscription to forward security log blobs to the Skyhawk ingestion webhook. Optionally, it authenticates to Skyhawk and registers the tenant/subscriptions via HTTP API calls.

## What it creates
- Azure AD application/service principal with configurable Graph app roles and delegated permissions, plus a long-lived client secret.
- Provider registration for `Microsoft.Storage`, `Microsoft.Insights`, and `Microsoft.EventGrid` in each target subscription.
- Resource group and StorageV2 account per subscription; Activity Log diagnostic settings writing to that storage account.
- Event Grid webhook subscription on the storage account (filters Network Security Group flow logs, Activity Logs, Audit Logs, Sign-in Logs, StorageRead).
- Role assignments for the service principal: Reader on subscriptions and management group, Storage Blob Data Reader, and a custom Skyhawk role (query flow log status).
- Skyhawk API flows: register the tenant, then register additional subscriptions.

## Prerequisites
- Terraform >= 1.13.0.
- Azure AD Global Administrator to create the app/service principal, grant Graph permissions, and assign roles across subscriptions/management group.
- Providers used: `azuread` 3.7.0, `azapi` ~> 2.8.0, `http` ~> 3.5.0, `time` ~> 0.13.1.
- Skyhawk details:
  - `skh_api_url` – the Skyhawk-provided ingestion webhook URL for Event Grid.
  - `skh_api_access_key_id` and `skh_api_secret_key` – generate in the Skyhawk portal: log in → click your username → Access keys → Create new key.

## Authenticate to Azure
- You must be a Global Admin. Make sure you are in the correct tenant and can see the subscriptions you plan to onboard.
- Azure Cloud Shell (recommended): open https://shell.azure.com/, then verify with `az account list --output table`.
- Local shell: run `az login --use-device-code`, complete the browser flow, then verify with `az account list --output table`.

## Quickstart
```hcl
variable "tenant_id" {
  description = "Azure AD tenant ID"
  type        = string
  default     = "" # set via tfvars/env/CLI instead of editing in code
}

provider "azuread" {
  tenant_id = var.tenant_id
}

provider "azapi" {}

module "skyhawk_full_onboarding" {
  source = "../../modules/full-onboarding/"

  tenant_id               = var.tenant_id
  skh_api_access_key_id   = "<skyhawk-access-key-id>"   # from portal Access keys
  skh_api_secret_key      = "<skyhawk-secret-key>"      # from portal Access keys
  skh_api_url             = "https://<skyhawk-webhook>" # provided by Skyhawk
  subscription_ids        = ["<sub-1-guid>", "<sub-2-guid>"]
  resource_group_location = "eastus"

  # Keep true to call Skyhawk APIs (auth + tenant/subscription registration).
  # Set false only if Skyhawk instructs you not to call the APIs.
  perform_skyhawk_registration = true

  # Optional overrides
  # resource_group_locations = { "<sub-1-guid>" = "westus2" }
  # application_display_name  = "skh-onboarder"
  # application_password_validity = "17520h" # Go duration, 2 years
}
```

Then:
1) `terraform init`
2) `terraform plan -out plan.out`
3) `terraform apply plan.out`

See `examples/full-onboarding` for a ready-to-fill sample.

## Inputs (key ones)
- `tenant_id` (string, required) – Azure AD tenant ID.
- `subscription_ids` (list(string)) – Subscriptions to onboard (Reader/blob-reader/custom role + diagnostics).
- `skh_api_url` (string, required) – Skyhawk-provided ingestion webhook used by Event Grid.
- `skh_api_access_key_id` / `skh_api_secret_key` (string, required) – Generated in Skyhawk portal under Access keys.
- `perform_skyhawk_registration` (bool) – Keep true to execute Skyhawk auth + tenant/account registration; set false only if Skyhawk instructs you to skip API calls.
- `resource_group_location` (string, default `eastus`) – Region for created resource groups; can override per subscription via `resource_group_locations`.
- `application_display_name` (string, default `skh-onboarder-1`) – Base name for the AAD app/service principal (auto-uniquified per subscription).
- `application_password_validity` (string, default `17520h`) – Duration for the generated client secret.
- `msgraph_roles` / `msgraph_delegated_permissions` – Graph app roles and delegated permissions granted to the service principal.
- `auth_endpoint`, `skh_azure_tenant_endpoint`, `skh_azure_account_endpoint`, `subscription_importance` – Skyhawk API endpoints and metadata; override only if instructed by Skyhawk.

## Outputs
- `tenant_permissions` – IDs/names for the resource group, storage account, and AAD app/SP per subscription.
- `client_secrets` (sensitive) – Client secret metadata and value for the service principal.
- `skh_jwt_token` (sensitive) – JWT returned from Skyhawk auth.
- `tenant_registration_response` / `account_registration_responses` (sensitive) – Raw HTTP response data from Skyhawk tenant/account registration.
- `tenant_registration_debug` / `account_registration_debug` (sensitive) – Debug payloads for the Skyhawk API requests.

## Notes
- Leave `perform_skyhawk_registration` true unless Skyhawk tells you to disable API calls.
- The module registers required resource providers and waits for registration; applies may take a few minutes.
