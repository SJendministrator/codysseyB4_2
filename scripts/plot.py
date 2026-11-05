#!/usr/bin/env python3
"""
evidence/ 의 실행 결과로 케이스별 Before & After 비교 그래프를 만든다.

사용법:
    python3 scripts/plot.py            # 전체 -> evidence/<case>/compare.png
    python3 scripts/plot.py cpu        # 하나만

어떤 실행을 겹쳐 그릴지는 아래 FIGURES 에 정의한다. 아직 없는 실행 폴더는 건너뛴다.
관제 수치(metrics.csv)뿐 아니라, 앱 로그(app.log)에 찍힌 앱 자체 지표도 그린다.
  app:heap -> "[MemoryWorker] Current Heap: 125MB"
  app:load -> "[CpuWorker] Current Load: 34.14%"

필요 패키지: matplotlib (pip install matplotlib)
"""
import csv
import re
import sys
from datetime import datetime
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT = Path(__file__).resolve().parent.parent
EVIDENCE = ROOT / "evidence"

FIGURES = {
    "oom": dict(
        title="OOM - MEMORY_LIMIT 256MB vs 512MB",
        runs=["oom/before-256mb-mtoff", "oom/before-256mb", "deadlock/after-mt-false"],
        panels=[("rss_mb", "Process RSS (MB)"), ("app:heap", "App-reported Heap (MB)")],
        limit_env="MEMORY_LIMIT", limit_panel=0, xmax=120,
    ),
    "cpu": dict(
        title="CPU - CPU_MAX_OCCUPY 100% vs 30%",
        runs=["cpu/before-100", "cpu/repeat-100-mt-true", "cpu/repeat-100-mt-false", "cpu/after-30"],
        panels=[("app:load", "App-reported Load (%)"),
                ("cpu_inst_pct@5", "Process CPU, 5s avg (%)"),
                ("cpu_ps_avg_pct", "ps %CPU, lifetime avg (%)"),
                ("sys_cpu_pct", "System CPU (%)")],
        limit_env="CPU_MAX_OCCUPY", limit_panel=0, xmax=150,
        refline=(0, 50, "Watchdog trips ~50%"),
    ),
    "deadlock": dict(
        title="Deadlock - MULTI_THREAD_ENABLE true vs false",
        runs=["deadlock/before-mt-true", "deadlock/after-mt-false"],
        panels=[("log_idle_s", "Seconds since last log line"),
                ("cpu_inst_pct", "Process CPU, instant (%)"),
                ("rss_mb", "Process RSS (MB)")],
        xmax=150,
    ),
}

TS = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d),(\d{3})")
APP_METRICS = {
    "app:heap": re.compile(r"Current Heap: (\d+(?:\.\d+)?)MB"),
    "app:load": re.compile(r"Current Load: (\d+(?:\.\d+)?)%"),
}


def read_kv(path, sep):
    out = {}
    if path.exists():
        for line in path.read_text().splitlines():
            if sep in line and not line.startswith("-"):
                k, v = line.split(sep, 1)
                out[k.strip()] = v.strip()
    return out


def app_series(run, key, start):
    xs, ys = [], []
    pat = APP_METRICS[key]
    for line in (run / "app.log").read_text(errors="replace").splitlines():
        m, v = TS.match(line), pat.search(line)
        if m and v:
            t = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S").timestamp() + int(m.group(2)) / 1000
            xs.append(t - start)
            ys.append(float(v.group(1)))
    return xs, ys


def plot_case(case):
    spec = FIGURES[case]
    runs = [EVIDENCE / r for r in spec["runs"] if (EVIDENCE / r / "metrics.csv").exists()]
    if not runs:
        print(f"[{case}] 실행 결과가 없습니다. 건너뜀")
        return
    panels = spec["panels"]
    fig, axes = plt.subplots(len(panels), 1, figsize=(10, 2.9 * len(panels) + 0.8), sharex=True,
                             layout="constrained")
    xmax = spec.get("xmax")

    for run in runs:
        summ = read_kv(run / "summary.txt", ":")
        env = read_kv(run / "env.txt", "=")
        start = datetime.strptime(summ["start"], "%Y-%m-%d %H:%M:%S").timestamp()
        rows = list(csv.DictReader(open(run / "metrics.csv")))
        mx = [float(r["elapsed_s"]) for r in rows]
        reason = summ.get("end_reason", "")
        ended = reason.startswith("EXITED") or reason.startswith("HUNG")
        label = (f'{run.parent.name}/{run.name}  '
                 f'(MEM={env.get("MEMORY_LIMIT")} CPU={env.get("CPU_MAX_OCCUPY")} '
                 f'MT={env.get("MULTI_THREAD_ENABLE")}) - {reason.split(" (")[0]} at {summ.get("survival_s")}s')
        color = None
        for i, (ax, (col, _)) in enumerate(zip(axes, panels)):
            if col.startswith("app:"):
                x, y = app_series(run, col, start)
            elif "@" in col:  # "컬럼@N" = N샘플 이동평균
                c, n = col.split("@"); n = int(n)
                raw = [float(r[c]) for r in rows]
                x, y = mx, [sum(raw[max(0, k - n + 1):k + 1]) / len(raw[max(0, k - n + 1):k + 1]) for k in range(len(raw))]
            else:
                x, y = mx, [float(r[col]) for r in rows]
            if not x:
                continue
            line, = ax.plot(x, y, linewidth=1.6, color=color, label=label if color is None else None,
                            marker="." if col.startswith("app:") else None, markersize=4)
            color = line.get_color()
            if ended and (xmax is None or x[-1] <= xmax):
                ax.plot(x[-1], y[-1], "x", color=color, markersize=10, mew=2)
            le = spec.get("limit_env")
            if le and i == spec.get("limit_panel") and le in env:
                ax.axhline(float(env[le]), color=color, ls="--", alpha=0.5, lw=1)

    for ax, (_, name) in zip(axes, panels):
        ax.set_ylabel(name, fontsize=9)
        ax.grid(alpha=0.3)
        lo, hi = ax.get_ylim()
        if hi - lo < 0.5:  # 값이 거의 일정한 패널(예: CPU 0%)은 0부터 보이게
            ax.set_ylim(0, max(hi, 0) + 5)
    if spec.get("refline"):
        pi, val, text = spec["refline"]
        axes[pi].axhline(val, color="black", ls=":", lw=1.2)
        axes[pi].text(1, val + 1.5, text, fontsize=8)
    if xmax:
        axes[-1].set_xlim(0, xmax)
    axes[-1].set_xlabel("Elapsed time since start (s)    x = process ended    dashed = configured limit")
    fig.legend(loc="outside upper center", fontsize=8, ncol=1, frameon=False,
               title=spec["title"], title_fontproperties={"size": 12})
    out = EVIDENCE / case / "compare.png"
    fig.savefig(out, dpi=130, bbox_inches="tight")
    plt.close(fig)
    print(f"[{case}] saved {out.relative_to(ROOT)}  ({len(runs)} runs)")


if __name__ == "__main__":
    targets = sys.argv[1:] or list(FIGURES)
    for c in targets:
        plot_case(c)
