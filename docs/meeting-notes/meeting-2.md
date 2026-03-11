# Meeting Notes - Week 2

## Summary

- Presented how vLLM is deployed and served on GKE (Google Kubernetes Engine).
- Walked through the [vLLM Parameters](../slides/vllm-parameters.md) document, covering install-time vs runtime parameter categories.

## Feedback

- Define a set of **performance metrics** and systematically observe how they change as parameters are tuned.
- Build a **repeatable experiment pipeline** — ideally with a UI where a user can adjust parameters, trigger a test run, and visualize Locust test results graphically afterward.

## Discussion Points & Research Items

- **Model source flexibility:** Investigate whether vLLM only pulls models from Hugging Face or if we can customize/bring our own models at deployment time.
- **Performance metrics beyond low-level:** Current metrics (TTFT, token throughput, etc.) are a starting point. Explore additional, higher-level or application-specific metrics as the experiments evolve.
- **Testing approach:**
  - Use **Locust** for load testing, initially assuming requests come from a single user.
  - Start simple: **1 question → 1 answer**, without inflating the conversation context.
  - Use a **standardized prompt dataset** (e.g., aligned with OpenAI's format) — context-free, single-turn prompts sent one by one.

## Next Steps

- [ ] **Research:** Determine how vLLM resolves models — Hugging Face only vs. custom/local model support in deployments.
- [ ] **Metrics:** Define a comprehensive list of performance metrics to track (beyond TTFT, throughput).
- [ ] **Pipeline:** Design and implement a repeatable benchmarking pipeline (parameter selection → Locust test execution → result visualization).
- [ ] **Experiment:** Run initial single-user, single-turn Locust benchmarks against the GKE-deployed vLLM instance using a context-free prompt dataset.
