#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Create Pub/Sub topic, Cloud Function, and Budget
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../config.env"
source "${SCRIPT_DIR}/../budget-config.env"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
FUNCTION_SOURCE="${SCRIPT_DIR}/../function"

# Uses REGION from config.env instead of FUNCTION_REGION
FUNCTION_REGION="${REGION}"

# --- Enable required APIs ---
APIS=("cloudfunctions.googleapis.com" "pubsub.googleapis.com" "cloudbilling.googleapis.com" "cloudresourcemanager.googleapis.com" "billingbudgets.googleapis.com" "cloudbuild.googleapis.com" "run.googleapis.com" "eventarc.googleapis.com")
for api in "${APIS[@]}"; do
    STATUS=$(gcloud services list --project="${PROJECT_ID}" --filter="name:${api}" --format="value(name)" 2>/dev/null)
    if [ -z "${STATUS}" ]; then
        echo "Enabling ${api}..."
        gcloud services enable "${api}" --project="${PROJECT_ID}" --quiet
    fi
done

# --- 1. Create Pub/Sub topic ---
EXISTING_TOPIC=$(gcloud pubsub topics list \
    --project="${PROJECT_ID}" \
    --filter="name:projects/${PROJECT_ID}/topics/${PUBSUB_TOPIC}" \
    --format="value(name)" 2>/dev/null)

if [ -n "${EXISTING_TOPIC}" ]; then
    echo "Pub/Sub topic ${PUBSUB_TOPIC} already exists."
else
    echo "Creating Pub/Sub topic ${PUBSUB_TOPIC}..."
    gcloud pubsub topics create "${PUBSUB_TOPIC}" \
        --project="${PROJECT_ID}" \
        --quiet
    echo "Topic created."
fi

# --- 2. Grant Cloud Build permission to default compute service account ---
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)" 2>/dev/null)
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

echo "Granting cloudbuild.builds.builder role to ${COMPUTE_SA}..."
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${COMPUTE_SA}" \
    --role="roles/cloudbuild.builds.builder" \
    --quiet >/dev/null 2>&1

# --- 3. Deploy Cloud Function (Gen2) ---
echo "Deploying Cloud Function ${FUNCTION_NAME}..."
gcloud functions deploy "${FUNCTION_NAME}" \
    --project="${PROJECT_ID}" \
    --region="${FUNCTION_REGION}" \
    --gen2 \
    --runtime="${FUNCTION_RUNTIME}" \
    --entry-point="${FUNCTION_ENTRY_POINT}" \
    --source="${FUNCTION_SOURCE}" \
    --trigger-topic="${PUBSUB_TOPIC}" \
    --set-env-vars="GCP_PROJECT=${PROJECT_ID}" \
    --quiet

echo "Cloud Function deployed."

# --- 4. Grant Pub/Sub permission to invoke the Cloud Run service ---
PUBSUB_SA="service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com"

echo "Granting iam.serviceAccountTokenCreator to Pub/Sub service agent..."
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${PUBSUB_SA}" \
    --role="roles/iam.serviceAccountTokenCreator" \
    --quiet >/dev/null 2>&1

echo "Granting run.invoker to default compute service account..."
gcloud run services add-iam-policy-binding "${FUNCTION_NAME}" \
    --region="${FUNCTION_REGION}" \
    --member="serviceAccount:${COMPUTE_SA}" \
    --role="roles/run.invoker" \
    --quiet >/dev/null 2>&1

# --- 5. Grant billing permission so the function can disable billing ---
BILLING_ACCOUNT_ID="${BILLING_ACCOUNT_ID:-$(gcloud billing projects describe "${PROJECT_ID}" --format="value(billingAccountName)" 2>/dev/null | sed 's|billingAccounts/||')}"

echo "Granting billing.admin to ${COMPUTE_SA}..."
gcloud billing accounts add-iam-policy-binding "${BILLING_ACCOUNT_ID}" \
    --member="serviceAccount:${COMPUTE_SA}" \
    --role="roles/billing.admin" \
    --quiet >/dev/null 2>&1

# --- 3. Create Budget ---
BILLING_ACCOUNT_ID="${BILLING_ACCOUNT_ID:-$(gcloud billing projects describe "${PROJECT_ID}" --format="value(billingAccountName)" 2>/dev/null | sed 's|billingAccounts/||')}"

if [ -z "${BILLING_ACCOUNT_ID}" ]; then
    echo "ERROR: Could not determine billing account. Set BILLING_ACCOUNT_ID in config.env."
    exit 1
fi

# Check if budget already exists
EXISTING_BUDGET=$(gcloud billing budgets list \
    --billing-account="${BILLING_ACCOUNT_ID}" \
    --filter="displayName=${BUDGET_DISPLAY_NAME}" \
    --format="value(name)" 2>/dev/null)

if [ -n "${EXISTING_BUDGET}" ]; then
    echo "Budget ${BUDGET_DISPLAY_NAME} already exists."
else
    echo "Creating budget ${BUDGET_DISPLAY_NAME} (amount: \$${BUDGET_AMOUNT})..."

    FULL_TOPIC="projects/${PROJECT_ID}/topics/${PUBSUB_TOPIC}"

    gcloud billing budgets create \
        --billing-account="${BILLING_ACCOUNT_ID}" \
        --display-name="${BUDGET_DISPLAY_NAME}" \
        --budget-amount="${BUDGET_AMOUNT}TRY" \
        --credit-types-treatment=exclude-all-credits \
        --threshold-rule=percent=${BUDGET_THRESHOLD} \
        --notifications-rule-pubsub-topic="${FULL_TOPIC}" \
        --quiet

    echo "Budget created."
fi

echo "Budget alert setup complete."
echo "  Topic:    ${PUBSUB_TOPIC}"
echo "  Function: ${FUNCTION_NAME}"
echo "  Budget:   ${BUDGET_DISPLAY_NAME} (${BUDGET_AMOUNT}TRY)"
