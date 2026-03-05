# VLLM Metrics

## General Metrics

* **vllm:corrupted_requests** (Counter): Corrupted requests (total number of requests with NaNs in logits).
* **vllm:external_prefix_cache_hits** (Counter): External prefix cache hits from KV connector cross-instance cache sharing (number of cached tokens).
* **vllm:external_prefix_cache_queries** (Counter): External prefix cache queries from KV connector cross-instance cache sharing (number of queried tokens).
* **vllm:generation_tokens** (Counter): Number of generation tokens processed.
* **vllm:mm_cache_hits** (Counter): Multi-modal cache hits (number of cached items).
* **vllm:mm_cache_queries** (Counter): Multi-modal cache queries (number of queried items).
* **vllm:num_preemptions** (Counter): Cumulative number of preemption from the engine.
* **vllm:prefix_cache_hits** (Counter): Prefix cache hits (number of cached tokens).
* **vllm:prefix_cache_queries** (Counter): Prefix cache queries (number of queried tokens).
* **vllm:prompt_tokens** (Counter): Number of prefill tokens processed.
* **vllm:prompt_tokens_by_source** (Counter): Number of prompt tokens by source.
* **vllm:prompt_tokens_cached** (Counter): Number of cached prompt tokens (local + external).
* **vllm:prompt_tokens_recomputed** (Counter): Number of cached tokens recomputed for forward pass.
* **vllm:request_success** (Counter): Count of successfully processed requests.
* **vllm:engine_sleep_state** (Gauge): Engine sleep state (0=awake, 1=sleeping; weights_offloaded=1 for level 1; discard_all=1 for level 2).
* **vllm:kv_cache_usage_perc** (Gauge): KV-cache usage (1 = 100%).
* **vllm:lora_requests_info** (Gauge): Running stats on LoRA requests.
* **vllm:num_requests_running** (Gauge): Number of requests in model execution batches.
* **vllm:num_requests_waiting** (Gauge): Number of requests waiting to be processed.
* **vllm:e2e_request_latency_seconds** (Histogram): E2E request latency in seconds.
* **vllm:inter_token_latency_seconds** (Histogram): Inter-token latency in seconds.
* **vllm:iteration_tokens_total** (Histogram): Number of tokens per engine_step.
* **vllm:kv_block_idle_before_evict_seconds** (Histogram): Idle time before KV cache block eviction.
* **vllm:kv_block_lifetime_seconds** (Histogram): KV cache block lifetime from allocation to eviction.
* **vllm:kv_block_reuse_gap_seconds** (Histogram): Time gaps between consecutive KV cache block accesses.
* **vllm:request_decode_time_seconds** (Histogram): Time spent in DECODE phase.
* **vllm:request_generation_tokens** (Histogram): Number of generation tokens processed per request.
* **vllm:request_inference_time_seconds** (Histogram): Time spent in RUNNING phase.
* **vllm:request_max_num_generation_tokens** (Histogram): Maximum number of requested generation tokens.
* **vllm:request_params_max_tokens** (Histogram): The `max_tokens` request parameter.
* **vllm:request_params_n** (Histogram): The `n` request parameter.
* **vllm:request_prefill_kv_computed_tokens** (Histogram): New KV tokens computed during prefill (excludes cached).
* **vllm:request_prefill_time_seconds** (Histogram): Time spent in PREFILL phase.
* **vllm:request_prompt_tokens** (Histogram): Number of prefill tokens processed per request.
* **vllm:request_queue_time_seconds** (Histogram): Time spent in WAITING phase.
* **vllm:request_time_per_output_token_seconds** (Histogram): Time per output token per request.
* **vllm:time_to_first_token_seconds** (Histogram): Time to first token (TTFT) in seconds.

---

## Speculative Decoding Metrics

* **vllm:spec_decode_num_accepted_tokens** (Counter): Number of accepted tokens.
* **vllm:spec_decode_num_accepted_tokens_per_pos** (Counter): Accepted tokens per draft position.
* **vllm:spec_decode_num_draft_tokens** (Counter): Number of draft tokens.
* **vllm:spec_decode_num_drafts** (Counter): Number of speculative decoding drafts.

---

## NIXL KV Connector Metrics

* **vllm:nixl_num_failed_notifications** (Counter): Number of failed NIXL KV Cache notifications.
* **vllm:nixl_num_failed_transfers** (Counter): Number of failed NIXL KV Cache transfers.
* **vllm:nixl_num_kv_expired_reqs** (Counter): Number of requests that had their KV expire.
* **vllm:nixl_bytes_transferred** (Histogram): Bytes transferred per NIXL KV Cache transfer.
* **vllm:nixl_num_descriptors** (Histogram): Number of descriptors per NIXL KV Cache transfer.
* **vllm:nixl_post_time_seconds** (Histogram): Transfer post time for NIXL KV Cache transfers.
* **vllm:nixl_xfer_time_seconds** (Histogram): Transfer duration for NIXL KV Cache transfers.

---

## Model Flops Utilization (MFU) Metrics

*Note: Enabled via `--enable-mfu-metrics*`

* **vllm:estimated_flops_per_gpu_total** (Counter): Estimated floating point operations per GPU.
* **vllm:estimated_read_bytes_per_gpu_total** (Counter): Estimated bytes read from memory per GPU.
* **vllm:estimated_write_bytes_per_gpu_total** (Counter): Estimated bytes written to memory per GPU.