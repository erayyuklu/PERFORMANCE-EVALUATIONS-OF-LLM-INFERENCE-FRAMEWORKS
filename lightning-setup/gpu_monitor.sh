#!/usr/bin/env bash
# =============================================================================
# gpu_monitor.sh — Lightweight GPU & vLLM metrics collector
#
# Polls nvidia-smi and vLLM /metrics endpoint at a fixed interval and writes
# timestamped CSV files. Designed to run in the background during Locust tests
# on Lightning.ai Studio (single L4 GPU, no Prometheus/Grafana needed).
#
# Usage:
#   bash gpu_monitor.sh start <output_prefix> [--interval 2] [--vllm-port 8000]
#   bash gpu_monitor.sh stop
#   bash gpu_monitor.sh status
#
# Example:
#   bash gpu_monitor.sh start results/run_123/baseline/baseline__u4__all
#   # ... run locust test ...
#   bash gpu_monitor.sh stop
#
# Output files:
#   <prefix>_gpu_metrics.csv     — nvidia-smi data (GPU util, VRAM, power, temp)
#   <prefix>_vllm_metrics.csv    — vLLM /metrics data (KV cache, queue, throughput)
# =============================================================================
set -euo pipefail

PID_FILE="/tmp/gpu_monitor.pid"
DEFAULT_INTERVAL=2
DEFAULT_VLLM_PORT=8000

# ---------------------------------------------------------------------------
# nvidia-smi poller
# ---------------------------------------------------------------------------
poll_gpu() {
  local out_file="$1"
  local interval="$2"

  # Write CSV header
  echo "timestamp,gpu_utilization_pct,memory_used_mb,memory_total_mb,memory_utilization_pct,power_draw_w,temperature_c" \
    > "${out_file}"

  while true; do
    # nvidia-smi query: returns comma-separated values
    local raw
    raw=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,power.draw,temperature.gpu \
          --format=csv,noheader,nounits 2>/dev/null || echo ",,,,")

    # Parse values (trim whitespace)
    local gpu_util mem_used mem_total power temp
    IFS=',' read -r gpu_util mem_used mem_total power temp <<< "${raw}"
    gpu_util=$(echo "${gpu_util}" | xargs)
    mem_used=$(echo "${mem_used}" | xargs)
    mem_total=$(echo "${mem_total}" | xargs)
    power=$(echo "${power}" | xargs)
    temp=$(echo "${temp}" | xargs)

    # Calculate memory utilization percentage
    local mem_pct="0"
    if [[ -n "${mem_total}" && "${mem_total}" != "0" ]]; then
      mem_pct=$(awk "BEGIN {printf \"%.1f\", ${mem_used}/${mem_total}*100}")
    fi

    # ISO timestamp
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

    echo "${ts},${gpu_util},${mem_used},${mem_total},${mem_pct},${power},${temp}" \
      >> "${out_file}"

    sleep "${interval}"
  done
}

