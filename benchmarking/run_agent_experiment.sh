#!/usr/bin/env bash
# =============================================================================
# run_agent_experiment.sh — Repeatable LangGraph Agent load test runner
#
# Usage:
#   ./run_agent_experiment.sh [--experiment-file experiments.json]
#                             [--experiment <name>] [--run-time <duration>]
#                             [--spawn-time <duration>]
#                             [--dry-run]
#
# What this script does for each experiment configuration:
#   1. Patch the Locust ConfigMap to target the Agent API
#   2. Switch Locust to use locustfile_agent.py
#   3. Trigger load test via the in-cluster Locust master REST API
#   4. Run Locust for each concurrency level (users)
#   5. Save all results under results/<run_id>/
#
# Requires: kubectl, jq, curl
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../vllm/infra_config.env"
source "${SCRIPT_DIR}/config.env"

# ---------------------------------------------------------------------------
# Agent-specific defaults
# ---------------------------------------------------------------------------
EXPERIMENT_FILE="${EXPERIMENT_FILE:-${SCRIPT_DIR}/experiments/agent_load_test.json}"
EXPERIMENT_NAME=""
RESULTS_BASE="${SCRIPT_DIR}/results"
PORT_FORWARD_PID=""
PROM_PORT_FORWARD_PID=""
DRY_RUN=false

# Agent experiment config
AGENT_RUN_TIME="${LOCUST_RUN_TIME:-180s}"
AGENT_SPAWN_TIME="${SPAWN_TIME:-60s}"
AGENT_COOLDOWN_SEC="${COOLDOWN_SEC:-0}"
AGENT_LOCUST_WORKERS="${LOCUST_WORKERS:-2}"

# Locust file to use for agent tests
AGENT_LOCUSTFILE="/locust/locustfile_agent.py"
AGENT_TARGET_HOST="http://agent-service.agent.svc.cluster.local"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --experiment-file) EXPERIMENT_FILE="$2";       shift 2 ;;
    --experiment)      EXPERIMENT_NAME="$2";       shift 2 ;;
    --run-time)        AGENT_RUN_TIME="$2";        shift 2 ;;
    --spawn-time)      AGENT_SPAWN_TIME="$2";      shift 2 ;;
    --dry-run)         DRY_RUN=true;               shift   ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "==> $*"; }
info() { echo "    $*"; }

cleanup() {
  set +e
  # Stop Locust swarm
  log "Stopping Locust swarm..."
  local master_pod
  master_pod=$(kubectl get pod -n "${LOCUST_NAMESPACE}" \
    -l app=locust,role=master \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "${master_pod}" ]]; then
    kubectl exec -n "${LOCUST_NAMESPACE}" "${master_pod}" -- \
      python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:8089/stop')" 2>&1 || true
  fi

  if [[ -n "${PORT_FORWARD_PID}" ]]; then
    kill "${PORT_FORWARD_PID}" 2>/dev/null || true
  fi
  if [[ -n "${PROM_PORT_FORWARD_PID}" ]]; then
    kill "${PROM_PORT_FORWARD_PID}" 2>/dev/null || true
  fi

  # Restore Locust to original vLLM config
  log "Restoring Locust ConfigMap to vLLM mode..."
  restore_locust_configmap || true
}
trap cleanup EXIT

wait_for_deployment() {
  local dep_name="$1"
  local ns="$2"
  log "Waiting for deployment '${dep_name}' to be ready..."
  kubectl rollout status deployment/"${dep_name}" \
    -n "${ns}" \
    --timeout=300s
}

parse_duration_seconds() {
  local value="$1"
  if [[ -z "${value}" ]]; then echo ""; return 0; fi
  if [[ "${value}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then printf '%s' "${value}"; return 0; fi
  if [[ "${value}" =~ ^([0-9]+([.][0-9]+)?)([smh])$ ]]; then
    local num="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[3]}"
    case "${unit}" in
      s) awk -v n="${num}" 'BEGIN { printf "%.6f", n }' ;;
      m) awk -v n="${num}" 'BEGIN { printf "%.6f", n * 60 }' ;;
      h) awk -v n="${num}" 'BEGIN { printf "%.6f", n * 3600 }' ;;
    esac
    return 0
  fi
  echo "ERROR: Invalid duration '${value}'." >&2
  exit 1
}

compute_spawn_rate() {
  local users="$1" spawn_time_sec="$2"
  awk -v u="${users}" -v t="${spawn_time_sec}" 'BEGIN {
    if (t <= 0) { print "ERROR"; exit 0 }
    r = u / t; if (r <= 0) r = 0.0001; printf "%.6f", r
  }'
}

