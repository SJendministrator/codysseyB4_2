#!/usr/bin/env bash
# =============================================================
# agent-leak-app 실행 환경 준비 스크립트
#
# 사용법 (반드시 source 로 실행해야 현재 셸에 환경변수가 남음):
#   source scripts/setup_env.sh
#   MEMORY_LIMIT=512 source scripts/setup_env.sh   # 값 덮어쓰기
#
# monitor.sh 가 내부에서 자동으로 source 하므로,
# 보통은 직접 실행할 필요 없이 monitor.sh 앞에 변수만 붙이면 된다.
# =============================================================

_fail() { echo "[setup_env] ERROR: $*" >&2; return 1 2>/dev/null || exit 1; }

# 1) 실행 계정: root 금지
if [ "$(id -u)" -eq 0 ]; then
    _fail "root 계정으로는 실행할 수 없습니다. 일반 사용자로 전환하세요 (예: su - agent)"
fi

# 2) 경로 관련 환경변수
export AGENT_HOME="${AGENT_HOME:-$HOME/agent_home}"
export AGENT_PORT=15034                                   # 고정값
export AGENT_UPLOAD_DIR="$AGENT_HOME/upload_files"
export AGENT_KEY_PATH="$AGENT_HOME/api_keys"
export AGENT_LOG_DIR="${AGENT_LOG_DIR:-$AGENT_HOME/logs}"

mkdir -p "$AGENT_UPLOAD_DIR" "$AGENT_KEY_PATH" "$AGENT_LOG_DIR" \
    || _fail "디렉터리 생성 실패"
[ -w "$AGENT_LOG_DIR" ] || _fail "AGENT_LOG_DIR 쓰기 권한 없음: $AGENT_LOG_DIR"

# 3) secret.key (개행 없이 정확히 기록)
printf 'agent_api_key_test' > "$AGENT_KEY_PATH/secret.key"
chmod 600 "$AGENT_KEY_PATH/secret.key"

# 4) 장애 재현용 튜닝 값 (미지정 시 기본값)
export MEMORY_LIMIT="${MEMORY_LIMIT:-256}"                # 50~512 (MB)
export CPU_MAX_OCCUPY="${CPU_MAX_OCCUPY:-50}"             # 10~100 (%)
export MULTI_THREAD_ENABLE="${MULTI_THREAD_ENABLE:-true}" # true/false

# 5) 값 검증 (앱 부트 시퀀스와 같은 조건)
[[ "$MEMORY_LIMIT" =~ ^[0-9]+$ ]] && [ "$MEMORY_LIMIT" -ge 50 ] && [ "$MEMORY_LIMIT" -le 512 ] \
    || _fail "MEMORY_LIMIT 은 50~512 사이 정수여야 함 (현재: $MEMORY_LIMIT)"
[[ "$CPU_MAX_OCCUPY" =~ ^[0-9]+$ ]] && [ "$CPU_MAX_OCCUPY" -ge 10 ] && [ "$CPU_MAX_OCCUPY" -le 100 ] \
    || _fail "CPU_MAX_OCCUPY 는 10~100 사이 정수여야 함 (현재: $CPU_MAX_OCCUPY)"
case "${MULTI_THREAD_ENABLE,,}" in
    true|false|1|0|yes|no) ;;
    *) _fail "MULTI_THREAD_ENABLE 은 true/false/1/0/yes/no 중 하나 (현재: $MULTI_THREAD_ENABLE)" ;;
esac

# 6) 포트 사용 여부 확인 (이전 실행이 남아 있으면 바인딩 실패함)
if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":$AGENT_PORT "; then
    _fail "포트 $AGENT_PORT 이 이미 사용 중입니다. 이전 프로세스를 종료하세요: pkill -f agent-leak-app"
fi

echo "[setup_env] OK  AGENT_HOME=$AGENT_HOME  MEMORY_LIMIT=${MEMORY_LIMIT}MB  CPU_MAX_OCCUPY=${CPU_MAX_OCCUPY}%  MULTI_THREAD_ENABLE=$MULTI_THREAD_ENABLE"
