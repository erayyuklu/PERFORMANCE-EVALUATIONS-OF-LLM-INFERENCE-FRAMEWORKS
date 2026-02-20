# vLLM Parameters: Install-time vs Runtime

---

## Part 1 — Install-time Parameters

These are decisions made **before** vLLM runs. They determine hardware support, compiled optimizations, and available backends. Once installed, these cannot be changed without reinstalling.

### 1.1 Hardware Platform

| Platform    | Details                                               |
| ----------- | ----------------------------------------------------- |
| NVIDIA CUDA | Most common. Requires CUDA 12.x and compatible driver |
| AMD ROCm    | For AMD Instinct GPUs                                 |
| Intel XPU   | For Intel Data Center GPUs                            |
| CPU-only    | Intel/AMD x86, ARM AArch64, Apple Silicon             |

The hardware platform is the **first and most fundamental decision**. It determines which pre-compiled kernels (PagedAttention, Flash Attention) will be available. vLLM compiles custom CUDA kernels at install time — these kernels are what make it fast. Choosing the wrong platform means those optimizations simply don't exist in your build.

NVIDIA CUDA is the primary target. vLLM's core innovations (PagedAttention, continuous batching kernels) are implemented as CUDA kernels first, then ported to other platforms. CUDA builds get the best performance and widest feature coverage.

### 1.2 Installation Method

| Method              | Command                                                                     | Notes                                       |
| ------------------- | --------------------------------------------------------------------------- | ------------------------------------------- |
| pip (pre-built)     | `pip install vllm`                                                          | Fastest. Uses pre-compiled CUDA 12.x wheels |
| pip (specific CUDA) | `pip install vllm --extra-index-url https://download.pytorch.org/whl/cu124` | Match your CUDA version                     |
| Docker              | `docker run --gpus all vllm/vllm-openai:latest`                             | Zero setup. Includes all dependencies       |
| Build from source   | `pip install -e .`                                                          | Full control over compilation flags         |

Pre-built pip wheels target specific CUDA versions (e.g., CUDA 12.4). If your driver supports a different CUDA version, you must either match it via `--extra-index-url` or build from source. **Mismatched CUDA versions** are the #1 installation failure.

Docker is the most reliable method for production because it bundles the exact CUDA toolkit, PyTorch version, and compiled kernels together — no version mismatch possible. This is why our GKE deployment uses the `vllm/vllm-openai` Docker image.

### 1.3 Key Environment Variables (Build-time)

| Variable               | Purpose                       | Example                             |
| ---------------------- | ----------------------------- | ----------------------------------- |
| `CUDA_HOME`            | Path to CUDA toolkit          | `/usr/local/cuda-12.4`              |
| `VLLM_TARGET_DEVICE`   | Target device for compilation | `cuda`, `cpu`, `rocm`               |
| `MAX_JOBS`             | Parallel compilation jobs     | `8`                                 |
| `TORCH_CUDA_ARCH_LIST` | Target GPU architectures      | `7.5;8.0;8.9;9.0` (T4;A100;L4;H100) |

`TORCH_CUDA_ARCH_LIST` is critical: each GPU generation has a **compute capability** number (T4 = 7.5, A100 = 8.0, L4 = 8.9, H100 = 9.0). When building from source, the CUDA kernels are compiled for these specific architectures. If you compile only for `8.0`, the binary **won't run on a T4** (7.5). Pre-built wheels include all common architectures, which is why they're larger but more portable.

### 1.4 What Gets Locked at Install-time

| Component               | Why It Matters                                                                 |
| ----------------------- | ------------------------------------------------------------------------------ |
| Flash Attention         | Compiled CUDA kernel — different versions have different memory efficiency     |
| Quantization backends   | AWQ, GPTQ need specific compiled extensions to decode 4-bit weights on the GPU |
| CUDA compute capability | Determines which GPU generations can run this build                            |
| PyTorch version         | vLLM's kernels are compiled against a specific PyTorch ABI                     |
| PagedAttention kernels  | The core innovation of vLLM — a custom CUDA kernel, not a Python library       |

**Key insight**: vLLM is not just a Python library. It ships **custom CUDA C++ kernels** for PagedAttention, which is why install-time decisions matter so much. These kernels are compiled code that runs directly on the GPU — they cannot be changed at runtime.

---

## Part 2 — Runtime Parameters (`vllm serve`)

