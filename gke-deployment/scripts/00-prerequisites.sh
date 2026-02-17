#!/usr/bin/env bash
# =============================================================================
# 00-prerequisites.sh — Validate required tools and enable GCP APIs
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

# Resolve project ID
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
if [ -z "${PROJECT_ID}" ]; then
    echo "ERROR: No GCP project set. Run: gcloud config set project <PROJECT_ID>"
    exit 1
fi

# Check required tools
MISSING=()
for cmd in gcloud kubectl envsubst; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        MISSING+=("${cmd}")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "ERROR: Missing required tools: ${MISSING[*]}"
    echo "Install them before proceeding."
    exit 1
fi

echo "Project: ${PROJECT_ID}"
echo "Tools: gcloud, kubectl, envsubst — OK"

# Enable required APIs
APIS=("container.googleapis.com" "compute.googleapis.com")
for api in "${APIS[@]}"; do
    STATUS=$(gcloud services list --project="${PROJECT_ID}" --filter="name:${api}" --format="value(name)" 2>/dev/null)
    if [ -z "${STATUS}" ]; then
        echo "Enabling ${api}..."
        gcloud services enable "${api}" --project="${PROJECT_ID}" --quiet
    else
        echo "API ${api} — already enabled"
    fi
done

# Check GPU quota
GPU_QUOTA=$(gcloud compute project-info describe \
    --project="${PROJECT_ID}" \
    --format="value(quotas[name=GPUS_ALL_REGIONS].limit)" 2>/dev/null)

if [ -z "${GPU_QUOTA}" ] || [ "$(echo "${GPU_QUOTA} <= 0" | bc -l 2>/dev/null || echo 1)" = "1" ]; then
    echo ""
    echo "WARNING: GPU quota (GPUS_ALL_REGIONS) is ${GPU_QUOTA:-unknown}."
    echo "You need at least ${GPU_COUNT} GPU(s). Request a quota increase at:"
    echo "  https://console.cloud.google.com/iam-admin/quotas?project=${PROJECT_ID}&metric=compute.googleapis.com%2Fgpus_all_regions"
    echo ""
    echo "After the quota is approved, re-run this script to verify."
    exit 1
else
    echo "GPU quota (GPUS_ALL_REGIONS): ${GPU_QUOTA}"
fi

echo "Prerequisites check complete."
