#!/usr/bin/env python3
"""
Generate the two poster-ready figures that capture the heart of Phase 1
(vLLM serving optimization on a single NVIDIA L4).

Figure 1 -- "The free lunch":
    FP8 KV cache vs. the default FP16 KV cache. Output-token throughput scales
    far better with concurrency, while accuracy is untouched (KV-cache precision
    does not change model weights). Annotated with the dramatic TTFT collapse.
    Data: benchmarking/results/unified_summary_qwen3.csv

Figure 2 -- "Know your hardware":
    Pushing KV-cache compression *past* FP8 with TurboQuant (down to 3-4 bits)
    BUYS NO quality but LOSES throughput on the L4 -- the dequantization compute
    overhead dominates. Data: benchmarking/results/turboquant_perf_quality_summary.csv

Both charts: Qwen3-8B, single NVIDIA L4, ShareGPT load test via distributed Locust.
"""

from pathlib import Path

import matplotlib.pyplot as plt
import matplotlib.font_manager as fm
import numpy as np
import pandas as pd
from matplotlib.patches import FancyBboxPatch

# --------------------------------------------------------------------------- #
# Paths
# --------------------------------------------------------------------------- #
HERE = Path(__file__).resolve().parent
RESULTS = HERE / "results"
OUTDIR = RESULTS / "poster_figures"
OUTDIR.mkdir(parents=True, exist_ok=True)

# --------------------------------------------------------------------------- #
# Shared poster style -- clean, high-contrast, large type
# --------------------------------------------------------------------------- #
INK = "#1d2433"          # near-black text
MUTED = "#5b6577"        # secondary text / grid
GRID = "#e4e8f0"
PANEL = "#ffffff"

# Accent palette
WIN = "#1f8a5b"          # FP8 -> the winning / recommended config (green)
BASE = "#9aa6bd"         # default / baseline (muted grey-blue)
LOSS = "#c0563b"         # the "too far" configs (warm red)
ACCENT = "#2563c9"       # callout blue

plt.rcParams.update({
    "font.family": "DejaVu Sans",
    "font.size": 14,
    "text.color": INK,
    "axes.edgecolor": MUTED,
    "axes.labelcolor": INK,
    "axes.titlecolor": INK,
    "xtick.color": INK,
    "ytick.color": INK,
    "axes.linewidth": 1.1,
    "figure.facecolor": PANEL,
    "axes.facecolor": PANEL,
    "savefig.facecolor": PANEL,
})


def _save(fig, stem):
    for ext in ("png", "svg"):
        fig.savefig(OUTDIR / f"{stem}.{ext}", dpi=300, bbox_inches="tight")
    print(f"  saved {OUTDIR / (stem + '.png')}")