These are passed when **starting** the vLLM server. They control model loading, memory allocation, serving behavior, and scheduling. They can be changed on every launch.

```bash
vllm serve <model> [options...]
```

---

### 2.1 Model Configuration (`ModelConfig`)

| Parameter             | Default             | Description                                                        |
| --------------------- | ------------------- | ------------------------------------------------------------------ |
| `--model`             | `Qwen/Qwen3-0.6B`   | HuggingFace model ID or local path                                 |
| `--dtype`             | `auto`              | Weight precision: `auto`, `half`, `bfloat16`, `float16`, `float32` |
| `--tokenizer`         | (same as model)     | Custom tokenizer path                                              |
| `--tokenizer-mode`    | `auto`              | Tokenizer type: `auto`, `hf`, `slow`, `mistral`                    |
| `--max-model-len`     | (from model config) | Maximum context length in tokens                                   |
| `--quantization`      | `None`              | Quantization method: `awq`, `gptq`, `fp8`, `bitsandbytes`, etc.    |
| `--trust-remote-code` | `False`             | Allow executing model's custom code                                |
| `--seed`              | `0`                 | Random seed for reproducibility                                    |
| `--revision`          | `None`              | Specific model revision / commit hash                              |
| `--served-model-name` | (model name)        | Name exposed via the API                                           |

#### `--dtype` — Not Just a Data Type, It's a Hardware Decision

| dtype      | Bits | Memory per 7B model | GPU Support                   |
| ---------- | ---- | ------------------- | ----------------------------- |
| `float32`  | 32   | ~28 GB              | All GPUs                      |
| `float16`  | 16   | ~14 GB              | All GPUs                      |
| `bfloat16` | 16   | ~14 GB              | Ampere+ only (A100, L4, H100) |
| `half`     | 16   | ~14 GB              | Same as float16               |

BF16 has the same memory footprint as FP16 but a **wider dynamic range** (more exponent bits, fewer mantissa bits). This means fewer overflow/underflow issues during inference. However, **T4 GPUs (Turing architecture) do not support BF16** — only Ampere and newer do. So dtype is not just a preference, it's a hardware constraint.

#### `--max-model-len` — The Memory vs Context Trade-off

This controls how long a conversation can be. The model might support 128K tokens, but that doesn't mean your GPU can handle it. KV cache memory grows **linearly** with context length:

```
KV cache per request ≈ 2 × num_layers × hidden_dim × max_model_len × dtype_size
```

For a 7B model with FP16 at 4096 tokens → ~512 MB per request.
At 128K tokens → ~16 GB per request — the **entire GPU** for a single request.

Reducing `max-model-len` frees memory for more KV cache blocks, allowing **more concurrent requests** at the cost of shorter conversations.

#### `--quantization` — Smaller and Sometimes Faster

| Method       | Bits | Quality Loss | Speed Impact                          |
| ------------ | ---- | ------------ | ------------------------------------- |
| None (FP16)  | 16   | None         | Baseline                              |
| AWQ          | 4    | Minimal      | Faster (less memory bandwidth needed) |
| GPTQ         | 4    | Minimal      | Similar to AWQ                        |
| FP8          | 8    | Very low     | Native support on H100                |
| bitsandbytes | 4/8  | Variable     | Supports CPU offload                  |

**Key insight**: LLM inference is **memory-bandwidth-bound**, not compute-bound. The GPU spends more time moving data from memory than doing math. Quantization reduces model size, which means **less data to move** → paradoxically, 4-bit models can be **faster** than 16-bit models despite the added dequantization step.

---

### 2.2 Cache Configuration (`CacheConfig`)

| Parameter                   | Default | Description                                         |
| --------------------------- | ------- | --------------------------------------------------- |
| `--gpu-memory-utilization`  | `0.9`   | Fraction of GPU memory to use (0.0–1.0)             |
| `--kv-cache-dtype`          | `auto`  | KV cache data type: `auto`, `fp8`, `bfloat16`       |
| `--block-size`              | (auto)  | Number of tokens per cache block                    |
| `--swap-space`              | `4`     | CPU swap space per GPU in GiB                       |
| `--enable-prefix-caching`   | (auto)  | Reuse KV cache across requests with shared prefixes |
| `--num-gpu-blocks-override` | `None`  | Manually set the number of GPU cache blocks         |

#### `--gpu-memory-utilization` — This Controls Your Throughput

