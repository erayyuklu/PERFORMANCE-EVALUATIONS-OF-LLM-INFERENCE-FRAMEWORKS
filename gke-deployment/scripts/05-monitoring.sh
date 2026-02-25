#!/usr/bin/env bash
# =============================================================================
# 05-monitoring.sh — Deploy Prometheus + Grafana and wire up vLLM monitoring
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

MONITORING_NS="monitoring"
HELM_RELEASE="monitoring"
K8S_DIR="${SCRIPT_DIR}/../k8s"

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

# 3. Install / upgrade kube-prometheus-stack
echo "==> Installing kube-prometheus-stack (Prometheus + Grafana + Alertmanager)..."
helm upgrade --install "${HELM_RELEASE}" prometheus-community/kube-prometheus-stack \
    --namespace "${MONITORING_NS}" \
    --set grafana.enabled=true \
    --set grafana.adminPassword=admin \
    --set grafana.sidecar.dashboards.enabled=true \
    --set grafana.sidecar.dashboards.searchNamespace=ALL \
    --set grafana.sidecar.dashboards.label=grafana_dashboard \
    --set-string grafana.sidecar.dashboards.labelValue="1" \
    --set grafana.sidecar.dashboards.folderAnnotation=grafana_folder \
    --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --wait \
    --timeout 5m

echo "==> kube-prometheus-stack installed."

# 4. Fetch & provision official vLLM Grafana dashboards
# Download dashboard JSONs from the official vllm-project GitHub repo,
# then create a ConfigMap labelled for the Grafana sidecar to auto-import.

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

# 5. Apply PodMonitor for vLLM
echo "==> Applying PodMonitor to scrape vLLM pods..."
kubectl apply -n "${MONITORING_NS}" -f "${K8S_DIR}/monitoring/pod-monitor.yaml"
echo "    ✓ PodMonitor applied. Prometheus will scrape vLLM pods on :8000/metrics."

# 6. Summary
echo ""
echo "==========================================================================="
echo "  ✅  Monitoring stack deployed successfully!"
echo "==========================================================================="
echo ""
echo "  Grafana UI:"
echo "    kubectl port-forward svc/${HELM_RELEASE}-grafana 3000:80 -n ${MONITORING_NS}"
echo "    → Open http://localhost:3000"
echo "    → Login: admin / admin"
echo ""
echo "  Prometheus UI:"
echo "    kubectl port-forward svc/${HELM_RELEASE}-kube-prometheus-prometheus 9090:9090 -n ${MONITORING_NS}"
echo "    → Open http://localhost:9090"
echo ""
echo "  Dashboards are auto-provisioned under the 'vLLM Monitoring' folder."
echo "==========================================================================="
