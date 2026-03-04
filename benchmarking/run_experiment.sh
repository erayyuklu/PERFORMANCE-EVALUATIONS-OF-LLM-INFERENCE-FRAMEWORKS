#!/usr/bin/env bash
# =============================================================================
# run_experiment.sh — Repeatable vLLM benchmark experiment runner
#
# Usage:
#   ./run_experiment.sh [--experiment-file experiments.json] [--host http://...]
#                       [--experiment <name>] [--external] [--in-cluster]
#
# What this script does for each experiment configuration:
#   1. Patch the vLLM Kubernetes deployment with the new parameters
#   2. Wait for the deployment to become ready
#   3. Port-forward the vLLM service to localhost (or use external/in-cluster mechanism)
#   4. Run Locust for each concurrency level (users)
#      (If --in-cluster: triggers test via Locust master REST API instead of local process)
#   5. Save all results under results/<run_id>/
#   6. Tear down port-forward
#
# Requires: kubectl, locust (pip install locust), jq
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../gke-deployment/config.env"

# ---------------------------------------------------------------------------
# Defaults (override via CLI flags)
# ---------------------------------------------------------------------------
EXPERIMENT_FILE="${SCRIPT_DIR}/experiments.json"
EXPERIMENT_NAME=""                              # if set, run only this experiment
VLLM_HOST="http://localhost:8000"
RESULTS_BASE="${SCRIPT_DIR}/results"
NAMESPACE="${K8S_NAMESPACE:-vllm}"
DEPLOYMENT_NAME="vllm"
LOCUST_RUN_TIME="${LOCUST_RUN_TIME:-120s}"     # how long each Locust run lasts
WARMUP_REQUESTS=5                               # requests to warm up before recording
PORT_FORWARD_PID=""
USE_EXTERNAL_IP=false                           # set to true via --external flag
USE_IN_CLUSTER=false                            # set to true via --in-cluster flag
LOCUST_MASTER_URL="http://localhost:8089"       # URL for Locust master (used with --in-cluster)

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --experiment-file) EXPERIMENT_FILE="$2";   shift 2 ;;
    --experiment)      EXPERIMENT_NAME="$2";   shift 2 ;;
    --host)            VLLM_HOST="$2";         shift 2 ;;
    --run-time)        LOCUST_RUN_TIME="$2";   shift 2 ;;
    --external)        USE_EXTERNAL_IP=true;   shift   ;;
    --in-cluster)      USE_IN_CLUSTER=true;    shift   ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "==> $*"; }
info() { echo "    $*"; }

cleanup() {
  if [[ -n "${PORT_FORWARD_PID}" ]]; then
    kill "${PORT_FORWARD_PID}" 2>/dev/null || true
    log "Port-forward stopped."
  fi
}
trap cleanup EXIT

