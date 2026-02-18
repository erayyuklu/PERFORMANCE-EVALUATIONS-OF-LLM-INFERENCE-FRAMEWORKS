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

K8S_DIR="${SCRIPT_DIR}/../k8s"

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

# --- Create vLLM config ConfigMap ---
kubectl create configmap vllm-args-config \
    --namespace="${K8S_NAMESPACE}" \
    --from-file=vllm-config="${K8S_DIR}/config.json" \
    --dry-run=client -o yaml | kubectl apply -f -
echo "vLLM config ConfigMap created."

# --- Apply K8s manifests ---
echo "Applying Kubernetes manifests..."
kubectl apply -n "${K8S_NAMESPACE}" -f "${K8S_DIR}/"

# --- Wait for rollout ---
DEPLOYMENT_NAME=$(kubectl get deployments -n "${K8S_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
echo "Waiting for deployment ${DEPLOYMENT_NAME} rollout (this may take several minutes while the model downloads)..."
kubectl rollout status deployment/"${DEPLOYMENT_NAME}" \
    --namespace="${K8S_NAMESPACE}" \
    --timeout=600s

echo "Deployment complete."
kubectl get pods -n "${K8S_NAMESPACE}"
