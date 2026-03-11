#!/usr/bin/env bash
# =============================================================================
# run_experiment.sh — Repeatable vLLM benchmark experiment runner (in-cluster)
#
# Usage:
#   ./run_experiment.sh [--experiment-file experiments.json]
#                       [--experiment <name>] [--run-time <duration>]
#                       [--dry-run]
#
# What this script does for each experiment configuration:
#   1. Patch the vLLM Kubernetes deployment with the new parameters
#   2. Wait for the deployment to become ready
#   3. Trigger load test via the in-cluster Locust master REST API
#   4. Run Locust for each concurrency level (users)
#   5. Save all results under results/<run_id>/
#
# Requires: kubectl, jq, curl
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../gke-deployment/config.env"
source "${SCRIPT_DIR}/config.env"

# ---------------------------------------------------------------------------
# Script-internal state (configurable parameters live in config.env)
# ---------------------------------------------------------------------------
EXPERIMENT_FILE="${EXPERIMENT_FILE:-${SCRIPT_DIR}/experiments.json}"
EXPERIMENT_NAME=""                              # if set, run only this experiment
RESULTS_BASE="${SCRIPT_DIR}/results"
NAMESPACE="${K8S_NAMESPACE:-vllm}"
DEPLOYMENT_NAME="vllm-server"
PORT_FORWARD_PID=""
PROM_PORT_FORWARD_PID=""
DRY_RUN=false

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --experiment-file) EXPERIMENT_FILE="$2";   shift 2 ;;
    --experiment)      EXPERIMENT_NAME="$2";   shift 2 ;;
    --run-time)        LOCUST_RUN_TIME="$2";   shift 2 ;;
    --dry-run)         DRY_RUN=true;           shift   ;;
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
    log "Port-forward to Locust master stopped."
  fi
  if [[ -n "${PROM_PORT_FORWARD_PID}" ]]; then
    kill "${PROM_PORT_FORWARD_PID}" 2>/dev/null || true
    log "Port-forward to Prometheus stopped."
  fi
}
trap cleanup EXIT

wait_for_deployment() {
  log "Waiting for deployment '${DEPLOYMENT_NAME}' to be ready..."
  kubectl rollout status deployment/"${DEPLOYMENT_NAME}" \
    -n "${NAMESPACE}" \
    --timeout=1200s
  log "Deployment is ready."
}

patch_vllm_args() {
  local extra_args="$1"
  log "Patching vLLM deployment with args: ${extra_args}"

  # Base args mirroring deployment.yaml (each flag and value as separate elements)
  local base_args='["--model","$(MODEL)","--max-model-len","$(MAX_MODEL_LEN)","--gpu-memory-utilization","$(GPU_MEMORY_UTILIZATION)","--dtype","$(DTYPE)","--tensor-parallel-size","$(TENSOR_PARALLEL_SIZE)","--port","$(PORT)"]'

  # Split extra_args into individual tokens and build a JSON array
  local extra_json="[]"
  if [[ -n "${extra_args}" ]]; then
    local extra_array=()
    read -ra extra_array <<< "${extra_args}"
    extra_json=$(printf '%s\n' "${extra_array[@]}" | jq -R . | jq -s .)
  fi

  # Merge base + extra args and patch the container args directly
  local merged_args
  merged_args=$(jq -n --argjson base "${base_args}" --argjson extra "${extra_json}" '$base + $extra')

  kubectl patch deployment/"${DEPLOYMENT_NAME}" \
    -n "${NAMESPACE}" \
    --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":${merged_args}}]"

  kubectl rollout restart deployment/"${DEPLOYMENT_NAME}" -n "${NAMESPACE}"
  sleep 3
  wait_for_deployment
}