# --------------------------------------------------------------------------- #
# FIGURE 1 -- FP8 KV cache throughput scaling
# --------------------------------------------------------------------------- #
def figure1_fp8_throughput():
    df = pd.read_csv(RESULTS / "unified_summary_qwen3.csv")

    default = df[df.experiment == "qwen3_kv_cache_auto"].sort_values("users")
    fp8 = df[df.experiment == "qwen3_kv_cache_fp8"].sort_values("users")

    users = default["users"].to_numpy()
    y_default = default["gen_throughput_mean"].to_numpy()
    y_fp8 = fp8["gen_throughput_mean"].to_numpy()

    # Peak-load throughput gain
    peak_gain = (y_fp8[-1] / y_default[-1] - 1) * 100

    # TTFT collapse at 64 concurrent users (mean)
    ttft_default_64 = float(default[default.users == 64]["ttft_mean"].iloc[0])
    ttft_fp8_64 = float(fp8[fp8.users == 64]["ttft_mean"].iloc[0])
    ttft_factor = ttft_default_64 / ttft_fp8_64

    fig, ax = plt.subplots(figsize=(10.0, 6.2))

    ax.plot(users, y_default, "-o", color=BASE, lw=3.2, ms=11,
            markerfacecolor="white", markeredgecolor=BASE, markeredgewidth=2.6,
            label="Default FP16 KV cache", zorder=3)
    ax.plot(users, y_fp8, "-o", color=WIN, lw=3.6, ms=12,
            markerfacecolor=WIN, markeredgecolor="white", markeredgewidth=1.8,
            label="FP8 KV cache  (recommended)", zorder=4)

    # Shade the widening gap
    ax.fill_between(users, y_default, y_fp8, where=(y_fp8 >= y_default),
                    color=WIN, alpha=0.10, zorder=1)

    # End-point value labels (offset right so they don't sit on the line)
    ax.annotate(f"{y_fp8[-1]:.0f}", (users[-1], y_fp8[-1]),
                textcoords="offset points", xytext=(14, 6),
                fontsize=14, fontweight="bold", color=WIN)
    ax.annotate(f"{y_default[-1]:.0f}", (users[-1], y_default[-1]),
                textcoords="offset points", xytext=(14, -16),
                fontsize=14, fontweight="bold", color=MUTED)

    # Peak-gain label -- sits inside the shaded gap between the two curves
    mid_x = (users[2] + users[3]) / 2          # midpoint between 64 and 128
    mid_y = (np.interp(mid_x, users, y_fp8) +
             np.interp(mid_x, users, y_default)) / 2
    ax.text(
        mid_x, mid_y,
        f"+{peak_gain:.0f}% throughput\nat peak load",
        fontsize=14.5, fontweight="bold", color=WIN,
        ha="center", va="center",
    )

    ax.set_xlabel("Concurrent users (active requests)", fontsize=15.5,
                  fontweight="semibold", labelpad=8)
    ax.set_ylabel("Output throughput  (tokens / s)", fontsize=15.5,
                  fontweight="semibold", labelpad=8)
    ax.set_title("FP8 KV Cache: More Throughput as Load Grows — For Free",
                 fontsize=18.5, fontweight="bold", pad=44, loc="left")
    ax.text(0, 1.05, "Qwen3-8B · single NVIDIA L4 · accuracy unchanged "
                     "(ARC / GSM8K / MMLU within <1%)",
            transform=ax.transAxes, fontsize=13, color=MUTED)

    ax.set_xticks(users)
    ax.set_xlim(users.min() - 8, users.max() + 26)
    ax.set_ylim(0, max(y_fp8) * 1.22)
    ax.grid(True, color=GRID, lw=1.0, zorder=0)
    ax.set_axisbelow(True)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)

    leg = ax.legend(loc="upper left", frameon=True, fontsize=13.5,
                    handlelength=2.2, borderpad=0.8)
    leg.get_frame().set_edgecolor(GRID)
    leg.get_frame().set_facecolor("white")

    # Killer-stat callout box
    box_txt = (f"Time-to-First-Token @ 64 users\n"
               f"{ttft_default_64/1000:.1f} s  →  {ttft_fp8_64/1000:.2f} s"
               f"   ({ttft_factor:.0f}× faster)")
    ax.text(
        0.975, 0.06, box_txt, transform=ax.transAxes,
        fontsize=13.5, fontweight="bold", color=ACCENT, ha="right", va="bottom",
        bbox=dict(boxstyle="round,pad=0.7", facecolor="#eef3fc",
                  edgecolor=ACCENT, linewidth=1.6),
    )

    fig.tight_layout()
    _save(fig, "phase1_fig1_fp8_kv_throughput")
    plt.close(fig)

    print(f"  [fig1] peak gain +{peak_gain:.1f}% | "
          f"TTFT@64 {ttft_default_64:.0f}ms -> {ttft_fp8_64:.0f}ms "
          f"({ttft_factor:.1f}x)")