wait_for_locust_workers() {
  local expected="${AGENT_LOCUST_WORKERS}"
  local max_attempts="${1:-120}"
  info "Waiting for ${expected} Locust worker(s) to connect..."
  for attempt in $(seq 1 "${max_attempts}"); do
    local wc
    wc=$(curl -sf "${LOCUST_MASTER_URL}/stats/requests" 2>/dev/null \
      | jq -r '.worker_count // 0' 2>/dev/null || echo "0")
    if [[ "${wc}" =~ ^[0-9]+$ ]] && [[ "${wc}" -ge "${expected}" ]]; then
      info "All workers connected: ${wc}/${expected}."
      return 0
    fi
    info "Waiting (${wc}/${expected}, attempt ${attempt}/${max_attempts})..."
    sleep 2
  done
  echo "ERROR: Workers not connected after wait." >&2
  exit 1
}

wait_for_swarm_running() {
  local timeout_sec="$1"
  local attempts
  attempts=$(awk -v t="${timeout_sec}" 'BEGIN { a = int((t + 1) / 2); if (a < 1) a = 1; print a }')
  for attempt in $(seq 1 "${attempts}"); do
    local state
    state=$(curl -sf "${LOCUST_MASTER_URL}/stats/requests" 2>/dev/null \
      | jq -r '.state // "unknown"' 2>/dev/null || echo "unknown")
    if [[ "${state}" == "running" ]]; then
      info "Swarm is running."
      return 0
    fi
    info "Waiting for swarm (current: ${state}, attempt ${attempt}/${attempts})..."
    sleep 2
  done
  echo "ERROR: Swarm did not reach 'running' state." >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Locust ConfigMap patching — switch to agent mode
# ---------------------------------------------------------------------------
# Save original ConfigMap values for restoration
ORIGINAL_HOST=""
ORIGINAL_LOCUSTFILE=""

patch_locust_for_agent() {
  log "Patching Locust ConfigMap for agent load testing..."

  # Save originals for restoration
  ORIGINAL_HOST=$(kubectl get configmap locust-config -n "${LOCUST_NAMESPACE}" \
    -o jsonpath='{.data.VLLM_TARGET_HOST}' 2>/dev/null || echo "")

  # Patch ConfigMap
  kubectl patch configmap locust-config -n "${LOCUST_NAMESPACE}" -p \
    "{\"data\":{\"VLLM_TARGET_HOST\":\"${AGENT_TARGET_HOST}\",\"AGENT_REQUEST_TIMEOUT\":\"${AGENT_REQUEST_TIMEOUT:-120}\"}}"

  # Patch master deployment to use agent locustfile
  kubectl patch deployment locust-master -n "${LOCUST_NAMESPACE}" --type=json -p \
    "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":[\"--master\",\"-f\",\"${AGENT_LOCUSTFILE}\",\"--stop-timeout\",\"${LOCUST_STOP_WAIT_SEC:-300}\",\"--csv=/tmp/locust\",\"--csv-full-history\"]}]"

  # Patch worker deployment to use agent locustfile
  kubectl patch deployment locust-worker -n "${LOCUST_NAMESPACE}" --type=json -p \
    "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":[\"--worker\",\"--master-host=locust-master\",\"-f\",\"${AGENT_LOCUSTFILE}\"]}]"

  # Restart deployments sequentially
  kubectl rollout restart deployment/locust-master -n "${LOCUST_NAMESPACE}"
  wait_for_deployment "locust-master" "${LOCUST_NAMESPACE}"
  sleep 10
  kubectl rollout restart deployment/locust-worker -n "${LOCUST_NAMESPACE}"
  wait_for_deployment "locust-worker" "${LOCUST_NAMESPACE}"

  info "Locust patched for agent mode."
}

restore_locust_configmap() {
  if [[ -z "${ORIGINAL_HOST}" ]]; then
    return 0
  fi

  log "Restoring Locust to original vLLM mode..."

  # Restore ConfigMap
  kubectl patch configmap locust-config -n "${LOCUST_NAMESPACE}" -p \
    "{\"data\":{\"VLLM_TARGET_HOST\":\"${ORIGINAL_HOST}\"}}"

  # Restore master deployment to original locustfile
  kubectl patch deployment locust-master -n "${LOCUST_NAMESPACE}" --type=json -p \
    "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":[\"--master\",\"-f\",\"/locust/locustfile.py\",\"--stop-timeout\",\"${LOCUST_STOP_WAIT_SEC:-300}\",\"--csv=/tmp/locust\",\"--csv-full-history\"]}]"

  # Restore worker deployment
  kubectl patch deployment locust-worker -n "${LOCUST_NAMESPACE}" --type=json -p \
    "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":[\"--worker\",\"--master-host=locust-master\",\"-f\",\"/locust/locustfile.py\"]}]"

  # Restart
  kubectl rollout restart deployment/locust-master -n "${LOCUST_NAMESPACE}"
  wait_for_deployment "locust-master" "${LOCUST_NAMESPACE}"
  sleep 10
  kubectl rollout restart deployment/locust-worker -n "${LOCUST_NAMESPACE}"
  wait_for_deployment "locust-worker" "${LOCUST_NAMESPACE}"

  info "Locust restored to vLLM mode."
}

# ---------------------------------------------------------------------------
# Run a single Locust load test iteration
# ---------------------------------------------------------------------------
run_agent_locust() {
  local users="$1"
  local label="$2"
  local out_csv="$3"

  local spawn_time_sec
  spawn_time_sec=$(parse_duration_seconds "${AGENT_SPAWN_TIME}")

  local effective_spawn_rate
  if [[ -n "${spawn_time_sec}" ]]; then
    effective_spawn_rate=$(compute_spawn_rate "${users}" "${spawn_time_sec}")
  else
    effective_spawn_rate="${users}"
  fi

  local ramp_time_sec
  ramp_time_sec=$(awk -v u="${users}" -v r="${effective_spawn_rate}" 'BEGIN { if (r <= 0) print 0; else printf "%.6f", u / r }')
  local swarm_wait_sec
  swarm_wait_sec=$(awk -v ramp="${ramp_time_sec}" 'BEGIN { t = int(ramp + 0.999999) + 90; if (t < 90) t = 90; print t }')

  log "Agent Locust run: users=${users}, spawn_rate=${effective_spawn_rate}, label=${label}"

  local start_ts
  start_ts=$(date +%s)

  wait_for_locust_workers 120

  info "Starting swarm: ${users} users at ${effective_spawn_rate} users/s..."
  curl -sf -X POST "${LOCUST_MASTER_URL}/swarm" \
    -d "user_count=${users}&spawn_rate=${effective_spawn_rate}" > /dev/null \
    || { echo "ERROR: Failed to start Locust swarm." >&2; exit 1; }

  wait_for_swarm_running "${swarm_wait_sec}"

  local duration_sec="${AGENT_RUN_TIME%s}"
  info "Sleeping for ${duration_sec}s while agent load test runs..."
  sleep "${duration_sec}"

  info "Stopping swarm..."
  curl -sf -X GET "${LOCUST_MASTER_URL}/stop" > /dev/null || true

  local end_ts
  end_ts=$(date +%s)

  # Download Locust CSV exports
  curl -sf "${LOCUST_MASTER_URL}/stats/requests/csv" -o "${out_csv}_stats.csv" || true
  curl -sf "${LOCUST_MASTER_URL}/stats/failures/csv" -o "${out_csv}_failures.csv" || true
  curl -sf "${LOCUST_MASTER_URL}/exceptions/csv" -o "${out_csv}_exceptions.csv" || true
  curl -sf "${LOCUST_MASTER_URL}/stats/requests_full_history/csv" -o "${out_csv}_stats_history.csv" || true

  # Fetch Prometheus metrics
  if [[ -f "${SCRIPT_DIR}/fetch_metrics.sh" ]]; then
    log "Fetching Prometheus metrics for ${label}..."
    "${SCRIPT_DIR}/fetch_metrics.sh" \
      --start "${start_ts}" --end "${end_ts}" \
      --output "${out_csv}_prometheus_metrics.csv" \
      --prometheus-url "${PROMETHEUS_URL}" || true
  fi

  # Copy per-request files from worker pods
  log "Copying per-request files from Locust worker pods..."
  sleep 10

  local worker_pods
  worker_pods=$(kubectl get pod -n "${LOCUST_NAMESPACE}" \
    -l app=locust,role=worker \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

  if [[ -n "${worker_pods}" ]]; then
    local first_worker=true
    for pod in ${worker_pods}; do
      local tmp_csv="${pod}_agent_custom.csv"
      local tmp_jsonl="${pod}_agent_responses.jsonl"

      if kubectl cp -n "${LOCUST_NAMESPACE}" "${pod}:${WORKER_ARTIFACTS_DIR}/locust_agent_metrics.csv" "${tmp_csv}" 2>/dev/null; then
        if [[ "${first_worker}" == "true" ]]; then
          mv "${tmp_csv}" "${out_csv}_agent_metrics.csv"
          first_worker=false
        else
          tail -n +2 "${tmp_csv}" >> "${out_csv}_agent_metrics.csv"
          rm -f "${tmp_csv}"
        fi
        info "Agent metrics copied from ${pod}."
      fi

      if kubectl cp -n "${LOCUST_NAMESPACE}" "${pod}:${WORKER_ARTIFACTS_DIR}/locust_agent_responses.jsonl" "${tmp_jsonl}" 2>/dev/null; then
        cat "${tmp_jsonl}" >> "${out_csv}_agent_responses.jsonl"
        rm -f "${tmp_jsonl}"
        info "Agent responses copied from ${pod}."
      fi
    done
  fi
}


# ---------------------------------------------------------------------------
# Main experiment loop
# ---------------------------------------------------------------------------
RUN_ID="agent_run_$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${RESULTS_BASE}/${RUN_ID}"
mkdir -p "${RUN_DIR}"

log "Agent Experiment Run ID: ${RUN_ID}"
log "Results directory: ${RUN_DIR}"
log "Experiments file: ${EXPERIMENT_FILE}"

# Load experiments
if [[ -n "${EXPERIMENT_NAME}" ]]; then
  EXPERIMENTS_JSON=$(jq --arg name "${EXPERIMENT_NAME}" '[.[] | select(.name == $name)]' "${EXPERIMENT_FILE}")
  if [[ "$(echo "${EXPERIMENTS_JSON}" | jq '. | length')" -eq 0 ]]; then
    echo "ERROR: No experiment named '${EXPERIMENT_NAME}'" >&2
    exit 1
  fi
else
  EXPERIMENTS_JSON=$(cat "${EXPERIMENT_FILE}")
fi

NUM_EXPERIMENTS=$(echo "${EXPERIMENTS_JSON}" | jq '. | length')
log "Total experiments: ${NUM_EXPERIMENTS}"

# ---------------------------------------------------------------------------
# Dry-run mode
# ---------------------------------------------------------------------------
if [[ "${DRY_RUN}" == "true" ]]; then
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "DRY RUN — no cluster changes will be made"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  for i in $(seq 0 $((NUM_EXPERIMENTS - 1))); do
    exp=$(echo "${EXPERIMENTS_JSON}" | jq -r ".[$i]")
    exp_name=$(echo "${exp}" | jq -r '.name')
    users_list=$(echo "${exp}" | jq -r '[.concurrency[]] | join(", ")')
    log "[$((i+1))/${NUM_EXPERIMENTS}] ${exp_name}"
    info "target:       ${AGENT_TARGET_HOST}"
    info "locustfile:   ${AGENT_LOCUSTFILE}"
    info "concurrency:  ${users_list}"
    info "run_time:     ${AGENT_RUN_TIME}"
    info "spawn_time:   ${AGENT_SPAWN_TIME}"
    info "cooldown_sec: ${AGENT_COOLDOWN_SEC}"
  done
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 0
fi

# ---------------------------------------------------------------------------
# Setup: patch Locust for agent mode, set up port-forwards
# ---------------------------------------------------------------------------
patch_locust_for_agent

log "Starting port-forward to Locust master..."
kubectl port-forward svc/locust-master 8089:8089 -n "${LOCUST_NAMESPACE}" &>/dev/null &
PORT_FORWARD_PID=$!

for attempt in $(seq 1 15); do
  if curl -sf "${LOCUST_MASTER_URL}/" &>/dev/null; then
    info "Locust master is reachable."
    break
  fi
  sleep 2
done

# Prometheus port-forward
log "Starting port-forward to Prometheus..."
kubectl port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 -n monitoring &>/dev/null &
PROM_PORT_FORWARD_PID=$!

wait_for_locust_workers 120

# ---------------------------------------------------------------------------
# Run experiments
# ---------------------------------------------------------------------------
for i in $(seq 0 $((NUM_EXPERIMENTS - 1))); do
  exp=$(echo "${EXPERIMENTS_JSON}" | jq -r ".[$i]")
  exp_name=$(echo "${exp}" | jq -r '.name' | tr -d '\r')
  users_list=$(echo "${exp}" | jq -r '.concurrency[]')

  log ""
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "Agent Experiment $((i+1))/${NUM_EXPERIMENTS}: ${exp_name}"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  EXP_DIR="${RUN_DIR}/${exp_name}"
  mkdir -p "${EXP_DIR}"
  echo "${exp}" | jq '.' > "${EXP_DIR}/config.json"

  for users in ${users_list}; do
    label="${exp_name}__u${users}"
    out_csv="${EXP_DIR}/${label}"

    run_agent_locust "${users}" "${label}" "${out_csv}"
    info "✓ Done: ${label}"
    sleep "${AGENT_COOLDOWN_SEC}"
  done
done

log ""
log "═══════════════════════════════════════════════"
log "  ✅  All agent experiments complete!"
log "  Results: ${RUN_DIR}"
log "═══════════════════════════════════════════════"
