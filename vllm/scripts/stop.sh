#!/usr/bin/env bash
# =============================================================================
# stop.sh — Pause the cluster to stop GPU charges without losing resources
#
# What this does:
#   --pause   Scale both the system (default-pool) and GPU node pools to 0
#             (stops VM/GPU charges, keeps disks & pool config)
#   --resume  Scale both pools back (system -> 1 node; GPU -> original node count)
#
# What is preserved:
#   ✓ Cluster and node pool definitions (no reconfig needed on resume)
#   ✓ Persistent disks (no data loss)
#   ✓ Kubernetes manifests / namespace / service definitions
#
# What stops charging:
#   ✓ GPU VM instances (biggest cost driver)
#   ✓ System VM instances (default-pool)
#   ✓ Nvidia L4 GPU reservation
#
# Note: The GKE control plane (e2-medium system pool) continues to run at
#       minimal cost. Delete the cluster entirely with cleanup.sh --all
#       if you want zero cost.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../infra_config.env"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"

usage() {
    echo "Usage: $0 [--pause | --resume]"
    echo ""
    echo "  --pause   Scale system (default-pool) and GPU node pools to 0 (stop VM/GPU charges)"
    echo "  --resume  Scale system pool to 1 and GPU node pool back to ${NUM_GPU_NODES} node(s)"
    exit 1
}

check_cluster() {
    EXISTING=$(gcloud container clusters list \
        --project="${PROJECT_ID}" \
        --zone="${ZONE}" \
        --filter="name=${CLUSTER_NAME}" \
        --format="value(name)" 2>/dev/null)

    if [ -z "${EXISTING}" ]; then
        echo "ERROR: Cluster '${CLUSTER_NAME}' not found in zone '${ZONE}'."
        echo "       Run gke.sh first to create it."
        exit 1
    fi
}

pause_cluster() {
    echo "============================================================"
    echo "  Pausing: scaling system (default-pool) and GPU node pools to 0"
    echo "  Cluster  : ${CLUSTER_NAME}"
    echo "  System   : default-pool"
    echo "  GPU pool : ${GPU_NODE_POOL_NAME}"
    echo "  Zone     : ${ZONE}"
    echo "============================================================"

    check_cluster

    # Scale down system pool first (e2-medium VMs)
    echo "Scaling down system node pool (default-pool) to 0..."
    gcloud container clusters resize "${CLUSTER_NAME}" \
        --project="${PROJECT_ID}" \
        --zone="${ZONE}" \
        --node-pool="default-pool" \
        --num-nodes=0 \
        --quiet

    # Scale down the GPU node pool — VMs are deleted, GPUs freed, disks kept
    echo "Scaling down GPU node pool (${GPU_NODE_POOL_NAME}) to 0..."
    gcloud container clusters resize "${CLUSTER_NAME}" \
        --project="${PROJECT_ID}" \
        --zone="${ZONE}" \
        --node-pool="${GPU_NODE_POOL_NAME}" \
        --num-nodes=0 \
        --quiet

    echo ""
    echo "✓ Both node pools scaled to 0. VM and GPU charges have stopped."
    echo "  Persistent disks and cluster configuration are intact."
    echo ""
    echo "  To resume:  bash $(basename "$0") --resume"
    echo "  To destroy: bash cleanup.sh --all"
}

resume_cluster() {
    echo "============================================================"
    echo "  Resuming: scaling system (default-pool) and GPU node pools"
    echo "  Cluster  : ${CLUSTER_NAME}"
    echo "  System   : default-pool -> 1 node"
    echo "  GPU pool : ${GPU_NODE_POOL_NAME} -> ${NUM_GPU_NODES} node(s)"
    echo "  Zone     : ${ZONE}"
    echo "============================================================"

    check_cluster

    # Bring system pool up first so the cluster is schedulable
    echo "Scaling up system node pool (default-pool) to 1..."
    gcloud container clusters resize "${CLUSTER_NAME}" \
        --project="${PROJECT_ID}" \
        --zone="${ZONE}" \
        --node-pool="default-pool" \
        --num-nodes=1 \
        --quiet

    echo "Scaling up GPU node pool (${GPU_NODE_POOL_NAME}) to ${NUM_GPU_NODES}..."
    gcloud container clusters resize "${CLUSTER_NAME}" \
        --project="${PROJECT_ID}" \
        --zone="${ZONE}" \
        --node-pool="${GPU_NODE_POOL_NAME}" \
        --num-nodes="${NUM_GPU_NODES}" \
        --quiet

    echo ""
    echo "Fetching updated cluster credentials..."
    gcloud container clusters get-credentials "${CLUSTER_NAME}" \
        --project="${PROJECT_ID}" \
        --zone="${ZONE}" \
        --quiet

    echo ""
    echo "✓ System and GPU node pools scaled back (system=1, gpu=${NUM_GPU_NODES})."
    echo ""
    kubectl get nodes
    echo ""
    echo "  Re-deploy workloads: bash deploy.sh"
}

if [ $# -eq 0 ]; then
    usage
fi

case "$1" in
    --pause)
        pause_cluster
        ;;
    --resume)
        resume_cluster
        ;;
    *)
        usage
        ;;
esac
