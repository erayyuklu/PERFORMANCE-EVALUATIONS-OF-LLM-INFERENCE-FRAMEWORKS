# Performance Metrics for LLM Inference Benchmarking

## 1. Latency Metrics

Latency metrics describe how fast the system responds **from the user's perspective**. For streaming LLM APIs, the user experience is shaped by multiple latency components — not just a single "response time."

### 1.1 Time to First Token (TTFT)

| Property | Value |
|---|---|
| **Definition** | Wall-clock time from when the request is sent until the first output token is received by the client. |
| **Unit** | Milliseconds (ms) |
| **What it captures** | Prompt processing (prefill phase) + network latency + any queueing delay. |
| **Why it matters** | This is the **perceived responsiveness** of the system. A user staring at a blank screen for 3 seconds feels the system is broken, even if the total generation is fast. |
| **Affected by** | Input prompt length, `--enable-prefix-caching`, `--enable-chunked-prefill`, `--max-num-batched-tokens`, GPU compute power, network round-trip time. |
| **Collection** | Measured client-side: `t_first_token - t_request_sent`. |

> **Note:** TTFT is the metric most affected by prompt length. During the prefill phase, all input tokens are processed in parallel by the model. For a 4096-token prompt on our L4 GPU, prefill alone can take ~400-600 ms.

### 1.2 Time Per Output Token (TPOT)

| Property | Value |
|---|---|
| **Definition** | Average time between consecutive output tokens during the decode phase (after the first token). |
| **Unit** | Milliseconds per token (ms/token) |
| **What it captures** | The sustained generation speed. One decode step ≈ one forward pass of the model. |
| **Why it matters** | Determines how fast text "streams" to the user. If TPOT > 60 ms, the text appears to the user slower than comfortable reading speed (~250 words/min). |
| **Affected by** | Batch size (concurrent sequences), model size, `--dtype`, quantization, `--tensor-parallel-size`, memory bandwidth. |
| **Calculation** | `(t_last_token - t_first_token) / (num_output_tokens - 1)` |

> **Key insight:** TPOT degrades as more concurrent requests share the GPU, because each decode step must process tokens for all active sequences. This is the fundamental throughput vs. latency trade-off in LLM serving.

### 1.3 End-to-End Latency (E2E Latency)

| Property | Value |
|---|---|
| **Definition** | Total wall-clock time from request submission to receiving the final token. |
| **Unit** | Milliseconds (ms) |
| **What it captures** | Everything: queueing + prefill + decode + network overhead. |
| **Why it matters** | The total time the user waits for a complete response. Critical for non-streaming or batch applications. |
| **Calculation** | `t_last_token - t_request_sent` or equivalently `TTFT + (TPOT × (num_output_tokens - 1))` |

### 1.4 Inter-Token Latency (ITL) — Variance

| Property | Value |
|---|---|
| **Definition** | The individual time gap between each pair of consecutive tokens, measured across all token pairs. |
| **Unit** | Milliseconds (ms) |
| **What it captures** | **Smoothness** of the token stream. Unlike TPOT (which is the average), ITL exposes jitter and stalls. |
| **Why it matters** | A system with a low average TPOT but high ITL variance produces a "stuttering" text stream — tokens come in bursts with pauses in between. Users perceive this as laggy. |
| **Report as** | P50, P95, P99, and standard deviation of all inter-token gaps across all requests. |
| **Causes of jitter** | Chunked prefill interrupting decode, KV cache memory swaps, garbage collection pauses, GPU scheduling contention. |

### 1.5 Time in Queue (Queueing Delay)

| Property | Value |
|---|---|
| **Definition** | Time a request spends waiting in vLLM's scheduling queue before processing begins. |
| **Unit** | Milliseconds (ms) |
| **What it captures** | System overload. When `--max-num-seqs` is reached, new requests queue up. |
| **Why it matters** | Under high concurrency, queueing delay can dominate the E2E latency. A system with 50 ms TTFT and 2 seconds of queueing delay has an effective TTFT of 2050 ms. |
| **Collection** | Can be extracted from vLLM server-side logs when `--enable-log-requests` is turned on. |

---

## 2. Throughput Metrics

Throughput metrics describe how much **total work** the system accomplishes per unit time — the supply side of the equation.

### 2.1 Output Token Throughput

| Property | Value |
|---|---|
| **Definition** | Total output tokens generated across all requests per second. |
| **Unit** | Tokens per second (tokens/s) |
| **What it captures** | The system's raw generation capacity. |
| **Why it matters** | The primary throughput metric. Directly determines how many users/requests the system can serve. Higher throughput = lower cost per token. |
| **Calculation** | `total_output_tokens / total_test_duration` |
| **Affected by** | Batch size (concurrent sequences), `--max-num-seqs`, `--gpu-memory-utilization`, quantization, parallelism. |

