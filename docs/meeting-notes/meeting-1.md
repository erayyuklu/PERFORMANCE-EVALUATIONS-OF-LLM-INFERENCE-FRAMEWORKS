# Meeting Notes - Week 1

## Feedback

- Google Colab is good for initial prototyping, but transition to Kubernetes and GCP for realistic performance evaluations.
- No need to dive deep into vLLM source code this week.

## Next Steps

- Set up a Kubernetes cluster on GCP and deploy vLLM for benchmarking.
- Document all configurable parameters in vLLM:
  - Installation parameters
    - Setting up on multiple GPUs, tensor parallelism, GPU memory utilization, etc.
  - Runtime parameters
    - Batch size, sequence length, automatic prefix caching, etc.
- Review last year's project to identify experiments worth replicating or extending.
