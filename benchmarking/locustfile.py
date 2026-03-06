"""
vLLM Benchmark — Locust Load Test
==================================
Measures TTFT, TPOT, ITL, and E2E latency for every request
against the vLLM OpenAI-compatible /v1/chat/completions endpoint.

Usage (local):
    locust -f locustfile.py --host http://localhost:8000 --headless \
           -u 1 -r 1 --run-time 60s \
           --csv results/single_user

Usage (in-cluster, from the Locust master pod):
    The host is set via LOCUST_HOST env var (automatically wired from the
    ConfigMap to http://vllm-service.vllm.svc.cluster.local).
    Prometheus metrics are served on :9646 by locust-plugins PrometheusListener
    and scraped by kube-prometheus-stack via the locust ServiceMonitor.

Environment variables:
    VLLM_MODEL_NAME        — model identifier sent in the request body (default: see below)
    VLLM_MAX_TOKENS        — max tokens to generate per request (default: 256)
    VLLM_DATASET           — path to prompt JSON dataset (default: prompts/dataset.json)
    VLLM_PROMPT_LEN        — filter by prompt category: short | medium | long | all (default: all)
    LOCUST_PROMETHEUS_PORT — port for the Prometheus /metrics endpoint (default: 9646)
"""

import json
import os
import random
import time
from pathlib import Path

import sseclient
from locust import HttpUser, between, events, task
from locust.runners import MasterRunner, WorkerRunner

# prometheus_client for built-in metrics export (replaces locust-plugins)
try:
    from prometheus_client import (
        CollectorRegistry, Counter, Gauge,
        start_http_server as _prom_start_http_server,
    )
    _HAS_PROM_CLIENT = True
except ImportError:
    _HAS_PROM_CLIENT = False

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
MODEL_NAME  = os.getenv("VLLM_MODEL_NAME", "deepseek-ai/DeepSeek-R1-Distill-Qwen-7B")
MAX_TOKENS  = int(os.getenv("VLLM_MAX_TOKENS", "256"))
DATASET_PATH = Path(os.getenv("VLLM_DATASET", Path(__file__).parent / "prompts" / "dataset.json"))
PROMPT_LEN  = os.getenv("VLLM_PROMPT_LEN", "all")   # short | medium | long | all
CSV_PREFIX  = os.getenv("CUSTOM_CSV_PREFIX", "")      # set by run_experiment.sh
PROMETHEUS_PORT = int(os.getenv("LOCUST_PROMETHEUS_PORT", "9646"))

# Aggregated custom metrics — written to CSV at end of test
_custom_rows: list[dict] = []


# ---------------------------------------------------------------------------
# Prometheus metrics export (built-in, no locust-plugins dependency)
# ---------------------------------------------------------------------------
_prom_registry = CollectorRegistry() if _HAS_PROM_CLIENT else None

if _HAS_PROM_CLIENT:
    _prom_users = Gauge(
        "locust_users", "Current number of active Locust users",
        registry=_prom_registry,
    )
    _prom_fail_ratio = Gauge(
        "locust_fail_ratio", "Current failure ratio (0-1)",
        registry=_prom_registry,
    )
    _prom_requests_total = Counter(
        "locust_requests_total", "Total number of completed Locust requests",
        labelnames=["result"],
        registry=_prom_registry,
    )


@events.init.add_listener
def _on_locust_init(environment, **kwargs):
    """
    Start a lightweight Prometheus /metrics server on the master (or standalone)
    process. Workers don't expose Prometheus; they send stats to master.
    """
    if isinstance(environment.runner, WorkerRunner):
        return

    if not _HAS_PROM_CLIENT:
        print(
            "[benchmarking] WARNING: prometheus_client not installed. "
            "Prometheus /metrics endpoint will NOT be available. "
            "Install with: pip install prometheus_client"
        )
        return

    # Start HTTP /metrics server on PROMETHEUS_PORT using the custom registry
    _prom_start_http_server(PROMETHEUS_PORT, registry=_prom_registry)
    print(f"[benchmarking] Prometheus /metrics listening on :{PROMETHEUS_PORT}")

    # Background greenlet to poll runner stats every 2 seconds
    import gevent

    def _update_prom_metrics():
        while True:
            try:
                runner = environment.runner
                if runner and runner.stats:
                    _prom_users.set(runner.user_count)
                    total = runner.stats.total
                    if total.num_requests > 0:
                        _prom_fail_ratio.set(total.fail_ratio)
            except Exception:
                pass
            gevent.sleep(2)

    gevent.spawn(_update_prom_metrics)


