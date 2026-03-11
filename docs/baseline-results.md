# Baseline Benchmark Results — 4 Concurrent Users

> **Date:** February 2026  
> **Model:** DeepSeek-R1-Distill-Qwen-7B (7B params, FP16)  
> **GPU:** NVIDIA L4 (24 GB VRAM) × 1  
> **Platform:** GKE (g2-standard-8), vLLM (latest), `max-model-len=4096`, `gpu-memory-utilization=0.90`  
> **Load Generator:** Locust (streaming SSE client)

---

## 1. Test Configuration

| Parameter         | Value                         |
| ----------------- | ----------------------------- |
| Concurrent users  | **4**                         |
| Total requests    | **513**                       |
| Test duration     | **33.9 minutes**              |
| Prompt categories | Mixed (short / medium / long) |
| Max output tokens | 256                           |
| Temperature       | 0.0 (deterministic)           |
| Streaming         | Enabled (SSE)                 |

### Prompt Dataset

- **37 unique prompts** designed to cover real-world LLM use cases
- Short prompts (~10-14 tokens): simple factual questions
- Medium prompts (~52-62 tokens): multi-part technical explanations
- Long prompts (~127-148 tokens): complex system design / architecture questions

| Category | Requests | Proportion |
| -------- | -------- | ---------- |
| Short    | 203      | 39.6%      |
| Medium   | 224      | 43.7%      |
| Long     | 86       | 16.8%      |

---

## 2. Key Results Summary

| Metric                 | Value          |
| ---------------------- | -------------- |
| **Success rate**       | 100% (513/513) |
| **TPOT (mean)**        | 57.35 ms/token |
| **TTFT (mean)**        | 324.2 ms       |
| **E2E latency (mean)** | 14.9 seconds   |
| **Token throughput**   | 64.4 tokens/s  |
| **Request throughput** | 0.25 req/s     |

---

## 3. Latency Metrics — Detailed Breakdown

### 3.1 Time Per Output Token (TPOT)

TPOT is remarkably stable in this test. With 4 concurrent users and vLLM's continuous batching, the decode latency remains close to the hardware floor — indicating that 4 users do not yet saturate the GPU's decode capacity.

| Statistic    | Value (ms/token) |
| ------------ | ---------------- |
| Mean         | 57.35            |
| Median (P50) | 57.32            |
| P95          | 57.53            |
| P99          | 57.74            |
| Min          | 57.00            |
| Max          | 59.06            |

> [!IMPORTANT]
> TPOT variance is ±0.2 ms — essentially constant even with 4 concurrent users. This suggests that the L4 GPU can handle a batch of 4 concurrent decode sequences without measurable overhead. The hardware floor for TPOT on this setup is ~57.3 ms/token.

#### TPOT by Prompt Category

| Category | Mean  | P50   | P99   |
| -------- | ----- | ----- | ----- |
| Short    | 57.36 | 57.32 | 57.74 |
| Medium   | 57.33 | 57.32 | 57.69 |
| Long     | 57.36 | 57.34 | 58.28 |

**Observation:** No significant difference across categories. This is expected — TPOT depends on decode-phase compute, not prompt length (prompt is already processed during prefill).

---

### 3.2 Time to First Token (TTFT)

TTFT captures the prefill phase (processing all input tokens) plus any scheduling or queueing overhead.

| Statistic    | Value (ms) |
| ------------ | ---------- |
| Mean         | 324.2      |
| Median (P50) | 308.2      |
| P95          | 421.6      |
| P99          | 633.0      |
| Min          | 211.0      |
| Max          | 1102.8     |

#### TTFT by Prompt Category

| Category            | Requests | Mean (ms) | P50 (ms) | P95 (ms) | P99 (ms) |
| ------------------- | -------- | --------- | -------- | -------- | -------- |
| Short (~12 tokens)  | 203      | 320.3     | 309.1    | 398.0    | 472.0    |
| Medium (~57 tokens) | 224      | 324.3     | 305.7    | 424.8    | 638.8    |
| Long (~139 tokens)  | 86       | 333.0     | 317.9    | 421.8    | 741.6    |

**Observation:** TTFT difference between short and long prompts is only ~13 ms on average. On this GPU, prefilling up to ~150 input tokens does not create a meaningful bottleneck. The L4's compute capacity can parallelize the prefill of short-to-medium prompts efficiently.

