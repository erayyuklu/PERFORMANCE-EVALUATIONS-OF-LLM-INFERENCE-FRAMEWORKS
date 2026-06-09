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
    The KV-cache precision sweet spot. Decode latency (TPOT) at 64 concurrent
    users across the full precision spectrum: FP16 (default) wastes memory
    bandwidth, FP8 is the optimum, and pushing further with TurboQuant (3-4 bit)
    pays a steep dequantization-compute penalty -- decode is up to ~2x slower
    with no accuracy gain. Data: raw per-request custom_metrics from the
    KV-cache (run_20260405_005704) and TurboQuant (run_20260511 / run_20260512)
    load tests; quality from turboquant_perf_quality_summary.csv.

Both charts: Qwen3-8B, single NVIDIA L4, ShareGPT load test via distributed Locust.
"""

import re
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
        fig.savefig(OUTDIR / f"{stem}.{ext}", dpi=300, bbox_inches="tight", pad_inches=0.15)
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

    fig.tight_layout()
    _save(fig, "phase1_fig1_fp8_kv_throughput")
    plt.close(fig)

    print(f"  [fig1] peak throughput gain +{peak_gain:.1f}%")


# --------------------------------------------------------------------------- #
# FIGURE 2 -- TurboQuant hardware limit on L4
# --------------------------------------------------------------------------- #
# FIGURE 2 -- KV-cache precision sweet spot (decode latency)
# --------------------------------------------------------------------------- #
def _median_tpot(run, exp, users):
    """Median decode latency (TPOT, ms/token) from raw per-request metrics.

    Some early runs wrote a stray private-use char (\\uf00d) between the user
    count and '_custom_metrics', so we match the file with a tolerant regex.
    """
    folder = RESULTS / run / exp
    pat = re.compile(rf"^{re.escape(exp)}__u{users}\D.*custom_metrics\.csv$")
    files = [f for f in folder.glob(f"{exp}__u{users}*custom_metrics.csv")
             if pat.match(f.name)]
    if not files:
        raise FileNotFoundError(f"{exp} u{users} custom_metrics not found")
    df = pd.read_csv(files[0])
    if "success" in df.columns:
        df = df[df["success"] == True]
    return float(df["tpot_ms"].median())


def figure2_kv_precision_sweetspot():
    USERS = 64  # operating point where all six configs ran to completion

    # KV-cache precision spectrum: least -> most compressed.
    # (label, role, run, experiment)
    spectrum = [
        ("FP16\n(default)",      "base", "run_20260405_005704", "qwen3_kv_cache_auto"),
        ("FP8\n(8-bit)",         "win",  "run_20260511_234500", "qwen3_kv_fp8_baseline"),
        ("TurboQuant\nK8·V4",    "loss", "run_20260511_234500", "qwen3_kv_turboquant_k8v4"),
        ("TurboQuant\n4-bit",    "loss", "run_20260511_234500", "qwen3_kv_turboquant_4bit_nc"),
        ("TurboQuant\nK3·V4",    "loss", "run_20260512_090311", "qwen3_kv_turboquant_k3v4_nc"),
        ("TurboQuant\n3-bit",    "loss", "run_20260512_090311", "qwen3_kv_turboquant_3bit_nc"),
    ]

    labels = [s[0] for s in spectrum]
    tpot = np.array([_median_tpot(s[2], s[3], USERS) for s in spectrum])
    role = [s[1] for s in spectrum]

    role_color = {"base": BASE, "win": WIN, "loss": LOSS}
    colors = [role_color[r] for r in role]

    fp8_tpot = tpot[role.index("win")]
    worst = tpot.max()

    x = np.arange(len(spectrum))
    fig, ax = plt.subplots(figsize=(11.5, 6.4))

    bars = ax.bar(x, tpot, width=0.58, color=colors,
                  edgecolor="white", linewidth=1.6, zorder=3)

    # FP8 reference line -- the floor everyone is compared against
    ax.axhline(fp8_tpot, color=WIN, lw=1.6, ls=(0, (5, 4)), zorder=2)
    ax.text(len(spectrum) - 0.55, fp8_tpot + 3, "FP8 floor",
            color=WIN, fontsize=11.5, fontweight="bold", ha="left", va="bottom")

    # Value labels (ms/token) + multiplier vs FP8 for the slow configs
    for xi, (h, r) in zip(x, zip(tpot, role)):
        ax.text(xi, h + 5, f"{h:.0f}", ha="center", va="bottom",
                fontsize=14, fontweight="bold",
                color=role_color[r])
        if r == "loss":
            ax.text(xi, h - 12, f"{h / fp8_tpot:.1f}×", ha="center", va="top",
                    fontsize=12, fontweight="bold", color="white")

    # "best" tag on FP8 -- positioned above and between FP8 and FP16 bars
    win_i = role.index("win")
    ax.annotate("fastest decode\n= the sweet spot",
                xy=(win_i, tpot[win_i]),
                xytext=(win_i - 0.5, tpot[win_i] + 62),
                fontsize=13, fontweight="bold", color=WIN, ha="center",
                arrowprops=dict(arrowstyle="-|>", color=WIN, lw=2.2,
                                connectionstyle="arc3,rad=0.25"))

    ax.set_ylabel("Decode latency  (ms / token)\nat 64 concurrent users",
                  fontsize=15, fontweight="semibold", labelpad=8)
    ax.set_title("FP8 Is the KV-Cache Sweet Spot",
                 fontsize=18.5, fontweight="bold", pad=42, loc="left")
    ax.text(0, 1.045,
            "Qwen3-8B \u00b7 FP16 wastes bandwidth \u00b7 TurboQuant wastes compute \u00b7 "
            "accuracy ~88% GSM8K throughout",
            transform=ax.transAxes, fontsize=12.5, color=MUTED)

    ax.set_xticks(x)
    ax.set_xticklabels(labels, fontsize=12)
    ax.set_ylim(0, worst * 1.50)
    ax.grid(True, axis="y", color=GRID, lw=1.0, zorder=0)
    ax.set_axisbelow(True)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)

    # Takeaway callout (upper-right)
    ax.text(
        0.97, 0.95,
        f"Going past FP8 makes decoding\nup to {worst / fp8_tpot:.1f}× slower"
        f"\n— for no accuracy gain.",
        transform=ax.transAxes, fontsize=12.8, color=LOSS, ha="right", va="top",
        fontweight="semibold",
        bbox=dict(boxstyle="round,pad=0.7", facecolor="#fbeeea",
                  edgecolor=LOSS, linewidth=1.6),
    )

    # Throughput context box (lower-left)
    df_uni = pd.read_csv(RESULTS / "unified_summary_qwen3.csv")
    fp8_tp = float(df_uni.loc[
        (df_uni.experiment == "qwen3_kv_cache_fp8") & (df_uni.users == USERS),
        "gen_throughput_mean"].iloc[0])
    fp16_tp = float(df_uni.loc[
        (df_uni.experiment == "qwen3_kv_cache_auto") & (df_uni.users == USERS),
        "gen_throughput_mean"].iloc[0])
    tp_txt = (f"Throughput\n"
              f"FP8  {fp8_tp:.0f} tok/s   vs   FP16  {fp16_tp:.0f} tok/s\n"
              f"(+{(fp8_tp / fp16_tp - 1) * 100:.0f}% with FP8)")
    ax.text(
        0.5, -0.22, tp_txt, transform=ax.transAxes,
        fontsize=12, fontweight="bold", color=ACCENT, ha="center", va="top",
        bbox=dict(boxstyle="round,pad=0.7", facecolor="#eef3fc",
                  edgecolor=ACCENT, linewidth=1.6),
    )

    fig.tight_layout()
    fig.subplots_adjust(bottom=0.22, right=0.95)
    _save(fig, "phase1_fig2_kv_precision_sweetspot")
    plt.close(fig)

    print(f"  [fig2] TPOT@u{USERS} (ms/tok): " +
          ", ".join(f"{l.replace(chr(10), ' ')}={t:.0f}"
                    for l, t in zip(labels, tpot)) +
          f"  | worst {worst / fp8_tpot:.2f}x FP8")


# --------------------------------------------------------------------------- #
# FIGURE 3 -- Time-to-first-token (responsiveness) under load
# --------------------------------------------------------------------------- #
def _median_ttft(run, exp, users):
    """Median time-to-first-token (ms) from raw per-request metrics.

    Some early runs wrote a stray private-use char (\\uf00d) between the user
    count and '_custom_metrics', so we match the file with a tolerant regex.
    """
    folder = RESULTS / run / exp
    pat = re.compile(rf"^{re.escape(exp)}__u{users}\D.*custom_metrics\.csv$")
    files = [f for f in folder.glob(f"{exp}__u{users}*custom_metrics.csv")
             if pat.match(f.name)]
    if not files:
        raise FileNotFoundError(f"{exp} u{users} custom_metrics not found")
    df = pd.read_csv(files[0])
    if "success" in df.columns:
        df = df[df["success"] == True]
    return float(df["ttft_ms"].median())


def figure3_ttft_latency():
    RUN = "run_20260405_005704"   # FP16 (auto) and FP8 measured back-to-back

    users = np.array([16, 32, 64, 128])
    ttft_fp16 = np.array([_median_ttft(RUN, "qwen3_kv_cache_auto", u)
                          for u in users]) / 1000.0
    ttft_fp8 = np.array([_median_ttft(RUN, "qwen3_kv_cache_fp8", u)
                         for u in users]) / 1000.0

    i64 = int(np.where(users == 64)[0][0])
    factor_64 = ttft_fp16[i64] / ttft_fp8[i64]

    fig, ax = plt.subplots(figsize=(10.0, 3.4))

    ax.plot(users, ttft_fp16, "-o", color=LOSS, lw=3.6, ms=12,
            markerfacecolor=LOSS, markeredgecolor="white", markeredgewidth=1.8,
            label="Default FP16 KV cache", zorder=4)
    ax.plot(users, ttft_fp8, "-o", color=WIN, lw=3.6, ms=12,
            markerfacecolor=WIN, markeredgecolor="white", markeredgewidth=1.8,
            label="FP8 KV cache  (recommended)", zorder=5)

    ax.fill_between(users, ttft_fp8, ttft_fp16, where=(ttft_fp16 >= ttft_fp8),
                    color=LOSS, alpha=0.08, zorder=1)

    # "30 s" label -- offset to the right so it doesn't collide with the arrow
    ax.annotate(f"{ttft_fp16[2]:.0f} s", (users[2], ttft_fp16[2]),
                textcoords="offset points", xytext=(-42, 12),
                fontsize=13.5, fontweight="bold", color=LOSS)
    ax.annotate(f"{ttft_fp16[3]:.0f} s", (users[3], ttft_fp16[3]),
                textcoords="offset points", xytext=(8, 6),
                fontsize=13.5, fontweight="bold", color=LOSS)
    ax.annotate(f"{ttft_fp8[3]:.0f} s", (users[3], ttft_fp8[3]),
                textcoords="offset points", xytext=(8, -18),
                fontsize=13, fontweight="bold", color=WIN)

    # The "latency wall" callout for u64, moved to the right of the plot
    ax.text(
        1.04, 0.4,
        f"At 64 users:\nFP16 stalls: {ttft_fp16[i64]:.0f} s wait\n"
        f"FP8 stays at {ttft_fp8[i64]:.1f} s\n({factor_64:.0f}\u00d7 faster)",
        transform=ax.transAxes,
        fontsize=13.5, fontweight="bold", color=ACCENT, ha="left", va="center",
        bbox=dict(boxstyle="round,pad=0.6", facecolor="#eef3fc",
                  edgecolor=ACCENT, linewidth=1.5),
    )

    ax.set_xlabel("Concurrent users (active requests)", fontsize=15.5,
                  fontweight="semibold", labelpad=8)
    ax.set_ylabel("TTFT  (seconds)", fontsize=15.5,
                  fontweight="semibold", labelpad=8)
    ax.set_title("FP8 KV Cache Keeps the Server Responsive Under Load",
                 fontsize=18, fontweight="bold", pad=44, loc="left")
    ax.text(0, 1.05,
            "Qwen3-8B \u00b7 single NVIDIA L4 \u00b7 median TTFT \u00b7 "
            "FP16 collapses into queueing at high load",
            transform=ax.transAxes, fontsize=12.5, color=MUTED)

    ax.set_xticks(users)
    ax.set_xlim(users.min() - 8, users.max() + 16)
    ax.set_ylim(-6, ttft_fp16.max() * 1.16)
    ax.grid(True, color=GRID, lw=1.0, zorder=0)
    ax.set_axisbelow(True)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)

    leg = ax.legend(loc="upper left", frameon=True, fontsize=12.0,
                    handlelength=1.8, borderpad=0.6, labelspacing=0.4)
    leg.get_frame().set_edgecolor(GRID)
    leg.get_frame().set_facecolor("white")

    fig.tight_layout()
    fig.subplots_adjust(right=0.74)
    _save(fig, "phase1_fig3_ttft_latency")
    plt.close(fig)

    print(f"  [fig3] TTFT median (s) FP16={np.round(ttft_fp16,1).tolist()} "
          f"FP8={np.round(ttft_fp8,1).tolist()} | @64 {factor_64:.0f}x faster")


def main():
    print("Generating poster Phase-1 figures ->", OUTDIR)
    figure1_fp8_throughput()
    figure2_kv_precision_sweetspot()
    figure3_ttft_latency()
    print("Done.")


if __name__ == "__main__":
    main()
