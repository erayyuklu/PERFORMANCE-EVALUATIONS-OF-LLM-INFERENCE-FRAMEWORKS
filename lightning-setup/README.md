# Lightning.ai Setup — vLLM Benchmarking

This directory contains scripts to run vLLM benchmarks on [Lightning.ai](https://lightning.ai/) GPU Studios, replacing the Kubernetes-based GKE deployment with direct process management.

## Why Lightning.ai?

|                   | GKE (previous)             | Lightning.ai (current)             |
| ----------------- | -------------------------- | ---------------------------------- |
| **GPU**           | NVIDIA L4 via GKE          | NVIDIA L4                          |
| **Orchestration** | Kubernetes                 | Direct process                     |
| **Cost**          | GCP billing                | $1.58/hr (free tier: 22 hrs/month) |
| **SSH access**    | Via `gcloud ssh`           | Built-in terminal                  |
| **Setup time**    | ~15 min (cluster + deploy) | ~5 min (pip install)               |

## Directory Structure

```
lightning-setup/
├── config.env          # vLLM serve parameters (model, port, memory, etc.)
├── setup.sh            # One-time: install vLLM + dependencies
├── serve.sh            # Start / stop / restart vLLM server
├── run_experiment.sh   # Run all experiments from experiments.json
└── README.md           # This file

benchmarking/           # Shared (unchanged)
├── locustfile.py       # Locust benchmark (TTFT, TPOT, ITL, E2E)
├── experiments.json    # Experiment configurations
├── prompts/            # Prompt datasets
└── results/            # Output directory
```

## Quick Start

### 1. Create a Lightning.ai GPU Studio

1. Go to [lightning.ai](https://lightning.ai/) → Studios → New Studio
2. Select **L4 GPU**
3. Open the terminal

### 2. Clone the repo

```bash
git clone https://github.com/<your-repo>/PERFORMANCE-EVALUATIONS-OF-LLM-INFERENCE-FRAMEWORKS.git
cd PERFORMANCE-EVALUATIONS-OF-LLM-INFERENCE-FRAMEWORKS/lightning-setup
```

### 3. Run setup (one-time)

```bash
bash setup.sh
```

### 4. Set Hugging Face token

```bash
export HF_TOKEN="hf_xxxxx"
```

### 5. Start vLLM

```bash
bash serve.sh start
bash serve.sh status   # verify it's running
```

### 6. Run benchmarks

```bash
# Run all experiments from experiments.json
bash run_experiment.sh

# Or customize
bash run_experiment.sh --run-time 60s
bash run_experiment.sh --experiments /path/to/custom_experiments.json
```

### 7. Stop vLLM when done

```bash
bash serve.sh stop
```

> **⚠️ Important:** Stop your Lightning.ai Studio when you're done to preserve your free GPU hours!

## serve.sh Commands

| Command                                             | Description                    |
| --------------------------------------------------- | ------------------------------ |
| `bash serve.sh start`                               | Start vLLM with default config |
| `bash serve.sh start --gpu-memory-utilization 0.95` | Start with custom args         |
| `bash serve.sh stop`                                | Gracefully stop vLLM           |
| `bash serve.sh restart`                             | Restart with default config    |
| `bash serve.sh restart --enable-chunked-prefill`    | Restart with new args          |
| `bash serve.sh status`                              | Check health + model info      |
| `bash serve.sh logs`                                | Tail vLLM server logs          |

## Differences from GKE Setup

The benchmarking layer (`locustfile.py`, `experiments.json`, prompt datasets) is **identical** — only the deployment layer changed:

| GKE                                       | Lightning.ai                       |
| ----------------------------------------- | ---------------------------------- |
| `kubectl apply -f deployment.yaml`        | `bash serve.sh start`              |
| `kubectl rollout restart`                 | `bash serve.sh restart --new-args` |
| `kubectl port-forward svc/vllm 8000:8000` | Already on localhost:8000          |
| `kubectl delete namespace vllm`           | `bash serve.sh stop`               |
| `05-monitoring.sh` (Prometheus + Grafana) | `curl localhost:8000/metrics`      |
