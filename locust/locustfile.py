"""
vLLM Benchmark — Locust Load Test
==================================
Measures TTFT, TPOT, ITL, and E2E latency for every request
against the vLLM OpenAI-compatible /v1/chat/completions endpoint.

Usage (in-cluster, triggered via Locust master REST API):
    The host is set via LOCUST_HOST env var (automatically wired from the
    ConfigMap to http://vllm-service.vllm.svc.cluster.local).
    Prometheus metrics are served on :9646 by the built-in prometheus_client
    and scraped by kube-prometheus-stack via the locust ServiceMonitor.

Dataset:
    Switch between datasets with DATASET_TYPE:
      sharegpt (default) — ShareGPT_V3 multi-turn conversations, auto-downloaded if absent.
      custom             — Your own dataset.json with {prompt, category, approx_tokens, …} records.

Environment variables:
    VLLM_MODEL_NAME        — model identifier sent in the request body (default: see below)
    VLLM_MAX_TOKENS        — max tokens to generate per request (default: 256)
    VLLM_TEMPERATURE       — sampling temperature (default: 0.0 for deterministic outputs)
    VLLM_REQUEST_TIMEOUT   — per-request timeout in seconds (default: 180)
    DATASET_TYPE           — which dataset to use: sharegpt | custom  (default: sharegpt)
    SHAREGPT_PATH          — path to the ShareGPT JSON file (default: prompts/sharegpt.json)
    SHAREGPT_URL           — URL to download ShareGPT from if the file is missing
    SHAREGPT_MIN_TURNS     — minimum human+gpt turn pairs to include a conversation (default: 1)
    CUSTOM_DATASET_PATH    — path to your custom dataset JSON (default: prompts/dataset.json)
    VLLM_PROMPT_LEN        — filter by prompt category: short | medium | long | all (default: all)
                             For ShareGPT: derived from first human turn char length
                               short < 200 chars | medium < 1000 chars | long ≥ 1000 chars
                             For custom: matched against the 'category' field in the record
    LOCUST_PROMETHEUS_PORT — port for the Prometheus /metrics endpoint (default: 9646)
    LOCUST_ARTIFACTS_DIR   — directory for worker artifact files (default: /tmp)
"""

import csv
import json
import os
import random
import re
import time
import urllib.request
from pathlib import Path

import sseclient
from locust import HttpUser, constant, events, task
from locust.runners import MasterRunner, WorkerRunner
import logging
import sys

# Configure logging to stdout so container/pod logs capture messages.
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
MODEL_NAME      = os.getenv("VLLM_MODEL_NAME",   "deepseek-ai/DeepSeek-R1-Distill-Qwen-7B")
MAX_TOKENS      = int(os.getenv("VLLM_MAX_TOKENS",    "256"))
TEMPERATURE     = float(os.getenv("VLLM_TEMPERATURE",  "0.0"))
REQUEST_TIMEOUT = float(os.getenv("VLLM_REQUEST_TIMEOUT", "180"))

DATASET_TYPE    = os.getenv("DATASET_TYPE", "sharegpt").lower()  # sharegpt | custom

_DEFAULT_SHAREGPT = Path(__file__).parent / "prompts" / "sharegpt.json"
SHAREGPT_PATH   = Path(os.getenv("SHAREGPT_PATH", _DEFAULT_SHAREGPT))
SHAREGPT_URL    = os.getenv(
    "SHAREGPT_URL",
    "https://huggingface.co/datasets/anon8231489123/ShareGPT_Vicuna_unfiltered"
    "/resolve/main/ShareGPT_V3_unfiltered_cleaned_split.json",
)
SHAREGPT_MIN_TURNS = int(os.getenv("SHAREGPT_MIN_TURNS", "1"))  # min human+gpt pairs

_DEFAULT_CUSTOM = Path(__file__).parent / "prompts" / "dataset.json"
CUSTOM_DATASET_PATH = Path(os.getenv("CUSTOM_DATASET_PATH", _DEFAULT_CUSTOM))

PROMPT_LEN      = os.getenv("VLLM_PROMPT_LEN", "all")  # short | medium | long | all
PROMETHEUS_PORT = int(os.getenv("LOCUST_PROMETHEUS_PORT", "9646"))
ARTIFACTS_DIR   = Path(os.getenv("LOCUST_ARTIFACTS_DIR", "/tmp"))

# Character thresholds for PROMPT_LEN categorisation (first human turn length)
_LEN_THRESHOLDS = {"short": 200, "medium": 1000}  # < short → short, < medium → medium, else long

# Aggregated custom metrics — populated on workers, written to file on test_stop
_custom_rows: list[dict] = []

# Prompt/response pairs — populated on workers, written to file on test_stop
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
    _custom_rows.clear()
    _response_rows.clear()


