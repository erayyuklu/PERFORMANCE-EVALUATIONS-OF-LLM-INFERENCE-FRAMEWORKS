#!/usr/bin/env python3
"""
run_gaia.py — Run GAIA benchmark against the LangGraph agent API.
=================================================================
Loads the GAIA validation set from HuggingFace, sends each question to
the agent, extracts the final answer, scores it with exact-match, and
writes per-question JSONL + summary JSON.

Usage:
    python run_gaia.py                           # defaults from config.env
    python run_gaia.py --levels 1 --limit 10     # Level 1 only, first 10
    python run_gaia.py --agent-url http://X:8000 # override agent URL
"""

import argparse
import asyncio
import json
import logging
import os
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

import httpx
import pandas as pd
from datasets import load_dataset
from huggingface_hub import snapshot_download

from scorer import score

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    stream=sys.stdout,
    level=logging.INFO,
    format="%(asctime)s  [%(levelname)s]  %(message)s",
)
logger = logging.getLogger(__name__)

SCRIPT_DIR = Path(__file__).resolve().parent

# ---------------------------------------------------------------------------
# Config — loaded from config.env then overridden by CLI args
# ---------------------------------------------------------------------------

def _load_env(path: Path) -> dict:
    """Parse a KEY=VALUE file, ignoring comments and blank lines."""
    env = {}
    if not path.exists():
        return env
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, _, value = line.partition("=")
        env[key.strip()] = value.strip().strip('"').strip("'")
    return env


_env = _load_env(SCRIPT_DIR / "config.env")

AGENT_K8S_NAMESPACE = _env.get("AGENT_K8S_NAMESPACE", "agent")
AGENT_K8S_SERVICE = _env.get("AGENT_K8S_SERVICE", "agent-service")
MODEL_FAMILY = _env.get("MODEL_FAMILY", "unknown-model")
QUANTIZATION = _env.get("QUANTIZATION", "noquantization")
AGENT_MODE = _env.get("AGENT_MODE", "single-agent")
GAIA_DATASET = _env.get("GAIA_DATASET", "gaia-benchmark/GAIA")
GAIA_CONFIG = _env.get("GAIA_CONFIG", "2023_all")
GAIA_SPLIT = _env.get("GAIA_SPLIT", "validation")
GAIA_LEVELS = _env.get("GAIA_LEVELS", "1,2,3")
LIMIT = int(_env.get("LIMIT", "0"))
OUTPUT_DIR = _env.get("OUTPUT_DIR", "../results")
REQUEST_TIMEOUT = int(_env.get("REQUEST_TIMEOUT", "180"))
MAX_CONCURRENT = int(_env.get("MAX_CONCURRENT", "4"))


def _discover_agent_url() -> str:
    """Discover the agent LoadBalancer URL via kubectl."""
    def _kubectl(jsonpath: str) -> str:
        return subprocess.check_output(
            ["kubectl", "get", "svc", AGENT_K8S_SERVICE, "-n", AGENT_K8S_NAMESPACE,
             "-o", f"jsonpath={jsonpath}"],
            text=True,
        ).strip()

    ip = _kubectl("{.status.loadBalancer.ingress[0].ip}")
    if not ip:
        raise RuntimeError(
            f"No external IP for {AGENT_K8S_SERVICE} in namespace {AGENT_K8S_NAMESPACE}. "
            f"Check: kubectl get svc {AGENT_K8S_SERVICE} -n {AGENT_K8S_NAMESPACE}"
        )
    port = _kubectl("{.spec.ports[0].port}")
    url = f"http://{ip}:{port}"
    logger.info(f"Discovered agent endpoint: {url}")
    return url

# ---------------------------------------------------------------------------
# GAIA prompt wrapper
# ---------------------------------------------------------------------------

GAIA_PROMPT_PREFIX = (
    "Answer the following question. Your response MUST end with exactly one "
    "line in this format:\n"
    "FINAL ANSWER: <your answer>\n"
    "where <your answer> is a short, precise response — a number, a name, "
    "a comma-separated list, or a short phrase, as the question requires. "
    "Do not include any explanation after the FINAL ANSWER line.\n\n"
)

