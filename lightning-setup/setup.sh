#!/usr/bin/env bash
# =============================================================================
# setup.sh — One-time environment setup for Lightning.ai Studio
#
# Run this once when you first start your GPU Studio:
#   bash setup.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCHMARK_DIR="${SCRIPT_DIR}/../benchmarking"

echo "==> [1/4] Upgrading pip..."
pip install --upgrade pip

echo "==> [2/5] Installing system tools..."
if ! command -v jq &> /dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y -qq jq
fi

echo "==> [3/5] Installing vLLM..."
pip install vllm

echo "==> [4/5] Installing benchmarking dependencies..."
pip install -r "${BENCHMARK_DIR}/requirements.txt"

echo "==> [5/5] Verifying GPU..."
python3 -c "
import torch
if torch.cuda.is_available():
    gpu = torch.cuda.get_device_name(0)
    mem = torch.cuda.get_device_properties(0).total_memory / 1e9
    print(f'  ✓ GPU detected: {gpu} ({mem:.1f} GB)')
else:
    print('  ✗ No GPU detected! Make sure you selected a GPU machine.')
    exit(1)
"

echo ""
echo "==========================================="
echo "  ✅ Setup complete!"
echo "==========================================="
echo ""
echo "  Next steps:"
echo "    1. Export your HF token:  export HF_TOKEN='hf_xxxxx'"
echo "    2. Start vLLM:            bash serve.sh start"
echo "    3. Run benchmarks:        bash run_experiment.sh"
echo ""