### 2.2 Request Throughput

| Property | Value |
|---|---|
| **Definition** | Number of completed requests per second. |
| **Unit** | Requests per second (req/s) |
| **What it captures** | System capacity at the request level (not token level). |
| **Why it matters** | Useful for capacity planning. If each user sends 1 request/min, and throughput is 2 req/s, the system can theoretically serve 120 concurrent users. |
| **Calculation** | `total_completed_requests / total_test_duration` |

> **Relationship:** Request throughput × average output tokens per request ≈ output token throughput. These two views of throughput complement each other — token throughput tells you about GPU efficiency, request throughput tells you about user capacity.

### 2.3 Input (Prefill) Token Throughput

| Property | Value |
|---|---|
| **Definition** | Total input tokens processed (prefilled) across all requests per second. |
| **Unit** | Tokens per second (tokens/s) |
| **What it captures** | How quickly the system can "read" new prompts. |
| **Why it matters** | Prefill is compute-bound (all tokens processed in parallel), unlike decode which is memory-bandwidth-bound. A system that is slow at prefill will have high TTFT regardless of decode speed. |
| **Calculation** | `total_input_tokens / total_test_duration` |

---

## 3. Resource Utilization Metrics

These metrics track **how efficiently the hardware is being used** and help identify bottlenecks.

### 3.1 GPU Utilization (%)

| Property | Value |
|---|---|
| **Definition** | Percentage of time the GPU's streaming multiprocessors (SMs) are active. |
| **Unit** | Percentage (%) |
| **Source** | `nvidia-smi`, DCGM exporter, or Kubernetes GPU metrics. |
| **Why it matters** | Low GPU utilization during inference indicates a bottleneck elsewhere (CPU, network, scheduling). LLM decode is memory-bandwidth-bound, so 100% SM utilization is not expected, but very low utilization (<30%) signals a problem. |

### 3.2 GPU Memory Utilization

| Property | Value |
|---|---|
| **Definition** | GPU memory in use vs. total available, broken down into model weights (static) and KV cache (dynamic). |
| **Unit** | GB or percentage (%) |
| **Source** | `nvidia-smi` for total; vLLM logs for the KV cache breakdown. |
| **Why it matters** | Directly determines max concurrency. If the KV cache is full, new requests queue. Monitoring memory usage over time reveals whether `--gpu-memory-utilization` is set appropriately. |

### 3.3 KV Cache Utilization (%)

| Property | Value |
|---|---|
| **Definition** | Fraction of allocated KV cache blocks currently in use. |
| **Unit** | Percentage (%) |
| **Source** | vLLM engine metrics (exposed via logs or Prometheus endpoint). |
| **Why it matters** | The most direct indicator of whether the system is memory-constrained. KV cache at 100% → requests start queueing → latency spikes. KV cache at 20% under load → `--gpu-memory-utilization` could be lowered, or `--max-model-len` reduced to create more blocks. |

### 3.4 GPU Power Consumption

| Property | Value |
|---|---|
| **Definition** | Instantaneous and average power draw of the GPU. |
| **Unit** | Watts (W) |
| **Source** | `nvidia-smi --query-gpu=power.draw` |
| **Why it matters** | Combined with throughput, it gives the energy cost per token — increasingly important for sustainability reporting and cloud cost estimation. |

---

## 4. Quality & Correctness Metrics

These metrics verify that the system is producing **valid, complete outputs** — essential to ensure that performance gains from tuning don't come at the expense of broken outputs.

### 4.1 Request Success Rate

| Property | Value |
|---|---|
| **Definition** | Percentage of requests that return an HTTP 200 with a complete response (finish reason = `stop` or `length`). |
| **Unit** | Percentage (%) |
| **Why it matters** | Under heavy load or with aggressive tuning, requests may timeout, OOM, or get truncated. A throughput number is meaningless if 30% of requests fail. |
| **Calculation** | `successful_requests / total_requests × 100` |

### 4.2 Error Rate & Error Classification

| Property | Value |
|---|---|
| **Definition** | Percentage and types of failed requests, classified by error type. |
| **Unit** | Percentage (%) and categorical breakdown |
| **Common error types** | `timeout`, `connection_error`, `rate_limited` (429), `server_error` (500), `oom` (out of memory). |
| **Why it matters** | Distinguishes between different failure modes. Timeouts suggest latency issues; 500 errors indicate server instability; OOM errors mean memory configuration needs adjustment. |

### 4.3 Output Completeness

| Property | Value |
|---|---|
| **Definition** | Whether the model's response was fully generated (finished with an EOS token or hit `max_tokens`) vs. being truncated or empty. |
| **Unit** | Percentage of complete responses (%) |
| **Why it matters** | A truncated response is a failed response from the user's perspective, even if the HTTP status is 200. Tracking the `finish_reason` field (`stop` vs. `length` vs. missing) is critical. |