# File-type extensions we can inline as plain text
TEXT_EXTENSIONS = {
    ".txt", ".csv", ".tsv", ".json", ".jsonl", ".md", ".py", ".js",
    ".html", ".xml", ".yaml", ".yml", ".log", ".sql", ".r", ".sh",
}

# Extensions we cannot extract text from
UNSUPPORTED_EXTENSIONS = {".png", ".jpg", ".jpeg", ".gif", ".bmp", ".mp3", ".wav", ".mp4", ".mov"}


def _extract_file_content(file_path: str) -> str | None:
    """Extract text content from a file locally. Returns None if unsupported."""
    ext = os.path.splitext(file_path)[1].lower()

    if ext in TEXT_EXTENSIONS:
        return Path(file_path).read_text(errors="replace")

    if ext == ".pdf":
        import pymupdf
        doc = pymupdf.open(file_path)
        pages = [page.get_text() for page in doc]
        doc.close()
        return "\n\n".join(pages).strip() or None

    if ext in (".xlsx", ".xls"):
        from openpyxl import load_workbook
        wb = load_workbook(file_path, read_only=True, data_only=True)
        parts = []
        for sheet_name in wb.sheetnames:
            ws = wb[sheet_name]
            rows = []
            for row in ws.iter_rows(values_only=True):
                rows.append("\t".join(str(c) if c is not None else "" for c in row))
            parts.append(f"=== Sheet: {sheet_name} ===\n" + "\n".join(rows))
        wb.close()
        return "\n\n".join(parts).strip() or None

    if ext == ".docx":
        from docx import Document
        doc = Document(file_path)
        paragraphs = [p.text for p in doc.paragraphs if p.text.strip()]
        # Also extract tables
        for table in doc.tables:
            for row in table.rows:
                paragraphs.append("\t".join(cell.text for cell in row.cells))
        return "\n".join(paragraphs).strip() or None

    if ext == ".pptx":
        from pptx import Presentation
        prs = Presentation(file_path)
        slides = []
        for i, slide in enumerate(prs.slides, 1):
            texts = []
            for shape in slide.shapes:
                if shape.has_text_frame:
                    texts.append(shape.text_frame.text)
                if shape.has_table:
                    for row in shape.table.rows:
                        texts.append("\t".join(cell.text for cell in row.cells))
            if texts:
                slides.append(f"=== Slide {i} ===\n" + "\n".join(texts))
        return "\n\n".join(slides).strip() or None

    return None


def _build_prompt(question: str, file_path: str | None) -> str:
    """Wrap a GAIA question with instructions and optional file content."""
    parts = [GAIA_PROMPT_PREFIX]

    if file_path and os.path.isfile(file_path):
        fname = os.path.basename(file_path)
        ext = os.path.splitext(file_path)[1].lower()

        if ext in UNSUPPORTED_EXTENSIONS:
            parts.append(
                f"[Attached file: {fname} — this is a {ext} file whose content "
                "cannot be provided as text.]\n\n"
            )
        else:
            try:
                content = _extract_file_content(file_path)
                if content:
                    parts.append(
                        f"The following file is attached: {fname}\n"
                        f"--- FILE CONTENT ---\n{content}\n--- END FILE ---\n\n"
                    )
                else:
                    parts.append(f"[Attached file: {fname} — extracted no content.]\n\n")
            except Exception as exc:
                parts.append(f"[Attached file: {fname} — could not read: {exc}]\n\n")

    parts.append(f"Question: {question}")
    return "".join(parts)


def _extract_final_answer(text: str) -> str:
    """Parse the 'FINAL ANSWER: ...' line from agent output."""
    # Search from the end since the answer should be the last such line
    matches = re.findall(r"FINAL ANSWER:\s*(.+)", text, re.IGNORECASE)
    if matches:
        return matches[-1].strip()
    # Fallback: return the last non-empty line
    lines = [l.strip() for l in text.strip().splitlines() if l.strip()]
    return lines[-1] if lines else ""