@events.init.add_listener
def _on_locust_init(environment, **kwargs):
    """
    Start Prometheus /metrics server on the master (or standalone) process.
    Workers don't expose Prometheus; they forward stats to master.
    """
    if isinstance(environment.runner, WorkerRunner):
        return

    if not _HAS_PROM_CLIENT:
        logger.warning(
            "[benchmarking] WARNING: prometheus_client not installed. "
            "Prometheus /metrics endpoint will NOT be available. "
            "Install with: pip install prometheus_client"
        )
        return

    _prom_start_http_server(PROMETHEUS_PORT, registry=_prom_registry)
    logger.info(f"[benchmarking] Prometheus /metrics listening on :{PROMETHEUS_PORT}")

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
# Dataset loaders — loaded once at module level, shared across all users
# ---------------------------------------------------------------------------

def _download_sharegpt() -> None:
    """Download the ShareGPT JSON file if it's not already present."""
    SHAREGPT_PATH.parent.mkdir(parents=True, exist_ok=True)
    logger.info(f"[benchmarking] Downloading ShareGPT dataset from {SHAREGPT_URL} ...")
    urllib.request.urlretrieve(SHAREGPT_URL, SHAREGPT_PATH)
    logger.info(f"[benchmarking] ShareGPT dataset saved to {SHAREGPT_PATH}")


def _categorise(first_human_text: str) -> str:
    """Return short / medium / long based on first human turn character length."""
    n = len(first_human_text)
    if n < _LEN_THRESHOLDS["short"]:
        return "short"
    if n < _LEN_THRESHOLDS["medium"]:
        return "medium"
    return "long"


def _load_sharegpt() -> list[dict]:
    """
    Parse the ShareGPT JSON, convert each conversation into a messages[] list
    (OpenAI chat format), and return the filtered list of prompt dicts.

    Each returned dict has:
        messages  — list of {"role": ..., "content": ...} for the full conversation
        category  — "short" | "medium" | "long" (based on first human turn length)
        approx_chars — character count of the first human turn (proxy for input size)
    """
    if not SHAREGPT_PATH.exists():
        _download_sharegpt()

    with open(SHAREGPT_PATH, "r", encoding="utf-8") as f:
        raw = json.load(f)

    role_map = {"human": "user", "gpt": "assistant", "system": "system"}
    prompts: list[dict] = []

    for convo in raw:
        turns = convo.get("conversations", [])
        # Filter out conversations that don't start with a human turn
        if not turns or turns[0].get("from") not in ("human", "system"):
            continue
        # Require at least SHAREGPT_MIN_TURNS complete human+gpt pairs
        human_turns = [t for t in turns if t.get("from") == "human"]
        if len(human_turns) < SHAREGPT_MIN_TURNS:
            continue

        messages = []
        first_human_text = ""
        for turn in turns:
            role = role_map.get(turn.get("from", ""), None)
            text = turn.get("value", "").strip()
            if not role or not text:
                continue
            if role == "user" and not first_human_text:
                first_human_text = text
            messages.append({"role": role, "content": text})

        if not first_human_text or not messages:
            continue

        category = _categorise(first_human_text)
        if PROMPT_LEN != "all" and category != PROMPT_LEN:
            continue

        prompts.append({
            "messages":     messages,
            "category":     category,
            "approx_chars": len(first_human_text),
        })

    if not prompts:
        raise ValueError(
            f"No ShareGPT conversations matched filter: "
            f"VLLM_PROMPT_LEN={PROMPT_LEN!r}, SHAREGPT_MIN_TURNS={SHAREGPT_MIN_TURNS}"
        )

    logger.info(
        f"[benchmarking] Loaded {len(prompts)} ShareGPT conversations "
        f"(filter: {PROMPT_LEN}, min_turns: {SHAREGPT_MIN_TURNS})"
    )
    return prompts


def _load_custom() -> list[dict]:
    """
    Load the custom dataset JSON.

    Expected record format (list of objects):
        {"prompt": "...", "category": "short|medium|long",
         "approx_tokens": 123, "system_prompt": "..." (optional)}

    Each returned dict has:
        messages     — list of {"role": ..., "content": ...}
        category     — from the record's "category" field
        approx_chars — len(prompt), used as a proxy for input size
    """
    with open(CUSTOM_DATASET_PATH, "r", encoding="utf-8") as f:
        data = json.load(f)
    records = data if isinstance(data, list) else data.get("prompts", [])

    if PROMPT_LEN != "all":
        records = [r for r in records if r.get("category") == PROMPT_LEN]

    if not records:
        raise ValueError(
            f"No prompts found for category={PROMPT_LEN!r} in {CUSTOM_DATASET_PATH}"
        )

    prompts: list[dict] = []
    for r in records:
        prompt_text   = r["prompt"]
        system_prompt = r.get("system_prompt", "")
        messages = []
        if system_prompt:
            messages.append({"role": "system", "content": system_prompt})
        messages.append({"role": "user", "content": prompt_text})
        prompts.append({
            "messages":     messages,
            "category":     r.get("category", "unknown"),
            "approx_chars": len(prompt_text),
        })

    logger.info(
        f"[benchmarking] Loaded {len(prompts)} custom prompts "
        f"(filter: {PROMPT_LEN}) from {CUSTOM_DATASET_PATH}"
    )
    return prompts


