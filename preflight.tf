# =============================================================================
# BUG-4 — Preflight permission checks
# =============================================================================
# Previously the module had NO pre-validation: it jumped straight into creating
# AAD apps, resource groups, storage accounts, role assignments, flow logs, etc.
# If the running identity lacked any required permission, it failed MID-APPLY,
# leaving partial resources that then caused re-run collisions (BUG-1/BUG-2).
#
# This file validates, as early as possible, that:
#   1. We can identify the running principal (AAD reachable).
#   2. Each target subscription is readable AND the caller can enumerate its
#      role assignments / providers (a proxy for having Contributor-level access).
#
# The probes below are READ-ONLY. If a probe fails, Terraform surfaces the
# underlying Azure 403 during plan/refresh; the `check` blocks add a clear,
# actionable message pointing at the missing permission and subscription so the
# operator does not have to decode a raw Azure error.
#
# NOTE: Azure has no single "can I do everything" API, so this is a best-effort
# fail-fast. It catches the common cases (no Reader, no subscription access, AAD
# not reachable). It intentionally does NOT try to pre-validate every single
# write permission — that would require dozens of dry-run calls. The goal is to
# turn "cryptic mid-apply 403 + partial state" into "clear pre-apply message".

# ---------------------------------------------------------------------------
# 1. Identify the running principal (fails early if AAD is unreachable / the
#    credentials are invalid).
# ---------------------------------------------------------------------------
data "azuread_client_config" "current" {}

# ---------------------------------------------------------------------------
# 2. Per-subscription read probe. Reading the subscription object requires at
#    least Reader on the subscription. If the caller cannot read it, this data
#    source errors during refresh with the Azure authorization failure.
# ---------------------------------------------------------------------------
data "azapi_resource" "subscription_probe" {
  for_each = toset(var.subscription_ids)

  type        = "Microsoft.Resources/subscriptions@2021-04-01"
  resource_id = format("/subscriptions/%s", each.value)

  response_export_values = ["subscriptionId", "state"]
}

# ---------------------------------------------------------------------------
# 3. Per-subscription role-assignment enumeration probe. Listing role
#    assignments at subscription scope requires Microsoft.Authorization/
#    roleAssignments/read, which Reader grants. This confirms the caller can at
#    least see the subscription's RBAC surface (a precondition for the module's
#    own role-assignment creation).
# ---------------------------------------------------------------------------
data "azapi_resource_list" "role_assignments_probe" {
  for_each = toset(var.subscription_ids)

  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  parent_id = format("/subscriptions/%s", each.value)

  response_export_values = ["value"]
}

# ---------------------------------------------------------------------------
# Check blocks: turn probe results into clear, actionable messages.
# `check` blocks emit warnings/errors WITHOUT blocking unrelated resources,
# and run during plan — surfacing issues before apply creates anything.
# ---------------------------------------------------------------------------
check "aad_identity_reachable" {
  assert {
    condition     = data.azuread_client_config.current.object_id != null
    error_message = <<-EOT
      PREFLIGHT FAILED: Could not resolve the running Azure AD identity.
      The credentials configured for the azuread/azapi providers are invalid or
      Azure AD is unreachable. Verify you are authenticated (az login / service
      principal env vars) before running this module.
    EOT
  }
}

check "subscriptions_readable" {
  assert {
    condition = alltrue([
      for sub_id in var.subscription_ids :
      try(data.azapi_resource.subscription_probe[sub_id].output.state, "") == "Enabled"
    ])
    error_message = <<-EOT
      PREFLIGHT FAILED: One or more target subscriptions are not readable or not
      in an Enabled state with the current identity. Ensure the running principal
      has at least the "Reader" role on every subscription in var.subscription_ids,
      and that each subscription is active. Subscriptions checked:
      ${join(", ", var.subscription_ids)}
    EOT
  }
}

check "role_assignments_enumerable" {
  assert {
    condition = alltrue([
      for sub_id in var.subscription_ids :
      can(data.azapi_resource_list.role_assignments_probe[sub_id].output.value)
    ])
    error_message = <<-EOT
      PREFLIGHT FAILED: Cannot enumerate role assignments on one or more target
      subscriptions. This module creates role assignments (subscription Reader,
      Storage Blob Data Reader, custom skyhawk role), which requires
      Microsoft.Authorization/roleAssignments write — typically the "Owner" or
      "User Access Administrator" role. If this probe fails you almost certainly
      lack the permission to create the role assignments later in the apply.
      Subscriptions checked: ${join(", ", var.subscription_ids)}
    EOT
  }
}
