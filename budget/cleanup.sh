#!/usr/bin/env bash
# =============================================================================
# cleanup.sh — Delete Budget, Cloud Function, and Pub/Sub topic
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../vllm/infra_config.env"
source "${SCRIPT_DIR}/config.env"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"

# Uses REGION from config.env (sourced from infra_config.env)
FUNCTION_REGION="${REGION}"

PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)" 2>/dev/null)
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
PUBSUB_SA="service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com"

# --- 1. Delete Budget ---
BILLING_ACCOUNT_ID="${BILLING_ACCOUNT_ID:-$(gcloud billing projects describe "${PROJECT_ID}" --format="value(billingAccountName)" 2>/dev/null | sed 's|billingAccounts/||')}"

if [ -n "${BILLING_ACCOUNT_ID}" ]; then
    BUDGET_PATH=$(gcloud billing budgets list \
        --billing-account="${BILLING_ACCOUNT_ID}" \
        --filter="displayName=${BUDGET_DISPLAY_NAME}" \
        --format="value(name)" 2>/dev/null | head -n 1)
    
    if [ -n "${BUDGET_PATH}" ]; then
        BUDGET_ID="${BUDGET_PATH##*/}"
        echo "Deleting budget ${BUDGET_DISPLAY_NAME} (ID: ${BUDGET_ID})..."
        gcloud billing budgets delete "${BUDGET_ID}" \
            --billing-account="${BILLING_ACCOUNT_ID}" \
            --quiet || echo "Failed to delete budget."
        echo "Budget deleted."
    else
        echo "Budget ${BUDGET_DISPLAY_NAME} not found."
    fi

    # Remove billing.admin role
    echo "Removing billing.admin role from ${COMPUTE_SA}..."
    gcloud billing accounts remove-iam-policy-binding "${BILLING_ACCOUNT_ID}" \
        --member="serviceAccount:${COMPUTE_SA}" \
        --role="roles/billing.admin" \
        --quiet >/dev/null 2>&1 || true
else
    echo "WARNING: Could not determine billing account. Skipping budget deletion."
fi

# --- 2. Remove Cloud Run and Pub/Sub IAM roles ---
echo "Removing run.invoker role from default compute service account..."
gcloud run services remove-iam-policy-binding "${FUNCTION_NAME}" \
    --region="${FUNCTION_REGION}" \
    --member="serviceAccount:${COMPUTE_SA}" \
    --role="roles/run.invoker" \
    --quiet >/dev/null 2>&1 || true

echo "Removing iam.serviceAccountTokenCreator role from Pub/Sub service agent..."
gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${PUBSUB_SA}" \
    --role="roles/iam.serviceAccountTokenCreator" \
    --quiet >/dev/null 2>&1 || true

# --- 3. Delete Cloud Function ---
EXISTING_FUNCTION=$(gcloud functions describe "${FUNCTION_NAME}" \
    --project="${PROJECT_ID}" \
    --region="${FUNCTION_REGION}" \
    --gen2 \
    --format="value(name)" 2>/dev/null || true)

if [ -n "${EXISTING_FUNCTION}" ]; then
    echo "Deleting Cloud Function ${FUNCTION_NAME}..."
    gcloud functions delete "${FUNCTION_NAME}" \
        --project="${PROJECT_ID}" \
        --region="${FUNCTION_REGION}" \
        --gen2 \
        --quiet || echo "Failed to delete Cloud Function."
    echo "Cloud Function deleted."
else
    echo "Cloud Function ${FUNCTION_NAME} not found."
fi

# --- 4. Remove Cloud Build permission ---
echo "Removing cloudbuild.builds.builder role from ${COMPUTE_SA}..."
gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${COMPUTE_SA}" \
    --role="roles/cloudbuild.builds.builder" \
    --quiet >/dev/null 2>&1 || true

# --- 5. Delete Pub/Sub topic ---
EXISTING_TOPIC=$(gcloud pubsub topics list \
    --project="${PROJECT_ID}" \
    --filter="name:projects/${PROJECT_ID}/topics/${PUBSUB_TOPIC}" \
    --format="value(name)" 2>/dev/null || true)

if [ -n "${EXISTING_TOPIC}" ]; then
    echo "Deleting Pub/Sub topic ${PUBSUB_TOPIC}..."
    gcloud pubsub topics delete "${PUBSUB_TOPIC}" \
        --project="${PROJECT_ID}" \
        --quiet || echo "Failed to delete Pub/Sub topic."
    echo "Topic deleted."
else
    echo "Pub/Sub topic ${PUBSUB_TOPIC} not found."
fi

echo "Cleanup complete."
