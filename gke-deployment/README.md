# GKE vLLM Deployment

Deploy DeepSeek-R1 (distilled 7B) on Google Kubernetes Engine using the official `vllm/vllm-openai` image with T4 GPU.

## Prerequisites

- Google Cloud SDK (`gcloud`) configured with a project
- `kubectl` installed
- `envsubst` available (part of `gettext`)
- A Hugging Face token with access to the model

## Configuration

Edit [`config.env`](config.env) to customize:

- Cluster name, region, zone, machine type
- Model name, vLLM image tag
- GPU type/count, resource requests
- Max sequence length, dtype, memory utilization

## Usage

Run each script in order. Each step is independent and re-runnable.

```bash
# Make scripts executable
chmod +x scripts/*.sh

# 0. Check prerequisites and enable APIs
./scripts/00-prerequisites.sh

# 1. Create GKE cluster with GPU node pool
./scripts/01-setup-cluster.sh

# 2. Deploy vLLM (requires HF_TOKEN)
export HF_TOKEN="your-huggingface-token"
./scripts/02-deploy-vllm.sh

# 3. Test the deployment
./scripts/03-test.sh

# 4. Cleanup (pick one)
./scripts/04-cleanup.sh --deployment   # K8s resources only
./scripts/04-cleanup.sh --cluster      # GKE cluster only
./scripts/04-cleanup.sh --all          # everything
```

## Budget Alert (Cost Control)

Automatically disable billing when spending exceeds the budget. This creates a Pub/Sub topic, a Cloud Function, and a Budget Alert.

```bash
# 5. Set up budget alert pipeline
./scripts/05-setup-budget-alert.sh

# 6. Cleanup budget resources (pick one)
./scripts/06-cleanup-budget.sh --function   # Cloud Function only
./scripts/06-cleanup-budget.sh --budget     # budget alert only
./scripts/06-cleanup-budget.sh --topic      # Pub/Sub topic only
./scripts/06-cleanup-budget.sh --all        # everything
```

Configure budget amount, thresholds, and function settings in `config.env`.

> **Warning:** When triggered, the function removes the billing account from the project, shutting down all paid resources.

## File Structure

```
gke-deployment/
├── config.env                              # all configuration
├── README.md
├── budget/
│   └── function/
│       ├── main.py                         # Cloud Function source
│       └── requirements.txt                # Python dependencies
├── k8s/
│   ├── vllm-deployment.yaml.template       # Deployment manifest
│   └── vllm-service.yaml.template          # Service manifest
└── scripts/
    ├── 00-prerequisites.sh                 # validate tools, enable APIs
    ├── 01-setup-cluster.sh                 # create cluster + GPU pool
    ├── 02-deploy-vllm.sh                   # deploy vLLM to K8s
    ├── 03-test.sh                          # port-forward and test
    ├── 04-cleanup.sh                       # tear down resources
    ├── 05-setup-budget-alert.sh            # budget alert pipeline
    └── 06-cleanup-budget.sh                # remove budget resources
```

## Notes

- The full DeepSeek-R1 (671B) does not fit on T4 GPUs. This deployment uses the **7B distilled** variant.
- `max_model_len` is set to 4096 to fit within T4's 16GB VRAM. Increase if using a larger GPU.
- Model download on first deploy takes several minutes. The readiness probe has a 240s initial delay to account for this.
- Project ID is fetched automatically from `gcloud config get-value project`.
- Disabling billing is a **destructive safety measure** — it will stop all paid resources in the project.
