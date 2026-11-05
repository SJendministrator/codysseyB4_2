#!/usr/bin/env bash
# =============================================================
# agent-leak-app 관제 스크립트
#
# 앱을 실행하고, 종료/타임아웃/무응답까지 프로세스 상태를 기록한다.
#
# 사용법:
#   ./scripts/monitor.sh <case> <label> [timeout_sec]
#
#   case   : oom | cpu | deadlock | sched  (evidence/<case>/ 아래에 저장)
#   label  : 이번 실행 이름 (예: before-256mb, after-512mb)
#   timeout: 최대 관측 시간(초). 기본 900초. 초과 시 "생존"으로 기록 후 종료
#
# 예시:
#   MEMORY_LIMIT=256 ./scripts/monitor.sh oom before-256mb
#   MEMORY_LIMIT=512 ./scripts/monitor.sh oom after-512mb
#   CPU_MAX_OCCUPY=30  ./scripts/monitor.sh cpu before-30
#   CPU_MAX_OCCUPY=100 ./scripts/monitor.sh cpu after-100
#   MULTI_THREAD_ENABLE=true  ./scripts/monitor.sh deadlock before-mt-true 300
#   MULTI_THREAD_ENABLE=false ./scripts/monitor.sh deadlock after-mt-false 300
#
# 조정 가능한 변수:
#   APP_BIN    앱 바이너리 경로 (기본: $HOME/agent-leak-app-x86)
#   INTERVAL   샘플링 간격 초 (기본 1)
#   STALL_SEC  "로그 무변화 + CPU≈0" 이 몇 초 지속되면 무응답 판정할지 (기본 30)
#   STALL_KILL 무응답 판정 후 몇 초 더 관찰하고 종료할지 (기본 60, 0이면 timeout까지 대기)
#
# 출력 (evidence/<case>/<label>/):
#   metrics.csv   샘플별 수치 (그래프용)
#   monitor.log   사람이 읽는 관제 로그
#   app.log       앱 stdout/stderr 전체
#   threads.log   스레드 스냅샷 (ps -L) 주기 기록
#   snapshots/    무응답 감지/종료 시점의 ps, top -H 등 증거
#   env.txt       이번 실행의 환경변수
#   summary.txt   생존 시간, 종료 사유, 핵심 로그 요약
#
# 참고: ps 의 %CPU 는 "프로세스 시작 이후 누적 평균"이라 순간 스파이크가
#       희석된다. 이 스크립트는 /proc/<pid>/stat 의 CPU tick 증가량으로
#       "직전 INTERVAL 동안의 순간 CPU 사용률"을 직접 계산한다.
# =============================================================
set -u

CASE="${1:-}"; LABEL="${2:-}"; TIMEOUT="${3:-900}"
if [ -z "$CASE" ] || [ -z "$LABEL" ]; then
    sed -n '2,25p' "$0"; exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BIN="${APP_BIN:-$HOME/agent-leak-app-x86}"
INTERVAL="${INTERVAL:-1}"
STALL_SEC="${STALL_SEC:-30}"
STALL_KILL="${STALL_KILL:-60}"
SNAP_EVERY="${SNAP_EVERY:-5}"       # 스레드 스냅샷 주기 (샘플 횟수 기준)

# ---------- 환경 준비 ----------
# shellcheck source=setup_env.sh
source "$ROOT/scripts/setup_env.sh" || exit 1
[ -x "$APP_BIN" ] || { echo "앱 바이너리를 찾을 수 없음: $APP_BIN (APP_BIN=경로 로 지정)"; exit 1; }
if pgrep -u "$(id -u)" -f "^$APP_BIN( |$)" >/dev/null; then
    echo "이미 실행 중인 agent-leak-app 이 있습니다. 먼저 종료하세요: pkill -f $(basename "$APP_BIN")"
    exit 1
fi

OUT="$ROOT/evidence/$CASE/$LABEL"
if [ -e "$OUT" ]; then
    echo "이미 존재하는 결과 폴더: $OUT  (다른 label 을 쓰거나 폴더를 지우세요)"; exit 1
