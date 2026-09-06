# =============================================================================
# BUG-4 — Preflight permission checks
# =============================================================================
# Goal: fail fast, BEFORE creating any resources, if the running identity clearly
# cannot proceed — instead of dying mid-apply and leaving partial state.
#
# Design note (review feedback): Terraform `check` blocks are ADVISORY ONLY — a
# failed assert prints a warning and the apply continues, and they run AFTER
# provisioning. They cannot "fail fast." So preflight is enforced two ways that
# actually block:
#   1. Read-only data-source probes below. If the identity cannot read a target
#      subscription, the provider hard-fails during refresh (a real 403) and the
#      plan/apply stops before any resource is created.
#   2. A `precondition` on the FIRST created resource (the per-subscription
#      resource group, see main.tf) that asserts every probed subscription is
#      Enabled/readable and the AAD identity resolved — with a clear message.
#      A failing precondition HALTS the apply before that resource is created.
#
# We intentionally do NOT try to pre-check write permissions (e.g., role
# assignment creation): Azure has no side-effect-free "can I write" API, listing
# role assignments only proves READ (a different action than the write the module
# needs), and it would pull an unbounded list on every plan. Verifying read +
# identity is the honest, cheap signal; genuine write-permission gaps still
# surface as a normal Azure error at the relevant resource (now with partial-state
# risk reduced because the cheap checks already gated the run).

# ---------------------------------------------------------------------------
# Identify the running principal. Fails early if AAD is unreachable / creds
# are invalid.
# ---------------------------------------------------------------------------
data "azuread_client_config" "current" {}

# ---------------------------------------------------------------------------
# Per-subscription read probe. Reading the subscription object requires at least
# Reader. If the caller cannot read it, this data source hard-fails during
# refresh with the Azure authorization error, aborting the plan before any
# resource is created. The exported `state` is also consumed by the precondition
# on the resource group (main.tf) to produce a clear, actionable message.
# ---------------------------------------------------------------------------
data "azapi_resource" "subscription_probe" {
  for_each = toset(var.subscription_ids)

  type        = "Microsoft.Resources/subscriptions@2021-04-01"
  resource_id = format("/subscriptions/%s", each.value)

  response_export_values = ["subscriptionId", "state"]
}

locals {
  # True only if the AAD identity resolved and every target subscription is
  # readable and Enabled. Consumed by the resource-group precondition (main.tf).
  preflight_identity_ok = data.azuread_client_config.current.object_id != null

  preflight_unready_subscriptions = [
    for sub_id in var.subscription_ids :
    sub_id
    if try(data.azapi_resource.subscription_probe[sub_id].output.state, "") != "Enabled"
  ]

  preflight_ok = local.preflight_identity_ok && length(local.preflight_unready_subscriptions) == 0

  # Build a headline that names EVERY failing check (review #7: don't let a
  # ternary hide the subscription problem when identity also fails).
  preflight_failed_reasons = compact([
    local.preflight_identity_ok ? "" : "the Azure AD identity could not be resolved",
    length(local.preflight_unready_subscriptions) == 0 ? "" : "one or more target subscriptions are not readable/Enabled",
  ])

  preflight_error_message = format(
    "PREFLIGHT FAILED: %s. Ensure you are authenticated to the correct tenant and the running principal has at least the \"Reader\" role on every target subscription, and that each subscription is Enabled. Identity resolved: %s. Not-ready subscriptions: [%s].",
    join("; and ", local.preflight_failed_reasons),
    local.preflight_identity_ok ? "yes" : "no",
    join(", ", local.preflight_unready_subscriptions),
  )
}

# ---------------------------------------------------------------------------
# Dedicated preflight GATE (review feedback #5).
# A single gate resource carries the precondition. Every independent top-level
# resource chain (`resource_group`, `vnet_flow_log_resource_group`,
# `azuread_application`) explicitly `depends_on` this gate, so the gate's
# coverage is an intentional, auditable property rather than an accidental
# byproduct of which resources happen to reference `resource_group.id`.
#
# terraform_data has no cloud side effects — it exists only to host the
# precondition and act as an ordering barrier. If preflight fails, this resource
# errors during apply BEFORE any dependent resource is created.
#
# KNOWN LIMITATION (documented, review #3/#4): a pure-Terraform gate cannot beat
# provider-level refresh errors. If an identity has NO read access to a target
# subscription, `data.azapi_resource.subscription_probe` hard-fails during
# refresh and the plan aborts before this gate is evaluated — the operator sees
# the raw Azure 403. Likewise, provider registration (Contributor-class write)
# runs upstream and is not probed here. This gate meaningfully covers the
# "readable-but-not-Enabled subscription" and "unresolved identity" cases and
# guarantees no dependent resource is created when those fail; it does not (and
# cannot, in pure Terraform) convert every possible upstream Azure error into a
# friendly message.
resource "terraform_data" "preflight_gate" {
  input = {
    identity_ok           = local.preflight_identity_ok
    unready_subscriptions = local.preflight_unready_subscriptions
  }

  lifecycle {
    precondition {
      condition     = local.preflight_ok
      error_message = local.preflight_error_message
    }
  }
}