GPU memory holds two things:

```
GPU Memory = Model Weights (fixed) + KV Cache (variable)
```

For a 7B FP16 model, weights ≈ 14 GB. On a 24 GB L4 GPU with `0.9` utilization:

- Usable memory = 24 × 0.9 = 21.6 GB
- KV cache space = 21.6 - 14 = **7.6 GB**

More KV cache → more concurrent requests → higher throughput. This parameter **indirectly determines your max batch size**. Setting it too high risks OOM; too low wastes expensive GPU memory.

#### `--block-size` and PagedAttention — vLLM's Core Innovation

Traditional inference pre-allocates `max_seq_len` of KV cache per request. If a request only uses 100 tokens out of 4096 allocated → **97% wasted memory**.

vLLM applies the same concept as **OS virtual memory paging** to KV cache. Memory is divided into small blocks (typically 16 tokens each). Blocks are allocated on-demand as the sequence grows. This nearly eliminates memory fragmentation and allows **2-4x more concurrent requests** on the same GPU.

`--block-size` controls the page size. Smaller blocks = less waste but more bookkeeping overhead.

#### `--enable-prefix-caching` — Shared Memory Across Requests

In real applications, every chat request starts with the same system prompt (e.g., "You are a helpful assistant..."). Without prefix caching, the KV cache for this prompt is recomputed for every request.

With prefix caching enabled, the KV cache from shared prefixes is **computed once and reused**. This dramatically reduces **TTFT (Time To First Token)** — the latency the user feels before seeing the first response token.

---

### 2.3 Parallel Configuration (`ParallelConfig`)

| Parameter                          | Default | Description                                   |
| ---------------------------------- | ------- | --------------------------------------------- |
| `--tensor-parallel-size` / `-tp`   | `1`     | Split model layers across N GPUs (horizontal) |
| `--pipeline-parallel-size` / `-pp` | `1`     | Split model stages across N GPUs (vertical)   |
| `--data-parallel-size` / `-dp`     | `1`     | Run N independent replicas                    |
| `--distributed-executor-backend`   | (auto)  | Backend: `mp` (multiprocessing) or `ray`      |

#### Tensor Parallel vs Pipeline Parallel — Two Different Strategies

**Tensor Parallel (TP)**: Splits the weight matrices within each layer across GPUs. Every GPU participates in every layer's computation, then they synchronize via **all-reduce**. Produces the lowest latency but requires **high-bandwidth interconnect** (NVLink: 600 GB/s). Standard PCIe (32 GB/s) creates a bottleneck.

**Pipeline Parallel (PP)**: Assigns different layers to different GPUs (GPU 1 gets layers 0-15, GPU 2 gets layers 16-31). Less inter-GPU communication but introduces **pipeline bubbles** — GPUs wait idle while data flows through the pipeline. Requires **micro-batching** to keep all GPUs busy.

**Data Parallel (DP)**: Each GPU has a full copy of the model and handles different requests. No inter-GPU communication but requires enough memory per GPU to hold the entire model.

**Decision rule**: Single GPU → all set to 1. Multi-GPU with NVLink → prefer TP. Multi-GPU without NVLink → prefer PP. Scaling to many requests → add DP.

---

### 2.4 Scheduler Configuration (`SchedulerConfig`)

| Parameter                    | Default | Description                                    |
| ---------------------------- | ------- | ---------------------------------------------- |
| `--max-num-batched-tokens`   | (auto)  | Max tokens processed in a single iteration     |
| `--max-num-seqs`             | (auto)  | Max concurrent sequences per iteration         |
| `--scheduling-policy`        | `fcfs`  | `fcfs` (first-come-first-served) or `priority` |
| `--enable-chunked-prefill`   | (auto)  | Allow splitting long prefills into chunks      |
| `--max-num-partial-prefills` | `1`     | Max number of partial prefills per step        |

#### Continuous Batching — Why vLLM Is Fast

Traditional (static) batching: collect N requests, process them together, wait for **all** to finish, then start the next batch. The slowest request (longest output) holds up the entire batch.

vLLM uses **continuous batching**: as soon as one request finishes, a new request is immediately inserted into the batch. The batch is dynamic — requests enter and leave independently. This alone can improve throughput by **10-20x** compared to static batching.

