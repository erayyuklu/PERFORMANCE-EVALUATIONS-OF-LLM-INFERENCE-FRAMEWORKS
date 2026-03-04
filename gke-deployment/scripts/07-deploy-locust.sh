#!/usr/bin/env bash
# =============================================================================
# 06-deploy-locust.sh — Build, push, and deploy Locust to GKE
#
# Usage:
#   ./06-deploy-locust.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

# 1. Fetch GCP Project ID if not set
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
if [[ -z "${PROJECT_ID}" ]]; then
    echo "ERROR: Could not determine GCP PROJECT_ID. Please set it via env var."
    exit 1
fi

IMAGE_TAG="europe-west3-docker.pkg.dev/${PROJECT_ID}/locust/locust-vllm:latest"

echo "==========================================================================="
echo "  Deploying Locust in-cluster test runner"
echo "  Target Image : ${IMAGE_TAG}"
echo "==========================================================================="

# 2. Build Docker image
echo "==> Building Locust Docker image..."
docker build -t "${IMAGE_TAG}" "${SCRIPT_DIR}/../../benchmarking/"

# 3. Push to Artifact Registry
echo "==> Pushing image to Artifact Registry..."
# Ensure the "locust" repository exists
if ! gcloud artifacts repositories describe locust --location=europe-west3 --project="${PROJECT_ID}" &>/dev/null; then
    echo "    Repository 'locust' not found. Creating it now..."
    gcloud artifacts repositories create locust \
        --repository-format=docker \
        --location=europe-west3 \
        --project="${PROJECT_ID}" \
        --description="Locust load testing images" || true
fi

# Ensure docker auth is set up
gcloud auth configure-docker europe-west3-docker.pkg.dev --quiet 2>/dev/null || true
docker push "${IMAGE_TAG}"

# 4. Deploy to Kubernetes
echo "==> Applying Kubernetes manifests..."

# The basic resources
kubectl apply -f "${SCRIPT_DIR}/../k8s/locust/namespace.yaml"
kubectl apply -f "${SCRIPT_DIR}/../k8s/locust/configmap.yaml"
kubectl apply -f "${SCRIPT_DIR}/../k8s/locust/service-master.yaml"

# Master and workers: dynamically replace the generic PROJECT_ID in the YAML
sed "s/PROJECT_ID/${PROJECT_ID}/g" "${SCRIPT_DIR}/../k8s/locust/deployment-master.yaml" | kubectl apply -f -
sed "s/PROJECT_ID/${PROJECT_ID}/g" "${SCRIPT_DIR}/../k8s/locust/deployment-worker.yaml" | kubectl apply -f -

# Monitoring manifests (won't hurt to re-apply if 05-monitoring.sh already did)
kubectl apply -f "${SCRIPT_DIR}/../k8s/locust/service-monitor.yaml" 2>/dev/null || echo "    ⚠ Monitoring not ready, skipping service-monitor"
kubectl apply -n monitoring -f "${SCRIPT_DIR}/../k8s/monitoring/locust-dashboard-cm.yaml" 2>/dev/null || echo "    ⚠ Monitoring not ready, skipping dashboard configmap"

echo ""
echo "==========================================================================="
echo "  ✅  Locust deployed successfully!"
echo "  Wait a moment for pods to start:"
echo "    kubectl get pods -n locust"
echo ""
echo "  View Locust UI locally:"
echo "    kubectl port-forward svc/locust-master 8089:8089 -n locust"
echo "    (http://localhost:8089)"
echo "==========================================================================="