# ---------------------------------------------------------------------------
# Agent call
# ---------------------------------------------------------------------------

async def _call_agent(
    client: httpx.AsyncClient,
    task: str,
    semaphore: asyncio.Semaphore,
    agent_url: str,
) -> tuple[str, float]:
    """Send a task to the agent API and return (result_text, duration_ms)."""
    async with semaphore:
        t0 = time.perf_counter()
        try:
            resp = await client.post(
                f"{agent_url}/api/v1/agent/run",
                json={"task": task},
                timeout=REQUEST_TIMEOUT,
            )
            resp.raise_for_status()
            data = resp.json()
            result_text = data.get("result", "")
            duration_ms = (time.perf_counter() - t0) * 1000
            return result_text, duration_ms
        except Exception as exc:
            duration_ms = (time.perf_counter() - t0) * 1000
            logger.warning(f"Agent call failed: {exc}")
            return f"[ERROR] {exc}", duration_ms


# ---------------------------------------------------------------------------
# Main evaluation loop
# ---------------------------------------------------------------------------

async def run_evaluation(args: argparse.Namespace):
    agent_url = args.agent_url or _discover_agent_url()
    levels = [int(l) for l in (args.levels or GAIA_LEVELS).split(",")]
    limit = args.limit if args.limit is not None else LIMIT
    output_base = Path(SCRIPT_DIR / (args.output_dir or OUTPUT_DIR))
    model_family = args.model_family or MODEL_FAMILY
    quantization = args.quantization or QUANTIZATION
    agent_mode = args.agent_mode or AGENT_MODE
    max_concurrent = args.max_concurrent or MAX_CONCURRENT

    # ── Download dataset ─────────────────────────────────────────────────
    logger.info(f"Downloading GAIA dataset: {GAIA_DATASET} ({GAIA_CONFIG}/{GAIA_SPLIT})")
    data_dir = snapshot_download(repo_id=GAIA_DATASET, repo_type="dataset")
    dataset = load_dataset(data_dir, GAIA_CONFIG, split=GAIA_SPLIT)
    logger.info(f"Loaded {len(dataset)} questions from GAIA {GAIA_SPLIT} split")

    # Filter by level
    dataset = dataset.filter(lambda x: int(x["Level"]) in levels)
    logger.info(f"After level filter ({levels}): {len(dataset)} questions")

    # Apply limit
    if limit > 0:
        dataset = dataset.select(range(min(limit, len(dataset))))
        logger.info(f"Limited to {len(dataset)} questions")

    # ── Prepare output directory ─────────────────────────────────────────
    # Convention: {OUTPUT_DIR}/{AGENT_MODE}/{MODEL_FAMILY}/{QUANTIZATION}/gaia
    run_dir = output_base / agent_mode / model_family / quantization / "gaia"
    run_dir.mkdir(parents=True, exist_ok=True)
    results_path = run_dir / "results.jsonl"
    summary_path = run_dir / "summary.json"

    logger.info(f"Results will be saved to: {run_dir}")
    logger.info(f"  Model family : {model_family}")
    logger.info(f"  Quantization : {quantization}")
    logger.info(f"  Agent mode   : {agent_mode}")
    logger.info(f"  Agent URL    : {agent_url}")
    logger.info(f"  Max concurrent: {max_concurrent}")
    logger.info("")

    # ── Run questions ────────────────────────────────────────────────────
    semaphore = asyncio.Semaphore(max_concurrent)
    results = []

    async with httpx.AsyncClient() as client:
        tasks = []
        for item in dataset:
            task_id = item["task_id"]
            question = item["Question"]
            expected = item.get("Final answer", "")
            level = item["Level"]
            file_name = item.get("file_name", "") or ""

            # Resolve file attachment path
            file_path = None
            if file_name:
                candidate = os.path.join(data_dir, item.get("file_path", ""))
                if os.path.isfile(candidate):
                    file_path = candidate

            prompt = _build_prompt(question, file_path)
            tasks.append((task_id, question, expected, level, file_name, prompt))

        async def _process(task_id, question, expected, level, file_name, prompt):
            result_text, duration_ms = await _call_agent(client, prompt, semaphore, agent_url)
            predicted = _extract_final_answer(result_text)
            correct = score(predicted, expected)

            record = {
                "task_id": task_id,
                "level": level,
                "question": question[:200],
                "file_name": file_name,
                "expected": expected,
                "predicted": predicted,
                "score": correct,
                "duration_ms": round(duration_ms, 2),
            }

            status = "CORRECT" if correct else "WRONG"
            logger.info(
                f"[{status}] Level {level} | expected={expected!r} | "
                f"predicted={predicted!r} | {duration_ms:.0f}ms"
            )
            return record

        coros = [
            _process(tid, q, exp, lvl, fn, p)
            for tid, q, exp, lvl, fn, p in tasks
        ]
        results = await asyncio.gather(*coros)

    # ── Write per-question results ───────────────────────────────────────
    with open(results_path, "w") as f:
        for r in results:
            f.write(json.dumps(r) + "\n")

    # ── Compute summary ──────────────────────────────────────────────────
    total = len(results)
    if total == 0:
        logger.warning("No questions were evaluated. Check your --levels and --limit flags.")
        summary = {"total": 0, "correct": 0, "accuracy": 0.0}
        with open(summary_path, "w") as f:
            json.dump(summary, f, indent=2)
        return

    df = pd.DataFrame(results)
    correct = int(df["score"].sum())
    accuracy = correct / total if total > 0 else 0.0

    per_level = {}
    for lvl in sorted(df["level"].unique()):
        lvl_df = df[df["level"] == lvl]
        lvl_total = len(lvl_df)
        lvl_correct = int(lvl_df["score"].sum())
        per_level[f"level_{lvl}"] = {
            "total": lvl_total,
            "correct": lvl_correct,
            "accuracy": round(lvl_correct / lvl_total, 4) if lvl_total > 0 else 0.0,
        }

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    summary = {
        "timestamp": timestamp,
        "model_family": model_family,
        "quantization": quantization,
        "agent_mode": agent_mode,
        "agent_url": agent_url,
        "dataset": GAIA_DATASET,
        "config": GAIA_CONFIG,
        "split": GAIA_SPLIT,
        "levels": levels,
        "total": total,
        "correct": correct,
        "accuracy": round(accuracy, 4),
        "per_level": per_level,
        "avg_duration_ms": round(float(df["duration_ms"].mean()), 2) if total > 0 else 0.0,
    }

    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2)

    # ── Print summary ────────────────────────────────────────────────────
    logger.info("")
    logger.info("=" * 60)
    logger.info("GAIA Evaluation Summary")
    logger.info("=" * 60)
    logger.info(f"Overall: {correct}/{total} = {accuracy:.1%}")
    for lvl_key, lvl_data in per_level.items():
        logger.info(
            f"  {lvl_key}: {lvl_data['correct']}/{lvl_data['total']} "
            f"= {lvl_data['accuracy']:.1%}"
        )
    logger.info(f"Avg duration: {summary['avg_duration_ms']:.0f}ms")
    logger.info(f"Results saved to: {run_dir}")
    logger.info("=" * 60)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Run GAIA benchmark against the agent API.")
    parser.add_argument("--agent-url", type=str, default=None, help="Agent base URL")
    parser.add_argument("--levels", type=str, default=None, help="Comma-separated levels (e.g. 1,2)")
    parser.add_argument("--limit", type=int, default=None, help="Max questions to run (0=all)")
    parser.add_argument("--output-dir", type=str, default=None, help="Output base directory")
    parser.add_argument("--model-family", type=str, default=None, help="Model family (e.g. qwen-3)")
    parser.add_argument("--quantization", type=str, default=None, help="Quantization config")
    parser.add_argument("--agent-mode", type=str, default=None, help="Agent mode (single-agent|planner-executor)")
    parser.add_argument("--max-concurrent", type=int, default=None, help="Max concurrent requests")
    args = parser.parse_args()
    asyncio.run(run_evaluation(args))


if __name__ == "__main__":
    main()