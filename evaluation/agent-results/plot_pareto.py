import os
import pandas as pd
import matplotlib.pyplot as plt
import numpy as np

# Define file mappings: (input_csv, output_base_name, plot_title, reduction_type)
JOBS = [
    (
        "comparison_cost_adjusted.csv",
        "phase2_pareto_cost_adjusted_percentage",
        "Phase 2 Performance Trade-off: Accuracy vs. % Cost Reduction",
        "percentage"
    )
]

def plot_file(csv_name, output_base, title, reduction_type):
    dir_path = os.path.dirname(__file__)
    csv_path = os.path.join(dir_path, csv_name)
    output_png = os.path.join(dir_path, f"{output_base}.png")
    
    if not os.path.exists(csv_path):
        print(f"Warning: File not found: {csv_path}")
        return
        
    # Load and parse CSV (semicolon delimiter and decimal comma)
    df = pd.read_csv(csv_path, sep=";", decimal=",")
    df.set_index("Metric", inplace=True)
    
    # Transpose to get configurations as rows
    df_transposed = df.transpose()
    df_transposed = df_transposed.apply(pd.to_numeric)
    
    configs = df_transposed.index.tolist()
    accuracies = df_transposed["Accuracy (%)"].tolist()
    costs = df_transposed["Cost"].tolist()
    durations = df_transposed["Duration (s)"].tolist()
    
    # Find baseline cost (Large-Planner-Executor)
    baseline_config_name = "Large-Planner-Executor"
    if baseline_config_name not in configs:
        # Fallback to look up containing string if exact match fails
        for c in configs:
            if "large" in c.lower() and "planner" in c.lower() and "executor" in c.lower():
                baseline_config_name = c
                break
    
    baseline_cost = df_transposed.loc[baseline_config_name, "Cost"]
    
    # Calculate cost reductions (always percentage here, but keeping structure clean)
    cost_reductions = []
    for cost in costs:
        if reduction_type == "absolute":
            red = baseline_cost - cost
        else:  # percentage
            red = ((baseline_cost - cost) / baseline_cost) * 100 if baseline_cost > 0 else 0.0
        cost_reductions.append(red)
            
    # Set up styling (Academic style, white background, no boxes)
    plt.figure(figsize=(9, 6), facecolor="white")
    ax = plt.gca()
    ax.set_facecolor("white")
    
    # Enable grid with light gray color
    plt.grid(True, which="both", linestyle="--", linewidth=0.5, color="#D3D3D3")
    
    PRIMARY_COLOR = "#003366"  # Dark Blue
    SECONDARY_COLOR = "#4A6B82"  # Slate Blue
    
    # Plot all points
    
    for i, config in enumerate(configs):
        if config == "Planner-Executor":
            # Highlight our hybrid sweet spot
            plt.scatter(cost_reductions[i], accuracies[i], s=50, 
                        color=PRIMARY_COLOR, edgecolor=PRIMARY_COLOR, 
                        linewidth=2, zorder=5, label="Hybrid Agent")
        else:
            plt.scatter(cost_reductions[i], accuracies[i], s=50, 
                        color=SECONDARY_COLOR, edgecolor="#A0A0A0", 
                        linewidth=1.5, zorder=4)
            
    # Calculate Pareto Frontier dynamically
    # Sort points by cost reduction descending, then accuracy descending
    sorted_points = sorted(
        zip(cost_reductions, accuracies, range(len(configs))),
        key=lambda item: (-item[0], -item[1])
    )
    
    pareto_indices = []
    max_acc = -1
    for cost_red, acc, idx in sorted_points:
        if acc > max_acc:
            pareto_indices.append(idx)
            max_acc = acc
            
    # Sort Pareto indices by cost reduction ascending for plotting the line
    pareto_indices.sort(key=lambda idx: cost_reductions[idx])
    
    pareto_x = [cost_reductions[idx] for idx in pareto_indices]
    pareto_y = [accuracies[idx] for idx in pareto_indices]
    
    plt.plot(pareto_x, pareto_y, linestyle="--", color=PRIMARY_COLOR, 
             linewidth=1.5, zorder=3, label="Pareto Frontier")
    
    # Custom adjustments for annotations to prevent overlap (in offset points)
    adjustments = {
        "Single-Agent": (-12, 0, "right"),
        "Small-Planner-Executor": (-12, 0, "right"),
        "Planner-Executor": (12, 0, "left"),
        "Planner-Only": (10, 10, "left"),
        "Large-Planner-Executor": (10, 16, "left")
    }
    
    # Map configuration names to their descriptive planner/executor models for plot labels
    config_labels = {
        "Large-Planner-Executor": "Planner: Gemini 3 Flash\nExecutor: Gemini 3 Flash",
        "Planner-Executor": "Planner: Gemini 3 Flash\nExecutor: Gemma 4 26B",
        "Small-Planner-Executor": "Planner: Gemma 4 26B\nExecutor: Gemma 4 26B",
        "Planner-Only": "Gemini 3 Flash",
        "Single-Agent": "Gemma 4 26B"
    }
    
    for i, config in enumerate(configs):
        x = cost_reductions[i]
        y = accuracies[i]
        
        # Position offset and alignment
        dx, dy, ha = adjustments.get(config, (12, 0, "left"))
        
        # Get descriptive label from configuration mapping
        label_name = config_labels.get(config, config.replace("-", " "))
            
        # Format the exact cost nicely
        cost_val = costs[i]
        if cost_val == 0:
            cost_str = "$0.00"
        elif cost_val < 0.01:
            cost_str = f"${cost_val:.6f}".rstrip('0').rstrip('.')
        else:
            cost_str = f"${cost_val:.4f}".rstrip('0').rstrip('.')
        
        plt.annotate(
            f"{label_name}\n({accuracies[i]:.1f}%, {cost_str})",
            (x, y),
            textcoords="offset points",
            xytext=(dx, dy),
            ha=ha,
            va="center",
            fontsize=9,
            fontweight="bold" if config == "Planner-Executor" else "normal",
            color=PRIMARY_COLOR if config == "Planner-Executor" else "#333333",
            zorder=6
        )
        
        if config == "Large-Planner-Executor":
            plt.annotate(
                "Baseline",
                (x, y),
                textcoords="offset points",
                xytext=(0, -12),
                ha="center",
                va="top",
                fontsize=9,
                fontweight="bold",
                color="#555555",
                zorder=6
            )

    # Highlight pointer text for our sweet spot (Planner-Executor is static sweet spot)
    plt.annotate(
        f"Optimal Sweet Spot\nCosts 90% Less\nMaintains 80% Accuracy\nCompared to Baseline",
        xy=(cost_reductions[configs.index("Planner-Executor")], accuracies[configs.index("Planner-Executor")]),
        textcoords="offset points",
        xytext=(-120, -55),
        arrowprops=dict(arrowstyle="->", color=PRIMARY_COLOR, linewidth=1),
        fontsize=9,
        fontweight="bold",
        color=PRIMARY_COLOR,
        bbox=dict(boxstyle="round,pad=0.5", facecolor="#F0F4F8", edgecolor=PRIMARY_COLOR, linewidth=0.5),
        ha="center",
        va="center"
    )

    # Configure axes
    plt.ylim(30, 95)
    
    if reduction_type == "absolute":
        plt.xlim(-0.01, 0.14)
        ax.set_xticks([0.0, 0.02, 0.04, 0.06, 0.08, 0.10, 0.12, 0.14])
        ax.set_xticklabels(["$0.00", "$0.02", "$0.04", "$0.06", "$0.08", "$0.10", "$0.12", "$0.14"])
        plt.xlabel("Cost Reduction per Question (USD)", fontsize=11, fontweight="bold", color=PRIMARY_COLOR)
    else:
        plt.xlim(-8, 112)
        ax.set_xticks([0, 20, 40, 60, 80, 100])
        ax.set_xticklabels(["0%", "20%", "40%", "60%", "80%", "100%"])
        plt.xlabel("Cost Reduction (%)", fontsize=11, fontweight="bold", color=PRIMARY_COLOR)
        
    plt.ylabel("GAIA Level 1 Accuracy (%)", fontsize=11, fontweight="bold", color=PRIMARY_COLOR)
    
    # Clean up spines (No top/right boxes)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.spines["left"].set_color(PRIMARY_COLOR)
    ax.spines["bottom"].set_color(PRIMARY_COLOR)
    
    # Legend
    plt.legend(frameon=True, facecolor="white", edgecolor="#D3D3D3", loc="upper right")
    plt.title(title, fontsize=12, fontweight="bold", color=PRIMARY_COLOR, pad=15)
    
    plt.tight_layout()
    plt.savefig(output_png, dpi=300)
    plt.close()
    print(f"Successfully generated for {csv_name} ({reduction_type}):\n - {output_png}")

def main():
    for csv_name, output_base, title, reduction_type in JOBS:
        plot_file(csv_name, output_base, title, reduction_type)

if __name__ == "__main__":
    main()
