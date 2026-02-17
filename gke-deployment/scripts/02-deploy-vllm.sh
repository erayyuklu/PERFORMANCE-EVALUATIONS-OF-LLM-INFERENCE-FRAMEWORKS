#!/usr/bin/env bash
# =============================================================================
# 02-deploy-vllm.sh — Deploy vLLM to the GKE cluster
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

# Source secrets if available
SECRETS_FILE="${SCRIPT_DIR}/../secrets.env"
if [ -f "${SECRETS_FILE}" ]; then
    source "${SECRETS_FILE}"
fi

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
TEMPLATE_DIR="${SCRIPT_DIR}/../k8s"

# --- Validate HF_TOKEN ---
if [ -z "${HF_TOKEN:-}" ]; then
    echo "ERROR: HF_TOKEN is not set."
    echo "Set it in secrets.env or export it: export HF_TOKEN=<your-token>"
    exit 1
fi

# --- Create namespace ---
kubectl create namespace "${K8S_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
echo "Namespace ${K8S_NAMESPACE} ready."

# --- Create HF token secret ---
kubectl create secret generic hf-token-secret \
    --namespace="${K8S_NAMESPACE}" \
    --from-literal=HF_TOKEN="${HF_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
echo "HF token secret created."

# --- Render and apply templates ---
export MODEL_NAME VLLM_IMAGE DEPLOYMENT_NAME SERVICE_NAME SERVICE_PORT
export MAX_MODEL_LEN GPU_MEMORY_UTILIZATION DTYPE TENSOR_PARALLEL_SIZE
export GPU_COUNT REPLICAS CPU_REQUEST CPU_LIMIT MEMORY_REQUEST MEMORY_LIMIT
export K8S_NAMESPACE

echo "Applying Kubernetes manifests..."
for template in "${TEMPLATE_DIR}"/*.yaml.template; do
    envsubst < "${template}" | kubectl apply -n "${K8S_NAMESPACE}" -f -
done

# --- Wait for rollout ---
echo "Waiting for deployment rollout (this may take several minutes while the model downloads)..."
kubectl rollout status deployment/"${DEPLOYMENT_NAME}" \
    --namespace="${K8S_NAMESPACE}" \
    --timeout=600s

echo "Deployment complete."
kubectl get pods -n "${K8S_NAMESPACE}"
