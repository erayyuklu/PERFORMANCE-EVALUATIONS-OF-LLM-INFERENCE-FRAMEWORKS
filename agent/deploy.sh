#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Build, push, and deploy LangGraph Agent API to GKE
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../vllm/infra_config.env"

# Parse arguments
AGENT_MODE="single-agent"
while [[ $# -gt 0 ]]; do
  case $1 in
    --mode)
      AGENT_MODE="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--mode <single-agent|planner-executor>]"
      exit 1
      ;;
  esac
done

# 1. Fetch GCP Project ID
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
if [[ -z "${PROJECT_ID}" ]]; then
    echo "ERROR: Could not determine GCP PROJECT_ID."
    exit 1
fi

IMAGE_TAG="europe-west3-docker.pkg.dev/${PROJECT_ID}/agent/agent-langgraph:latest"
NAMESPACE="agent"

echo "==========================================================================="
echo "  Deploying LangGraph Agent API"
echo "  Target Image : ${IMAGE_TAG}"
echo "  Mode         : ${AGENT_MODE}"
echo "==========================================================================="

# 2. Build Docker image
echo "==> Building Agent Docker image..."
docker build --platform=linux/amd64 -t "${IMAGE_TAG}" "${SCRIPT_DIR}/"

# 3. Push to Artifact Registry
echo "==> Pushing image to Artifact Registry..."
if ! gcloud artifacts repositories describe agent --location=europe-west3 --project="${PROJECT_ID}" &>/dev/null; then
    echo "    Repository 'agent' not found. Creating it now..."
    gcloud artifacts repositories create agent \
        --repository-format=docker \
        --location=europe-west3 \
        --project="${PROJECT_ID}" \
        --description="LangGraph Agent API images" || true
fi

gcloud auth configure-docker europe-west3-docker.pkg.dev --quiet 2>/dev/null || true
docker push "${IMAGE_TAG}"

# 4. Deploy to Kubernetes
echo "==> Applying Kubernetes manifests..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Create ConfigMap from config.env (non-sensitive)
kubectl create configmap agent-config \
    --namespace="${NAMESPACE}" \
    --from-env-file="${SCRIPT_DIR}/config.env" \
    --dry-run=client -o yaml | kubectl apply -f -

# Create Secret from .env (sensitive)
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    echo "==> Creating agent-secrets from .env..."
    kubectl create secret generic agent-secrets \
        --namespace="${NAMESPACE}" \
        --from-env-file="${SCRIPT_DIR}/.env" \
        --dry-run=client -o yaml | kubectl apply -f -
fi

# Deploy PostgreSQL checkpointer first
echo "==> Deploying PostgreSQL checkpointer..."
kubectl apply -f "${SCRIPT_DIR}/k8s/postgres.yaml"
echo "    Waiting for PostgreSQL to be ready..."
kubectl rollout status statefulset/agent-postgres -n "${NAMESPACE}" --timeout=120s

# Deploy agent application
echo "==> Deploying Agent API..."
sed -e "s/PROJECT_ID/${PROJECT_ID}/g" -e "s/AGENT_MODE/${AGENT_MODE}/g" "${SCRIPT_DIR}/k8s/deployment.yaml" | kubectl apply -f -
kubectl apply -f "${SCRIPT_DIR}/k8s/service.yaml"
kubectl apply -f "${SCRIPT_DIR}/k8s/hpa.yaml"
kubectl apply -f "${SCRIPT_DIR}/k8s/service-monitor.yaml" || echo "    ⚠ ServiceMonitor CRD not found (monitoring stack not deployed yet?)"

# 5. Rollout
echo "==> Rolling out new image..."
kubectl rollout restart deployment/agent-server -n "${NAMESPACE}"
kubectl rollout status deployment/agent-server -n "${NAMESPACE}" --timeout=300s

echo ""
echo "==========================================================================="
echo "  ✅  LangGraph Agent API deployed successfully!"
echo "  Internal URL: http://agent-service.agent.svc.cluster.local"
echo ""
echo "  Smoke test:"
echo "    kubectl port-forward svc/agent-service 8000:80 -n ${NAMESPACE}"
echo '    curl -X POST http://localhost:8000/api/v1/agent/run \'
echo '      -H "Content-Type: application/json" \'
echo '      -d '"'"'{"task": "What is the weather in Istanbul?"}'"'"''
echo "==========================================================================="
