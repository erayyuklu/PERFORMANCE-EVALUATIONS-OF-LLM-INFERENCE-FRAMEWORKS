#!/usr/bin/env bash
# =============================================================================
# run_experiment.sh — Repeatable vLLM benchmark experiment runner
#
# Usage:
#   ./run_experiment.sh [--experiments experiments.json] [--host http://...]
#
# What this script does for each experiment configuration:
#   1. Patch the vLLM Kubernetes deployment with the new parameters
#   2. Wait for the deployment to become ready
#   3. Port-forward the vLLM service to localhost
#   4. Run Locust for each concurrency level (users)
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
EXPERIMENTS_FILE="${SCRIPT_DIR}/experiments.json"
VLLM_HOST="http://localhost:8000"
RESULTS_BASE="${SCRIPT_DIR}/results"
NAMESPACE="${K8S_NAMESPACE:-vllm}"
DEPLOYMENT_NAME="vllm"
LOCUST_RUN_TIME="${LOCUST_RUN_TIME:-120s}"     # how long each Locust run lasts
WARMUP_REQUESTS=5                               # requests to warm up before recording
PORT_FORWARD_PID=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --experiments) EXPERIMENTS_FILE="$2"; shift 2 ;;
    --host)        VLLM_HOST="$2";        shift 2 ;;
    --run-time)    LOCUST_RUN_TIME="$2";  shift 2 ;;
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

start_port_forward() {
  log "Starting port-forward localhost:8000 → vllm service..."
  kubectl port-forward svc/vllm-service 8000:8000 -n "${NAMESPACE}" &>/dev/null &
  PORT_FORWARD_PID=$!
  sleep 4   # give kubectl time to establish the tunnel
  info "Port-forward PID: ${PORT_FORWARD_PID}"
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

  log "Running Locust: users=${users}, prompt_len=${prompt_len}, label=${label}"
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
}

# ---------------------------------------------------------------------------
# Main experiment loop
# ---------------------------------------------------------------------------
RUN_ID="run_$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${RESULTS_BASE}/${RUN_ID}"
mkdir -p "${RUN_DIR}"

log "Run ID: ${RUN_ID}"
log "Results directory: ${RUN_DIR}"
log "Experiments file: ${EXPERIMENTS_FILE}"

# Read number of experiments
NUM_EXPERIMENTS=$(jq '. | length' "${EXPERIMENTS_FILE}")
log "Total experiments: ${NUM_EXPERIMENTS}"

for i in $(seq 0 $((NUM_EXPERIMENTS - 1))); do
  exp=$(jq -r ".[$i]" "${EXPERIMENTS_FILE}")
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
    wait_for_deployment
  fi

  # Start port-forward
  start_port_forward

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

  # Stop port-forward before next experiment (will restart after redeploy)
  stop_port_forward
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