- `--max-num-seqs` caps how many sequences are in the batch simultaneously
- `--max-num-batched-tokens` caps the total tokens processed per iteration
- `--enable-chunked-prefill` splits long prompts into chunks so they don't monopolize an entire iteration, allowing decoding steps for other requests to proceed

---

### 2.5 Load Configuration (`LoadConfig`)

| Parameter                     | Default | Description                                                                         |
| ----------------------------- | ------- | ----------------------------------------------------------------------------------- |
| `--load-format`               | `auto`  | Weight format: `auto`, `safetensors`, `pt`, `gguf`, `bitsandbytes`, `sharded_state` |
| `--download-dir`              | `None`  | Directory to download model weights                                                 |
| `--safetensors-load-strategy` | `lazy`  | How to load safetensors files                                                       |

`safetensors` is the modern standard — it uses memory mapping for fast, safe loading without executing arbitrary Python code (unlike pickle-based `.bin` files). The `lazy` strategy loads weight tensors on-demand rather than all at once, reducing peak memory during startup.

For production, `sharded_state` loads pre-sharded checkpoint files, which is significantly faster when using tensor parallelism since each GPU only loads its own shard.

---

### 2.6 Frontend / API Server Configuration (`Frontend`)

| Parameter             | Default      | Description                                    |
| --------------------- | ------------ | ---------------------------------------------- |
| `--host`              | `None`       | Bind address for the server                    |
| `--port`              | `8000`       | Port number                                    |
| `--api-key`           | `None`       | API key for authentication                     |
| `--chat-template`     | (from model) | Custom Jinja2 chat template                    |
| `--uvicorn-log-level` | `info`       | Log level: `debug`, `info`, `warning`, `error` |
| `--allowed-origins`   | `['*']`      | CORS allowed origins                           |
| `--lora-modules`      | `None`       | LoRA adapter modules to load                   |

vLLM exposes an **OpenAI-compatible API**. This means any application built for the OpenAI API can switch to a self-hosted vLLM server by just changing the base URL. The `--served-model-name` and `--chat-template` parameters control how the model appears and behaves through this API.

---

### 2.7 LoRA Configuration (`LoRAConfig`)

| Parameter         | Default             | Description                                       |
| ----------------- | ------------------- | ------------------------------------------------- |
| `--enable-lora`   | `False`             | Enable LoRA adapter support                       |
| `--max-loras`     | `1`                 | Max number of LoRA adapters loaded simultaneously |
| `--max-lora-rank` | `16`                | Maximum LoRA rank (8, 16, 32, 64, 128, 256, 512)  |
| `--lora-dtype`    | `auto`              | Data type for LoRA weights                        |
| `--max-cpu-loras` | (same as max-loras) | Max LoRA adapters stored in CPU memory            |

LoRA (Low-Rank Adaptation) allows serving **multiple fine-tuned variants** from a single base model. The base weights stay in GPU memory, and small LoRA adapters (~1-5% of model size) are swapped in/out per request. This is how one vLLM server can serve a coding assistant, a medical assistant, and a legal assistant simultaneously from the same 7B base model.

---

### 2.8 Observability Configuration (`ObservabilityConfig`)

| Parameter                    | Default | Description                          |
| ---------------------------- | ------- | ------------------------------------ |
| `--disable-log-stats`        | `False` | Disable periodic stats logging       |
| `--enable-log-requests`      | `False` | Log every incoming request           |
| `--aggregate-engine-logging` | `False` | Aggregate engine logs across workers |

For benchmarking and performance evaluation, `--enable-log-requests` is essential — it logs token counts, latencies, and queue times for every request. This data feeds into metrics like TTFT, TPOT, and throughput that define inference framework performance.

---

## Quick Reference: Install-time vs Runtime

| Aspect          | Install-time                                     | Runtime                                |
| --------------- | ------------------------------------------------ | -------------------------------------- |
| **When**        | `pip install` / Docker build                     | `vllm serve` command                   |
| **Can change?** | Requires reinstall                               | Every launch                           |
| **What**        | Hardware kernels, compiled backends, GPU targets | Model, memory, parallelism, scheduling |
| **Scope**       | "What the system **can** do"                     | "How the system **behaves**"           |

---

## References

- [vLLM Installation Guide](https://docs.vllm.ai/en/latest/getting_started/installation/)
- [vllm serve CLI Reference](https://docs.vllm.ai/en/latest/cli/serve/)
- [PagedAttention Paper](https://arxiv.org/abs/2309.06180)