fi
mkdir -p "$OUT/snapshots"
CSV="$OUT/metrics.csv"; MLOG="$OUT/monitor.log"; ALOG="$OUT/app.log"; TLOG="$OUT/threads.log"

CLK=$(getconf CLK_TCK)
NCPU=$(nproc)
MEMTOTAL_KB=$(awk '/^MemTotal/{print $2}' /proc/meminfo)

env | grep -E '^(AGENT_|MEMORY_LIMIT|CPU_MAX_OCCUPY|MULTI_THREAD_ENABLE)' | sort > "$OUT/env.txt"
{ echo "host: $(hostname)  user: $(id -un)  cpus: $NCPU  mem_total_kb: $MEMTOTAL_KB"
  uname -a; } >> "$OUT/env.txt"

# ---------- 유틸 ----------
now()      { date '+%Y-%m-%d %H:%M:%S'; }
now_s()    { date +%s.%N; }
log()      { echo "$*" | tee -a "$MLOG"; }

# 앱 PID + 모든 자손 PID (PyInstaller 바이너리는 부모/자식 2개 프로세스로 뜬다)
pid_tree() {
    local p="$1" c
    [ -d "/proc/$p" ] && echo "$p"
    for c in $(pgrep -P "$p" 2>/dev/null); do pid_tree "$c"; done
}

# 프로세스 CPU tick (utime+stime). comm 에 공백이 있어도 안전하도록 ')' 이후만 파싱
proc_ticks()   { sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $12+$13}'; }
proc_state()   { sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $1}'; }
proc_threads() { sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $18}'; }
proc_rss_kb()  { awk '/^VmRSS/{print $2}' "/proc/$1/status" 2>/dev/null; }
sys_ticks()    { awk '/^cpu /{idle=$5+$6; tot=0; for(i=2;i<=NF;i++) tot+=$i; print tot, idle}' /proc/stat; }

snapshot() {   # $1 = 태그
    local tag="$1" f="$OUT/snapshots/$(date +%H%M%S)-$1.txt"
    {
        echo "### [$tag] $(now)"
        echo; echo "\$ ps -ef | grep agent-leak-app | grep -v grep"
        ps -ef | grep agent-leak-app | grep -v grep
        echo; echo "\$ ps -L -o pid,lwp,stat,pcpu,pmem,wchan:24,comm -p $PIDS_CSV"
        ps -L -o pid,lwp,stat,pcpu,pmem,wchan:24,comm -p "$PIDS_CSV" 2>/dev/null
        echo; echo "\$ top -H -b -n 1 -p $PIDS_CSV"
        top -H -b -n 1 -p "$PIDS_CSV" 2>/dev/null | head -40
        echo; echo "\$ pstree -p $APP_PID"
        pstree -p "$APP_PID" 2>/dev/null || echo "(pstree 없음)"
        echo; echo "\$ tail -n 20 app.log"
        tail -n 20 "$ALOG"
    } > "$f"
    log "[$(now)] SNAPSHOT saved: snapshots/$(basename "$f")"
}

write_summary() {
    local end_s; end_s=${END_S:-$(now_s)}
    local surv; surv=$(awk -v a="$end_s" -v b="$START_S" 'BEGIN{printf "%.1f", a-b}')
    {
        echo "case        : $CASE"
        echo "label       : $LABEL"
        echo "settings    : MEMORY_LIMIT=${MEMORY_LIMIT}MB CPU_MAX_OCCUPY=${CPU_MAX_OCCUPY}% MULTI_THREAD_ENABLE=$MULTI_THREAD_ENABLE"
        echo "start       : $START_H"
        echo "end         : ${END_H:-$(now)}"
        echo "survival_s  : $surv"
        echo "end_reason  : $END_REASON"
        echo "peak_rss_mb : $(awk -v r="$PEAK_RSS" 'BEGIN{printf "%.1f", r/1024}')"
        echo "peak_cpu_pct: $PEAK_CPU   (순간값, 코어 ${NCPU}개 기준 최대 $((NCPU*100))%)"
        echo
        echo "---- key log lines ----"
        grep -nE 'CRITICAL|MemoryGuard|WATCHDOG|Watchdog|SIGTERM|SIGKILL|TERMINAT|WAITING|BLOCKED|[Dd]eadlock|[Ll]ock|ERROR|FATAL' "$ALOG" | tail -n 40
        echo
        echo "---- last 15 lines of app.log ----"
        tail -n 15 "$ALOG"
    } > "$OUT/summary.txt"
}

