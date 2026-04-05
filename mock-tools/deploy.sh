#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Build, push, and deploy Mock Tool Server to GKE
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../vllm/infra_config.env"

# 1. Fetch GCP Project ID
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
if [[ -z "${PROJECT_ID}" ]]; then
    echo "ERROR: Could not determine GCP PROJECT_ID."
    exit 1
fi

IMAGE_TAG="europe-west3-docker.pkg.dev/${PROJECT_ID}/mock-tools/mock-tools-server:latest"

echo "==========================================================================="
echo "  Deploying Mock Tool Server"
echo "  Target Image : ${IMAGE_TAG}"
echo "==========================================================================="

# 2. Build Docker image
echo "==> Building Mock Tool Server Docker image..."
docker build --platform=linux/amd64 -t "${IMAGE_TAG}" "${SCRIPT_DIR}/"

# 3. Push to Artifact Registry
echo "==> Pushing image to Artifact Registry..."
if ! gcloud artifacts repositories describe mock-tools --location=europe-west3 --project="${PROJECT_ID}" &>/dev/null; then
    echo "    Repository 'mock-tools' not found. Creating it now..."
    gcloud artifacts repositories create mock-tools \
        --repository-format=docker \
        --location=europe-west3 \
        --project="${PROJECT_ID}" \
        --description="Mock tool server images for agent load testing" || true
fi

gcloud auth configure-docker europe-west3-docker.pkg.dev --quiet 2>/dev/null || true
docker push "${IMAGE_TAG}"

# 4. Deploy to Kubernetes
echo "==> Applying Kubernetes manifests..."
kubectl create namespace mock-tools --dry-run=client -o yaml | kubectl apply -f -

sed "s/PROJECT_ID/${PROJECT_ID}/g" "${SCRIPT_DIR}/k8s/deployment.yaml" | kubectl apply -f -
kubectl apply -f "${SCRIPT_DIR}/k8s/service.yaml"

# 5. Wait for rollout
echo "==> Waiting for deployment rollout..."
kubectl rollout restart deployment/mock-tools-server -n mock-tools
kubectl rollout status deployment/mock-tools-server -n mock-tools --timeout=120s

echo ""
echo "==========================================================================="
echo "  ✅  Mock Tool Server deployed successfully!"
echo "  Internal URL: http://mock-tools-service.mock-tools.svc.cluster.local"
echo "==========================================================================="