> [!NOTE]
> The max TTFT of 1102 ms is an outlier — likely caused by a transient GPU scheduling hiccup or prefill contention when multiple requests arrive simultaneously. P99 values (473–742 ms) are more representative of worst-case behavior.

---

### 3.3 End-to-End Latency (E2E)

| Statistic    | Value (ms) |
| ------------ | ---------- |
| Mean         | 14,909.6   |
| Median (P50) | 14,927.5   |
| P95          | 15,058.3   |
| P99          | 15,203.4   |
| Min          | 13,791.9   |
| Max          | 15,644.0   |

E2E is dominated by decode time: `E2E ≈ TTFT + TPOT × (output_tokens - 1) ≈ 324 + 57.3 × 255 ≈ 14,936 ms`. The theoretical calculation matches the observed mean within 0.2%.

Requests finishing with `stop` (17 requests, output < 256 tokens) have lower E2E (~13.8s), explaining the min value.

---

### 3.4 Inter-Token Latency (ITL)

ITL measures the **smoothness** of the token stream — whether tokens arrive at a steady rate or in bursts.

| Statistic    | P50 (ms) | P99 (ms) |
| ------------ | -------- | -------- |
| Mean         | 57.31    | 85.10    |
| Median (P50) | 57.29    | 80.95    |
| P95          | 57.56    | 113.09   |
| P99          | 57.93    | 163.05   |
| Max          | 58.32    | 217.56   |

**Observation:** The P50-ITL is essentially identical to TPOT (~57.3 ms), confirming steady token generation. The P99-ITL mean of 85 ms indicates occasional ~50% spikes above the steady state — this jitter likely comes from prefill interruptions (when a new request triggers a prefill while decode is running) or GPU memory management.

---

## 4. Throughput Metrics

| Metric                        | Value             |
| ----------------------------- | ----------------- |
| Output token throughput       | **64.4 tokens/s** |
| Request throughput            | **0.25 req/s**    |
| Total output tokens generated | 130,988           |
| Avg output tokens per request | 255.3             |

### Output Completeness

| Finish Reason                 | Count | Percentage |
| ----------------------------- | ----- | ---------- |
| `length` (hit max_tokens=256) | 496   | 96.7%      |
| `stop` (model generated EOS)  | 17    | 3.3%       |

96.7% of requests hit the `max_tokens` limit — the model wanted to generate more but was capped at 256 tokens. This confirms `max_tokens=256` is an effective cap for benchmarking purposes.

---

## 5. Locust Dashboard Summary

> The full interactive Locust report is available here: [📊 Locust Report (HTML)](../benchmarking/results/locust_report.html)

### Locust Request Statistics

| Endpoint           | Requests | Fails | Avg (ms)  | Min (ms) | Max (ms) | RPS      |
| ------------------ | -------- | ----- | --------- | -------- | -------- | -------- |
| `POST chat/long`   | 86       | 0     | 184.4     | 138      | 621      | 0.04     |
| `POST chat/medium` | 224      | 0     | 175.3     | 137      | 870      | 0.11     |
| `POST chat/short`  | 203      | 0     | 172.3     | 136      | 545      | 0.10     |
| **Aggregated**     | **513**  | **0** | **175.7** | **136**  | **870**  | **0.25** |

> [!TIP]
> Locust's "Average Response Time" (~175 ms) measures the **time to first byte** (TTFB) of the HTTP response, not the full streaming duration. Our custom TTFT metric (~324 ms) includes SSE event parsing overhead on top of this, explaining the difference.

### Locust Response Time Percentiles

| Endpoint       | P50 (ms) | P66 (ms) | P75 (ms) | P90 (ms) | P95 (ms) | P99 (ms) | P100 (ms) |
| -------------- | -------- | -------- | -------- | -------- | -------- | -------- | --------- |
| `chat/long`    | 170      | 180      | 190      | 210      | 230      | 250      | 620       |
| `chat/medium`  | 150      | 160      | 170      | 190      | 220      | 260      | 870       |
| `chat/short`   | 150      | 160      | 170      | 190      | 220      | 260      | 550       |
| **Aggregated** | **150**  | **160**  | **170**  | **190**  | **220**  | **260**  | **870**   |

---

## 6. Theoretical vs. Observed Performance