# --------------------------------------------------------------------------- #
# FIGURE 2 -- TurboQuant hardware limit on L4
# --------------------------------------------------------------------------- #
def figure2_turboquant_limit():
    df = pd.read_csv(RESULTS / "turboquant_perf_quality_summary.csv")

    # Pretty labels for each configuration
    label_map = {
        "qwen3_kv_fp8_baseline":       "FP8\n(8-bit KV)",
        "qwen3_kv_turboquant_k3v4_nc": "TurboQuant\nK3·V4",
        "qwen3_kv_turboquant_4bit_nc": "TurboQuant\n4-bit",
        "qwen3_kv_turboquant_3bit_nc": "TurboQuant\n3-bit",
        "qwen3_kv_turboquant_k8v4":    "TurboQuant\nK8·V4",
    }
    df = df[df.experiment.isin(label_map)].copy()
    df["label"] = df["experiment"].map(label_map)

    baseline_tp = float(
        df.loc[df.experiment == "qwen3_kv_fp8_baseline",
               "throughput_u128_tok_s"].iloc[0])
    df["rel_tp"] = df["throughput_u128_tok_s"] / baseline_tp * 100.0

    # Sort so the FP8 winner sits first, then descending throughput
    df = df.sort_values("rel_tp", ascending=False).reset_index(drop=True)

    is_base = (df["experiment"] == "qwen3_kv_fp8_baseline").to_numpy()
    colors = np.where(is_base, WIN, LOSS)

    x = np.arange(len(df))
    fig, ax = plt.subplots(figsize=(10.5, 6.2))

    bars = ax.bar(x, df["rel_tp"], width=0.62, color=colors,
                  edgecolor="white", linewidth=1.5, zorder=3)

    # 100% reference line (FP8)
    ax.axhline(100, color=WIN, lw=1.6, ls=(0, (5, 4)), zorder=2)

    # Bar labels: relative throughput + quality (GSM8K) to show quality is flat
    for xi, (_, row) in zip(x, df.iterrows()):
        rel = row["rel_tp"]
        # Percentage label above the bar
        ax.text(xi, rel + 2.5, f"{rel:.0f}%", ha="center", va="bottom",
                fontsize=14, fontweight="bold",
                color=WIN if row["experiment"] == "qwen3_kv_fp8_baseline" else LOSS)
        # GSM8K quality inside the bar -- adaptive y to keep inside short bars
        gsm_y = min(rel * 0.08, 6)   # push label up a bit from bottom
        ax.text(xi, gsm_y, f"GSM8K\n{row['gsm8k_flex']*100:.1f}%", ha="center",
                va="bottom", fontsize=10.5, color="white", fontweight="semibold")

    worst = df["rel_tp"].min()
    ax.set_ylabel("Throughput @ 128 users\n(% of FP8 baseline)", fontsize=15.5,
                  fontweight="semibold", labelpad=8)
    ax.set_title("Pushing Past FP8 Backfires on the L4",
                 fontsize=18.5, fontweight="bold", pad=42, loc="left")
    ax.text(0, 1.045,
            "Qwen3-8B · 3–4-bit TurboQuant KV cache · quality stays flat, "
            "but dequantization overhead crushes throughput",
            transform=ax.transAxes, fontsize=13, color=MUTED)

    ax.set_xticks(x)
    ax.set_xticklabels(df["label"], fontsize=12.5)
    ax.set_ylim(0, 118)
    ax.set_yticks([0, 25, 50, 75, 100])
    ax.grid(True, axis="y", color=GRID, lw=1.0, zorder=0)
    ax.set_axisbelow(True)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)

    # Takeaway callout -- positioned upper-center-right, clear of bars
    ax.text(
        0.97, 0.88,
        f"Aggressive KV compression keeps only\n"
        f"{worst:.0f}–{df[~is_base]['rel_tp'].max():.0f}% of FP8 throughput\n"
        f"— with no accuracy gain to show for it.",
        transform=ax.transAxes, fontsize=12.8, color=LOSS, ha="right", va="top",
        fontweight="semibold",
        bbox=dict(boxstyle="round,pad=0.7", facecolor="#fbeeea",
                  edgecolor=LOSS, linewidth=1.6),
    )

    fig.tight_layout()
    _save(fig, "phase1_fig2_turboquant_limit")
    plt.close(fig)

    print(f"  [fig2] FP8 baseline = {baseline_tp:.0f} tok/s | "
          f"TurboQuant retains {worst:.0f}%–{df[~is_base]['rel_tp'].max():.0f}%")


def main():
    print("Generating poster Phase-1 figures ->", OUTDIR)
    figure1_fp8_throughput()
    figure2_turboquant_limit()
    print("Done.")


if __name__ == "__main__":
    main()
