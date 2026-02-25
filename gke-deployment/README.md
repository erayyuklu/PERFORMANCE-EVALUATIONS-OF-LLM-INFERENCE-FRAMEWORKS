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

## Monitoring (Prometheus + Grafana)

The monitoring stack deploys **kube-prometheus-stack** (Prometheus, Grafana, Alertmanager) and automatically wires up vLLM metric scraping and dashboard provisioning.

```bash
# 5. Deploy the monitoring stack
./scripts/05-monitoring.sh
```

This script:
1. Installs `kube-prometheus-stack` via Helm into the `monitoring` namespace.
2. Downloads the **official vLLM Grafana dashboards** from the [vllm-project/vllm](https://github.com/vllm-project/vllm) GitHub repo.
3. Creates a ConfigMap so the Grafana sidecar auto-imports the dashboards.
4. Applies a `PodMonitor` so Prometheus scrapes vLLM pods on port `8000/metrics` every 15s.

### Accessing the UIs

**Grafana** (dashboards & visualization):

```bash
kubectl port-forward svc/monitoring-grafana 3000:80 -n monitoring
# → http://localhost:3000  (login: admin / admin)
```

**Prometheus** (raw metrics & queries):

```bash
kubectl port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 -n monitoring
# → http://localhost:9090
```

### Key Dashboards

All dashboards are auto-provisioned under the **"vLLM Monitoring"** folder in Grafana:

| Dashboard | What it shows |
|---|---|
| **Performance Statistics** | Latency (TTFT, TPOT, E2E), throughput (tokens/sec), GPU KV cache utilization |
| **Query Statistics** | Request volume, queue depth, active/pending/finished requests |
| **vLLM Overview** (legacy) | Combined view of request metrics, model performance, and resource usage |

## Budget Alert (Cost Control)

Automatically disable billing when spending exceeds the budget. This creates a Pub/Sub topic, a Cloud Function, and a Budget Alert.

```bash
# Deploy budget alert pipeline
./budget/scripts/deploy.sh

# Cleanup budget resources
./budget/scripts/cleanup.sh
```

Configure budget amount and thresholds in [`budget/budget-config.env`](budget/budget-config.env).

> **Warning:** When triggered, the Cloud Function removes the billing account from the project, shutting down all paid resources.

## File Structure

```
gke-deployment/
├── config.env                              # all configuration
├── secrets.env                             # HF_TOKEN (git-ignored)
├── README.md
├── budget/
│   ├── budget-config.env                   # budget-specific settings
│   ├── function/
│   │   ├── main.py                         # Cloud Function source
│   │   └── requirements.txt                # Python dependencies
│   └── scripts/
│       ├── deploy.sh                       # deploy budget alert pipeline
│       └── cleanup.sh                      # remove budget resources
├── k8s/
│   ├── config.json                         # vLLM args (model, dtype, etc.)
│   ├── deployment.yaml                     # vLLM Deployment manifest
│   ├── service.yaml                        # vLLM Service manifest
│   └── monitoring/
│       └── pod-monitor.yaml                # PodMonitor for Prometheus scraping
└── scripts/
    ├── 00-prerequisites.sh                 # validate tools, enable APIs
    ├── 01-gke.sh                           # create cluster + GPU pool
    ├── 02-deploy.sh                        # deploy vLLM to K8s
    ├── 03-test.sh                          # port-forward and test
    ├── 04-cleanup.sh                       # tear down resources
    └── 05-monitoring.sh                    # deploy Prometheus + Grafana
```

## Notes

- The full DeepSeek-R1 (671B) does not fit on T4 GPUs. This deployment uses the **7B distilled** variant.
- `max_model_len` is set to 4096 to fit within T4's 16GB VRAM. Increase if using a larger GPU.
- Model download on first deploy takes several minutes. The readiness probe has a 240s initial delay to account for this.
- Project ID is fetched automatically from `gcloud config get-value project`.
- Disabling billing is a **destructive safety measure** — it will stop all paid resources in the project.
