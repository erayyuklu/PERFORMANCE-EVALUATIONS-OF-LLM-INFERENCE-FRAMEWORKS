# Experiment Execution Guide

## Overview

| # | File | Experiments | What it measures | Order |
|---|------|-------------|-----------------|-------|
| 1 | `experiments.json` | 3 | Quantization impact on performance | 1st |
| 2 | `experiments_io_profiles.json` | 6 | User profile + input/output length effects | 2nd |
| 3 | `experiments_non_reasoning.json` | 3 | Reasoning vs non-reasoning model comparison | 3rd |
| 4 | `experiments_server_tuning.json` | 7 | vLLM server parameter optimization | 4th |

---

## 1. `experiments.json` — Quantization Impact

### Why?
Quantization compresses model weights to save GPU memory and speed up decoding. **But does it degrade quality?** Measuring this trade-off is a cornerstone of the thesis.

### Experiments

| Experiment | What changes? | vLLM args |
|------------|--------------|-----------|
| `baseline` | Nothing — reference point | (default FP16) |
| `fp8_quantization` | Model weights 16-bit → 8-bit | `--quantization fp8` |
| `bitsandbytes_quantization` | Model weights 16-bit → 4/8-bit | `--quantization bitsandbytes` |

Each runs at 16 and 64 concurrent users.

### ConfigMap Changes
None — runs with the default ShareGPT dataset.

### Expected Results

| Metric | Baseline | FP8 | BitsAndBytes |
|--------|----------|-----|--------------|
| **TTFT** | Reference | ↓ 5-15% lower | ↓ 10-20% lower |
| **TPOT** | Reference | ↓ 10-20% lower | ↓ 15-30% lower |
| **Throughput** | Reference | ↑ Higher | ↑ Highest |
| **lm-eval quality** | Reference | ↓ 1-3% drop | ↓ 3-8% drop |

**Hypothesis:** "Quantization speeds up inference but comes with a quality cost. FP8 offers a reasonable balance; BitsAndBytes is aggressive but risky."

### Post-experiment
```bash
bash evaluation/run_eval.sh  # run quality evaluation for each variant
```

---

## 2. `experiments_io_profiles.json` — Profile + Input/Output Length

### Why?
We are testing two key scenarios:
1. **The Shakespeare problem:** Short input but very long output (creative-short prompts) → the decode phase gets heavily loaded.
2. **Profile-based behavior differences:** Is the model faster at coding prompts or creative writing?

### Experiments

| Experiment | What it measures |
|------------|-----------------|
| `custom_all_profiles` | All profiles mixed — general reference |
| `custom_coding_only` | Coding prompts only |
| `custom_creative_only` | Creative writing only (includes short-input-long-output) |
| `custom_reasoning_only` | Math/logic only |
| `custom_short_input_only` | Short inputs across all profiles |
| `custom_long_input_only` | Long inputs across all profiles |

### ConfigMap Changes
```
DATASET_TYPE=custom
VLLM_USER_PROFILE=<per experiment: all / coding / creative / reasoning>
VLLM_PROMPT_LEN=<per experiment: all / short / long>
```

### Expected Results

| Scenario | TTFT | TPOT | E2E |
|----------|------|------|-----|
| **Short input** | ↓ Very low (small prefill) | Normal | Short |
| **Long input** | ↑ High (large prefill) | Normal | Long |
| **Creative (short-input-long-output)** | ↓ Low | Normal but E2E ↑ very long | **Very long** (thousands of tokens to generate) |
| **Coding** | Medium | Medium | Medium-long |
| **Reasoning** | Medium | ↑ High (chain-of-thought extended thinking) | Long |

**Hypothesis:** "Creative-short prompts will have the lowest TTFT but the highest E2E. Reasoning prompts will show high TPOT due to thinking tokens."

---

## 3. `experiments_non_reasoning.json` — Model Comparison

### Why?
DeepSeek-R1 is a **reasoning model** — it generates a `<think>...</think>` block before every answer. This extra token generation affects performance. **How does a same-size non-reasoning model (Qwen2.5-7B-Instruct) compare?**

### Experiments

| Experiment | Model | Quantization |
|------------|-------|-------------|
| `non_reasoning_baseline` | Qwen2.5-7B-Instruct | None (FP16) |
| `non_reasoning_fp8` | Qwen2.5-7B-Instruct | FP8 |
| `non_reasoning_bitsandbytes` | Qwen2.5-7B-Instruct | BnB |