# ---------- 앱 실행 ----------
START_S=$(now_s); START_H=$(now)
"$APP_BIN" > "$ALOG" 2>&1 &
APP_PID=$!
END_REASON=""; EXIT_CODE=""

cleanup() {
    [ -n "$END_REASON" ] || END_REASON="INTERRUPTED (Ctrl+C)"
    for p in $(pid_tree "$APP_PID" | sort -rn); do kill -TERM "$p" 2>/dev/null; done
    sleep 1
    for p in $(pid_tree "$APP_PID"); do kill -KILL "$p" 2>/dev/null; done
}
trap 'cleanup; write_summary; exit 130' INT TERM

log "[$START_H] START case=$CASE label=$LABEL pid=$APP_PID MEMORY_LIMIT=${MEMORY_LIMIT}MB CPU_MAX_OCCUPY=${CPU_MAX_OCCUPY}% MULTI_THREAD_ENABLE=$MULTI_THREAD_ENABLE timeout=${TIMEOUT}s"
echo "timestamp,elapsed_s,pids,state,threads,rss_kb,rss_mb,mem_pct,cpu_inst_pct,cpu_ps_avg_pct,sys_cpu_pct,load1,log_bytes,log_idle_s" > "$CSV"

declare -A PREV_TICKS
read -r PREV_SYS_TOT PREV_SYS_IDLE < <(sys_ticks)
PREV_T=$START_S
LAST_LOG_SIZE=0; LAST_LOG_CHANGE=$START_S
STALL_AT=""; N=0; PEAK_RSS=0; PEAK_CPU=0

