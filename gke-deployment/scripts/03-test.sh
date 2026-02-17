#!/usr/bin/env bash
# =============================================================================
# 03-test.sh — Test the vLLM deployment via port-forward
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

LOCAL_PORT="${1:-${SERVICE_PORT}}"

# --- Start port-forward in background ---
echo "Starting port-forward to ${SERVICE_NAME}:${SERVICE_PORT} on localhost:${LOCAL_PORT}..."
kubectl port-forward "svc/${SERVICE_NAME}" "${LOCAL_PORT}:${SERVICE_PORT}" \
    -n "${K8S_NAMESPACE}" &
PF_PID=$!

# Give port-forward time to establish
sleep 3

cleanup() {
    kill "${PF_PID}" 2>/dev/null || true
    wait "${PF_PID}" 2>/dev/null || true
}
trap cleanup EXIT

BASE_URL="http://localhost:${LOCAL_PORT}"

# --- Test: List models ---
echo ""
echo "=== GET /v1/models ==="
curl -s "${BASE_URL}/v1/models" | head -c 2000
echo ""

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
