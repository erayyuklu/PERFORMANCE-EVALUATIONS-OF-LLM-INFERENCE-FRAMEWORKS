#!/usr/bin/env bash
# =============================================================================
# run_experiment.sh — Repeatable vLLM benchmark experiment runner
#                     (Lightning.ai / bare-metal version — no Kubernetes)
#
# Usage:
#   bash run_experiment.sh
#   bash run_experiment.sh --experiments ../benchmarking/experiments.json
#   bash run_experiment.sh --run-time 60s
#
# This is the Lightning.ai equivalent of benchmarking/run_experiment.sh.
# Instead of patching K8s deployments, it restarts the vLLM process with
# new arguments for each experiment configuration.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCHMARK_DIR="${SCRIPT_DIR}/../benchmarking"
source "${SCRIPT_DIR}/config.env"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
EXPERIMENTS_FILE="${BENCHMARK_DIR}/experiments.json"
VLLM_HOST="http://localhost:${PORT}"
RESULTS_BASE="${BENCHMARK_DIR}/results"
LOCUST_RUN_TIME="${LOCUST_RUN_TIME:-120s}"

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

restart_vllm() {
  local extra_args="$1"
  log "Restarting vLLM with extra args: ${extra_args}"
  # shellcheck disable=SC2086
  bash "${SCRIPT_DIR}/serve.sh" restart ${extra_args}
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

# ---------------------------------------------------------------------------
# Main experiment loop
# ---------------------------------------------------------------------------
RUN_ID="run_$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${RESULTS_BASE}/${RUN_ID}"
mkdir -p "${RUN_DIR}"

log "Run ID: ${RUN_ID}"
log "Results directory: ${RUN_DIR}"
log "Experiments file: ${EXPERIMENTS_FILE}"

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

  # Restart vLLM with new args (or start if not running)
  if [[ -n "${extra_args}" ]]; then
    restart_vllm "${extra_args}"
  else
    log "No extra args — using default vLLM config."
    # Make sure vLLM is running
    bash "${SCRIPT_DIR}/serve.sh" start
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
done

# Stop vLLM after all experiments
bash "${SCRIPT_DIR}/serve.sh" stop

log ""
log "═══════════════════════════════════════════════"
log "  ✅  All experiments complete!"
log "  Results: ${RUN_DIR}"
log "═══════════════════════════════════════════════"
log ""
log "  To analyze results, run:"
log "    jupyter notebook ${BENCHMARK_DIR}/analyze_results.ipynb"
log ""
