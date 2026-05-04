"""
Agent Benchmark — Locust Load Test
====================================
Measures end-to-end agent execution time for LangGraph agent tasks.

Metrics captured per request:
  - E2E latency (total time from task submission to final result)
  - Number of graph steps (LLM calls + tool calls)
  - Number of tool calls
  - Success/failure rate

Target: FastAPI Agent API at /api/v1/agent/run

Usage (in-cluster, triggered via Locust master REST API):
    The host is set via LOCUST_HOST env var → http://agent-service.agent.svc.cluster.local

Environment variables:
    AGENT_REQUEST_TIMEOUT — per-request timeout in seconds (default: 120)
    LOCUST_PROMETHEUS_PORT — port for the Prometheus /metrics endpoint (default: 9646)
    LOCUST_ARTIFACTS_DIR   — directory for worker artifact files (default: /tmp)
"""

import csv
import json
import os
import random
import time
from pathlib import Path

from locust import HttpUser, constant, events, task, runners
from locust.runners import MasterRunner, WorkerRunner
import logging
import sys

runners.MASTER_HEARTBEAT_TIMEOUT = 300
runners.HEARTBEAT_LIVENESS = 30

# Configure logging
logging.basicConfig(
    stream=sys.stdout,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
logger = logging.getLogger(__name__)

# prometheus_client for built-in metrics export
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
REQUEST_TIMEOUT = float(os.getenv("AGENT_REQUEST_TIMEOUT", "120"))
PROMETHEUS_PORT = int(os.getenv("LOCUST_PROMETHEUS_PORT", "9646"))
ARTIFACTS_DIR = Path(os.getenv("LOCUST_ARTIFACTS_DIR", "/tmp"))

# ---------------------------------------------------------------------------
# Agent tasks — complex multi-step prompts that trigger tool usage
# ---------------------------------------------------------------------------
AGENT_TASKS = [
    # Single-tool tasks
    "Search Wikipedia for the history of Istanbul and summarize the key events in 3 bullet points.",
    "Get the current weather in London and tell me if I should bring an umbrella.",
    "Look up financial data for AAPL stock and write a brief investment summary.",
    "What is the weather like in Tokyo right now? Should I pack warm clothes?",
    "Search Wikipedia for artificial intelligence and explain it in simple terms.",
    "Get financial data for MSFT and compare its P/E ratio to a typical tech stock.",

    # Multi-tool tasks
    "Get the current weather in London and compare it to Istanbul. Which city is warmer today?",
    "Calculate the compound interest on $10000 at 5% annual rate for 10 years, then search Wikipedia for compound interest to verify the formula.",
    "Get the weather in Tokyo, search Wikipedia for Tokyo, and write a short travel advisory.",
    "Look up GOOGL financial data, calculate the P/E ratio if EPS is $5.80, and summarize the investment outlook.",
    "Search Wikipedia for the stock market, then get financial data for AAPL and GOOGL. Compare the two companies.",
    "Calculate 15% tip on a $85.50 restaurant bill, then search Wikipedia for tipping customs around the world.",

    # Reasoning + tool tasks
    "Get weather data for Istanbul and New York. Calculate the temperature difference in both Celsius and Fahrenheit.",
    "Look up AAPL financial data. If I invested $5000 at the current price, calculate how many shares I could buy and what the dividend income would be.",
    "Search Wikipedia for compound interest. Then calculate how much $1000 grows in 5 years at 7% compounded monthly.",
]

# Aggregated custom metrics
_custom_rows: list[dict] = []

# Prompt/response pairs
_response_rows: list[dict] = []


# ---------------------------------------------------------------------------
# Prometheus metrics export
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


@events.test_start.add_listener
def _on_test_start(environment, **kwargs):
    """Clear per-run buffers so each swarm run produces its own output files."""
    global _files_written
    _custom_rows.clear()
    _response_rows.clear()
    _files_written = False


@events.init.add_listener
def _on_locust_init(environment, **kwargs):
    """Start Prometheus /metrics server on the master (or standalone) process."""
    if isinstance(environment.runner, WorkerRunner):
        return
    if not _HAS_PROM_CLIENT:
        logger.warning("[agent-bench] prometheus_client not installed.")
        return
    _prom_start_http_server(PROMETHEUS_PORT, registry=_prom_registry)
    logger.info(f"[agent-bench] Prometheus /metrics listening on :{PROMETHEUS_PORT}")

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
# Locust User
# ---------------------------------------------------------------------------
class AgentUser(HttpUser):
    """Simulates a user sending complex tasks to the LangGraph Agent API."""
    wait_time = constant(0)

    @task
    def run_agent_task(self):
        task_text = random.choice(AGENT_TASKS)

        t_start = time.perf_counter()
        success = True
        error_type = None
        steps = 0
        tool_calls = 0
        result_text = ""
        server_duration_ms = 0

        try:
            with self.client.post(
                "/api/v1/agent/run",
                json={"task": task_text},
                catch_response=True,
                name="agent/run",
                timeout=REQUEST_TIMEOUT,
            ) as response:
                if response.status_code != 200:
                    success = False
                    error_type = f"http_{response.status_code}"
                    response.failure(f"HTTP {response.status_code}")
                else:
                    body = response.json()
                    steps = body.get("steps", 0)
                    tool_calls = body.get("tool_calls", 0)
                    result_text = body.get("result", "")
                    server_duration_ms = body.get("duration_ms", 0)
                    response.success()
        except Exception as exc:
            success = False
            error_type = type(exc).__name__

        t_end = time.perf_counter()
        e2e_ms = (t_end - t_start) * 1000

        _custom_rows.append({
            "timestamp":          t_start,
            "task":               task_text[:100],
            "e2e_ms":             round(e2e_ms, 2),
            "server_duration_ms": round(server_duration_ms, 2),
            "steps":              steps,
            "tool_calls":         tool_calls,
            "success":            success,
            "error_type":         error_type,
        })

        _response_rows.append({
            "timestamp":   t_start,
            "task":        task_text,
            "result":      result_text,
            "steps":       steps,
            "tool_calls":  tool_calls,
            "e2e_ms":      round(e2e_ms, 2),
            "success":     success,
        })


# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------
def _percentile(data: list[float], pct: int) -> float:
    if not data:
        return 0.0
    s = sorted(data)
    k = (len(s) - 1) * pct / 100
    lo, hi = int(k), min(int(k) + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


# ---------------------------------------------------------------------------
# Export metrics on test completion
# ---------------------------------------------------------------------------
_RESPONSES_POD_PATH = ARTIFACTS_DIR / "locust_agent_responses.jsonl"
_CUSTOM_METRICS_POD_PATH = ARTIFACTS_DIR / "locust_agent_metrics.csv"

# Guard against double-writes (test_stop + quitting can both fire)
_files_written = False


@events.test_stop.add_listener
def _on_test_stop(environment, **kwargs):
    global _files_written
    try:
        _write_custom_metrics(environment)
        _write_responses(environment)
        _files_written = True
    except Exception:
        logger.exception("[agent-bench] Error writing files in test_stop")





def _write_responses(environment):
    """Write prompt/response pairs to a JSONL file."""
    if isinstance(environment.runner, MasterRunner):
        return
    if not _response_rows:
        logger.info("[agent-bench] No prompt/response data to write.")
        return
    ARTIFACTS_DIR.mkdir(parents=True, exist_ok=True)
    with open(_RESPONSES_POD_PATH, "w", encoding="utf-8") as f:
        for row in _response_rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    logger.info(
        f"[agent-bench] Responses written to: {_RESPONSES_POD_PATH} "
        f"({len(_response_rows)} entries)"
    )


def _write_custom_metrics(environment):
    """Write custom per-request metrics to a CSV file."""
    if isinstance(environment.runner, MasterRunner):
        return
    if not _custom_rows:
        return
    ARTIFACTS_DIR.mkdir(parents=True, exist_ok=True)
    fieldnames = list(_custom_rows[0].keys())
    with open(_CUSTOM_METRICS_POD_PATH, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(_custom_rows)
    logger.info(
        f"\n[agent-bench] Custom metrics written to: {_CUSTOM_METRICS_POD_PATH} "
        f"({len(_custom_rows)} rows)"
    )
    _print_summary(_custom_rows)


def _print_summary(rows: list[dict]):
    """Print a quick human-readable summary to stdout."""
    successful = [r for r in rows if r["success"]]
    failed = [r for r in rows if not r["success"]]
    n = len(rows)

    e2es = [r["e2e_ms"] for r in successful if r["e2e_ms"] is not None]
    steps_list = [r["steps"] for r in successful]
    tool_calls_list = [r["tool_calls"] for r in successful]

    def _stats(values):
        if not values:
            return "N/A"
        s = sorted(values)
        return (
            f"mean={sum(s)/len(s):.1f}  "
            f"p50={_percentile(s, 50):.1f}  "
            f"p95={_percentile(s, 95):.1f}  "
            f"p99={_percentile(s, 99):.1f}  "
            f"min={s[0]:.1f}  max={s[-1]:.1f}"
        )

    logger.info("\n" + "=" * 70)
    logger.info("  AGENT BENCHMARK SUMMARY")
    logger.info("=" * 70)
    logger.info(f"  Total requests : {n}")
    logger.info(f"  Successful     : {len(successful)}  ({100*len(successful)/n:.1f}%)" if n > 0 else "  Successful     : 0")
    logger.info(f"  Failed         : {len(failed)}")
    logger.info(f"  E2E  (ms)      : {_stats(e2es)}")
    logger.info(f"  Steps          : {_stats([float(x) for x in steps_list])}")
    logger.info(f"  Tool Calls     : {_stats([float(x) for x in tool_calls_list])}")
    logger.info("=" * 70 + "\n")
