#!/usr/bin/env bash
# =============================================================================
# fetch_metrics.sh — Fetch Prometheus metrics for a given time range and save
#                    to a single CSV file.
#
# Usage:
#   ./fetch_metrics.sh --start <epoch_sec> --end <epoch_sec> \
#                      --output <csv_file> \
#                      [--prometheus-url <url>] [--step <interval>]
#
# Queries all non-locust metrics displayed on the Grafana dashboard
# (dashboard.json) and writes them into a single CSV with format:
#   timestamp,metric_name,labels,value
#
# Requires: curl, jq
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
STEP="15s"
START=""
END=""
OUTPUT=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --start)          START="$2";          shift 2 ;;
    --end)            END="$2";            shift 2 ;;
    --output)         OUTPUT="$2";         shift 2 ;;
    --prometheus-url) PROMETHEUS_URL="$2"; shift 2 ;;
    --step)           STEP="$2";           shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "${START}" || -z "${END}" || -z "${OUTPUT}" ]]; then
  echo "ERROR: --start, --end, and --output are required." >&2
  exit 1
fi

log()  { echo "  [fetch_metrics] $*"; }

# ---------------------------------------------------------------------------
# Metric definitions — each entry is  "column_name|promql"
# Derived from dashboard.json panels 4–19 (non-locust panels).
# ---------------------------------------------------------------------------
METRICS=(
  # --- vLLM latency histograms (panels 4-7) ---
  'ttft_p50_ms|histogram_quantile(0.50, sum(rate(vllm:time_to_first_token_seconds_bucket[1m])) by (le)) * 1000'
  'ttft_p95_ms|histogram_quantile(0.95, sum(rate(vllm:time_to_first_token_seconds_bucket[1m])) by (le)) * 1000'
  'ttft_p99_ms|histogram_quantile(0.99, sum(rate(vllm:time_to_first_token_seconds_bucket[1m])) by (le)) * 1000'
  'itl_p50_ms|histogram_quantile(0.50, sum(rate(vllm:inter_token_latency_seconds_bucket[1m])) by (le)) * 1000'
  'itl_p95_ms|histogram_quantile(0.95, sum(rate(vllm:inter_token_latency_seconds_bucket[1m])) by (le)) * 1000'
  'itl_p99_ms|histogram_quantile(0.99, sum(rate(vllm:inter_token_latency_seconds_bucket[1m])) by (le)) * 1000'
  'e2e_p50_ms|histogram_quantile(0.50, sum(rate(vllm:e2e_request_latency_seconds_bucket[1m])) by (le)) * 1000'
  'e2e_p95_ms|histogram_quantile(0.95, sum(rate(vllm:e2e_request_latency_seconds_bucket[1m])) by (le)) * 1000'
  'e2e_p99_ms|histogram_quantile(0.99, sum(rate(vllm:e2e_request_latency_seconds_bucket[1m])) by (le)) * 1000'
  'tpot_p50_ms|histogram_quantile(0.50, sum(rate(vllm:request_time_per_output_token_seconds_bucket[1m])) by (le)) * 1000'
  'tpot_p95_ms|histogram_quantile(0.95, sum(rate(vllm:request_time_per_output_token_seconds_bucket[1m])) by (le)) * 1000'
  'tpot_p99_ms|histogram_quantile(0.99, sum(rate(vllm:request_time_per_output_token_seconds_bucket[1m])) by (le)) * 1000'

  # --- vLLM throughput (panels 8-9) ---
  'prompt_tokens_per_sec|sum(rate(vllm:prompt_tokens_total[1m]))'
  'generation_tokens_per_sec|sum(rate(vllm:generation_tokens_total[1m]))'

  # --- vLLM request success rate (panel 10) ---
  'request_success_per_sec|sum(rate(vllm:request_success_total[1m])) by (finished_reason)'

  # --- vLLM running & waiting requests (panel 11) ---
  'requests_running|sum(vllm:num_requests_running)'
  'requests_waiting|sum(vllm:num_requests_waiting)'

  # --- vLLM KV-Cache utilization (panel 12) ---
  'kv_cache_usage_pct|vllm:kv_cache_usage_perc'

  # --- vLLM preemptions (panel 13) ---
  'preemptions_per_sec|sum(rate(vllm:num_preemptions_total[1m]))'

  # --- vLLM prefix cache (panel 14) ---
  'prefix_cache_hits_per_sec|sum(rate(vllm:prefix_cache_hits_total[1m]))'
  'prefix_cache_queries_per_sec|sum(rate(vllm:prefix_cache_queries_total[1m]))'

  # --- GPU metrics (panels 15-16) ---
  'gpu_util_pct|avg(DCGM_FI_DEV_GPU_UTIL) by (gpu, modelName)'
  'gpu_fb_used_mib|avg(DCGM_FI_DEV_FB_USED) by (gpu, modelName)'

  # --- Container resource metrics (panels 17-18) ---
  'container_cpu_cores|sum(rate(container_cpu_usage_seconds_total{container!="", container!="POD"}[1m])) by (container, pod)'
  'container_mem_bytes|sum(container_memory_working_set_bytes{container!="", container!="POD"}) by (container, pod)'

  # --- Network I/O (panel 19) ---
  'net_rx_bytes_per_sec|sum(rate(container_network_receive_bytes_total{container!=""}[1m])) by (pod)'
  'net_tx_bytes_per_sec|sum(rate(container_network_transmit_bytes_total{container!=""}[1m])) by (pod)'
)

