# GAIA Benchmark — Agent Evaluation

Evaluates the LangGraph agent's response quality on the [GAIA](https://huggingface.co/datasets/gaia-benchmark/GAIA) benchmark: real-world questions requiring multi-step reasoning and tool use.

## Prerequisites

- Python 3.10+
- HuggingFace account with access to the gated GAIA dataset (`huggingface-cli login`)
- Agent API running with `TOOL_MODE=real` and `E2B_API_KEY` set

## Setup

```bash
pip install -r requirements.txt
```

## Configuration

Edit `config.env` or pass CLI flags:

| Variable | Default | Description |
|---|---|---|
| `AGENT_BASE_URL` | `http://localhost:8000` | Agent API endpoint |
| `GAIA_DATASET` | `gaia-benchmark/GAIA` | HuggingFace dataset ID |
| `GAIA_CONFIG` | `2023_all` | Dataset config name |
| `GAIA_SPLIT` | `validation` | Dataset split |
| `GAIA_LEVELS` | `1,2,3` | Difficulty levels to test |
| `LIMIT` | `0` | Max questions (0 = all) |
| `OUTPUT_DIR` | `../results/gaia` | Output directory |
| `REQUEST_TIMEOUT` | `180` | Timeout per question (seconds) |
| `MAX_CONCURRENT` | `4` | Parallel requests to agent |

## Usage

```bash
# Run with defaults from config.env
python run_gaia.py

# Only Level 1, first 10 questions
python run_gaia.py --levels 1 --limit 10

# Override agent URL
python run_gaia.py --agent-url http://agent-ip:8000
```

## Output

Each run creates a timestamped directory under `../results/gaia/`:

```
results/gaia/run_YYYYMMDD_HHMMSS/
├── results.jsonl   # Per-question: task_id, question, expected, predicted, score, level, duration_ms
└── summary.json    # Accuracy overall + per-level breakdown
```

## Scoring

GAIA uses exact-match scoring with normalization:
- Lowercase, strip whitespace
- Normalize numbers (remove commas, strip trailing `.0`)
- Strip currency/unit symbols (`$`, `%`)