print_grafana_link() {
  local duration_sec="${LOCUST_RUN_TIME%s}"

  # Count total individual locust runs across all experiments
  local total_runs=0
  for idx in $(seq 0 $((NUM_EXPERIMENTS - 1))); do
    local e n_users n_cats
    e=$(echo "${EXPERIMENTS_JSON}" | jq -r ".[${idx}]")
    n_users=$(echo "${e}" | jq '.concurrency | length')
    n_cats=$(echo "${e}" | jq '.prompt_categories | length')
    total_runs=$(( total_runs + n_users * n_cats ))
  done

  # Expected window: runs × (duration + cooldown) + 2 min overhead buffer
  local total_sec=$(( total_runs * (duration_sec + COOLDOWN_SEC) + 120 ))

  local from_ms to_ms
  from_ms=$(date +%s%3N)                              # epoch milliseconds (GNU date / Linux)
  to_ms=$(( from_ms + total_sec * 1000 ))

  # Resolve Grafana external IP
  local grafana_ip
  grafana_ip=$(
    kubectl get svc -n monitoring \
      -l "app.kubernetes.io/name=grafana" \
      -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
  )

  if [[ -z "${grafana_ip}" ]]; then
    log "⚠  Could not resolve Grafana external IP — dashboard link unavailable."
    return
  fi

  local url="http://${grafana_ip}/d/locust-load-test/locust-load-test?orgId=1&from=${from_ms}&to=${to_ms}"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "  Grafana — Locust Dashboard (absolute time range)"
  log "  Covers ${total_runs} run(s) × ${duration_sec}s + overhead"
  log "  ${url}"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Called ONCE before the main loop to avoid repeating readiness checks per run.
ensure_locust_ready() {
  log "Waiting for Locust pods to be ready..."
  kubectl wait --for=condition=Ready pod -l app=locust \
    -n "${LOCUST_NAMESPACE}" --timeout=300s
  info "All Locust pods are Ready."

  # Give workers time to register with master (they connect via ZMQ after pod Ready)
  info "Waiting 15s for workers to register with master..."
  sleep 15

  log "Starting port-forward to Locust master (locust-master:8089)..."
  kubectl port-forward svc/locust-master 8089:8089 -n "${LOCUST_NAMESPACE}" &>/dev/null &
  PORT_FORWARD_PID=$!
  info "Locust Port-forward PID: ${PORT_FORWARD_PID}"

  # Verify the port-forward is actually reachable before proceeding
  local attempt
  for attempt in $(seq 1 15); do
    if curl -sf "${LOCUST_MASTER_URL}/" &>/dev/null; then
      info "Locust master is reachable at ${LOCUST_MASTER_URL}."
      break
    fi
    info "Waiting for Locust master to become reachable (attempt ${attempt}/15)..."
    sleep 2
  done
  if ! curl -sf "${LOCUST_MASTER_URL}/" &>/dev/null; then
    echo "ERROR: Locust master at ${LOCUST_MASTER_URL} is not reachable after port-forward." >&2
    exit 1
  fi

  # Start port-forward to Prometheus for metrics fetching
  log "Starting port-forward to Prometheus (prometheus-server:9090)..."
  kubectl port-forward svc/prometheus-server 9090:80 -n monitoring &>/dev/null &
  PROM_PORT_FORWARD_PID=$!
  info "Prometheus Port-forward PID: ${PROM_PORT_FORWARD_PID}"

  for attempt in $(seq 1 15); do
    if curl -sf "${PROMETHEUS_URL}/-/ready" &>/dev/null; then
      info "Prometheus is reachable at ${PROMETHEUS_URL}."
      return 0
    fi
    info "Waiting for Prometheus to become reachable (attempt ${attempt}/15)..."
    sleep 2
  done
  echo "ERROR: Prometheus at ${PROMETHEUS_URL} is not reachable after port-forward." >&2
  exit 1
}

# Poll until Locust reports state == "running", then return.
# This ensures the sleep timer starts only after ramp-up is complete.
wait_for_swarm_running() {
  local attempt
  for attempt in $(seq 1 30); do
    local state
    state=$(curl -sf "${LOCUST_MASTER_URL}/stats/requests" 2>/dev/null \
              | jq -r '.state // "unknown"' 2>/dev/null || echo "unknown")
    if [[ "${state}" == "running" ]]; then
      info "Swarm is running."
      return 0
    fi
    info "Waiting for swarm to reach 'running' state (current: ${state}, attempt ${attempt}/30)..."
    sleep 2
  done
  echo "ERROR: Locust swarm did not reach 'running' state within 60s." >&2
  exit 1
}

run_locust() {
  local users="$1"
  local label="$2"
  local out_csv="$3"
  local effective_spawn_rate="${SPAWN_RATE:-${users}}"

  log "Triggering in-cluster Locust run (users=${users}, spawn_rate=${effective_spawn_rate}, label=${label})..."

  # Record start timestamp (epoch seconds) for Prometheus query_range
  local start_ts
  start_ts=$(date +%s)

  # Trigger run via API — fail immediately on curl error
  info "Starting swarm: ${users} users at ${effective_spawn_rate} users/s..."
  curl -sf -X POST "${LOCUST_MASTER_URL}/swarm" \
    -d "user_count=${users}&spawn_rate=${effective_spawn_rate}" > /dev/null \
    || { echo "ERROR: Failed to start Locust swarm (POST /swarm)." >&2; exit 1; }

  # Poll until ramp-up is complete before starting the timer
  wait_for_swarm_running

  local duration_sec="${LOCUST_RUN_TIME%s}"
  info "Sleeping for ${duration_sec}s while cluster-Locust runs..."
  sleep "${duration_sec}"

  # Stop the swarm
  curl -sf -X GET "${LOCUST_MASTER_URL}/stop" > /dev/null \
    || { echo "ERROR: Failed to stop Locust swarm (GET /stop)." >&2; exit 1; }
  info "Stopped Locust swarm."

  # Record end timestamp
  local end_ts
  end_ts=$(date +%s)

  # Download standard Locust CSV exports from master
  curl -sf "${LOCUST_MASTER_URL}/stats/requests/csv" \
    -o "${out_csv}_stats.csv" \
    || { echo "ERROR: Failed to download stats CSV." >&2; exit 1; }
  curl -sf "${LOCUST_MASTER_URL}/stats/failures/csv" \
    -o "${out_csv}_failures.csv" \
    || { echo "ERROR: Failed to download failures CSV." >&2; exit 1; }
  curl -sf "${LOCUST_MASTER_URL}/exceptions/csv" \
    -o "${out_csv}_exceptions.csv" \
    || { echo "ERROR: Failed to download exceptions CSV." >&2; exit 1; }
  if curl -sf "${LOCUST_MASTER_URL}/stats/requests_full_history/csv" \
    -o "${out_csv}_stats_history.csv"; then
    info "Downloaded stats/failures/exceptions/stats_history CSVs to $(dirname "${out_csv}")/"
  else
    info "Downloaded stats/failures/exceptions CSVs to $(dirname "${out_csv}")/"
    info "stats_history CSV unavailable; continuing without it."
  fi

  # Fetch Prometheus metrics for this run's time window
  log "Fetching Prometheus metrics for ${label} (${start_ts} → ${end_ts})..."
  "${SCRIPT_DIR}/fetch_metrics.sh" \
    --start "${start_ts}" \
    --end "${end_ts}" \
    --output "${out_csv}_prometheus_metrics.csv" \
    --prometheus-url "${PROMETHEUS_URL}" \
    || log "WARNING: Prometheus metrics fetch failed for ${label}; continuing."
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

# ---------------------------------------------------------------------------
# Dry-run: print plan and exit without touching the cluster
# ---------------------------------------------------------------------------
if [[ "${DRY_RUN}" == "true" ]]; then
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "DRY RUN — no cluster changes will be made"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  for i in $(seq 0 $((NUM_EXPERIMENTS - 1))); do
    exp=$(echo "${EXPERIMENTS_JSON}" | jq -r ".[$i]")
    exp_name=$(echo "${exp}" | jq -r '.name')
    extra_args=$(echo "${exp}" | jq -r '.vllm_extra_args // "(none)"')
    users_list=$(echo "${exp}" | jq -r '[.concurrency[]] | join(", ")')
    prompt_categories=$(echo "${exp}" | jq -r '[.prompt_categories[]] | join(", ")')
    log "[$((i+1))/${NUM_EXPERIMENTS}] ${exp_name}"
    info "extra_args:        ${extra_args}"
    info "concurrency:       ${users_list}"
    info "run_time:          ${LOCUST_RUN_TIME}"
    info "spawn_rate:        ${SPAWN_RATE:-(= user_count)}"
    info "cooldown_sec:      ${COOLDOWN_SEC}"
  done
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 0
fi

print_grafana_link

# Ensure Locust pods are ready and the port-forward is established once,
# before any runs begin (avoids repeating this check on every run_locust call).
ensure_locust_ready

for i in $(seq 0 $((NUM_EXPERIMENTS - 1))); do
  exp=$(echo "${EXPERIMENTS_JSON}" | jq -r ".[$i]")
  exp_name=$(echo "${exp}" | jq -r '.name')
  extra_args=$(echo "${exp}" | jq -r '.vllm_extra_args // ""')
  users_list=$(echo "${exp}" | jq -r '.concurrency[]')

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

  for users in ${users_list}; do
    label="${exp_name}__u${users}"
    out_csv="${EXP_DIR}/${label}"

    run_locust "${users}" "${label}" "${out_csv}"
    info "✓ Done: ${label}"

    # Brief cooldown between runs
    sleep "${COOLDOWN_SEC}"
  done
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
