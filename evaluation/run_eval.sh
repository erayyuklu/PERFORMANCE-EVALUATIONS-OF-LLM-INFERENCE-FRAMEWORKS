#!/usr/bin/env bash
# =============================================================================
# run_eval.sh — Run lm-evaluation-harness against a vLLM deployment on GKE
#
#   Usage:
#     ./run_eval.sh                     # run all tasks from config.env
#     ./run_eval.sh --tasks gsm8k       # override tasks
#     ./run_eval.sh --num_fewshot 0     # override few-shot count
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"
source "${SCRIPT_DIR}/../vllm/secrets.env"

# ── Helpers ──────────────────────────────────────────────────────────────────

log()  { printf '%s  [INFO]  %s\n' "$(date '+%H:%M:%S')" "$*"; }
err()  { printf '%s  [ERROR] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { err "$@"; exit 1; }

# ── CLI overrides ────────────────────────────────────────────────────────────
# Allow overriding config.env values via --key value pairs.

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tasks)         TASKS="$2";         shift 2 ;;
    --num_fewshot)   NUM_FEWSHOT="$2";   shift 2 ;;
    --batch_size)    BATCH_SIZE="$2";    shift 2 ;;
    --num_concurrent) NUM_CONCURRENT="$2"; shift 2 ;;
    --max_gen_toks|--max_tokens) MAX_GEN_TOKS="$2"; shift 2 ;;
    --enable_thinking) ENABLE_THINKING="$2"; shift 2 ;;
    --output_dir)    OUTPUT_DIR="$2";    shift 2 ;;
    --limit)         LIMIT=$2;           shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# Default to final-answer-only mode for reasoning models where reasoning is
# emitted separately from content (e.g., reasoning_content in vLLM).
ENABLE_THINKING="${ENABLE_THINKING:-false}"
# Raise generation budget above lm-eval default (256) to avoid truncating answers.
MAX_GEN_TOKS="${MAX_GEN_TOKS:-4096}"

# ── Discover vLLM endpoint via kubectl ───────────────────────────────────────

log "Discovering vLLM service endpoint in namespace '${K8S_NAMESPACE}'..."

SERVICE_NAME=$(kubectl get svc -n "${K8S_NAMESPACE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) \
    || die "Could not list services in namespace '${K8S_NAMESPACE}'. Is kubectl configured?"

EXTERNAL_IP=$(kubectl get svc "${SERVICE_NAME}" -n "${K8S_NAMESPACE}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

if [[ -z "${EXTERNAL_IP}" ]]; then
    die "No external IP assigned to '${SERVICE_NAME}' in namespace '${K8S_NAMESPACE}'.
  Ensure the LoadBalancer is ready:  kubectl get svc ${SERVICE_NAME} -n ${K8S_NAMESPACE}"
fi

SERVICE_PORT=$(kubectl get svc "${SERVICE_NAME}" -n "${K8S_NAMESPACE}" \
    -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)

VLLM_BASE_URL="http://${EXTERNAL_IP}:${SERVICE_PORT}"
log "vLLM endpoint: ${VLLM_BASE_URL}"

# ── Health check ─────────────────────────────────────────────────────────────

log "Checking vLLM health (GET /v1/models)..."
if ! MODELS_RESPONSE=$(curl -sf --max-time 10 "${VLLM_BASE_URL}/v1/models"); then
    die "Health check failed — cannot reach ${VLLM_BASE_URL}/v1/models"
fi

SERVED_MODEL=$(echo "${MODELS_RESPONSE}" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
if [[ -z "${SERVED_MODEL}" ]]; then
    die "Could not parse model name from /v1/models response."
fi
log "Served model detected: ${SERVED_MODEL}"

# Verify the served model matches config
if [[ "${SERVED_MODEL}" != "${MODEL_NAME}" ]]; then
    log "WARNING: Served model '${SERVED_MODEL}' differs from MODEL_NAME '${MODEL_NAME}' in config."
    log "Using served model name '${SERVED_MODEL}' for evaluation."
    MODEL_NAME="${SERVED_MODEL}"
fi

# ── Prepare output directory ─────────────────────────────────────────────────

RUN_TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
RUN_DIR="${SCRIPT_DIR}/${OUTPUT_DIR}/run_${RUN_TIMESTAMP}"
mkdir -p "${RUN_DIR}"
log "Results will be saved to: ${RUN_DIR}"

# Save run metadata
cat > "${RUN_DIR}/eval_config.json" <<EOF
{
  "timestamp": "${RUN_TIMESTAMP}",
  "model": "${MODEL_NAME}",
  "vllm_endpoint": "${VLLM_BASE_URL}",
  "tasks": "${TASKS}",
  "num_fewshot": ${NUM_FEWSHOT},
  "batch_size": "${BATCH_SIZE}",
  "num_concurrent": ${NUM_CONCURRENT},
  "enable_thinking": ${ENABLE_THINKING},
  "max_gen_toks": ${MAX_GEN_TOKS}
}
EOF

# ── Run lm-eval ──────────────────────────────────────────────────────────────

log "Starting lm-eval evaluation..."
log "  Model      : ${MODEL_NAME}"
log "  Tasks      : ${TASKS}"
log "  Few-shot   : ${NUM_FEWSHOT}"
log "  Batch size : ${BATCH_SIZE}"
log "  Max tokens : ${MAX_GEN_TOKS}"
log "  Thinking   : ${ENABLE_THINKING}"
LIMIT_ARG=""
if [[ -n "${LIMIT:-}" ]]; then
    LIMIT_ARG="--limit ${LIMIT}"
    log "  Limit      : ${LIMIT}"
fi
log ""

GEN_KWARGS_JSON="{\"max_gen_toks\":${MAX_GEN_TOKS},\"chat_template_kwargs\":{\"enable_thinking\":${ENABLE_THINKING}}}"
GEN_KWARGS_ARGS=(
  --gen_kwargs "${GEN_KWARGS_JSON}"
)

if [[ -n "${HF_TOKEN:-}" ]]; then
    export HF_TOKEN="${HF_TOKEN}"
fi

OPENAI_API_KEY="EMPTY" \
python -m lm_eval --model local-chat-completions \
  --model_args "model=${MODEL_NAME},base_url=${VLLM_BASE_URL}/v1/chat/completions,num_concurrent=${NUM_CONCURRENT},tokenized_requests=False" \
  "${GEN_KWARGS_ARGS[@]}" \
  --tasks "${TASKS}" \
  --num_fewshot "${NUM_FEWSHOT}" \
  --batch_size "${BATCH_SIZE}" \
  --output_path "${RUN_DIR}" \
  ${LIMIT_ARG} \
  --log_samples \
  --apply_chat_template

EXIT_CODE=$?

if [[ ${EXIT_CODE} -eq 0 ]]; then
    log "Evaluation completed successfully!"
    log "Results saved to: ${RUN_DIR}"
else
    err "Evaluation failed with exit code ${EXIT_CODE}."
fi

exit ${EXIT_CODE}
