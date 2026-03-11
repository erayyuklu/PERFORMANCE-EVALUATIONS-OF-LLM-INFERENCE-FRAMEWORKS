#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Deploy vLLM to the GKE cluster
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../infra_config.env"

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
VLLM_CONFIG_ENV="${SCRIPT_DIR}/../vllm_config.env"
kubectl create configmap vllm-args-config \
    --namespace="${K8S_NAMESPACE}" \
    --from-env-file="${VLLM_CONFIG_ENV}" \
    --dry-run=client -o yaml | kubectl apply -f -
echo "vLLM config ConfigMap created."

# --- Apply K8s manifests ---
echo "Applying Kubernetes manifests..."
kubectl apply -n "${K8S_NAMESPACE}" -f "${K8S_DIR}/"

# --- Restart Deployment to pick up ConfigMap changes ---
DEPLOYMENT_NAME=$(kubectl get deployments -n "${K8S_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "${DEPLOYMENT_NAME}" ]; then
    echo "Restarting deployment ${DEPLOYMENT_NAME} to pick up potential config changes..."
    kubectl rollout restart deployment/"${DEPLOYMENT_NAME}" -n "${K8S_NAMESPACE}"
fi

# --- Wait for rollout ---
# If this is the first deployment, DEPLOYMENT_NAME might be empty initially until kubectl apply finishes properly, so let's get it again if needed.
if [ -z "${DEPLOYMENT_NAME}" ]; then
    DEPLOYMENT_NAME=$(kubectl get deployments -n "${K8S_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
fi

echo "Waiting for deployment ${DEPLOYMENT_NAME} rollout (this may take several minutes while the model downloads)..."
kubectl rollout status deployment/"${DEPLOYMENT_NAME}" \
    --namespace="${K8S_NAMESPACE}" \
    --timeout=1200s

echo "Deployment complete."
kubectl get pods -n "${K8S_NAMESPACE}"

# --- Wait for external IP ---
echo ""
echo "Waiting for LoadBalancer external IP (this may take 1-3 minutes)..."
EXTERNAL_IP=""
for i in $(seq 1 30); do
    EXTERNAL_IP=$(kubectl get svc vllm-service -n "${K8S_NAMESPACE}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [ -n "${EXTERNAL_IP}" ]; then
        break
    fi
    echo "  Still waiting... (${i}/30)"
    sleep 10
done

if [ -n "${EXTERNAL_IP}" ]; then
    echo ""
    echo "=============================================="
    echo "  vLLM external IP : ${EXTERNAL_IP}"
    echo "  API base URL      : http://${EXTERNAL_IP}/v1"
    echo "  Models endpoint   : http://${EXTERNAL_IP}/v1/models"
    echo "=============================================="
else
    echo "WARNING: External IP not yet assigned. Check later with:"
    echo "  kubectl get svc vllm-service -n ${K8S_NAMESPACE}"
fi