sleep "$INTERVAL"
while kill -0 "$APP_PID" 2>/dev/null && [ "$(proc_state "$APP_PID")" != "Z" ]; do
    T=$(now_s); DT=$(awk -v a="$T" -v b="$PREV_T" 'BEGIN{print a-b}')
    PIDS=$(pid_tree "$APP_PID" | tr '\n' ' ')
    PIDS_CSV=$(echo $PIDS | tr ' ' ',')
    [ -n "$PIDS" ] || break

    RSS=0; DTICKS=0; THREADS=0; STATES=""
    for p in $PIDS; do
        r=$(proc_rss_kb "$p"); RSS=$((RSS + ${r:-0}))
        tk=$(proc_ticks "$p"); tk=${tk:-0}
        DTICKS=$((DTICKS + tk - ${PREV_TICKS[$p]:-$tk}))
        PREV_TICKS[$p]=$tk
        th=$(proc_threads "$p"); THREADS=$((THREADS + ${th:-0}))
        STATES+="$(proc_state "$p")"
    done
    CPU_INST=$(awk -v t="$DTICKS" -v c="$CLK" -v d="$DT" 'BEGIN{printf "%.1f", (d>0)? t/c/d*100 : 0}')
    CPU_PS=$(ps -o %cpu= -p "$PIDS_CSV" 2>/dev/null | awk '{s+=$1} END{printf "%.1f", s}')
    MEM_PCT=$(awk -v r="$RSS" -v m="$MEMTOTAL_KB" 'BEGIN{printf "%.2f", r/m*100}')
    RSS_MB=$(awk -v r="$RSS" 'BEGIN{printf "%.1f", r/1024}')

    read -r SYS_TOT SYS_IDLE < <(sys_ticks)
    SYS_CPU=$(awk -v t="$((SYS_TOT-PREV_SYS_TOT))" -v i="$((SYS_IDLE-PREV_SYS_IDLE))" 'BEGIN{printf "%.1f", (t>0)? (t-i)/t*100 : 0}')
    PREV_SYS_TOT=$SYS_TOT; PREV_SYS_IDLE=$SYS_IDLE
    LOAD1=$(cut -d' ' -f1 /proc/loadavg)

    LOG_SIZE=$(stat -c %s "$ALOG" 2>/dev/null || echo 0)
    if [ "$LOG_SIZE" != "$LAST_LOG_SIZE" ]; then LAST_LOG_SIZE=$LOG_SIZE; LAST_LOG_CHANGE=$T; fi
    LOG_IDLE=$(awk -v a="$T" -v b="$LAST_LOG_CHANGE" 'BEGIN{printf "%.0f", a-b}')
    ELAPSED=$(awk -v a="$T" -v b="$START_S" 'BEGIN{printf "%.1f", a-b}')

    awk -v a="$RSS" -v b="$PEAK_RSS" 'BEGIN{exit !(a>b)}' && PEAK_RSS=$RSS
    awk -v a="$CPU_INST" -v b="$PEAK_CPU" 'BEGIN{exit !(a>b)}' && PEAK_CPU=$CPU_INST

    echo "$(now),$ELAPSED,${PIDS_CSV//,/;},$STATES,$THREADS,$RSS,$RSS_MB,$MEM_PCT,$CPU_INST,$CPU_PS,$SYS_CPU,$LOAD1,$LOG_SIZE,$LOG_IDLE" >> "$CSV"
    echo "[$(now)] PROCESS:agent-leak-app PID:${PIDS_CSV} STATE:$STATES THREADS:$THREADS CPU:${CPU_INST}% MEM:${MEM_PCT}% RSS:${RSS_MB}MB SYS_CPU:${SYS_CPU}% LOAD:$LOAD1 LOG_IDLE:${LOG_IDLE}s" >> "$MLOG"

    # 주기적 스레드 스냅샷
    N=$((N+1))
    if [ $((N % SNAP_EVERY)) -eq 1 ]; then
        { echo "### $(now) (elapsed ${ELAPSED}s)"
          ps -L -o pid,lwp,stat,pcpu,wchan:24,comm -p "$PIDS_CSV" 2>/dev/null; echo; } >> "$TLOG"
    fi

    # 무응답(행) 감지: 프로세스는 살아있는데 로그도 안 늘고 CPU 도 거의 0
    if [ -z "$STALL_AT" ] && [ "$LOG_IDLE" -ge "$STALL_SEC" ] \
       && awk -v c="$CPU_INST" 'BEGIN{exit !(c<1.0)}'; then
        STALL_AT=$T
        log "[$(now)] !!! STALL DETECTED: PID alive, log idle ${LOG_IDLE}s, CPU ${CPU_INST}%"
        snapshot stall-detected
    fi
    if [ -n "$STALL_AT" ] && [ "$STALL_KILL" -gt 0 ] \
       && awk -v a="$T" -v b="$STALL_AT" -v k="$STALL_KILL" 'BEGIN{exit !(a-b>=k)}'; then
        snapshot stall-before-kill
        END_REASON="HUNG (no response for $((STALL_SEC+STALL_KILL))s, killed by monitor)"
        break
    fi

    # 타임아웃
    if awk -v e="$ELAPSED" -v t="$TIMEOUT" 'BEGIN{exit !(e>=t)}'; then
        snapshot timeout
        END_REASON="SURVIVED (still running at timeout ${TIMEOUT}s, stopped by monitor)"
        break
    fi

    PREV_T=$T
    sleep "$INTERVAL"
done

END_S=$(now_s); END_H=$(now)
if [ -z "$END_REASON" ]; then
    wait "$APP_PID" 2>/dev/null; EXIT_CODE=$?
    END_REASON="EXITED by itself (exit code $EXIT_CODE)"
    [ "$EXIT_CODE" -gt 128 ] && END_REASON+=" = signal $((EXIT_CODE-128)) ($(kill -l $((EXIT_CODE-128)) 2>/dev/null))"
else
    cleanup
fi

write_summary
log "[$END_H] END  reason=$END_REASON"
echo
echo "결과 저장 위치: $OUT"
cat "$OUT/summary.txt" | head -9