"""GCP Billing Kill-Switch Cloud Function.

The ONLY mechanism that actually STOPS GCP spend. Budget alerts merely notify;
this function DETACHES billing from the project when actual spend >= budget,
which halts every billable resource.

Trigger: Pub/Sub messages from the `billing-kill` budget topic.
Entry point: stop_billing(event, context)

Boundary: detaches the PROJECT's billing (heimdall-cp-prod by default) only.
It does NOT touch the SuperPe billing account or its other projects.
"""

import base64
import json
import logging
import os

import googleapiclient.discovery

# Structured logging so the $1 test is observable in Cloud Logging.
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("billing-kill-switch")

# Default target if the environment does not name one. The spec scopes this
# kill switch to heimdall-cp-prod only.
DEFAULT_PROJECT_ID = "heimdall-cp-prod"


def _resolve_project_id(notification):
    """Resolve the target project id.

    Order: explicit env (GCP_PROJECT / GOOGLE_CLOUD_PROJECT), then the
    notification payload if it carries one, then the scoped default.
    """
    for env_key in ("GCP_PROJECT", "GOOGLE_CLOUD_PROJECT"):
        value = os.environ.get(env_key)
        if value:
            return value
    # Budget notifications may carry the project under different shapes; accept
    # the common ones defensively without assuming presence.
    if isinstance(notification, dict):
        for key in ("projectId", "project_id"):
            value = notification.get(key)
            if value:
                return value
    return DEFAULT_PROJECT_ID


def _build_billing_client():
    """Build the Cloud Billing v1 discovery client.

    Isolated so tests can monkeypatch this seam without touching real GCP.
    cache_discovery is disabled to avoid file-cache warnings in the Functions
    runtime.
    """
    return googleapiclient.discovery.build(
        "cloudbilling", "v1", cache_discovery=False
    )


def _detach_billing(billing, project_resource):
    """Detach billing from the project. Idempotent.

    Returns True if a detach call was made, False if billing was already
    disabled (no-op).
    """
    info = billing.projects().getBillingInfo(name=project_resource).execute()
    if not info.get("billingEnabled"):
        logger.info(
            "billing already disabled — idempotent no-op (project=%s)",
            project_resource,
        )
        return False

    logger.warning(
        "DETACHING billing — disabling all billable resources (project=%s)",
        project_resource,
    )
    billing.projects().updateBillingInfo(
        name=project_resource, body={"billingAccountName": ""}
    ).execute()
    logger.warning(
        "billing DETACHED — spend stopped (project=%s)", project_resource
    )
    return True


def stop_billing(event, context):
    """Pub/Sub-triggered entry point for the budget kill switch.

    The budget notification arrives as a base64-encoded JSON Pub/Sub message in
    event['data']. Fields used: costAmount, budgetAmount, budgetDisplayName,
    currencyCode.

    If costAmount < budgetAmount: log the ratio and return (threshold pings).
    If costAmount >= budgetAmount: detach billing (idempotent).
    """
    raw = None
    if isinstance(event, dict):
        raw = event.get("data")
    if not raw:
        logger.error("no Pub/Sub data in event — nothing to process")
        return

    # Decode base64 -> JSON, defensively.
    try:
        decoded = base64.b64decode(raw).decode("utf-8")
        notification = json.loads(decoded)
    except (ValueError, TypeError, json.JSONDecodeError) as exc:
        logger.error("failed to decode/parse budget notification: %s", exc)
        return

    if not isinstance(notification, dict):
        logger.error("budget notification is not a JSON object — ignoring")
        return

    cost_amount = notification.get("costAmount")
    budget_amount = notification.get("budgetAmount")
    budget_name = notification.get("budgetDisplayName", "<unnamed>")
    currency = notification.get("currencyCode", "")

    if cost_amount is None or budget_amount is None:
        logger.error(
            "missing costAmount/budgetAmount in notification (budget=%s) — "
            "cannot evaluate threshold",
            budget_name,
        )
        return

    try:
        cost_amount = float(cost_amount)
        budget_amount = float(budget_amount)
    except (ValueError, TypeError) as exc:
        logger.error("costAmount/budgetAmount not numeric: %s", exc)
        return

    project_id = _resolve_project_id(notification)
    project_resource = "projects/%s" % project_id
    ratio = (cost_amount / budget_amount) if budget_amount else float("inf")

    if cost_amount < budget_amount:
        logger.info(
            "under threshold — no action (budget=%s, cost=%.2f%s, "
            "budget=%.2f%s, ratio=%.2f)",
            budget_name,
            cost_amount,
            currency,
            budget_amount,
            currency,
            ratio,
        )
        return

    logger.warning(
        "threshold REACHED — initiating detach (budget=%s, cost=%.2f%s, "
        "budget=%.2f%s, ratio=%.2f, project=%s)",
        budget_name,
        cost_amount,
        currency,
        budget_amount,
        currency,
        ratio,
        project_id,
    )

    billing = _build_billing_client()
    _detach_billing(billing, project_resource)
