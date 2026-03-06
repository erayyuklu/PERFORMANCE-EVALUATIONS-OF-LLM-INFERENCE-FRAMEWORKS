#!/usr/bin/env bash
# =============================================================================
# run_experiment.sh — Repeatable vLLM benchmark experiment runner
#                     (Lightning.ai / bare-metal version — no Kubernetes)
#
# Usage:
#   bash run_experiment.sh
#   bash run_experiment.sh --experiments ../benchmarking/experiments.json
#   bash run_experiment.sh --run-time 90s
#   bash run_experiment.sh --experiment baseline   # run only one experiment
#
# This is the Lightning.ai equivalent of benchmarking/run_experiment.sh.
# Instead of patching K8s deployments, it restarts the vLLM process with
# new arguments for each experiment configuration.
#
# For each sub-test, this script:
#   1. (Re)starts vLLM with the experiment's extra args
#   2. Starts GPU & vLLM metric monitoring in the background
#   3. Runs the Locust load test
#   4. Stops the GPU monitor
#   5. Saves all CSVs (Locust + GPU + vLLM metrics) under results/<run_id>/
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCHMARK_DIR="${SCRIPT_DIR}/../benchmarking"
source "${SCRIPT_DIR}/config.env"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
EXPERIMENTS_FILE="${BENCHMARK_DIR}/experiments.json"
EXPERIMENT_NAME=""                              # if set, run only this one
VLLM_HOST="http://localhost:${PORT}"
RESULTS_BASE="${BENCHMARK_DIR}/results"
LOCUST_RUN_TIME="${LOCUST_RUN_TIME:-90s}"
GPU_MONITOR_INTERVAL=2                          # seconds between GPU polls
OUTPUT_DIR=""                                   # if set, reuse this run dir
SKIP_EXISTING=false                              # skip experiments with results
DATASET_OVERRIDE=""                              # global dataset path override

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --experiments)       EXPERIMENTS_FILE="$2";       shift 2 ;;
    --experiment)        EXPERIMENT_NAME="$2";        shift 2 ;;
    --host)              VLLM_HOST="$2";              shift 2 ;;
    --run-time)          LOCUST_RUN_TIME="$2";        shift 2 ;;
    --monitor-interval)  GPU_MONITOR_INTERVAL="$2";   shift 2 ;;
    --output-dir)        OUTPUT_DIR="$2";            shift 2 ;;
    --skip-existing)     SKIP_EXISTING=true;           shift ;;
    --dataset)           DATASET_OVERRIDE="$2";       shift 2 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "==> $*"; }
info() { echo "    $*"; }

restart_vllm() {
  local extra_args="$1"
  log "Restarting vLLM with extra args: ${extra_args}"
  # shellcheck disable=SC2086
  bash "${SCRIPT_DIR}/serve.sh" restart ${extra_args}
}

start_gpu_monitor() {
  local out_prefix="$1"
  bash "${SCRIPT_DIR}/gpu_monitor.sh" start "${out_prefix}" \
    --interval "${GPU_MONITOR_INTERVAL}" \
    --vllm-port "${PORT}"
}

stop_gpu_monitor() {
  bash "${SCRIPT_DIR}/gpu_monitor.sh" stop
}

