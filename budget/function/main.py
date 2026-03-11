import base64
import json
import os

from googleapiclient import discovery
import functions_framework


PROJECT_ID = os.getenv("GCP_PROJECT")
PROJECT_NAME = f"projects/{PROJECT_ID}"


@functions_framework.cloud_event
def stop_billing(cloud_event):
    """Cloud Function triggered by Pub/Sub to disable billing."""
    pubsub_data = base64.b64decode(cloud_event.data["message"]["data"]).decode("utf-8")
    pubsub_json = json.loads(pubsub_data)
    cost_amount = pubsub_json["costAmount"]
    budget_amount = pubsub_json["budgetAmount"]

    if cost_amount <= budget_amount:
        print(f"No action necessary. (Current cost: {cost_amount})")
        return

    if PROJECT_ID is None:
        print("No project specified with GCP_PROJECT environment variable")
        return

    billing = discovery.build("cloudbilling", "v1", cache_discovery=False)
    projects = billing.projects()

    billing_enabled = _is_billing_enabled(PROJECT_NAME, projects)
    if billing_enabled:
        _disable_billing_for_project(PROJECT_NAME, projects)
    else:
        print("Billing already disabled")


def _is_billing_enabled(project_name, projects):
    """Check whether billing is enabled for a project."""
    try:
        res = projects.getBillingInfo(name=project_name).execute()
        return res["billingEnabled"]
    except KeyError:
        return False
    except Exception:
        print("Unable to determine billing status, assuming enabled")
        return True


def _disable_billing_for_project(project_name, projects):
    """Disable billing by removing the billing account."""
    body = {"billingAccountName": ""}
    try:
        res = projects.updateBillingInfo(name=project_name, body=body).execute()
        print(f"Billing disabled: {json.dumps(res)}")
    except Exception:
        print("Failed to disable billing, possibly check permissions")
