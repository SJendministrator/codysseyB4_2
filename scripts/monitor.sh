#!/bin/bash

APP="$HOME/agent-leak-app-x86"
OUT="$1"

if [ -z "$OUT" ]; then
    echo "사용법: ./monitor.sh <output.csv>"
    exit 1
fi

mkdir -p "$(dirname "$OUT")"

echo "timestamp,pids,total_rss_kb,total_vsz_kb,total_cpu_percent,total_mem_percent" > "$OUT"

"$APP" > /workspace/evidence/oom/app-monitor.log 2>&1 &

echo "Monitoring agent-leak-app-x86 processes..."

while true; do
    PIDS=$(pgrep -f "$APP" || true)

    if [ -z "$PIDS" ]; then
        break
    fi

    NOW=$(date '+%Y-%m-%d %H:%M:%S')

    STATS=$(ps -o pid=,rss=,vsz=,%cpu=,%mem= -p $PIDS 2>/dev/null)

    if [ -n "$STATS" ]; then
        RSS=$(echo "$STATS" | awk '{sum += $2} END {print sum+0}')
        VSZ=$(echo "$STATS" | awk '{sum += $3} END {print sum+0}')
        CPU=$(echo "$STATS" | awk '{sum += $4} END {print sum+0}')
        MEM=$(echo "$STATS" | awk '{sum += $5} END {print sum+0}')
        PID_LIST=$(echo "$PIDS" | tr '\n' ';')

        echo "$NOW,$PID_LIST,$RSS,$VSZ,$CPU,$MEM" >> "$OUT"
    fi

    sleep 0.5
done

echo "Monitoring finished."