def _load_dataset() -> list[dict]:
    """Dispatch to the correct loader based on DATASET_TYPE."""
    if DATASET_TYPE == "custom":
        return _load_custom()
    if DATASET_TYPE == "sharegpt":
        return _load_sharegpt()
    raise ValueError(f"Unknown DATASET_TYPE={DATASET_TYPE!r}. Use 'sharegpt' or 'custom'.")


# Load once at module level — shared read-only across all VllmUser instances
_PROMPTS: list[dict] = _load_dataset()


# ---------------------------------------------------------------------------
# SSE streaming parser — yields (token_text, finish_reason) tuples
# ---------------------------------------------------------------------------
def _stream_tokens(response):
    """
    Parse an SSE stream from vLLM and yield
    (content_text, reasoning_text, finish_reason) tuples.

    Some reasoning-capable models stream chain-of-thought in
    choices[0].delta.reasoning_content while final answer tokens are in
    choices[0].delta.content.
    """
    client = sseclient.SSEClient(response)
    for event in client.events():
        if event.data == "[DONE]":
            break
        try:
            chunk = json.loads(event.data)
        except json.JSONDecodeError:
            continue
        choices = chunk.get("choices", [])
        if not choices:
            continue

        choice = choices[0]
        delta = choice.get("delta", {})
        content_text = delta.get("content", "") or ""
        reasoning_text = (
            delta.get("reasoning_content")
            or delta.get("reasoning")
            or ""
        )
        finish = choice.get("finish_reason")
        yield content_text, reasoning_text, finish


def _split_thinking_from_content(content_text: str) -> tuple[str, str]:
    """Extract <think>...</think> blocks if a model embeds reasoning inline."""
    m = re.search(r"<think>\s*(.*?)\s*</think>\s*(.*)", content_text, flags=re.DOTALL | re.IGNORECASE)
    if not m:
        return "", content_text
    return m.group(1).strip(), m.group(2).lstrip()