@events.request.add_listener
def _on_request(request_type, name, response_time, response_length, exception, **kwargs):
    if not _HAS_PROM_CLIENT:
        return
    result = "failure" if exception else "success"
    _prom_requests_total.labels(result=result).inc()


# ---------------------------------------------------------------------------
# Dataset loading
# ---------------------------------------------------------------------------
def _load_prompts() -> list[dict]:
    with open(DATASET_PATH, "r") as f:
        data = json.load(f)
    prompts = data if isinstance(data, list) else data.get("prompts", [])
    if PROMPT_LEN != "all":
        prompts = [p for p in prompts if p.get("category") == PROMPT_LEN]
    if not prompts:
        raise ValueError(f"No prompts found for category='{PROMPT_LEN}' in {DATASET_PATH}")
    return prompts


# ---------------------------------------------------------------------------
# SSE streaming parser — yields decoded token strings
# ---------------------------------------------------------------------------
def _stream_tokens(response):
    """
    Parse an SSE stream from vLLM and yield (token_text, finish_reason) tuples.
    Each SSE data line is a JSON chunk with choices[0].delta.content.
    """
    client = sseclient.SSEClient(response)
    for event in client.events():
        if event.data == "[DONE]":
            break
        try:
            chunk = json.loads(event.data)
        except json.JSONDecodeError:
            continue
        choice = chunk["choices"][0]
        delta  = choice.get("delta", {})
        text   = delta.get("content", "")
        finish = choice.get("finish_reason")
        yield text, finish


# ---------------------------------------------------------------------------
# Locust User
# ---------------------------------------------------------------------------
class VllmUser(HttpUser):
    wait_time = between(0.5, 1.5)   # seconds between tasks (single-user: set to 0)

    def on_start(self):
        self.prompts = _load_prompts()

    @task
    def chat_completion(self):
        prompt_entry = random.choice(self.prompts)
        prompt_text  = prompt_entry["prompt"]
        category     = prompt_entry.get("category", "unknown")

        # Build messages — include system_prompt if present in dataset
        messages = []
        system_prompt = prompt_entry.get("system_prompt", "")
        if system_prompt:
            messages.append({"role": "system", "content": system_prompt})
        messages.append({"role": "user", "content": prompt_text})

        payload = {
            "model": MODEL_NAME,
            "messages": messages,
            "max_tokens": MAX_TOKENS,
            "stream": True,
            "temperature": 0.0,   # deterministic for reproducibility
        }

        t_request_sent = time.perf_counter()
        t_first_token  = None
        inter_token_times: list[float] = []
        output_tokens  = 0
        finish_reason  = None
        success        = True
        error_type     = None

        try:
            with self.client.post(
                "/v1/chat/completions",
                json=payload,
                stream=True,
                headers={"Accept": "text/event-stream"},
                catch_response=True,
                name=f"chat/{category}",
            ) as response:

                if response.status_code != 200:
                    success    = False
                    error_type = f"http_{response.status_code}"
                    response.failure(f"HTTP {response.status_code}")
                    return

                t_prev = None
                for token_text, finish in _stream_tokens(response):
                    t_now = time.perf_counter()

                    if t_first_token is None:
                        t_first_token = t_now

                    if t_prev is not None and token_text:
                        inter_token_times.append((t_now - t_prev) * 1000)  # ms

                    if token_text:
                        output_tokens += 1
                        t_prev = t_now

                    if finish:
                        finish_reason = finish

                response.success()

        except Exception as exc:
            success    = False
            error_type = type(exc).__name__

        t_last_token = time.perf_counter()

        # ---- Derived metrics ------------------------------------------------
        if t_first_token is None:
            # No tokens received → complete failure
            ttft_ms = None
            tpot_ms = None
            e2e_ms  = (t_last_token - t_request_sent) * 1000
            itl_p50 = None
            itl_p99 = None
        else:
            ttft_ms  = (t_first_token - t_request_sent) * 1000
            e2e_ms   = (t_last_token  - t_request_sent) * 1000
            decode_tokens = max(output_tokens - 1, 1)
            tpot_ms  = (t_last_token - t_first_token) * 1000 / decode_tokens
            itl_p50  = _percentile(inter_token_times, 50) if inter_token_times else None
            itl_p99  = _percentile(inter_token_times, 99) if inter_token_times else None

        _custom_rows.append({
            "timestamp":     t_request_sent,
            "category":      category,
            "input_tokens":  prompt_entry.get("approx_tokens", 0),
            "output_tokens": output_tokens,
            "ttft_ms":       ttft_ms,
            "tpot_ms":       tpot_ms,
            "e2e_ms":        e2e_ms,
            "itl_p50_ms":    itl_p50,
            "itl_p99_ms":    itl_p99,
            "finish_reason": finish_reason,
            "success":       success,
            "error_type":    error_type,
        })


# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------
def _percentile(data: list[float], pct: int) -> float:
    if not data:
        return 0.0
    sorted_data = sorted(data)
    k = (len(sorted_data) - 1) * pct / 100
    lo, hi = int(k), min(int(k) + 1, len(sorted_data) - 1)
    return sorted_data[lo] + (sorted_data[hi] - sorted_data[lo]) * (k - lo)


# ---------------------------------------------------------------------------
# Export custom metrics to CSV on test completion
# ---------------------------------------------------------------------------
@events.test_stop.add_listener
def _on_test_stop(environment, **kwargs):
    _write_custom_metrics(environment)

@events.quitting.add_listener
def _on_quitting(environment, **kwargs):
    _write_custom_metrics(environment)

def _write_custom_metrics(environment):
    if isinstance(environment.runner, (MasterRunner, WorkerRunner)):
        return  # only the local/master process writes

    if not _custom_rows:
        return

    import csv, os
    results_dir = Path(__file__).parent / "results"
    results_dir.mkdir(exist_ok=True)

    if CSV_PREFIX:
        out_path = Path(f"{CSV_PREFIX}_custom_metrics.csv")
        out_path.parent.mkdir(parents=True, exist_ok=True)
    else:
        out_path = results_dir / f"custom_metrics_{int(time.time())}.csv"
    fieldnames = list(_custom_rows[0].keys())
    with open(out_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(_custom_rows)

    print(f"\n[benchmarking] Custom metrics written to: {out_path}")
    _print_summary(_custom_rows)


def _print_summary(rows: list[dict]):
    """Print a quick human-readable summary to stdout."""
    successful = [r for r in rows if r["success"]]
    failed     = [r for r in rows if not r["success"]]
    n = len(rows)

    ttfts  = [r["ttft_ms"]  for r in successful if r["ttft_ms"]  is not None]
    tpots  = [r["tpot_ms"]  for r in successful if r["tpot_ms"]  is not None]
    e2es   = [r["e2e_ms"]   for r in successful if r["e2e_ms"]   is not None]

    def _stats(values):
        if not values:
            return "N/A"
        return (
            f"mean={sum(values)/len(values):.1f}  "
            f"p50={_percentile(values, 50):.1f}  "
            f"p95={_percentile(values, 95):.1f}  "
            f"p99={_percentile(values, 99):.1f}  "
            f"min={min(values):.1f}  max={max(values):.1f}"
        )

    print("\n" + "=" * 70)
    print("  BENCHMARK SUMMARY")
    print("=" * 70)
    print(f"  Total requests : {n}")
    print(f"  Successful     : {len(successful)}  ({100*len(successful)/n:.1f}%)")
    print(f"  Failed         : {len(failed)}")
    print(f"  TTFT (ms)      : {_stats(ttfts)}")
    print(f"  TPOT (ms/tok)  : {_stats(tpots)}")
    print(f"  E2E  (ms)      : {_stats(e2es)}")
    print("=" * 70 + "\n")