---

## 5. Derived & Efficiency Metrics

These combine raw metrics to provide **actionable ratios** for optimization decisions.

### 5.1 Normalized Latency

| Property | Value |
|---|---|
| **Definition** | End-to-end latency divided by the number of output tokens. |
| **Unit** | Milliseconds per token (ms/token) |
| **Calculation** | `E2E_latency / num_output_tokens` |
| **Why it matters** | Allows fair comparison between requests with different output lengths. A 200-token response that takes 2 seconds (10 ms/token) is more efficient than a 10-token response that takes 1 second (100 ms/token). |

### 5.2 Throughput-Latency Ratio (Efficiency Frontier)

| Property | Value |
|---|---|
| **Definition** | Plotting output token throughput (Y-axis) against P50 or P99 TPOT (X-axis) across different configurations. |
| **Unit** | Composite (tokens/s vs. ms/token) |
| **Why it matters** | Every tuning choice (batch size, quantization, memory utilization) moves you along a throughput-latency curve. The goal is to find configurations on the **Pareto frontier** — maximum throughput for a given latency budget. |

### 5.3 Cost per Token

| Property | Value |
|---|---|
| **Definition** | Cloud compute cost divided by total tokens generated during a test run. |
| **Unit** | USD per million tokens ($/M tokens) |
| **Calculation** | `(GPU_hourly_cost × test_duration_hours) / (total_tokens / 1,000,000)` |
| **Why it matters** | The ultimate business metric. A configuration that doubles throughput halves cost per token, but only if it doesn't increase error rate. For our L4 on GKE (≈$0.70/hr), this grounds abstract performance numbers in real dollars. |

### 5.4 Tokens per Joule (Energy Efficiency)

| Property | Value |
|---|---|
| **Definition** | Total tokens generated divided by total energy consumed. |
| **Unit** | Tokens per joule (tokens/J) |
| **Calculation** | `total_output_tokens / (avg_power_watts × test_duration_seconds)` |
| **Why it matters** | Captures how efficiently the hardware converts energy into useful work. Quantized models often produce more tokens per joule despite lower precision — smaller weights → less memory traffic → less energy per token. |

---

## Metric Collection Strategy

### What We Measure Where

| Source | Metrics Collected |
|---|---|
| **Locust (client-side)** | TTFT, TPOT, ITL, E2E latency, request success/error rate, output token counts |
| **vLLM server logs** | Queueing delay, KV cache utilization, prefill/decode durations, batch sizes |
| **nvidia-smi / DCGM** | GPU utilization (%), GPU memory (GB), power draw (W), temperature |
| **GKE / Kubernetes** | Pod restarts, CPU/memory usage of the node, network I/O |

### Statistical Reporting

Raw averages can be misleading — especially for latency. We report every latency metric as:

| Statistic | What It Shows |
|---|---|
| **Mean** | Overall central tendency |
| **Median (P50)** | Typical user experience |
| **P90** | 90% of requests are faster than this |
| **P95** | Tail latency — catches most outliers |
| **P99** | Worst-case user experience |
| **Min / Max** | Absolute bounds |
| **Std Dev** | Spread / consistency |

> **Why P99 matters:** If you serve 1,000 requests/minute, P99 = 5 seconds means ~10 users per minute wait 5+ seconds. At scale, tail latency defines your SLA, not the average.

---

## Summary: Metric Quick Reference

| # | Metric | Category | Unit | Primary / Derived |
|---|---|---|---|---|
| 1 | Time to First Token (TTFT) | Latency | ms | Primary |
| 2 | Time Per Output Token (TPOT) | Latency | ms/token | Primary |
| 3 | End-to-End Latency | Latency | ms | Primary |
| 4 | Inter-Token Latency (ITL) | Latency | ms | Primary |
| 5 | Queueing Delay | Latency | ms | Primary |
| 6 | Output Token Throughput | Throughput | tokens/s | Primary |
| 7 | Request Throughput | Throughput | req/s | Primary |
| 8 | Input Token Throughput | Throughput | tokens/s | Primary |
| 9 | GPU Utilization | Resource | % | Primary |
| 10 | GPU Memory Utilization | Resource | GB / % | Primary |
| 11 | KV Cache Utilization | Resource | % | Primary |
| 12 | GPU Power Consumption | Resource | W | Primary |
| 13 | Request Success Rate | Quality | % | Primary |
| 14 | Error Rate & Classification | Quality | % | Primary |
| 15 | Output Completeness | Quality | % | Primary |
| 16 | Normalized Latency | Efficiency | ms/token | Derived |
| 17 | Throughput-Latency Ratio | Efficiency | composite | Derived |
| 18 | Cost per Token | Efficiency | $/M tokens | Derived |
| 19 | Tokens per Joule | Efficiency | tokens/J | Derived |