# ---------------------------------------------------------------------------
# query_prometheus  <metric_name> <promql>
#
# Queries Prometheus query_range API and appends rows to the output CSV.
# Each time series in the result produces rows with:
#   timestamp, metric_name, labels (key=val;...), value
# ---------------------------------------------------------------------------
query_prometheus() {
  local metric_name="$1"
  local promql="$2"

  local response
  response=$(curl -sf --retry 2 --retry-delay 3 \
    --data-urlencode "query=${promql}" \
    --data-urlencode "start=${START}" \
    --data-urlencode "end=${END}" \
    --data-urlencode "step=${STEP}" \
    "${PROMETHEUS_URL}/api/v1/query_range" 2>/dev/null) || {
    log "WARNING: Query failed for '${metric_name}', skipping."
    return 0
  }

  # Check if the response contains data
  local status
  status=$(echo "${response}" | jq -r '.status // "error"')
  if [[ "${status}" != "success" ]]; then
    log "WARNING: Prometheus returned status='${status}' for '${metric_name}', skipping."
    return 0
  fi

  # Extract and flatten: for each result series, build label string and output rows
  echo "${response}" | jq -r --arg name "${metric_name}" '
    .data.result[] |
    # Build semicolon-separated label string, excluding __name__
    ( .metric | to_entries | map(select(.key != "__name__")) |
      map(.key + "=" + .value) | join(";") ) as $labels |
    .values[] |
    [ (.[0] | tostring), $name, $labels, (.[1] | tostring) ] |
    @csv
  ' >> "${OUTPUT}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log "Fetching Prometheus metrics (start=${START}, end=${END}, step=${STEP})..."
log "Output: ${OUTPUT}"

# Write CSV header
echo 'timestamp,metric_name,labels,value' > "${OUTPUT}"

total=${#METRICS[@]}
count=0

for entry in "${METRICS[@]}"; do
  metric_name="${entry%%|*}"
  promql="${entry#*|}"
  count=$((count + 1))

  query_prometheus "${metric_name}" "${promql}"
done

# Count data rows (excluding header)
row_count=$(( $(wc -l < "${OUTPUT}") - 1 ))
log "Done. Wrote ${row_count} data rows across ${total} metrics to ${OUTPUT}"
