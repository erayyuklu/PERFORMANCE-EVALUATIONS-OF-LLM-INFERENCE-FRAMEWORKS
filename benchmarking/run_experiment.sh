#!/usr/bin/env bash
# =============================================================================
# run_experiment.sh — Repeatable vLLM benchmark experiment runner (in-cluster)
#
# Usage:
#   ./run_experiment.sh [--experiment-file experiments.json]
#                       [--experiment <name>] [--run-time <duration>]
#                       [--spawn-time <duration>]
#                       [--skip-patch]
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
source "${SCRIPT_DIR}/../vllm/infra_config.env"
source "${SCRIPT_DIR}/config.env"

# ---------------------------------------------------------------------------
# Script-internal state (configurable parameters live in config.env)
# ---------------------------------------------------------------------------
EXPERIMENT_FILE="${EXPERIMENT_FILE:-${SCRIPT_DIR}/experiments/experiments.json}"
EXPERIMENT_NAME=""                              # if set, run only this experiment
RESULTS_BASE="${SCRIPT_DIR}/results"
NAMESPACE="${K8S_NAMESPACE:-vllm}"
DEPLOYMENT_NAME="vllm-server"
PORT_FORWARD_PID=""
PROM_PORT_FORWARD_PID=""
DRY_RUN=false
SKIP_PATCH=false                              # run tests without patching vLLM args
# Estimated time for a vLLM deployment rollout (seconds). Default: 15 minutes
ROLLOUT_SEC="${ROLLOUT_SEC:-900}"
# Maximum time to wait for Locust to drain in-flight requests after /stop.
LOCUST_STOP_WAIT_SEC="${LOCUST_STOP_WAIT_SEC:-300}"
# Directory inside worker containers where per-request artifacts are written.
WORKER_ARTIFACTS_DIR="${WORKER_ARTIFACTS_DIR:-/tmp}"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --experiment-file) EXPERIMENT_FILE="$2";   shift 2 ;;
    --experiment)      EXPERIMENT_NAME="$2";   shift 2 ;;
    --run-time)        LOCUST_RUN_TIME="$2";   shift 2 ;;
    --spawn-time)      SPAWN_TIME="$2";        shift 2 ;;
    --skip-patch)      SKIP_PATCH=true;         shift   ;;
    --dry-run)         DRY_RUN=true;           shift   ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "==> $*"; }
info() { echo "    $*"; }

