# Benchmarking

Repeatable performance benchmarking pipeline for the vLLM GKE deployment.  
Measures every metric defined in [`slides/metrics.md`](../slides/metrics.md) across a configurable experiment matrix.

## Structure

```
benchmarking/
├── locustfile.py          # Locust load test — measures TTFT, TPOT, ITL, E2E
├── experiments.json       # Experiment matrix (vLLM params × concurrency levels)
├── run_experiment.sh      # Automated runner: patch → wait → test → save results
├── analyze_results.ipynb  # Jupyter notebook for visualization and analysis
├── requirements.txt       # Python dependencies
├── prompts/
│   └── dataset.json       # 37 curated prompts: 15 short, 15 medium, 7 long
└── results/               # Auto-created. One subfolder per run_YYYYMMDD_HHMMSS/
```

## Quick Start

### 1. Install dependencies

```bash
cd benchmarking
pip install -r requirements.txt
```

### 2. Deploy vLLM and start monitoring (if not already running)

```bash
cd ../gke-deployment
./scripts/02-deploy.sh
./scripts/05-monitoring.sh
```

### 3. Run a single manual test (single user, medium prompts, 60 seconds)

```bash
# Port-forward vLLM service first
kubectl port-forward svc/vllm-service 8000:8000 -n vllm &

# Run Locust headlessly
VLLM_PROMPT_LEN=medium locust \
  -f locustfile.py \
  --host http://localhost:8000 \
  --headless -u 1 -r 1 --run-time 60s \
  --csv results/manual_test
```

### 4. Run the full experiment matrix

Runs all experiments defined in `experiments.json` automatically.  
Each experiment patches the Kubernetes deployment, waits for readiness, tests, and saves results.

```bash
chmod +x run_experiment.sh
./run_experiment.sh
```

Optional flags:

```bash
./run_experiment.sh \
  --experiments experiments.json \
  --host http://localhost:8000 \
  --run-time 180s
```

### 5. Analyze results

```bash
jupyter notebook analyze_results.ipynb
```

The notebook auto-picks the most recent `results/run_*/` directory and produces:

| Chart | Description |
|---|---|
| TTFT box plot | Distribution of time-to-first-token per experiment × concurrency |
| TPOT box plot | Time-per-output-token; shows decode phase efficiency |
| **Pareto frontier** | Throughput (tokens/s) vs P95 TTFT — the key trade-off chart |
| Cost per token | USD per million output tokens at each concurrency level |
| P99 TTFT heatmap | Quick overview of tail latency across all experiments |
| Error analysis | Failed request breakdown by error type |

## Experiment Matrix

Defined in [`experiments.json`](experiments.json). Each entry specifies:

| Field | Description |
|---|---|
| `name` | Short identifier used in file paths and charts |
| `vllm_extra_args` | Flags passed to the vLLM server (empty = current deployment unchanged) |
| `concurrency` | List of concurrent user counts to test |
| `prompt_categories` | `short` / `medium` / `long` (filters from dataset.json) |

### Configured Experiments

| Experiment | Key Parameter | Purpose |
|---|---|---|
| `baseline` | — | Reference point |
| `max_seqs_8` | `--max-num-seqs 8` | Lower concurrency cap → better single-user latency |
| `max_seqs_32` | `--max-num-seqs 32` | Higher throughput under heavy load |
| `gpu_mem_70` | `--gpu-memory-utilization 0.70` | Conservative memory; fewer KV cache blocks |
| `gpu_mem_95` | `--gpu-memory-utilization 0.95` | Aggressive memory; maximum KV cache |
| `chunked_prefill_on` | `--enable-chunked-prefill` | Reduces TTFT jitter for long prompts |
| `prefix_caching` | `--enable-prefix-caching` | Reuses KV blocks across repeated prefixes |
| `chunked_prefill_plus_prefix_cache` | both | Expected best configuration for mixed prompts |

## Prompt Dataset

[`prompts/dataset.json`](prompts/dataset.json) contains 37 single-turn, context-free prompts:

| Category | Count | Approx input tokens | What it tests |
|---|---|---|---|
| `short` | 15 | ~10–15 | Minimal prefill; measures pure decode speed |
| `medium` | 15 | ~50–65 | Realistic chat prompts; balanced prefill+decode |
| `long` | 7 | ~125–150 | Heavy prefill; stresses TTFT and KV cache |

All prompts are in OpenAI chat format (`role: user`) and are domain-agnostic (no context inflation).

## Metrics Collected

Every Locust request records (client-side):

| Metric | Unit | How measured |
|---|---|---|
| TTFT | ms | `t_first_token - t_request_sent` |
| TPOT | ms/token | `(t_last - t_first) / (output_tokens - 1)` |
| E2E latency | ms | `t_last_token - t_request_sent` |
| ITL P50 / P99 | ms | Percentiles of all inter-token gaps |
| Output tokens | count | Token count in streamed response |
| Success / Error | bool / str | HTTP status + finish_reason |

Locust also writes its standard stats (request/s, p50/p95/p99 response times) to `results/<run_id>/<experiment>/<label>_stats.csv`.

## Reproducibility Notes

- `temperature=0.0` — deterministic outputs for the same prompt
- Prompt ordering is random per Locust worker; use `random.seed()` in locustfile if you need exact reproduction
- Allow 60s warmup before recording (handled by `WARMUP_REQUESTS` in the runner)
- Run on the same GKE node type between experiments to eliminate hardware variance
