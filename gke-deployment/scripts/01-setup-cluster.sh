#!/usr/bin/env bash
# =============================================================================
# 01-setup-cluster.sh — Create GKE cluster with GPU node pool
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"

# --- Create cluster (skip if exists) ---
EXISTING=$(gcloud container clusters list \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --filter="name=${CLUSTER_NAME}" \
    --format="value(name)" 2>/dev/null)

if [ -n "${EXISTING}" ]; then
    echo "Cluster ${CLUSTER_NAME} already exists, skipping creation."
else
    echo "Creating cluster ${CLUSTER_NAME}..."
    gcloud container clusters create "${CLUSTER_NAME}" \
        --project="${PROJECT_ID}" \
        --zone="${ZONE}" \
        --cluster-version="${CLUSTER_VERSION}" \
        --num-nodes=1 \
        --machine-type="e2-medium" \
        --disk-size="${DISK_SIZE_GB}" \
        --quiet
    echo "Cluster created."
fi

# --- Create GPU node pool (skip if exists) ---
EXISTING_POOL=$(gcloud container node-pools list \
    --cluster="${CLUSTER_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --filter="name=${NODE_POOL_NAME}" \
    --format="value(name)" 2>/dev/null)

if [ -n "${EXISTING_POOL}" ]; then
    echo "Node pool ${NODE_POOL_NAME} already exists, skipping creation."
else
    echo "Creating GPU node pool ${NODE_POOL_NAME}..."
    gcloud container node-pools create "${NODE_POOL_NAME}" \
        --cluster="${CLUSTER_NAME}" \
        --project="${PROJECT_ID}" \
        --zone="${ZONE}" \
        --machine-type="${MACHINE_TYPE}" \
        --accelerator="type=${GPU_TYPE},count=${GPU_COUNT}" \
        --num-nodes="${NUM_GPU_NODES}" \
        --disk-size="${DISK_SIZE_GB}" \
        --quiet
    echo "GPU node pool created."
fi

# --- Install NVIDIA GPU drivers ---
echo "Installing NVIDIA GPU device plugin..."
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/master/nvidia-driver-installer/cos/daemonset-preloaded-latest.yaml 2>/dev/null || true

# --- Get credentials ---
echo "Fetching cluster credentials..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --quiet

echo "Cluster setup complete."
kubectl get nodes
