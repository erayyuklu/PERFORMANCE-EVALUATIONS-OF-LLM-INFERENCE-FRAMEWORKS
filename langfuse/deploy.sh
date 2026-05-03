#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Deploy Langfuse v4 (self-hosted) to GKE
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="langfuse"

echo "==========================================================================="
echo "  Deploying Langfuse v4 (self-hosted) on GKE"
echo "==========================================================================="

# 1. Create namespace
echo "==> Creating namespace '${NAMESPACE}'..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# 2. Deploy PostgreSQL
echo "==> Deploying Langfuse PostgreSQL..."
kubectl apply -f "${SCRIPT_DIR}/k8s/postgres.yaml"
echo "    Waiting for PostgreSQL to be ready..."
kubectl rollout status statefulset/langfuse-postgres -n "${NAMESPACE}" --timeout=120s
echo "    ✓ Langfuse PostgreSQL is ready."

# 3. Deploy ClickHouse
echo "==> Deploying ClickHouse..."
kubectl apply -f "${SCRIPT_DIR}/k8s/clickhouse.yaml"
echo "    Waiting for ClickHouse to be ready..."
kubectl rollout status statefulset/langfuse-clickhouse -n "${NAMESPACE}" --timeout=180s
echo "    ✓ ClickHouse is ready."

# 4. Deploy Redis
echo "==> Deploying Redis..."
kubectl apply -f "${SCRIPT_DIR}/k8s/redis.yaml"
echo "    Waiting for Redis to be ready..."
kubectl rollout status deployment/langfuse-redis -n "${NAMESPACE}" --timeout=120s
echo "    ✓ Redis is ready."

# 5. Deploy MinIO (S3-compatible blob storage)
echo "==> Deploying MinIO..."
kubectl apply -f "${SCRIPT_DIR}/k8s/minio.yaml"
echo "    Waiting for MinIO to be ready..."
kubectl rollout status statefulset/langfuse-minio -n "${NAMESPACE}" --timeout=120s
echo "    ✓ MinIO is ready."

# 6. Deploy Langfuse Web server (runs DB migrations on startup)
echo "==> Deploying Langfuse Web server..."
kubectl apply -f "${SCRIPT_DIR}/k8s/langfuse.yaml"
kubectl rollout status deployment/langfuse-server -n "${NAMESPACE}" --timeout=300s
echo "    ✓ Langfuse Web server is ready."

# 7. Deploy Langfuse Worker (depends on DB schema created by web)
echo "==> Deploying Langfuse Worker..."
kubectl apply -f "${SCRIPT_DIR}/k8s/langfuse-worker.yaml"
kubectl rollout status deployment/langfuse-worker -n "${NAMESPACE}" --timeout=300s
echo "    ✓ Langfuse Worker is ready."

# 8. Apply ServiceMonitor (optional — requires monitoring stack)
echo "==> Applying Langfuse ServiceMonitor..."
kubectl apply -f "${SCRIPT_DIR}/k8s/service-monitor.yaml" || echo "    ⚠ ServiceMonitor CRD not found (monitoring stack not deployed yet?)"

# 9. Get external IP
echo ""
echo "==========================================================================="
echo "  ✅  Langfuse v4 deployed successfully!"
echo "==========================================================================="
echo ""
echo "  Waiting for external IP (this may take 1-3 minutes)..."

LANGFUSE_IP=""
for i in $(seq 1 30); do
    LANGFUSE_IP=$(kubectl get svc langfuse-service -n "${NAMESPACE}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [ -n "${LANGFUSE_IP}" ]; then
        break
    fi
    echo "  Still waiting... (${i}/30)"
    sleep 10
done

if [ -n "${LANGFUSE_IP}" ]; then
    echo ""
    echo "  Langfuse UI: http://${LANGFUSE_IP}:3000"
    echo ""
    echo "  To connect your agent, update agent/config.env:"
    echo "    LANGFUSE_HOST=http://${LANGFUSE_IP}:3000"
    echo "    LANGFUSE_PUBLIC_KEY=<your-public-key>"
    echo "    LANGFUSE_SECRET_KEY=<your-secret-key>"
    echo ""
    echo "  First-time setup:"
    echo "    1. Open http://${LANGFUSE_IP}:3000 in your browser"
    echo "    2. Create an account"
    echo "    3. Create a project and copy the API keys"
    echo "    4. Update agent/config.env with the keys"
    echo "    5. Re-run agent/deploy.sh to pick up the new config"
else
    echo "  ⚠  External IP not yet assigned. Check:"
    echo "    kubectl get svc langfuse-service -n ${NAMESPACE}"
fi
echo "==========================================================================="