### ConfigMap Changes
Model is automatically switched via `vllm_extra_args` (`--model Qwen/Qwen2.5-7B-Instruct --reasoning-parser none`).

### Expected Results

| Comparison | Reasoning (DeepSeek-R1) | Non-reasoning (Qwen2.5) |
|------------|-------------------------|--------------------------|
| **TTFT** | Similar | Similar |
| **TPOT** | ↑ Higher (thinking tokens) | ↓ Lower |
| **E2E** | ↑ Much longer | ↓ Shorter |
| **Output token count** | ↑ High (think + answer) | ↓ Low (answer only) |
| **Quantization sensitivity** | **?** To be measured | **?** To be measured |
| **lm-eval gsm8k** | ↑ Higher (reasoning advantage) | ↓ Lower |
| **lm-eval mmlu** | Similar | Similar |

**Hypothesis:** "The non-reasoning model wins on speed metrics but loses on reasoning benchmarks (gsm8k). Whether quantization causes greater quality loss in reasoning models is a key finding of this thesis."

### Post-experiment
```bash
# Update evaluation config for the Qwen model:
# MODEL_NAME="Qwen/Qwen2.5-7B-Instruct" and ENABLE_THINKING=false
bash evaluation/run_eval.sh
```

---

## 4. `experiments_server_tuning.json` — vLLM Parameter Optimization

### Why?
vLLM's internal parameters directly control the throughput ↔ latency trade-off. This experiment answers: **"How do we get maximum efficiency from this GPU?"**

### Experiments

| Experiment | Parameter | Value | What it does |
|------------|-----------|-------|-------------|
| `chunked_prefill` | `--enable-chunked-prefill` | on | Chunks long prompt prefills, reducing head-of-line blocking for short requests |
| `max_num_seqs_8` | `--max-num-seqs` | 8 | Small batch → low latency, low throughput |
| `max_num_seqs_32` | `--max-num-seqs` | 32 | Medium batch → balanced |
| `max_num_seqs_128` | `--max-num-seqs` | 128 | Large batch → high throughput, high latency |
| `gpu_mem_085` | `--gpu-memory-utilization` | 0.85 | Less KV cache space → fewer concurrent sequences |
| `gpu_mem_090` | `--gpu-memory-utilization` | 0.90 | Slightly more space |
| `chunked_prefill_max_seqs_32` | Both combined | on + 32 | Most promising combination |

### ConfigMap Changes
None — runs with the default ShareGPT dataset. vLLM deployment is automatically patched.

### Expected Results

| Parameter | TTFT impact | Throughput impact | Risk |
|-----------|-------------|-------------------|------|
| **chunked-prefill ON** | ↓ Lower, especially for long prompts | → Neutral or slight increase | Low |
| **max-num-seqs ↑** | ↑ Increases (more queuing) | ↑ Increases (better GPU utilization) | OOM risk |
| **max-num-seqs ↓** | ↓ Decreases (less queuing) | ↓ Decreases (GPU sits idle) | Low |
| **gpu-mem ↓** | → Neutral | ↓ Decreases (less KV cache) | Low |

**Hypothesis:** "`chunked_prefill_max_seqs_32` will provide the best throughput/latency balance. `max_num_seqs_128` will yield high throughput but P99 TTFT will spike."

---

## Execution Summary

```
1. experiments.json              ~  4 Locust runs  (2 experiments × 2 concurrency levels)
   └── + 3× lm-eval              +  3 quality evaluations

2. experiments_io_profiles.json  ~ 12 Locust runs  (6 experiments × 2 concurrency levels)
   └── Update ConfigMap           DATASET_TYPE=custom, per-experiment profile

3. experiments_non_reasoning.json ~  6 Locust runs  (3 experiments × 2 concurrency levels)
   └── + 3× lm-eval              +  3 quality evaluations (different model)

4. experiments_server_tuning.json ~ 17 Locust runs  (7 experiments × 2-3 concurrency levels)
```

**Total: ~39 Locust runs + ~6 lm-eval evaluations**

Each Locust run takes ~3 minutes (180s) plus cooldown and rollout time. Server tuning experiments require deployment restarts (~15 min rollout each), so that batch may take ~3-4 hours. Other batches take approximately 30-45 minutes each.
