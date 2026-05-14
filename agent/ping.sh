#!/usr/bin/env bash
# =============================================================================
# ping.sh — Test the LangGraph Agent API deployment
#   Usage:
#     ./ping.sh              # test via LoadBalancer external IP
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAMESPACE="agent"
SERVICE_NAME="agent-service"

# --- Resolve external IP ---
EXTERNAL_IP=$(kubectl get svc "${SERVICE_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

if [ -z "${EXTERNAL_IP}" ]; then
    echo "ERROR: No external IP assigned yet. Ensure the LoadBalancer has an external IP."
    echo "  kubectl get svc ${SERVICE_NAME} -n ${NAMESPACE}"
    exit 1
fi

SERVICE_PORT=$(kubectl get svc "${SERVICE_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)

BASE_URL="http://${EXTERNAL_IP}:${SERVICE_PORT}"
echo "Testing against external IP: ${EXTERNAL_IP} (port ${SERVICE_PORT})"

# Helper: current time in milliseconds (portable)
now_ms() {
    if date +%s%3N >/dev/null 2>&1; then
        date +%s%3N
    else
        printf '%s\n' $(($(date +%s%N)/1000000))
    fi
}

# --- Test: Health check ---
echo ""
echo "=== GET /health ==="
HEALTH_RESPONSE=$(curl -s --max-time 10 "${BASE_URL}/health")
echo "${HEALTH_RESPONSE}"
echo ""

# --- Test: Agent run ---
echo "=== POST /api/v1/agent/run ==="
start_ts=$(now_ms)
AGENT_RESPONSE=$(curl -s --max-time 300 "${BASE_URL}/api/v1/agent/run" \
    -H "Content-Type: application/json" \
    -d '{"task": "Use web_search, visit_webpage, python_execute, read_document tools. I need to check if you can use the tools. Make sure to use all the tools at least once."}')
end_ts=$(now_ms)

echo "${AGENT_RESPONSE}" | head -c 2000
elapsed_ms=$((end_ts - start_ts))
echo ""
echo ""
echo "E2E latency (agent run): ${elapsed_ms} ms"

echo ""
echo "Tests complete."