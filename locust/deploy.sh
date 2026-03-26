#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Build, push, and deploy Locust to GKE
#
# Usage:
#   ./deploy.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../vllm/infra_config.env"

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
docker build --platform=linux/amd64 -t "${IMAGE_TAG}" "${SCRIPT_DIR}/"

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
kubectl create namespace locust --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap locust-config \
    --namespace=locust \
    --from-env-file="${SCRIPT_DIR}/config.env" \
    --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${SCRIPT_DIR}/k8s/service-master.yaml"

# Master and workers: dynamically replace the generic PROJECT_ID in the YAML
sed "s/PROJECT_ID/${PROJECT_ID}/g" "${SCRIPT_DIR}/k8s/deployment-master.yaml" | kubectl apply -f -
sed "s/PROJECT_ID/${PROJECT_ID}/g" "${SCRIPT_DIR}/k8s/deployment-worker.yaml" | kubectl apply -f -

# Force pods to pull the newly pushed :latest image
echo "==> Rolling out new image..."
kubectl rollout restart deployment/locust-master -n locust
kubectl rollout status deployment/locust-master -n locust --timeout=360s

echo "Waiting for master to be fully ready before restarting workers..."
sleep 150

kubectl rollout restart deployment/locust-worker -n locust
kubectl rollout status deployment/locust-worker -n locust --timeout=360s

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
