# Skyhawk Security Azure Onboarding (Terraform Module)

## Overview
Terraform module that onboards one or more Azure subscriptions to Skyhawk Security. It creates an Azure AD application/service principal with Microsoft Graph permissions, assigns Reader/Storage Blob Data Reader and a custom Skyhawk role, provisions storage accounts for logs, wires Activity Logs (per subscription) and VNet Flow Logs (per subscription and region) to storage, and sets Event Grid subscriptions to forward security log blobs to the Skyhawk ingestion webhook. Storage accounts are network-hardened (public network access denied by default, with only the Skyhawk collector allow-listed). Optionally, it authenticates to Skyhawk and registers the tenant/subscriptions via HTTP API calls.

## What it creates
- Azure AD application/service principal with configurable Graph app roles and delegated permissions, plus a long-lived client secret.
- Provider registration for `Microsoft.Storage`, `Microsoft.Insights`, `Microsoft.EventGrid`, and `Microsoft.Network` in each target subscription.
- Resource group and StorageV2 account per subscription; Activity Log diagnostic settings writing to that storage account.
- VNet Flow Logs for all discovered VNets in each subscription. Flow logs are written to a dedicated StorageV2 account per subscription and region (flow logs are region-bound), created under a `skh-flowlogs-<region>-rg` resource group (enabled by default, opt-out via `enable_vnet_flow_logs = false`).
- Storage accounts are network-hardened: `defaultAction = Deny` (public access blocked; satisfies CIS Azure benchmark 3.7), `bypass = AzureServices` (allows Azure writers such as Network Watcher, Event Grid, and diagnostic settings), plus an IP allow-list for the Skyhawk collector egress IP(s) (`collector_egress_ips`). Also `allowBlobPublicAccess = false`, `minimumTlsVersion = TLS1_2`, HTTPS-only.
- Event Grid webhook subscriptions forwarding log blobs to the Skyhawk webhook: one on the per-subscription Activity Log storage account (filters Activity/Audit/Sign-in/StorageRead + flow-log containers), and one on each per-region flow-log storage account (filters VNet Flow Logs and NSG Flow Logs). Both are required for logs to reach Skyhawk.
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

module "skyhawk_onboarding" {
  source  = "skyhawk-security/onboarding/azure"
  version = "2.0.0"

  tenant_id               = var.tenant_id
  skh_api_access_key_id   = "<skyhawk-access-key-id>"   # from portal Access keys
  skh_api_secret_key      = "<skyhawk-secret-key>"      # from portal Access keys
  skh_api_url             = "https://<skyhawk-webhook>" # provided by Skyhawk
  subscription_ids        = ["<sub-1-guid>", "<sub-2-guid>"]
  resource_group_location = "eastus"

  # Keep true to call Skyhawk APIs (auth + tenant/subscription registration).
  # Set false only if Skyhawk instructs you not to call the APIs.
  perform_skyhawk_registration = true

  # VNet Flow Logs are enabled by default for all VNets.
  # Set false to skip flow log creation.
  # enable_vnet_flow_logs = false

  # Optional: custom tags applied to all created resources
  # tags = {
  #   environment  = "production"
  #   cost-center  = "security"
  #   project      = "skyhawk-onboarding"
  # }

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
- `enable_vnet_flow_logs` (bool, default `true`) – Auto-discover all VNets and create flow logs. Set false to skip.
- `collector_egress_ips` (list(string), default `["3.227.150.87/32"]`) – Public egress IP(s) of the Skyhawk log collector, added to the storage account IP allow-list so the collector can read log blobs while `defaultAction = Deny`. A `/32` suffix is accepted and normalized. Override only if instructed by Skyhawk (e.g., a different collection region).
- `tags` (map(string), default `{}`) – Custom tags to apply to all taggable resources (resource groups, storage accounts, flow logs). Merged with the default `managed-by = skyhawk-security` tag; customer-provided tags take precedence on conflicts.
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

## Upgrading to v2.2.0

v2.2.0 hardens storage and fixes flow-log delivery. Behavioral changes to be aware of:

- **Storage network hardening (CIS 3.7):** storage accounts now default to `defaultAction = Deny`.
  The Skyhawk collector egress IP is allow-listed via the new `collector_egress_ips` input
  (default `["3.227.150.87/32"]`). If your collector uses a different egress IP, set this variable.
- **Flow-log storage account naming changed** to a deterministic hash suffix (`skhflow<hash>`) to
  avoid global name collisions across region variants (e.g., `eastus` vs `eastus2`). On upgrade,
  existing flow-log storage accounts created by an older version will be **replaced** (destroy +
  recreate) because the storage account name is immutable. This drops historical flow-log blobs in
  the old account; ongoing collection continues in the new account.
- **New Event Grid subscription on flow-log storage accounts:** earlier versions did not create an
  Event Grid subscription on the flow-log storage account, so flow logs were written but never
  delivered to Skyhawk. v2.2.0 adds it. After upgrading, flow-log ingestion begins working.
- **Idempotent flow logs:** flow-log updates now send an explicit (disabled) Traffic Analytics
  configuration, so re-applies against flow logs that had Traffic Analytics enabled no longer fail.

## Upgrading from v1.x

In v2.0.0, the module code moved from `modules/full-onboarding/` to the repository root. Update your source:

```hcl
# Before (v1.x):
source = "skyhawk-security/onboarding/azure//modules/full-onboarding"

# After (v2.x):
source  = "skyhawk-security/onboarding/azure"
version = "2.0.0"
```

## Notes
- Leave `perform_skyhawk_registration` true unless Skyhawk tells you to disable API calls.
- The module registers required resource providers and waits for registration; applies may take a few minutes.
- VNet Flow Logs are auto-discovered and created for all VNets in onboarded subscriptions. No VNet IDs need to be specified.
