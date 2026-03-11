#!/usr/bin/env bash
# =============================================================================
# 05-monitoring.sh — Deploy Prometheus + Grafana and wire up vLLM monitoring
#
# Usage:
#   ./05-monitoring.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../vllm/infra_config.env"

MONITORING_NS="monitoring"
HELM_RELEASE="monitoring"
K8S_DIR="${SCRIPT_DIR}/k8s"

# Official vLLM dashboard JSON URLs (from vllm-project/vllm on GitHub)
VLLM_GITHUB_RAW="https://raw.githubusercontent.com/vllm-project/vllm/main/examples/online_serving"
DASHBOARD_URLS=(
    "${VLLM_GITHUB_RAW}/dashboards/grafana/performance_statistics.json"
    "${VLLM_GITHUB_RAW}/dashboards/grafana/query_statistics.json"
    "${VLLM_GITHUB_RAW}/prometheus_grafana/grafana.json"
)

# 1. Helm repo
echo "==> Adding prometheus-community Helm repo..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update

# 2. Namespace
echo "==> Creating namespace '${MONITORING_NS}'..."
kubectl create namespace "${MONITORING_NS}" --dry-run=client -o yaml | kubectl apply -f -

# 3. Install / upgrade kube-prometheus-stack (Grafana + Prometheus both as LoadBalancer)
echo "==> Installing kube-prometheus-stack (Prometheus + Grafana + Alertmanager)..."
helm upgrade --install "${HELM_RELEASE}" prometheus-community/kube-prometheus-stack \
    --namespace "${MONITORING_NS}" \
    --set grafana.enabled=true \
    --set grafana.adminPassword=admin \
    --set grafana.service.type="LoadBalancer" \
    --set grafana.sidecar.dashboards.enabled=true \
    --set grafana.sidecar.dashboards.searchNamespace=ALL \
    --set grafana.sidecar.dashboards.label=grafana_dashboard \
    --set-string grafana.sidecar.dashboards.labelValue="1" \
    --set grafana.sidecar.dashboards.folderAnnotation=grafana_folder \
    --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --set prometheus.service.type="LoadBalancer" \
    --set grafana.imageRenderer.enabled=true \
    --set grafana.imageRenderer.replicas=1 \
    --set grafana."grafana\.ini"."auth.anonymous".enabled=true \
    --set grafana."grafana\.ini"."auth.anonymous".org_role=Viewer \
    --set grafana."grafana\.ini".rendering.server_url=http://${HELM_RELEASE}-grafana-image-renderer.${MONITORING_NS}:8081/render \
    --set grafana."grafana\.ini".rendering.callback_url=http://${HELM_RELEASE}-grafana.${MONITORING_NS}:80/ \
    --wait \
    --timeout 5m

echo "==> kube-prometheus-stack installed."

# 4. Fetch & provision official vLLM Grafana dashboards
echo "==> Downloading official vLLM Grafana dashboards from GitHub..."
TMPDIR_DASHBOARDS=$(mktemp -d)
trap "rm -rf ${TMPDIR_DASHBOARDS}" EXIT

for url in "${DASHBOARD_URLS[@]}"; do
    filename=$(basename "${url}")
    echo "    ↓ ${filename}"
    if ! curl -fsSL -o "${TMPDIR_DASHBOARDS}/${filename}" "${url}"; then
        echo "    ⚠  Failed to download: ${url}"
    fi
done

# Create a single ConfigMap from all downloaded dashboards
DASHBOARD_FILES=$(find "${TMPDIR_DASHBOARDS}" -name '*.json' -type f)
if [ -n "${DASHBOARD_FILES}" ]; then
    FROM_FILE_ARGS=""
    for f in ${DASHBOARD_FILES}; do
        FROM_FILE_ARGS="${FROM_FILE_ARGS} --from-file=$(basename ${f})=${f}"
    done

    eval kubectl create configmap vllm-dashboards \
        --namespace="${MONITORING_NS}" \
        ${FROM_FILE_ARGS} \
        --dry-run=client -o yaml | \
    kubectl label --local -f - grafana_dashboard=1 -o yaml | \
    kubectl annotate --local -f - grafana_folder="vLLM Monitoring" -o yaml | \
    kubectl apply -f -
    echo "    ✓ vLLM dashboards provisioned into Grafana."
else
    echo "    ⚠  No dashboard files were downloaded. Skipping."
fi

# 5. Apply ServiceMonitors
echo "==> Applying ServiceMonitor to scrape vLLM via vllm-service..."
kubectl apply -n "${MONITORING_NS}" -f "${K8S_DIR}/service-monitor.yaml"
echo "    ✓ ServiceMonitor applied. Prometheus will scrape vLLM via vllm-service:http/metrics."

echo "==> Applying PodMonitor for GKE-managed DCGM exporter (GPU metrics)..."
kubectl apply -f "${K8S_DIR}/dcgm-pod-monitor.yaml"
echo "    ✓ DCGM PodMonitor applied. Prometheus will scrape DCGM_FI_DEV_* metrics."

echo "==> Applying ServiceMonitor and Grafana Dashboard for Locust..."
kubectl apply -f "${SCRIPT_DIR}/../locust/k8s/service-monitor.yaml" || echo "    ⚠ Could not apply locust ServiceMonitor (is locust namespace created?)"
kubectl create configmap locust-dashboard \
    --namespace="${MONITORING_NS}" \
    --from-file=dashboard.json="${SCRIPT_DIR}/dashboard.json" \
    --dry-run=client -o yaml | \
kubectl label --local -f - grafana_dashboard=1 -o yaml | \
kubectl annotate --local -f - grafana_folder="Load Testing" -o yaml | \
kubectl apply -f -
echo "    ✓ Locust dashboard and ServiceMonitor applied."

# 6. Resolve and print external IPs (poll up to 5 min)
echo ""
echo "==========================================================================="
echo "  ✅  Monitoring stack deployed successfully!"
echo "==========================================================================="
echo ""
echo "  Waiting for external IPs (this may take 1-3 minutes)..."

GRAFANA_IP=""
PROMETHEUS_IP=""

for i in $(seq 1 30); do
    [ -z "${GRAFANA_IP}" ] && \
        GRAFANA_IP=$(kubectl get svc "${HELM_RELEASE}-grafana" -n "${MONITORING_NS}" \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [ -z "${PROMETHEUS_IP}" ] && \
        PROMETHEUS_IP=$(kubectl get svc "${HELM_RELEASE}-kube-prometheus-prometheus" -n "${MONITORING_NS}" \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [ -n "${GRAFANA_IP}" ] && [ -n "${PROMETHEUS_IP}" ] && break
    echo "  Still waiting... (${i}/30)"
    sleep 10
done

echo ""
echo "  Grafana:"
if [ -n "${GRAFANA_IP}" ]; then
    echo "    → http://${GRAFANA_IP}  (admin / admin)"
else
    echo "    ⚠  IP not yet assigned. Check: kubectl get svc ${HELM_RELEASE}-grafana -n ${MONITORING_NS}"
fi

echo ""
echo "  Prometheus:"
if [ -n "${PROMETHEUS_IP}" ]; then
    echo "    → http://${PROMETHEUS_IP}:9090"
else
    echo "    ⚠  IP not yet assigned. Check: kubectl get svc ${HELM_RELEASE}-kube-prometheus-prometheus -n ${MONITORING_NS}"
fi

echo ""
echo "  vLLM metrics source  : vllm-service (port 80 → :8000/metrics)"
echo "  Dashboards folder    : vLLM Monitoring (auto-provisioned)"
echo "==========================================================================="