| Metric                 | Expected (L4 spec)        | Observed              | Notes                                      |
| ---------------------- | ------------------------- | --------------------- | ------------------------------------------ |
| TPOT                   | ~50-60 ms/token (7B FP16) | 57.3 ms               | Within expected range                      |
| Per-request throughput | ~17 tok/s per stream      | 17.5 tok/s per stream | `1000/57.3 = 17.5`                         |
| Aggregate throughput   | ~70 tok/s (4 streams)     | 64.4 tok/s            | Slightly below ideal due to wait_time gaps |
| TTFT (short prompt)    | 200-400 ms                | 320 ms                | Matches expectation                        |

> [!TIP]
> With 4 users, the ideal aggregate throughput would be 4 × 17.5 = 70 tok/s. The observed 64.4 tok/s is 92% of this — the gap comes from Locust's `wait_time` (0.5-1.5s between requests) and occasional non-overlapping windows.

---

## 7. Key Takeaways

1. **TPOT is rock-solid at 57.3 ms even with 4 concurrent users** — vLLM's continuous batching handles 4 sequences without measurable decode overhead. This is a key finding: the system is far from saturated.

2. **TTFT is insensitive to prompt length** in this range (10-150 tokens) — the L4 GPU handles prefill without noticeable delay differences.

3. **100% success rate** — the system is stable under 4-user load with default vLLM parameters.

4. **ITL jitter is minimal** — P99 ITL averages 85 ms (1.5× the median), indicating a smooth streaming experience for all users.

5. **Aggregate throughput ~64.4 tok/s** — the system processes ~130K tokens in 34 minutes across 513 requests with zero failures.

---

## 8. Next Steps — Planned Experiments

The baseline establishes 4-user performance under default settings. Planned experiments will measure degradation across two dimensions:

### Concurrency Scaling (Baseline Experiment)

| Users | Expected TPOT Impact | Key Question                                     |
| ----- | -------------------- | ------------------------------------------------ |
| 4     | 57.3 ms ✓ (measured) | Baseline — no degradation observed               |
| 8     | ~60-80 ms            | When does batching overhead become noticeable?   |
| 16    | ~80-150 ms           | Is latency still acceptable for interactive use? |
| 32    | ~150-300 ms+         | At what point does the system become unusable?   |

### Parameter Tuning Experiments

| Experiment        | vLLM Parameter                   | Hypothesis                                           |
| ----------------- | -------------------------------- | ---------------------------------------------------- |
| `max_seqs_8`      | `--max-num-seqs 8`               | Limits batch size → lower TPOT at cost of throughput |
| `max_seqs_32`     | `--max-num-seqs 32`              | Higher throughput but TPOT may spike                 |
| `gpu_mem_70`      | `--gpu-memory-utilization 0.70`  | Fewer KV cache blocks → earlier queueing             |
| `gpu_mem_95`      | `--gpu-memory-utilization 0.95`  | More KV cache → higher concurrency capacity          |
| `chunked_prefill` | `--enable-chunked-prefill`       | Reduces TTFT jitter under concurrency                |
| `prefix_caching`  | `--enable-prefix-caching`        | Reuses KV blocks for shared prefixes                 |
| Combined          | chunked prefill + prefix caching | Expected best latency profile                        |

---

## Appendix: Infrastructure Details

### GKE Cluster Configuration

| Component       | Specification                        |
| --------------- | ------------------------------------ |
| Machine type    | `g2-standard-8` (8 vCPUs, 32 GB RAM) |
| GPU             | NVIDIA L4 (24 GB VRAM, Ada Lovelace) |
| GPU count       | 1                                    |
| Region          | europe-west3-b                       |
| Disk            | 100 GB SSD                           |
| Container image | `vllm/vllm-openai:latest`            |

### vLLM Runtime Configuration

```json
{
  "model": "deepseek-ai/DeepSeek-R1-Distill-Qwen-7B",
  "max-model-len": 4096,
  "gpu-memory-utilization": 0.9,
  "dtype": "half",
  "tensor-parallel-size": 1,
  "port": 8000
}
```

### Benchmark Tooling

- **Locust** — HTTP load generator with custom SSE streaming parser
- **Custom metrics collection** — per-request TTFT, TPOT, ITL (P50/P99), E2E, finish reason, token counts
- **Experiment runner** — bash script that automates: GKE deployment patching → warmup → Locust run → results collection
