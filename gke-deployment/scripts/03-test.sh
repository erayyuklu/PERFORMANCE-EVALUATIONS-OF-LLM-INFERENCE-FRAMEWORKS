#!/usr/bin/env bash
# =============================================================================
# 03-test.sh — Test the vLLM deployment
#   Usage:
#     ./03-test.sh              # test via port-forward (default)
#     ./03-test.sh --external   # test via LoadBalancer external IP
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

SERVICE_NAME=$(kubectl get svc -n "${K8S_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

USE_EXTERNAL="${1:-}"

if [ "${USE_EXTERNAL}" = "--external" ]; then
    # --- Use LoadBalancer external IP ---
    EXTERNAL_IP=$(kubectl get svc "${SERVICE_NAME}" -n "${K8S_NAMESPACE}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [ -z "${EXTERNAL_IP}" ]; then
        echo "ERROR: No external IP assigned yet. Run without --external or wait for the LoadBalancer to be ready."
        echo "  kubectl get svc ${SERVICE_NAME} -n ${K8S_NAMESPACE}"
        exit 1
    fi
    SERVICE_PORT=$(kubectl get svc "${SERVICE_NAME}" -n "${K8S_NAMESPACE}" \
        -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
    BASE_URL="http://${EXTERNAL_IP}:${SERVICE_PORT}"
    echo "Testing against external IP: ${EXTERNAL_IP} (port ${SERVICE_PORT})"
else
    # --- Use port-forward ---
    SERVICE_PORT=$(kubectl get svc "${K8S_NAMESPACE}" "${SERVICE_NAME}" \
        -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || \
        kubectl get svc -n "${K8S_NAMESPACE}" "${SERVICE_NAME}" \
        -o jsonpath='{.spec.ports[0].targetPort}' 2>/dev/null)
    LOCAL_PORT="${SERVICE_PORT}"
    echo "Starting port-forward to ${SERVICE_NAME}:${SERVICE_PORT} on localhost:${LOCAL_PORT}..."
    kubectl port-forward "svc/${SERVICE_NAME}" "${LOCAL_PORT}:${SERVICE_PORT}" \
        -n "${K8S_NAMESPACE}" &
    PF_PID=$!

    cleanup() {
        kill "${PF_PID}" 2>/dev/null || true
        wait "${PF_PID}" 2>/dev/null || true
    }
    trap cleanup EXIT
    sleep 3
    BASE_URL="http://localhost:${LOCAL_PORT}"
fi

# --- Test: List models ---
echo ""
echo "=== GET /v1/models ==="
MODELS_RESPONSE=$(curl -s "${BASE_URL}/v1/models")
echo "${MODELS_RESPONSE}" | head -c 2000
echo ""

# --- Extract the actual model name from the live endpoint ---
MODEL_NAME=$(echo "${MODELS_RESPONSE}" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
if [ -z "${MODEL_NAME}" ]; then
    echo "ERROR: Could not extract model name from /v1/models response."
    exit 1
fi
echo "Detected model: ${MODEL_NAME}"

# --- Test: Completions ---
echo ""
echo "=== POST /v1/completions ==="
curl -s "${BASE_URL}/v1/completions" \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"${MODEL_NAME}\",
        \"prompt\": \"What is 2+2?\",
        \"max_tokens\": 64,
        \"temperature\": 0.7
    }" | head -c 2000
echo ""

echo ""
echo "Tests complete."

