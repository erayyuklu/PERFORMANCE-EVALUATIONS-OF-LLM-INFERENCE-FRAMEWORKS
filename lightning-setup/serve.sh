#!/usr/bin/env bash
# =============================================================================
# serve.sh — Start / Stop / Restart the vLLM server
#
# Usage:
#   bash serve.sh start                       # default config
#   bash serve.sh start --gpu-memory-utilization 0.95   # override args
#   bash serve.sh stop
#   bash serve.sh restart
#   bash serve.sh restart --enable-chunked-prefill      # restart with new args
#   bash serve.sh status
#   bash serve.sh logs
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

VLLM_PID_FILE="/tmp/vllm_serve.pid"
VLLM_LOG_FILE="/tmp/vllm_serve.log"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_is_running() {
  if [ -f "${VLLM_PID_FILE}" ]; then
    local pid
    pid=$(cat "${VLLM_PID_FILE}")
    if kill -0 "${pid}" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

_wait_for_health() {
  local url="http://localhost:${PORT}/health"
  local max_wait=300  # 5 minutes (model download can take a while)
  local waited=0
  echo "    Waiting for vLLM to be ready (this may take a few minutes on first run)..."
  while [ ${waited} -lt ${max_wait} ]; do
    if curl -sf "${url}" > /dev/null 2>&1; then
      echo "    ✓ vLLM is healthy and ready on port ${PORT}"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
    if [ $((waited % 30)) -eq 0 ]; then
      echo "    ... still waiting (${waited}s elapsed)"
    fi
  done
  echo "    ✗ vLLM did not become healthy within ${max_wait}s"
  echo "    Check logs: bash serve.sh logs"
  return 1
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_start() {
  if _is_running; then
    echo "vLLM is already running (PID: $(cat ${VLLM_PID_FILE}))"
    return 0
  fi

  local extra_args=("$@")

  echo "==> Starting vLLM server..."
  echo "    Model:  ${MODEL}"
  echo "    Port:   ${PORT}"
  if [ ${#extra_args[@]} -gt 0 ]; then
    echo "    Extra:  ${extra_args[*]}"
  fi

  nohup vllm serve "${MODEL}" \
    --port "${PORT}" \
    --max-model-len "${MAX_MODEL_LEN}" \
    --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION}" \
    --dtype "${DTYPE}" \
    --tensor-parallel-size "${TENSOR_PARALLEL_SIZE}" \
    "${extra_args[@]}" \
    > "${VLLM_LOG_FILE}" 2>&1 &

  echo $! > "${VLLM_PID_FILE}"
  echo "    PID: $(cat ${VLLM_PID_FILE})"

  _wait_for_health
}

cmd_stop() {
  if ! _is_running; then
    echo "vLLM is not running."
    rm -f "${VLLM_PID_FILE}"
    return 0
  fi

  local pid
  pid=$(cat "${VLLM_PID_FILE}")
  echo "==> Stopping vLLM (PID: ${pid})..."
  kill "${pid}" 2>/dev/null || true

  # Wait for graceful shutdown
  local waited=0
  while kill -0 "${pid}" 2>/dev/null && [ ${waited} -lt 15 ]; do
    sleep 1
    waited=$((waited + 1))
  done

  # Force kill if still running
  if kill -0 "${pid}" 2>/dev/null; then
    echo "    Force killing..."
    kill -9 "${pid}" 2>/dev/null || true
  fi

  rm -f "${VLLM_PID_FILE}"
  echo "    ✓ vLLM stopped."
}

cmd_restart() {
  cmd_stop
  sleep 2
  cmd_start "$@"
}

cmd_status() {
  if _is_running; then
    local pid
    pid=$(cat "${VLLM_PID_FILE}")
    echo "vLLM is running (PID: ${pid})"
    echo ""
    # Quick health check
    if curl -sf "http://localhost:${PORT}/health" > /dev/null 2>&1; then
      echo "  Health:  ✓ OK"
    else
      echo "  Health:  ✗ Not responding"
    fi
    # Show model info
    local models
    models=$(curl -sf "http://localhost:${PORT}/v1/models" 2>/dev/null || echo "")
    if [ -n "${models}" ]; then
      echo "  Models:  $(echo "${models}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(', '.join(m['id'] for m in d['data']))" 2>/dev/null || echo 'N/A')"
    fi
  else
    echo "vLLM is not running."
  fi
}

cmd_logs() {
  if [ -f "${VLLM_LOG_FILE}" ]; then
    tail -f "${VLLM_LOG_FILE}"
  else
    echo "No log file found."
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
ACTION="${1:-}"
shift || true

case "${ACTION}" in
  start)   cmd_start "$@" ;;
  stop)    cmd_stop ;;
  restart) cmd_restart "$@" ;;
  status)  cmd_status ;;
  logs)    cmd_logs ;;
  *)
    echo "Usage: bash serve.sh {start|stop|restart|status|logs} [extra vllm args...]"
    echo ""
    echo "Examples:"
    echo "  bash serve.sh start"
    echo "  bash serve.sh start --gpu-memory-utilization 0.95"
    echo "  bash serve.sh restart --enable-chunked-prefill"
    echo "  bash serve.sh status"
    echo "  bash serve.sh logs"
    exit 1
    ;;
esac