fetch_external_ip() {
  log "Fetching external IP of vllm-service..."
  local ip
  for attempt in $(seq 1 20); do
    ip=$(kubectl get svc vllm-service -n "${NAMESPACE}" \
          -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [[ -n "${ip}" ]]; then
      VLLM_HOST="http://${ip}:8000"
      log "External IP resolved: ${VLLM_HOST}"
      return 0
    fi
    info "Waiting for external IP (attempt ${attempt}/20)..."
    sleep 5
  done
  echo "ERROR: Could not resolve external IP for vllm-service after 100 s" >&2
  exit 1
}

start_port_forward() {
  if [[ "${USE_IN_CLUSTER}" == "true" ]]; then
    log "Starting port-forward to Locust master (locust-master:8089)..."
    kubectl port-forward svc/locust-master 8089:8089 -n locust &>/dev/null &
    PORT_FORWARD_PID=$!
    sleep 4
    info "Locust Port-forward PID: ${PORT_FORWARD_PID}"
  else
    log "Starting port-forward localhost:8000 → vllm service..."
    kubectl port-forward svc/vllm-service 8000:8000 -n "${NAMESPACE}" &>/dev/null &
    PORT_FORWARD_PID=$!
    sleep 4   # give kubectl time to establish the tunnel
    info "vLLM Port-forward PID: ${PORT_FORWARD_PID}"
  fi
}

stop_port_forward() {
  if [[ -n "${PORT_FORWARD_PID}" ]]; then
    kill "${PORT_FORWARD_PID}" 2>/dev/null || true
    PORT_FORWARD_PID=""
  fi
}

wait_for_deployment() {
  log "Waiting for deployment '${DEPLOYMENT_NAME}' to be ready..."
  kubectl rollout status deployment/"${DEPLOYMENT_NAME}" \
    -n "${NAMESPACE}" \
    --timeout=300s
  log "Deployment is ready."
}

patch_vllm_args() {
  local extra_args="$1"
  log "Patching vLLM deployment with args: ${extra_args}"
  # We store vLLM args in the k8s ConfigMap config.json's 'args' key.
  # Here we patch the deployment's container args directly for simplicity.
  # Each experiment specifies the full --served-model-name + parameter flags.
  kubectl set env deployment/"${DEPLOYMENT_NAME}" \
    -n "${NAMESPACE}" \
    VLLM_EXTRA_ARGS="${extra_args}" \
    --record=false 2>/dev/null || true
  kubectl rollout restart deployment/"${DEPLOYMENT_NAME}" -n "${NAMESPACE}"
  sleep 3
  wait_for_deployment
}

run_locust() {
  local users="$1"
  local label="$2"
  local out_csv="$3"
  local prompt_len="${4:-all}"

  if [[ "${USE_IN_CLUSTER}" == "true" ]]; then
    log "Triggering in-cluster Locust run (users=${users}, label=${label})..."

    # Ensure all locust pods are Ready before proceeding
    log "Waiting for Locust pods to be ready..."
    kubectl wait --for=condition=Ready pod -l app=locust -n locust --timeout=300s
    info "All Locust pods are Ready."

    # Give workers time to register with master (they connect via ZMQ after pod Ready)
    info "Waiting 15s for workers to register with master..."
    sleep 15

    # Start port-forward to master (only if not already running)
    if [[ -z "${PORT_FORWARD_PID}" ]]; then
      log "Starting port-forward to Locust master (locust-master:8089)..."
      kubectl port-forward svc/locust-master 8089:8089 -n locust &>/dev/null &
      PORT_FORWARD_PID=$!
      sleep 4
      info "Locust Port-forward PID: ${PORT_FORWARD_PID}"
    fi

    # Trigger run via API
    info "Starting swarm with ${users} users..."
    curl -s -X POST "${LOCUST_MASTER_URL}/swarm" \
      -d "user_count=${users}&spawn_rate=${users}" > /dev/null
    
    # Extract duration in seconds to sleep
    local duration_sec="${LOCUST_RUN_TIME%s}"
    info "Sleeping for ${duration_sec}s while cluster-Locust runs..."
    sleep "${duration_sec}"
    
    # Stop the swarm
    curl -s -X GET "${LOCUST_MASTER_URL}/stop" > /dev/null
    info "Stopped Locust swarm."
    
    # Download stats CSV from master
    curl -s -X GET "${LOCUST_MASTER_URL}/stats/requests/csv" -o "${out_csv}_stats.csv"
    info "Downloaded summary CSV to ${out_csv}_stats.csv"

  else
    log "Running local Locust: users=${users}, prompt_len=${prompt_len}, label=${label}"
    VLLM_PROMPT_LEN="${prompt_len}" \
    CUSTOM_CSV_PREFIX="${out_csv}" \
    locust \
      -f "${SCRIPT_DIR}/locustfile.py" \
      --host "${VLLM_HOST}" \
      --headless \
      -u "${users}" \
      -r "${users}" \
      --run-time "${LOCUST_RUN_TIME}" \
      --csv "${out_csv}" \
      --csv-full-history \
      --loglevel WARNING 2>&1 | tee -a "${out_csv}_locust.log"
  fi
}

# ---------------------------------------------------------------------------
# Main experiment loop
# ---------------------------------------------------------------------------
RUN_ID="run_$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${RESULTS_BASE}/${RUN_ID}"
mkdir -p "${RUN_DIR}"

log "Run ID: ${RUN_ID}"
log "Results directory: ${RUN_DIR}"
log "Experiments file: ${EXPERIMENT_FILE}"

# Optionally filter to a single named experiment
if [[ -n "${EXPERIMENT_NAME}" ]]; then
  EXPERIMENTS_JSON=$(jq --arg name "${EXPERIMENT_NAME}" '[.[] | select(.name == $name)]' "${EXPERIMENT_FILE}")
  if [[ "$(echo "${EXPERIMENTS_JSON}" | jq '. | length')" -eq 0 ]]; then
    echo "ERROR: No experiment named '${EXPERIMENT_NAME}' found in ${EXPERIMENT_FILE}" >&2
    exit 1
  fi
  log "Filtering to experiment: ${EXPERIMENT_NAME}"
else
  EXPERIMENTS_JSON=$(cat "${EXPERIMENT_FILE}")
fi

NUM_EXPERIMENTS=$(echo "${EXPERIMENTS_JSON}" | jq '. | length')
log "Total experiments: ${NUM_EXPERIMENTS}"

for i in $(seq 0 $((NUM_EXPERIMENTS - 1))); do
  exp=$(echo "${EXPERIMENTS_JSON}" | jq -r ".[$i]")
  exp_name=$(echo "${exp}" | jq -r '.name')
  extra_args=$(echo "${exp}" | jq -r '.vllm_extra_args // ""')
  users_list=$(echo "${exp}" | jq -r '.concurrency[]')
  prompt_categories=$(echo "${exp}" | jq -r '.prompt_categories[]')

  log ""
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "Experiment $((i+1))/${NUM_EXPERIMENTS}: ${exp_name}"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  EXP_DIR="${RUN_DIR}/${exp_name}"
  mkdir -p "${EXP_DIR}"

  # Save experiment config
  echo "${exp}" | jq '.' > "${EXP_DIR}/config.json"

  # Patch deployment (skip if no extra args supplied — use current deployment)
  if [[ -n "${extra_args}" ]]; then
    patch_vllm_args "${extra_args}"
  else
    log "No deployment patch. Using current vLLM deployment."
  fi

  # Connect to vLLM — either via external IP or a local port-forward
  # (--in-cluster mode handles its own port-forward inside run_locust after pod readiness)
  if [[ "${USE_IN_CLUSTER}" == "true" ]]; then
    log "In-cluster mode: port-forward will start after pods are ready."
  elif [[ "${USE_EXTERNAL_IP}" == "true" ]]; then
    fetch_external_ip
  else
    start_port_forward
  fi

  for prompt_cat in ${prompt_categories}; do
    for users in ${users_list}; do
      label="${exp_name}__u${users}__${prompt_cat}"
      out_csv="${EXP_DIR}/${label}"

      run_locust "${users}" "${label}" "${out_csv}" "${prompt_cat}"
      info "✓ Done: ${label}"

      # Brief cooldown between runs
      sleep 5
    done
  done

  # Stop port-forward before next experiment (skipped when using external IP)
  if [[ "${USE_EXTERNAL_IP}" != "true" ]]; then
    stop_port_forward
  fi
done

log ""
log "═══════════════════════════════════════════════"
log "  ✅  All experiments complete!"
log "  Results: ${RUN_DIR}"
log "═══════════════════════════════════════════════"
log ""
log "  To analyze results, run:"
log "    jupyter notebook ${SCRIPT_DIR}/analyze_results.ipynb"
log ""