run_locust() {
  local users="$1"
  local label="$2"
  local out_csv="$3"
  local prompt_len="${4:-all}"

  local dataset="${5:-}"

  log "Running Locust: users=${users}, prompt_len=${prompt_len}, label=${label}"
  if [[ -n "${dataset}" ]]; then
    info "Dataset: ${dataset}"
    export VLLM_DATASET="${dataset}"
  else
    unset VLLM_DATASET 2>/dev/null || true
  fi
  VLLM_PROMPT_LEN="${prompt_len}" \
  CUSTOM_CSV_PREFIX="${out_csv}" \
  locust \
    -f "${BENCHMARK_DIR}/locustfile.py" \
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
# Time estimation
# ---------------------------------------------------------------------------
estimate_total_time() {
  local experiments_json="$1"
  local num_exp
  num_exp=$(echo "${experiments_json}" | jq '. | length')

  local total_sub_tests=0
  for i in $(seq 0 $((num_exp - 1))); do
    local n_conc n_cats
    n_conc=$(echo "${experiments_json}" | jq -r ".[$i].concurrency | length")
    n_cats=$(echo "${experiments_json}" | jq -r ".[$i].prompt_categories | length")
    total_sub_tests=$((total_sub_tests + n_conc * n_cats))
  done

  local run_secs="${LOCUST_RUN_TIME%s}"
  local locust_time=$((total_sub_tests * run_secs))
  local cooldown_time=$((total_sub_tests * 5))
  local restart_time=$((num_exp * 180))  # worst case: 3 min per restart
  local total_secs=$((locust_time + cooldown_time + restart_time))
  local total_mins=$(( (total_secs + 59) / 60 ))

  echo ""
  log "Time Estimate"
  info "Experiments:   ${num_exp}"
  info "Sub-tests:     ${total_sub_tests}"
  info "Run time each: ${LOCUST_RUN_TIME}"
  info "Locust total:  $((locust_time / 60)) min"
  info "Restarts:      ~$((restart_time / 60)) min (worst case)"
  info "Cooldowns:     ~$((cooldown_time / 60)) min"
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info "Estimated total: ~${total_mins} min"
  echo ""
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if ! command -v locust &> /dev/null; then
  echo "ERROR: locust not found. Run: bash setup.sh"
  exit 1
fi

if ! command -v jq &> /dev/null; then
  echo "ERROR: jq not found. Run: sudo apt-get install -y jq"
  exit 1
fi

if ! command -v nvidia-smi &> /dev/null; then
  echo "WARNING: nvidia-smi not found. GPU metrics will be empty."
fi

# ---------------------------------------------------------------------------
# Load experiments (optionally filter to one)
# ---------------------------------------------------------------------------
if [[ -n "${EXPERIMENT_NAME}" ]]; then
  EXPERIMENTS_JSON=$(jq --arg name "${EXPERIMENT_NAME}" \
    '[.[] | select(.name == $name)]' "${EXPERIMENTS_FILE}")
  if [[ "$(echo "${EXPERIMENTS_JSON}" | jq '. | length')" -eq 0 ]]; then
    echo "ERROR: No experiment named '${EXPERIMENT_NAME}' in ${EXPERIMENTS_FILE}" >&2
    exit 1
  fi
  log "Filtering to experiment: ${EXPERIMENT_NAME}"
else
  EXPERIMENTS_JSON=$(cat "${EXPERIMENTS_FILE}")
fi

# ---------------------------------------------------------------------------
# Main experiment loop
# ---------------------------------------------------------------------------
if [[ -n "${OUTPUT_DIR}" ]]; then
  RUN_DIR="${OUTPUT_DIR}"
  RUN_ID="$(basename "${RUN_DIR}")"
else
  RUN_ID="run_$(date +%Y%m%d_%H%M%S)"
  RUN_DIR="${RESULTS_BASE}/${RUN_ID}"
fi
mkdir -p "${RUN_DIR}"

log "Run ID: ${RUN_ID}"
log "Results directory: ${RUN_DIR}"
log "Experiments file: ${EXPERIMENTS_FILE}"
log "Locust run time: ${LOCUST_RUN_TIME}"

NUM_EXPERIMENTS=$(echo "${EXPERIMENTS_JSON}" | jq '. | length')
log "Total experiments: ${NUM_EXPERIMENTS}"

estimate_total_time "${EXPERIMENTS_JSON}"

# Track overall timing
OVERALL_START=$(date +%s)

for i in $(seq 0 $((NUM_EXPERIMENTS - 1))); do
  exp=$(echo "${EXPERIMENTS_JSON}" | jq -r ".[$i]")
  exp_name=$(echo "${exp}" | jq -r '.name')
  exp_desc=$(echo "${exp}" | jq -r '.description')
  extra_args=$(echo "${exp}" | jq -r '.vllm_extra_args // ""')
  users_list=$(echo "${exp}" | jq -r '.concurrency[]')
  prompt_categories=$(echo "${exp}" | jq -r '.prompt_categories[]')

  log ""
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "Experiment $((i+1))/${NUM_EXPERIMENTS}: ${exp_name}"
  log "  ${exp_desc}"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  EXP_DIR="${RUN_DIR}/${exp_name}"
  mkdir -p "${EXP_DIR}"

  # Skip if results already exist and --skip-existing is set
  if [[ "${SKIP_EXISTING}" == "true" ]]; then
    existing_csvs=$(find "${EXP_DIR}" -name '*_custom_metrics.csv' -size +0c 2>/dev/null | wc -l)
    expected_csvs=$(echo "${exp}" | jq '[.concurrency[], .prompt_categories[]] | length / 2' | bc 2>/dev/null || echo 0)
    if [[ ${existing_csvs} -gt 0 ]]; then
      log "Skipping ${exp_name} — already has ${existing_csvs} result(s) (--skip-existing)"
      continue
    fi
  fi

  # Save experiment config
  echo "${exp}" | jq '.' > "${EXP_DIR}/config.json"

  # Restart vLLM with new args (or start if not running)
  if [[ -n "${extra_args}" ]]; then
    if ! restart_vllm "${extra_args}"; then
      log "⚠ vLLM failed to start for ${exp_name} — skipping this experiment."
      info "Check /tmp/vllm_serve.log for details."
      continue
    fi
  else
    log "No extra args — using default vLLM config."
    if ! bash "${SCRIPT_DIR}/serve.sh" start; then
      log "⚠ vLLM failed to start for ${exp_name} — skipping this experiment."
      continue
    fi
  fi

  for prompt_cat in ${prompt_categories}; do
    for users in ${users_list}; do
      label="${exp_name}__u${users}__${prompt_cat}"
      out_prefix="${EXP_DIR}/${label}"

      log ""
      log "▶ Sub-test: ${label}"
      info "Users: ${users} | Prompts: ${prompt_cat} | Duration: ${LOCUST_RUN_TIME}"

      # 1) Start GPU + vLLM monitoring in background
      start_gpu_monitor "${out_prefix}"

      # 2) Run Locust load test (blocking)
      # Resolve dataset: per-experiment > global override > default
      dataset_path=""
      exp_dataset=$(echo "${exp}" | jq -r '.dataset // ""')
      if [[ -n "${exp_dataset}" ]]; then
        dataset_path="${BENCHMARK_DIR}/${exp_dataset}"
      elif [[ -n "${DATASET_OVERRIDE}" ]]; then
        dataset_path="${DATASET_OVERRIDE}"
      fi

      run_locust "${users}" "${label}" "${out_prefix}" "${prompt_cat}" "${dataset_path}"

      # 3) Stop GPU monitoring
      stop_gpu_monitor

      info "✓ Done: ${label}"
      info "  Files:"
      info "    Locust:  ${out_prefix}_custom_metrics.csv"
      info "    GPU:     ${out_prefix}_gpu_metrics.csv"
      info "    vLLM:    ${out_prefix}_vllm_metrics.csv"

      # Brief cooldown between runs
      sleep 5
    done
  done
done

# Stop vLLM after all experiments
bash "${SCRIPT_DIR}/serve.sh" stop

# Calculate total elapsed time
OVERALL_END=$(date +%s)
ELAPSED_MIN=$(( (OVERALL_END - OVERALL_START) / 60 ))
ELAPSED_SEC=$(( (OVERALL_END - OVERALL_START) % 60 ))

log ""
log "═══════════════════════════════════════════════"
log "  All experiments complete!"
log "  Results: ${RUN_DIR}"
log "  Total time: ${ELAPSED_MIN}m ${ELAPSED_SEC}s"
log "═══════════════════════════════════════════════"
log ""
log "  Each sub-test directory contains:"
log "    *_custom_metrics.csv  — Locust per-request data (TTFT, TPOT, ITL, E2E)"
log "    *_gpu_metrics.csv     — nvidia-smi time series (GPU util, VRAM, power, temp)"
log "    *_vllm_metrics.csv    — vLLM /metrics time series (KV cache, queue, throughput)"
log ""
log "  To analyze results, run:"
log "    jupyter notebook ${BENCHMARK_DIR}/analyze_results.ipynb"
log ""
