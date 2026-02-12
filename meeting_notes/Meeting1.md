# 📝 Meeting Notes: LLM Inference Performance

**Project Title:** Performance Evaluations of LLM Inference Frameworks

### 1. Core Concepts
* **Focus:** LLM Serving, Transformer Architecture, KV Cache, PagedAttention.
* **Frameworks:** **vLLM** (Primary), NVIDIA Dynamo (TorchDynamo), and Clang alternatives.

### 2. Project Goals
* **Deployment:** Set up vLLM (Local/Cloud) and optimize configuration.
* **Metrics:** Measure and optimize **Time to First Token (TTFT)** and **Throughput**.
* **Workload Characterization:** Analyze performance changes based on input/output length and batch size.

### 3. Experiments & Analysis
* **Scaling:** Compare Single-GPU vs. Multi-GPU (4x) performance.
* **Quantization:** Evaluate impact on memory reduction vs. performance loss (Floating point precision).
* **Future Scope:** Potential extension to an organizational model serving & fine-tuning platform.

### ✅ Next Steps (Action Items)
- [ ] **Research:** Read the original **vLLM paper** and predecessor studies.
- [ ] **Setup:** Install vLLM and explore core parameters.
- [ ] **Planning:** Define specific metrics for benchmarking.
