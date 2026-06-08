"""
This script calculates the cost per million tokens for input and output separately 
based on the GKE load testing results of gemma4_kv_fp8_baseline.
It assumes the server is run on a g2-standard-4 machine with an hourly cost of $0.706.
"""

import os
import glob
import pandas as pd

# Target directory containing the benchmarking results
script_dir = os.path.dirname(os.path.abspath(__file__))
results_dir = os.path.join(script_dir, "results", "run_20260416_010036", "gemma4_kv_fp8_baseline")

# Fallback to absolute path if the relative path isn't found
if not os.path.exists(results_dir):
    results_dir = r"c:\Projeler\PERFORMANCE-EVALUATIONS-OF-LLM-INFERENCE-FRAMEWORKS\benchmarking\results\run_20260416_010036\gemma4_kv_fp8_baseline"

hourly_cost = 0.706

# Find prometheus metrics files for all concurrency configurations
csv_files = glob.glob(os.path.join(results_dir, "*_prometheus_metrics.csv"))

if not csv_files:
    print(f"Error: No metrics files found in {results_dir}")
    exit(1)

results = []

for filepath in sorted(csv_files):
    basename = os.path.basename(filepath)
    # Extract concurrency from filename (e.g. gemma4_kv_fp8_baseline__u16_prometheus_metrics.csv -> 16)
    concurrency_part = basename.split("__")[-1].replace("_prometheus_metrics.csv", "")
    concurrency = int(concurrency_part.replace("u", ""))
    
    df = pd.read_csv(filepath)
    
    # Filter for input (prompt) and output (generation) token throughput
    prompt_df = df[df['metric_name'] == 'prompt_tokens_per_sec'].copy()
    prompt_df['value'] = pd.to_numeric(prompt_df['value'], errors='coerce')
    
    gen_df = df[df['metric_name'] == 'generation_tokens_per_sec'].copy()
    gen_df['value'] = pd.to_numeric(gen_df['value'], errors='coerce')
    
    # Find peak values (which represent highest capability and lowest cost)
    peak_prompt = prompt_df['value'].max()
    peak_gen = gen_df['value'].max()
    
    # Find average active throughput (ignoring idle intervals where value is 0 or NaN)
    active_prompt = prompt_df[prompt_df['value'] > 0]
    active_gen = gen_df[gen_df['value'] > 0]
    avg_active_prompt = active_prompt['value'].mean() if not active_prompt.empty else 0
    avg_active_gen = active_gen['value'].mean() if not active_gen.empty else 0
    
    # Calculations based on peak token throughput
    # (hourly_cost / (tokens_per_sec * 3600 seconds/hour)) * 1,000,000
    cost_peak_input = (hourly_cost / (peak_prompt * 3600)) * 1000000 if peak_prompt > 0 else float('inf')
    cost_peak_output = (hourly_cost / (peak_gen * 3600)) * 1000000 if peak_gen > 0 else float('inf')
    
    # Calculations based on average active throughput
    cost_avg_active_input = (hourly_cost / (avg_active_prompt * 3600)) * 1000000 if avg_active_prompt > 0 else float('inf')
    cost_avg_active_output = (hourly_cost / (avg_active_gen * 3600)) * 1000000 if avg_active_gen > 0 else float('inf')
    
    results.append({
        'concurrency': concurrency,
        'peak_prompt': peak_prompt,
        'peak_gen': peak_gen,
        'avg_active_prompt': avg_active_prompt,
        'avg_active_gen': avg_active_gen,
        'cost_peak_input': cost_peak_input,
        'cost_peak_output': cost_peak_output,
        'cost_avg_active_input': cost_avg_active_input,
        'cost_avg_active_output': cost_avg_active_output
    })

results_df = pd.DataFrame(results).sort_values(by='concurrency')

print("=" * 90)
print(f" LLM INFERENCE COST ANALYSIS (g2-standard-4 Hourly Cost: ${hourly_cost:.4f})")
print("=" * 90)

for _, r in results_df.iterrows():
    print(f"\nConcurrency: {int(r['concurrency'])} Users")
    print(f"  Input (Prompt) Tokens:")
    print(f"    - Peak Rate: {r['peak_prompt']:.4f} tokens/s -> Lowest Cost/M: ${r['cost_peak_input']:.6f}")
    print(f"    - Avg Active Rate: {r['avg_active_prompt']:.4f} tokens/s -> Avg Active Cost/M: ${r['cost_avg_active_input']:.6f}")
    print(f"  Output (Generation) Tokens:")
    print(f"    - Peak Rate: {r['peak_gen']:.4f} tokens/s -> Lowest Cost/M: ${r['cost_peak_output']:.6f}")
    print(f"    - Avg Active Rate: {r['avg_active_gen']:.4f} tokens/s -> Avg Active Cost/M: ${r['cost_avg_active_output']:.6f}")
    print("-" * 50)

# Global results (Absolute lowest cost achievable)
overall_peak_prompt = results_df['peak_prompt'].max()
overall_peak_gen = results_df['peak_gen'].max()

overall_cost_input = (hourly_cost / (overall_peak_prompt * 3600)) * 1000000
overall_cost_output = (hourly_cost / (overall_peak_gen * 3600)) * 1000000

print("\n" + "=" * 90)
print(" ABSOLUTE MINIMUM COST SUMMARY (GLOBAL PEAK THROUGHPUT)")
print("=" * 90)
print(f"Peak Input Throughput: {overall_peak_prompt:.4f} tokens/sec (at Concurrency = 128)")
print(f"Lowest Cost per Million Input Tokens:  ${overall_cost_input:.6f}")
print(f"Peak Output Throughput: {overall_peak_gen:.4f} tokens/sec (at Concurrency = 128)")
print(f"Lowest Cost per Million Output Tokens: ${overall_cost_output:.6f}")
print("=" * 90)
