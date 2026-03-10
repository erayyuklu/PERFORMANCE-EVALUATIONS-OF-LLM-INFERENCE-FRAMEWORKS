#!/usr/bin/env bash
# =============================================================================
# get-ips.sh — Fetch external IPs for vLLM, Grafana, and Prometheus
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

MONITORING_NS="monitoring"
HELM_RELEASE="monitoring"

echo "============================================="
echo "  Fetching external IPs..."
echo "============================================="

# --- vLLM IP ---
VLLM_SVC=$(kubectl get svc -n "${K8S_NAMESPACE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -n "${VLLM_SVC}" ]; then
    VLLM_IP=$(kubectl get svc "${VLLM_SVC}" -n "${K8S_NAMESPACE}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    VLLM_PORT=$(kubectl get svc "${VLLM_SVC}" -n "${K8S_NAMESPACE}" \
        -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)
else
    VLLM_IP=""
    VLLM_PORT=""
fi

# --- Grafana IP ---
GRAFANA_IP=$(kubectl get svc "${HELM_RELEASE}-grafana" -n "${MONITORING_NS}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

# --- Prometheus IP ---
PROMETHEUS_IP=$(kubectl get svc "${HELM_RELEASE}-kube-prometheus-prometheus" -n "${MONITORING_NS}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

# --- Print results ---
echo ""
echo "  vLLM:"
if [ -n "${VLLM_IP}" ]; then
    echo "    URL  : http://${VLLM_IP}:${VLLM_PORT}"
else
    echo "    ⚠  No external IP assigned. Service may be ClusterIP or still pending."
    echo "    Check: kubectl get svc -n ${K8S_NAMESPACE}"
fi

echo ""
echo "  Grafana:"
if [ -n "${GRAFANA_IP}" ]; then
    echo "    URL  : http://${GRAFANA_IP}  (admin / admin)"
else
    echo "    ⚠  No external IP assigned. Grafana may be ClusterIP or still pending."
    echo "    Check: kubectl get svc ${HELM_RELEASE}-grafana -n ${MONITORING_NS}"
fi

echo ""
echo "  Prometheus:"
if [ -n "${PROMETHEUS_IP}" ]; then
    echo "    URL  : http://${PROMETHEUS_IP}:9090"
else
    echo "    ⚠  No external IP assigned. Prometheus may be ClusterIP or still pending."
    echo "    Check: kubectl get svc ${HELM_RELEASE}-kube-prometheus-prometheus -n ${MONITORING_NS}"
fi

echo ""
echo "============================================="
