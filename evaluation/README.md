# LM-Eval — Model Quality Evaluation

Evaluate the accuracy of the vLLM-served model using [lm-evaluation-harness](https://github.com/EleutherAI/lm-evaluation-harness). Runs **locally** against the remote vLLM API on GKE.

## Prerequisites

- Python 3.9+
- `kubectl` configured with access to the GKE cluster
- vLLM service running with a LoadBalancer external IP

## Setup

```bash
pip install -r requirements.txt
```

## Configuration

Edit `config.env` to adjust evaluation parameters:

| Variable          | Default                                                    | Description                     |
|-------------------|------------------------------------------------------------|---------------------------------|
| `MODEL_NAME`      | `deepseek-ai/DeepSeek-R1-Distill-Qwen-7B`                 | HuggingFace model ID            |
| `K8S_NAMESPACE`   | `vllm`                                                     | Kubernetes namespace             |
| `TASKS`           | `gsm8k,mmlu,hellaswag,arc_challenge,truthfulqa_mc2`        | Comma-separated lm-eval tasks   |
| `NUM_FEWSHOT`     | `5`                                                        | Number of few-shot examples      |
| `BATCH_SIZE`      | `auto`                                                     | Request batch size               |
| `NUM_CONCURRENT`  | `4`                                                        | Concurrent API requests          |
| `OUTPUT_DIR`      | `./results`                                                | Results output directory         |

## Usage

```bash
# Run with defaults from config.env
bash run_eval.sh

# Override specific settings
bash run_eval.sh --tasks gsm8k,mmlu --num_fewshot 0
```

The script will:
1. Discover the vLLM external IP via `kubectl`
2. Health-check the `/v1/models` endpoint
3. Run `lm_eval` with `local-chat-completions` against the vLLM API
4. Save results to `results/run_<timestamp>/`

## Results

Each run creates a timestamped directory under `results/` containing:
- `eval_config.json` — run metadata
- lm-eval output JSON files with per-task scores and sample logs

## Notes

- **Chat API**: Uses `local-chat-completions` since DeepSeek-R1 is a chat/instruction-tuned model. This supports `generate_until` tasks but not `loglikelihood`-based scoring.
- **No API key needed**: `OPENAI_API_KEY` is set to `"EMPTY"` since vLLM doesn't require authentication.