stop_locust_swarm_on_exit() {
  # Cleanup is best-effort; never fail hard while exiting.
  # Use kubectl exec instead of the port-forward, because SIGINT (Ctrl-C)
  # kills the background port-forward processes before this trap fires.
  log "Stopping Locust swarm before shutting down port-forwards..."

  local master_pod
  master_pod=$(kubectl get pod -n "${LOCUST_NAMESPACE}" \
    -l app=locust,role=master \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -z "${master_pod}" ]]; then
    info "Could not find Locust master pod; skipping swarm stop."
    return 0
  fi

  # Send stop signal directly inside the pod (using Python since curl might be missing)
  local exec_output
  if exec_output=$(kubectl exec -n "${LOCUST_NAMESPACE}" "${master_pod}" -- python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:8089/stop')" 2>&1); then
    info "Successfully sent stop signal to Locust master pod."
  else
    info "Warning: Failed to send stop signal to Locust master pod."
    info "Exec output: ${exec_output}"
  fi

  local waited=0
  local state="unknown"
  while (( waited < LOCUST_STOP_WAIT_SEC )); do
    # Fetch stats via Python, then pipe resulting JSON to jq locally
    state=$(kubectl exec -n "${LOCUST_NAMESPACE}" "${master_pod}" -- \
      python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8089/stats/requests', timeout=3).read().decode('utf-8'))" 2>/dev/null \
      | jq -r '.state // "unknown"' 2>/dev/null || echo "unknown")

    if [[ "${state}" != "running" && "${state}" != "spawning" ]]; then
      info "Locust swarm state after stop: ${state}."
      return 0
    fi

    sleep 2
    waited=$(( waited + 2 ))
  done

  info "Locust swarm still active after ${LOCUST_STOP_WAIT_SEC}s; continuing cleanup."
}

cleanup() {
  set +e
  stop_locust_swarm_on_exit

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
  local dep_name="$1"
  local ns="$2"
  log "Waiting for deployment '${dep_name}' to be ready..."
  kubectl rollout status deployment/"${dep_name}" \
    -n "${ns}" \
    --timeout=1200s
  log "Deployment is ready."
}

patch_vllm_args() {
  local model_override="$1"
  local extra_args="$2"

  # Default behavior is to use YAML config, unless experiment args already
  # specify a config file.
  local use_default_config=true
  if [[ " ${extra_args} " =~ [[:space:]]--config[[:space:]] ]]; then
    use_default_config=false
  fi

  local args_array=()
  if [[ "${use_default_config}" == "true" ]]; then
    args_array=("--config" "/etc/vllm/vllm_config.yaml")
  fi

  # Model must be positional for `vllm serve`.
  if [[ -n "${model_override}" ]]; then
    args_array=("${model_override}" "${args_array[@]}")
  fi

  if [[ -n "${extra_args}" ]]; then
    local extra_array=()
    read -ra extra_array <<< "${extra_args}"
    args_array+=("${extra_array[@]}")
  fi

  log "Patching vLLM deployment with args: ${args_array[*]}"

  local merged_args
  merged_args=$(printf '%s\n' "${args_array[@]}" | jq -R . | jq -s .)

  kubectl patch deployment/"${DEPLOYMENT_NAME}" \
    -n "${NAMESPACE}" \
    --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":${merged_args}}]"

  kubectl rollout restart deployment/"${DEPLOYMENT_NAME}" -n "${NAMESPACE}"
  sleep 3
  wait_for_deployment "${DEPLOYMENT_NAME}" "${NAMESPACE}"
}

wait_for_locust_workers() {
  local max_attempts="${1:-120}"
  local attempt

  for attempt in $(seq 1 "${max_attempts}"); do
    local worker_count
    worker_count=$(curl -sf "${LOCUST_MASTER_URL}/stats/requests" 2>/dev/null \
      | jq -r '.worker_count // 0' 2>/dev/null || echo "0")
    if [[ "${worker_count}" =~ ^[0-9]+$ ]] && [[ "${worker_count}" -ge 1 ]]; then
      info "Locust workers connected: ${worker_count}."
      return 0
    fi
    info "Waiting for Locust workers to register on master (attempt ${attempt}/${max_attempts})..."
    sleep 2
  done

  echo "ERROR: No Locust workers connected to master after wait period." >&2
  exit 1
}

patch_locust_configmap() {
  local overrides_json="$1"

  # Apply configmap overrides
  local has_overrides
  has_overrides=$(echo "${overrides_json}" | jq 'if type=="object" then length else 0 end')
  
  if [[ "${has_overrides}" -gt 0 ]]; then
    log "Patching locust-config ConfigMap with overrides..."
    
    local patch_str="{\"data\":{"
    while IFS="=" read -r key val; do
      info "  ${key}=${val}"
      patch_str+="\"${key}\":\"${val}\","
    done < <(echo "${overrides_json}" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
    patch_str="${patch_str%,}}}"
    
    kubectl patch configmap locust-config -n "${LOCUST_NAMESPACE}" -p "${patch_str}"

    info "ConfigMap patched. Restarting Locust deployments sequentially..."
    
    # 1. Restart Master and wait for it to be fully rolled out
    kubectl rollout restart deployment/locust-master -n "${LOCUST_NAMESPACE}"
    wait_for_deployment "locust-master" "${LOCUST_NAMESPACE}"
    
    # Wait extra to ensure old master endpoints are completely un-registered K8s-side
    sleep 10
    
    # 2. Restart Workers
    kubectl rollout restart deployment/locust-worker -n "${LOCUST_NAMESPACE}"
    wait_for_deployment "locust-worker" "${LOCUST_NAMESPACE}"
  fi
  info "Locust deployments are ready."

  # Re-establish port-forward to Locust master (old one is dead after restart)
  if [[ -n "${PORT_FORWARD_PID}" ]]; then
    kill "${PORT_FORWARD_PID}" 2>/dev/null || true
  fi
  kubectl port-forward svc/locust-master 8089:8089 -n "${LOCUST_NAMESPACE}" &>/dev/null &
  PORT_FORWARD_PID=$!
  info "New Locust port-forward PID: ${PORT_FORWARD_PID}"

  # Wait for port-forward to be reachable
  local attempt
  for attempt in $(seq 1 15); do
    if curl -sf "${LOCUST_MASTER_URL}/" &>/dev/null; then
      info "Locust master is reachable."
      break
    fi
    sleep 2
  done

  # Ensure workers are connected
  wait_for_locust_workers 60
}

print_grafana_link() {
  local duration_sec="${LOCUST_RUN_TIME%s}"

  # Count total individual locust runs across all experiments and rollouts
  local total_runs=0
  local rollout_count=0
  for idx in $(seq 0 $((NUM_EXPERIMENTS - 1))); do
    local e n_users n_cats extra_args exp_model
    e=$(echo "${EXPERIMENTS_JSON}" | jq -r ".[${idx}]")
    n_users=$(echo "${e}" | jq '.concurrency | length')
    n_cats=$(echo "${e}" | jq '.prompt_categories | length')
    exp_model=$(echo "${e}" | jq -r '.model // ""')
    extra_args=$(echo "${EXPERIMENTS_JSON}" | jq -r ".[${idx}].vllm_extra_args // \"\"")
    if [[ -n "${exp_model}" || -n "${extra_args}" ]]; then
      rollout_count=$(( rollout_count + 1 ))
    fi
    total_runs=$(( total_runs + n_users * n_cats ))
  done

  # Expected window: runs × (duration + cooldown) + rollouts + 2 min overhead buffer
  local total_sec=$(( total_runs * (duration_sec + COOLDOWN_SEC) + rollout_count * ROLLOUT_SEC + 120 ))

  local from_ms to_ms
  from_ms=$(python3 -c 'import time; print(int(time.time() * 1000))')
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

  # Save Grafana link to results directory for later reference
  if [[ -n "${RUN_DIR:-}" ]]; then
    echo "${url}" > "${RUN_DIR}/grafana_link.txt" || true
    log "Saved Grafana link to ${RUN_DIR}/grafana_link.txt"
  fi
}

# Called ONCE before the main loop to avoid repeating readiness checks per run.
ensure_locust_ready() {
  log "Waiting for Locust pods to be ready..."
  kubectl wait --for=condition=Ready pod -l app=locust \
    -n "${LOCUST_NAMESPACE}" --timeout=300s
  info "All Locust pods are Ready."

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
  log "Starting port-forward to Prometheus (monitoring-kube-prometheus-prometheus:9090)..."
  kubectl port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 -n monitoring &>/dev/null &
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
  local timeout_sec="$1"
  local attempts
  attempts=$(awk -v timeout="${timeout_sec}" 'BEGIN { a = int((timeout + 1) / 2); if (a < 1) a = 1; print a }')

  local attempt
  for attempt in $(seq 1 "${attempts}"); do
    local state
    state=$(curl -sf "${LOCUST_MASTER_URL}/stats/requests" 2>/dev/null \
              | jq -r '.state // "unknown"' 2>/dev/null || echo "unknown")
    if [[ "${state}" == "running" ]]; then
      info "Swarm is running."
      return 0
    fi
    info "Waiting for swarm to reach 'running' state (current: ${state}, attempt ${attempt}/${attempts})..."
    sleep 2
  done
  echo "ERROR: Locust swarm did not reach 'running' state within ${timeout_sec}s." >&2
  exit 1
}

parse_duration_seconds() {
  local value="$1"

  if [[ -z "${value}" ]]; then
    echo ""
    return 0
  fi

  if [[ "${value}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s' "${value}"
    return 0
  fi

  if [[ "${value}" =~ ^([0-9]+([.][0-9]+)?)([smh])$ ]]; then
    local num="${BASH_REMATCH[1]}"
    local unit="${BASH_REMATCH[3]}"
    case "${unit}" in
      s) awk -v n="${num}" 'BEGIN { printf "%.6f", n }' ;;
      m) awk -v n="${num}" 'BEGIN { printf "%.6f", n * 60 }' ;;
      h) awk -v n="${num}" 'BEGIN { printf "%.6f", n * 3600 }' ;;
    esac
    return 0
  fi

  echo "ERROR: Invalid duration '${value}'. Use a number or suffix s/m/h (e.g. 30, 30s, 1m)." >&2
  exit 1
}

compute_spawn_rate_from_time() {
  local users="$1"
  local spawn_time_sec="$2"

  awk -v u="${users}" -v t="${spawn_time_sec}" 'BEGIN {
    if (t <= 0) {
      print "ERROR"
      exit 0
    }
    r = u / t
    if (r <= 0) r = 0.0001
    printf "%.6f", r
  }'
}