# ---------------------------------------------------------------------------
# Locust User
# ---------------------------------------------------------------------------
class VllmUser(HttpUser):
    # No think-time between tasks — concurrency level alone controls load intensity.
    wait_time = constant(0)

    @task
    def chat_completion(self):
        entry    = random.choice(_PROMPTS)
        messages = entry["messages"]
        category = entry["category"]

        payload = {
            "model":       MODEL_NAME,
            "messages":    messages,
            "max_tokens":  MAX_TOKENS,
            "stream":      True,
            "temperature": TEMPERATURE,
        }

        t_request_sent = time.perf_counter()
        t_first_token  = None
        t_last_token   = None
        inter_token_times: list[float] = []
        output_tokens  = 0
        finish_reason  = None
        success        = True
        error_type     = None
        reasoning_text = ""
        response_text  = ""

        try:
            with self.client.post(
                "/v1/chat/completions",
                json=payload,
                stream=True,
                headers={"Accept": "text/event-stream"},
                catch_response=True,
                name=f"chat/{category}",
                timeout=REQUEST_TIMEOUT,
            ) as response:

                if response.status_code != 200:
                    success      = False
                    error_type   = f"http_{response.status_code}"
                    t_last_token = time.perf_counter()
                    response.failure(f"HTTP {response.status_code}")
                    return

                t_prev = None
                reasoning_parts: list[str] = []
                response_parts: list[str] = []
                for content_piece, reasoning_piece, finish in _stream_tokens(response):
                    t_now = time.perf_counter()

                    emitted_any = bool(content_piece or reasoning_piece)
                    if t_first_token is None and emitted_any:
                        t_first_token = t_now

                    if t_prev is not None and emitted_any:
                        inter_token_times.append((t_now - t_prev) * 1000)  # ms

                    if reasoning_piece:
                        reasoning_parts.append(reasoning_piece)
                    if content_piece:
                        response_parts.append(content_piece)

                    if emitted_any:
                        output_tokens += 1
                        t_prev = t_now

                    if finish:
                        finish_reason = finish

                t_last_token = time.perf_counter()
                reasoning_text = "".join(reasoning_parts)
                response_text = "".join(response_parts)

                # Fallback for models that put reasoning inside <think>...</think>
                # in the normal content stream.
                if not reasoning_text and response_text:
                    extracted_reasoning, cleaned_response = _split_thinking_from_content(response_text)
                    if extracted_reasoning:
                        reasoning_text = extracted_reasoning
                        response_text = cleaned_response

                response.success()

        except Exception as exc:
            t_last_token = time.perf_counter()
            success      = False
            error_type   = type(exc).__name__

        # ---- Derived metrics ------------------------------------------------
        if t_first_token is None:
            ttft_ms = None
            tpot_ms = None
            e2e_ms  = (t_last_token - t_request_sent) * 1000
            itl_p50 = None
            itl_p99 = None
        else:
            ttft_ms       = (t_first_token - t_request_sent) * 1000
            e2e_ms        = (t_last_token  - t_request_sent) * 1000
            decode_tokens = max(output_tokens - 1, 1)
            tpot_ms       = (t_last_token - t_first_token) * 1000 / decode_tokens
            itl_p50       = _percentile(inter_token_times, 50) if inter_token_times else None
            itl_p99       = _percentile(inter_token_times, 99) if inter_token_times else None

        # Extract the last user message as the human-readable prompt
        prompt_text = next(
            (m["content"] for m in reversed(messages) if m.get("role") == "user"),
            "",
        )

        input_messages = [
            {"role": m.get("role", ""), "content": m.get("content", "")}
            for m in messages
        ]
        assistant_message = {
            "role": "assistant",
            "content": response_text,
        }
        if reasoning_text:
            assistant_message["reasoning"] = reasoning_text
        conversation = input_messages + [assistant_message]

        _custom_rows.append({
            "timestamp":     t_request_sent,
            "category":      category,
            "approx_chars":  entry["approx_chars"],
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

        _response_rows.append({
            "timestamp":     t_request_sent,
            "category":      category,
            "conversation":  conversation,
            "prompt":        prompt_text,
            "reasoning":     reasoning_text,
            "response":      response_text,
            "output_tokens": output_tokens,
            "finish_reason": finish_reason,
            "success":       success,
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
# Export custom metrics to CSV on test completion
# ---------------------------------------------------------------------------
@events.test_stop.add_listener
def _on_test_stop(environment, **kwargs):
    _write_custom_metrics(environment)
    _write_responses(environment)


# Fixed paths on the pod — run_experiment.sh retrieves them with kubectl cp
_RESPONSES_POD_PATH      = ARTIFACTS_DIR / "locust_responses.jsonl"
_CUSTOM_METRICS_POD_PATH = ARTIFACTS_DIR / "locust_custom_metrics.csv"


def _write_responses(environment):
    """Write prompt/response pairs to a JSONL file.

    In distributed mode each worker writes its own shard to the pod's /tmp.
    run_experiment.sh then kubectl-cp from every worker pod and concatenates.
    The master process skips writing in distributed mode.
    """
    if isinstance(environment.runner, MasterRunner):
        return

    if not _response_rows:
        logger.info("[benchmarking] No prompt/response data to write.")
        return

    ARTIFACTS_DIR.mkdir(parents=True, exist_ok=True)

    with open(_RESPONSES_POD_PATH, "w", encoding="utf-8") as f:
        for row in _response_rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")

    logger.info(
        f"[benchmarking] Prompt/response log written to: {_RESPONSES_POD_PATH} "
        f"({len(_response_rows)} entries)"
    )


def _write_custom_metrics(environment):
    """Write custom per-request metrics to a CSV file.

    In distributed mode each worker writes its own shard to the pod's /tmp.
    run_experiment.sh then kubectl-cp from every worker pod and merges.
    The master process skips writing in distributed mode.
    """
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
        f"\n[benchmarking] Custom metrics written to: {_CUSTOM_METRICS_POD_PATH} "
        f"({len(_custom_rows)} rows)"
    )
    _print_summary(_custom_rows)


def _print_summary(rows: list[dict]):
    """Print a quick human-readable summary to stdout."""
    successful = [r for r in rows if r["success"]]
    failed     = [r for r in rows if not r["success"]]
    n = len(rows)

    ttfts = [r["ttft_ms"] for r in successful if r["ttft_ms"] is not None]
    tpots = [r["tpot_ms"] for r in successful if r["tpot_ms"] is not None]
    e2es  = [r["e2e_ms"]  for r in successful if r["e2e_ms"]  is not None]

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
    logger.info("  BENCHMARK SUMMARY")
    logger.info("=" * 70)
    logger.info(f"  Total requests : {n}")
    logger.info(f"  Successful     : {len(successful)}  ({100*len(successful)/n:.1f}%)")
    logger.info(f"  Failed         : {len(failed)}")
    logger.info(f"  TTFT (ms)      : {_stats(ttfts)}")
    logger.info(f"  TPOT (ms/tok)  : {_stats(tpots)}")
    logger.info(f"  E2E  (ms)      : {_stats(e2es)}")
    logger.info("=" * 70 + "\n")
