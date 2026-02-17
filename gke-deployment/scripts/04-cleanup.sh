#!/usr/bin/env bash
# =============================================================================
# 04-cleanup.sh — Clean up GKE resources
# Usage: 04-cleanup.sh [--deployment | --cluster | --all]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"

usage() {
    echo "Usage: $0 [--deployment | --cluster | --all]"
    echo ""
    echo "  --deployment  Delete K8s deployment, service, and namespace"
    echo "  --cluster     Delete the GKE cluster (includes everything in it)"
    echo "  --all         Delete deployment resources and the cluster"
    exit 1
}

delete_deployment() {
    echo "Deleting namespace ${K8S_NAMESPACE} and all resources in it..."
    kubectl delete namespace "${K8S_NAMESPACE}" --ignore-not-found=true
    echo "Deployment resources deleted."
}

delete_cluster() {
    echo "Deleting cluster ${CLUSTER_NAME}..."
    gcloud container clusters delete "${CLUSTER_NAME}" \
        --project="${PROJECT_ID}" \
        --zone="${ZONE}" \
        --quiet
    echo "Cluster deleted."
}

if [ $# -eq 0 ]; then
    usage
fi

case "$1" in
    --deployment)
        delete_deployment
        ;;
    --cluster)
        delete_cluster
        ;;
    --all)
        delete_deployment
        delete_cluster
        ;;
    *)
        usage
        ;;
esac

echo "Cleanup complete."
