#!/usr/bin/env python3
"""
evidence/<case>/*/metrics.csv 를 읽어 Before & After 비교 그래프를 만든다.

사용법:
    python3 scripts/plot.py oom        # -> evidence/oom/compare.png
    python3 scripts/plot.py cpu
    python3 scripts/plot.py deadlock
    python3 scripts/plot.py all

필요 패키지: matplotlib (pip install matplotlib)
"""
import csv
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT = Path(__file__).resolve().parent.parent
EVIDENCE = ROOT / "evidence"

# 케이스별로 보여줄 지표 (컬럼명, 축 이름)
PANELS = {
    "oom":      [("rss_mb", "RSS (MB)"), ("cpu_inst_pct", "CPU (%)")],
    "cpu":      [("cpu_inst_pct", "Process CPU (%)"), ("sys_cpu_pct", "System CPU (%)")],
    "deadlock": [("cpu_inst_pct", "CPU (%)"), ("log_idle_s", "Seconds since last log line")],
    "sched":    [("cpu_inst_pct", "CPU (%)"), ("threads", "Threads")],
}


def load(csv_path):
    rows = list(csv.DictReader(open(csv_path)))
    return rows


def read_summary(run_dir):
    info = {}
    f = run_dir / "summary.txt"
    if f.exists():
        for line in f.read_text().splitlines():
            if ":" in line and not line.startswith("-"):
                k, v = line.split(":", 1)
                info[k.strip()] = v.strip()
    return info


def read_env(run_dir):
    env = {}
    f = run_dir / "env.txt"
    if f.exists():
        for line in f.read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                env[k] = v
    return env


def plot_case(case):
    case_dir = EVIDENCE / case
    runs = sorted(d for d in case_dir.iterdir() if (d / "metrics.csv").exists()) if case_dir.exists() else []
    if not runs:
        print(f"[{case}] metrics.csv 가 없습니다. 건너뜀")
        return
    panels = PANELS.get(case, PANELS["oom"])
    fig, axes = plt.subplots(len(panels), 1, figsize=(10, 3.4 * len(panels)), sharex=True)
    for run in runs:
        rows = load(run / "metrics.csv")
        if not rows:
            continue
        x = [float(r["elapsed_s"]) for r in rows]
        info = read_summary(run)
        label = f'{run.name} (survived {info.get("survival_s", "?")}s)'
        env = read_env(run)
        for i, (ax, (col, _)) in enumerate(zip(axes, panels)):
            y = [float(r[col]) for r in rows]
            line, = ax.plot(x, y, label=label, linewidth=1.6)
            ax.plot(x[-1], y[-1], "x", color=line.get_color(), markersize=10, mew=2)  # 종료 지점
            if i == 0 and case == "oom" and "MEMORY_LIMIT" in env:
                ax.axhline(float(env["MEMORY_LIMIT"]), color=line.get_color(), ls="--", alpha=0.6,
                           label=f'MEMORY_LIMIT={env["MEMORY_LIMIT"]}MB')
            if i == 0 and case == "cpu" and "CPU_MAX_OCCUPY" in env:
                ax.axhline(float(env["CPU_MAX_OCCUPY"]), color=line.get_color(), ls="--", alpha=0.6,
                           label=f'CPU_MAX_OCCUPY={env["CPU_MAX_OCCUPY"]}%')
    for ax, (_, name) in zip(axes, panels):
        ax.set_ylabel(name)
        ax.grid(alpha=0.3)
    axes[0].legend(loc="best", fontsize=9)
    axes[-1].set_xlabel("Elapsed time (s)")
    fig.suptitle(f"agent-leak-app - {case.upper()} Before & After", fontsize=13)
    fig.tight_layout()
    out = case_dir / "compare.png"
    fig.savefig(out, dpi=130)
    print(f"[{case}] saved {out.relative_to(ROOT)}")


if __name__ == "__main__":
    target = sys.argv[1] if len(sys.argv) > 1 else "all"
    for c in (PANELS if target == "all" else [target]):
        plot_case(c)