# ---------------------------------------------------------------------------
# vLLM /metrics poller (Prometheus text format parser)
# ---------------------------------------------------------------------------
poll_vllm() {
  local out_file="$1"
  local interval="$2"
  local port="$3"
  local metrics_url="http://localhost:${port}/metrics"

  # Write CSV header
  echo "timestamp,num_requests_running,num_requests_waiting,gpu_cache_usage_pct,cpu_cache_usage_pct,avg_prompt_throughput_toks_per_s,avg_generation_throughput_toks_per_s" \
    > "${out_file}"

  while true; do
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Fetch metrics from vLLM (Prometheus text exposition format)
    local raw
    raw=$(curl -sf "${metrics_url}" 2>/dev/null || echo "")

    if [[ -z "${raw}" ]]; then
      echo "${ts},,,,,,," >> "${out_file}"
      sleep "${interval}"
      continue
    fi

    # Parse specific metrics from Prometheus text format
    # Each metric line looks like: metric_name{labels} value
    # or: metric_name value
    local requests_running requests_waiting gpu_cache cpu_cache prompt_tput gen_tput

    requests_running=$(echo "${raw}" | grep -E '^vllm:num_requests_running\b' | grep -v '^#' | awk '{print $NF}' | tail -1)
    requests_waiting=$(echo "${raw}" | grep -E '^vllm:num_requests_waiting\b' | grep -v '^#' | awk '{print $NF}' | tail -1)
    gpu_cache=$(echo "${raw}" | grep -E '^vllm:gpu_cache_usage_perc\b' | grep -v '^#' | awk '{print $NF}' | tail -1)
    cpu_cache=$(echo "${raw}" | grep -E '^vllm:cpu_cache_usage_perc\b' | grep -v '^#' | awk '{print $NF}' | tail -1)
    prompt_tput=$(echo "${raw}" | grep -E '^vllm:avg_prompt_throughput_toks_per_s\b' | grep -v '^#' | awk '{print $NF}' | tail -1)
    gen_tput=$(echo "${raw}" | grep -E '^vllm:avg_generation_throughput_toks_per_s\b' | grep -v '^#' | awk '{print $NF}' | tail -1)

    # Convert gpu_cache from 0-1 fraction to percentage
    if [[ -n "${gpu_cache}" ]]; then
      gpu_cache=$(awk "BEGIN {printf \"%.2f\", ${gpu_cache} * 100}")
    fi
    if [[ -n "${cpu_cache}" ]]; then
      cpu_cache=$(awk "BEGIN {printf \"%.2f\", ${cpu_cache} * 100}")
    fi

    echo "${ts},${requests_running:-},${requests_waiting:-},${gpu_cache:-},${cpu_cache:-},${prompt_tput:-},${gen_tput:-}" \
      >> "${out_file}"

    sleep "${interval}"
  done
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_start() {
  if [[ -f "${PID_FILE}" ]] && kill -0 "$(cat ${PID_FILE} 2>/dev/null)" 2>/dev/null; then
    echo "[gpu_monitor] Already running (PID: $(cat ${PID_FILE})). Stop first."
    return 1
  fi

  local output_prefix=""
  local interval="${DEFAULT_INTERVAL}"
  local vllm_port="${DEFAULT_VLLM_PORT}"

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --interval)   interval="$2";   shift 2 ;;
      --vllm-port)  vllm_port="$2";  shift 2 ;;
      *)
        if [[ -z "${output_prefix}" ]]; then
          output_prefix="$1"; shift
        else
          echo "Unknown argument: $1"; exit 1
        fi
        ;;
    esac
  done

  if [[ -z "${output_prefix}" ]]; then
    echo "Usage: bash gpu_monitor.sh start <output_prefix> [--interval N] [--vllm-port PORT]"
    exit 1
  fi

  # Ensure output directory exists
  mkdir -p "$(dirname "${output_prefix}")"

  local gpu_csv="${output_prefix}_gpu_metrics.csv"
  local vllm_csv="${output_prefix}_vllm_metrics.csv"

  echo "[gpu_monitor] Starting GPU & vLLM metrics collection..."
  echo "[gpu_monitor]   Interval:    ${interval}s"
  echo "[gpu_monitor]   GPU CSV:     ${gpu_csv}"
  echo "[gpu_monitor]   vLLM CSV:    ${vllm_csv}"
  echo "[gpu_monitor]   vLLM port:   ${vllm_port}"

  # Launch both pollers as background processes
  poll_gpu  "${gpu_csv}"  "${interval}" &
  local gpu_pid=$!

  poll_vllm "${vllm_csv}" "${interval}" "${vllm_port}" &
  local vllm_pid=$!

  # Store both PIDs (main PID = this subshell, but we need individual PIDs)
  echo "${gpu_pid} ${vllm_pid}" > "${PID_FILE}"

  echo "[gpu_monitor] Running (GPU PID: ${gpu_pid}, vLLM PID: ${vllm_pid})"
}

cmd_stop() {
  if [[ ! -f "${PID_FILE}" ]]; then
    echo "[gpu_monitor] Not running."
    return 0
  fi

  local pids
  pids=$(cat "${PID_FILE}")
  echo "[gpu_monitor] Stopping monitors (PIDs: ${pids})..."

  for pid in ${pids}; do
    kill "${pid}" 2>/dev/null || true
  done

  # Wait briefly for graceful shutdown
  sleep 1
  for pid in ${pids}; do
    kill -9 "${pid}" 2>/dev/null || true
  done

  rm -f "${PID_FILE}"
  echo "[gpu_monitor] Stopped."
}

cmd_status() {
  if [[ ! -f "${PID_FILE}" ]]; then
    echo "[gpu_monitor] Not running."
    return 0
  fi

  local pids
  pids=$(cat "${PID_FILE}")
  local running=0
  for pid in ${pids}; do
    if kill -0 "${pid}" 2>/dev/null; then
      running=$((running + 1))
    fi
  done

  if [[ ${running} -gt 0 ]]; then
    echo "[gpu_monitor] Running (${running} poller(s) active, PIDs: ${pids})"
  else
    echo "[gpu_monitor] PID file exists but processes are dead. Cleaning up."
    rm -f "${PID_FILE}"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
ACTION="${1:-}"
shift || true

case "${ACTION}" in
  start)  cmd_start "$@" ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  *)
    echo "Usage: bash gpu_monitor.sh {start|stop|status} [args...]"
    echo ""
    echo "Commands:"
    echo "  start <output_prefix> [--interval 2] [--vllm-port 8000]"
    echo "  stop"
    echo "  status"
    exit 1
    ;;
esac