run_locust() {
  local users="$1"
  local label="$2"
  local out_csv="$3"

  local spawn_time_sec=""
  spawn_time_sec=$(parse_duration_seconds "${SPAWN_TIME:-}")

  local effective_spawn_rate
  if [[ -n "${spawn_time_sec}" ]]; then
    effective_spawn_rate=$(compute_spawn_rate_from_time "${users}" "${spawn_time_sec}")
    if [[ "${effective_spawn_rate}" == "ERROR" ]]; then
      echo "ERROR: SPAWN_TIME must be greater than 0." >&2
      exit 1
    fi
  else
    # Default behavior: reach target users in about 1 second.
    effective_spawn_rate="${users}"
  fi

  # Wait at least 90s; extend based on estimated ramp-up duration.
  local ramp_time_sec
  ramp_time_sec=$(awk -v u="${users}" -v r="${effective_spawn_rate}" 'BEGIN { if (r <= 0) print 0; else printf "%.6f", u / r }')
  local swarm_wait_sec
  swarm_wait_sec=$(awk -v ramp="${ramp_time_sec}" 'BEGIN {
    t = int(ramp + 0.999999) + 90
    if (t < 90) t = 90
    print t
  }')

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
  wait_for_swarm_running "${swarm_wait_sec}"

  local duration_sec="${LOCUST_RUN_TIME%s}"
  info "Sleeping for ${duration_sec}s while cluster-Locust runs..."
  sleep "${duration_sec}"

  # Stop the swarm
  info "Stop signal sent. Waiting for graceful drain..."
  curl -sf -X GET "${LOCUST_MASTER_URL}/stop" > /dev/null \
    || { echo "ERROR: Failed to stop Locust swarm (GET /stop)." >&2; exit 1; }

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

  # Copy and merge per-request files from all worker pods.
  # Workers write their own shard on test_stop; we concatenate them locally.
  log "Copying per-request files from Locust worker pods..."
  sleep 10  # allow test_stop handlers on workers to finish writing

  local worker_pods
  worker_pods=$(kubectl get pod -n "${LOCUST_NAMESPACE}" \
    -l app=locust,role=worker \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

  if [[ -z "${worker_pods}" ]]; then
    info "WARNING: No worker pods found — skipping per-request file copy."
  else
    local first_worker=true
    local tmp_csv tmp_jsonl
    for pod in ${worker_pods}; do
      tmp_csv="${pod}_custom.csv"
      tmp_jsonl="${pod}_responses.jsonl"

      # Custom metrics CSV — first worker becomes the file, rest are appended (no header)
      if kubectl cp -n "${LOCUST_NAMESPACE}" "${pod}:${WORKER_ARTIFACTS_DIR}/locust_custom_metrics.csv" "${tmp_csv}"; then
        if [[ "${first_worker}" == "true" ]]; then
          mv "${tmp_csv}" "${out_csv}_custom_metrics.csv"
          first_worker=false
        else
          tail -n +2 "${tmp_csv}" >> "${out_csv}_custom_metrics.csv"
          rm -f "${tmp_csv}"
        fi
        info "Custom metrics copied from ${pod}."
      else
        info "WARNING: Could not fetch custom metrics from ${pod}."
      fi

      # Prompt/response JSONL — simply concatenate
      if kubectl cp -n "${LOCUST_NAMESPACE}" "${pod}:${WORKER_ARTIFACTS_DIR}/locust_responses.jsonl" "${tmp_jsonl}"; then
        cat "${tmp_jsonl}" >> "${out_csv}_prompt_responses.jsonl"
        rm -f "${tmp_jsonl}"
        info "Prompt/response log copied from ${pod}."
      else
        info "WARNING: Could not fetch prompt/response log from ${pod}."
      fi
    done
    [[ "${first_worker}" == "false" ]] \
      && info "Per-request files saved to $(dirname "${out_csv}")/" \
      || info "WARNING: No per-request data was collected from any worker."
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
    exp_model=$(echo "${exp}" | jq -r '.model // ""')
    extra_args=$(echo "${exp}" | jq -r '.vllm_extra_args // ""')

    if [[ "${extra_args}" =~ (^|[[:space:]])--model[[:space:]]+([^[:space:]]+) ]]; then
      legacy_model="${BASH_REMATCH[2]}"
      if [[ -z "${exp_model}" ]]; then
        exp_model="${legacy_model}"
      fi
      extra_args=$(echo "${extra_args}" | sed -E 's/(^|[[:space:]])--model[[:space:]]+[^[:space:]]+//g' | xargs || true)
    fi

    [[ -z "${extra_args}" ]] && extra_args="(none)"
    [[ -z "${exp_model}" ]] && exp_model="(default from YAML)"

    users_list=$(echo "${exp}" | jq -r '[.concurrency[]] | join(", ")')
    prompt_categories=$(echo "${exp}" | jq -r '[.prompt_categories[]] | join(", ")')
    log "[$((i+1))/${NUM_EXPERIMENTS}] ${exp_name}"
    info "model:             ${exp_model}"
    info "extra_args:        ${extra_args}"
    info "concurrency:       ${users_list}"
    info "run_time:          ${LOCUST_RUN_TIME}"
    info "spawn_time:        ${SPAWN_TIME:-(1s default via user_count)}"
    info "spawn_rate:        computed per user_count (users / spawn_time)"
    info "skip_patch:        ${SKIP_PATCH}"
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
  exp_model=$(echo "${exp}" | jq -r '.model // ""')
  extra_args=$(echo "${exp}" | jq -r '.vllm_extra_args // ""')

  # Backward-compat: convert legacy --model flag in extra args to positional model.
  if [[ "${extra_args}" =~ (^|[[:space:]])--model[[:space:]]+([^[:space:]]+) ]]; then
    legacy_model="${BASH_REMATCH[2]}"
    if [[ -z "${exp_model}" ]]; then
      exp_model="${legacy_model}"
    fi
    extra_args=$(echo "${extra_args}" | sed -E 's/(^|[[:space:]])--model[[:space:]]+[^[:space:]]+//g' | xargs || true)
  fi

  users_list=$(echo "${exp}" | jq -r '.concurrency[]')

  log ""
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "Experiment $((i+1))/${NUM_EXPERIMENTS}: ${exp_name}"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  EXP_DIR="${RUN_DIR}/${exp_name}"
  mkdir -p "${EXP_DIR}"

  # Save experiment config
  echo "${exp}" | jq '.' > "${EXP_DIR}/config.json"

  if [[ "${SKIP_PATCH}" == "true" ]]; then
    log "Skipping vLLM deployment patch for ${exp_name}; using current server args/config."
  else
    # Patch per experiment so overrides are deterministic.
    patch_vllm_args "${exp_model}" "${extra_args}"
  fi

  # Patch locust-config ConfigMap if experiment has configmap_overrides
  cm_overrides=$(echo "${exp}" | jq -r '.configmap_overrides // empty')
  if [[ -n "${cm_overrides}" ]]; then
    patch_locust_configmap "${cm_overrides}"
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
