# Meeting Notes - Week 3

## Summary

- Discussed the GCP free tier expiration issue and the inability to rent new GPUs. Will attempt to find a workaround to continue experiments.
- Received guidance on next directions for benchmarking — focusing on output token behavior, GPU utilization metrics, and combining vLLM-side data with our custom reports.

## Feedback

- Tests can be designed around **return (output) tokens** — e.g., sending short prompts and requesting long responses to stress-test generation throughput.
- GPU utilization should be measured more carefully:
  - **KV cache ratio** — how much of the key-value cache is being used.
  - **Memory usage** — track GPU memory consumption during inference.
  - Consider using a **larger/more demanding model** to push GPU limits and surface bottlenecks.
- **Data consolidation** is the main task for next week: merge vLLM-reported metrics with our custom benchmark reports to produce meaningful, unified insights.

## Discussion Points & Research Items

- **Output-heavy test scenarios:** Design prompts that yield long completions (short input → long output) to isolate and measure token generation performance.
- **GPU stress metrics:** Go beyond latency/throughput — monitor KV cache utilization, VRAM usage, and compute saturation to understand how hard the GPU is being pushed.
- **Unified reporting:** vLLM exposes its own telemetry (e.g., via `/metrics` endpoint); combining this with Locust-side and custom script metrics will give a more complete picture.

## Next Steps

- [ ] **GCP:** Resolve the free tier / GPU availability issue to resume cloud-based experiments.
- [ ] **Test design:** Create short-prompt, long-output test scenarios to benchmark return token generation.
- [ ] **GPU metrics:** Integrate KV cache ratio and memory usage tracking into the benchmarking pipeline.
- [ ] **Model scaling:** Evaluate running a more capable (larger) model to better stress-test GPU resources.
- [ ] **Data merge:** Combine vLLM-side metrics with custom benchmark reports into a unified, interpretable dataset — this is the primary deliverable for next week.
