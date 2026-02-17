#!/usr/bin/env bash
# =============================================================================
# 06-cleanup-budget.sh — Remove budget alert resources
# Usage: 06-cleanup-budget.sh [--function | --budget | --topic | --all]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"

usage() {
    echo "Usage: $0 [--function | --budget | --topic | --all]"
    echo ""
    echo "  --function  Delete the Cloud Function"
    echo "  --budget    Delete the budget alert"
    echo "  --topic     Delete the Pub/Sub topic"
    echo "  --all       Delete all budget alert resources"
    exit 1
}

delete_function() {
    echo "Deleting Cloud Function ${FUNCTION_NAME}..."
    gcloud functions delete "${FUNCTION_NAME}" \
        --project="${PROJECT_ID}" \
        --region="${FUNCTION_REGION}" \
        --gen2 \
        --quiet 2>/dev/null || echo "Function not found or already deleted."
}

delete_budget() {
    BILLING_ACCOUNT_ID="${BILLING_ACCOUNT_ID:-$(gcloud billing projects describe "${PROJECT_ID}" --format="value(billingAccountName)" 2>/dev/null | sed 's|billingAccounts/||')}"

    if [ -z "${BILLING_ACCOUNT_ID}" ]; then
        echo "ERROR: Could not determine billing account."
        return
    fi

    BUDGET_NAME=$(gcloud billing budgets list \
        --billing-account="${BILLING_ACCOUNT_ID}" \
        --filter="displayName=${BUDGET_DISPLAY_NAME}" \
        --format="value(name)" 2>/dev/null)

    if [ -n "${BUDGET_NAME}" ]; then
        echo "Deleting budget ${BUDGET_DISPLAY_NAME}..."
        gcloud billing budgets delete "${BUDGET_NAME}" \
            --billing-account="${BILLING_ACCOUNT_ID}" \
            --quiet
        echo "Budget deleted."
    else
        echo "Budget ${BUDGET_DISPLAY_NAME} not found."
    fi
}

delete_topic() {
    echo "Deleting Pub/Sub topic ${PUBSUB_TOPIC}..."
    gcloud pubsub topics delete "${PUBSUB_TOPIC}" \
        --project="${PROJECT_ID}" \
        --quiet 2>/dev/null || echo "Topic not found or already deleted."
}

if [ $# -eq 0 ]; then
    usage
fi

case "$1" in
    --function)
        delete_function
        ;;
    --budget)
        delete_budget
        ;;
    --topic)
        delete_topic
        ;;
    --all)
        delete_function
        delete_budget
        delete_topic
        ;;
    *)
        usage
        ;;
esac

echo "Cleanup complete."
