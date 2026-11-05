# codysseyB4_2 — 시스템 장애 분석 (OOM · CPU Spike · Deadlock)

컴퓨터가 갑자기 느려지거나 멈췄을 때, 재부팅부터 하지 않고 **관제 데이터와 로그를 근거로 원인을 추론하고 GitHub Issue 형태의 기술 리포트로 남기는** 미션입니다.

- 대상: 제공 바이너리 `agent-leak-app` (Python/PyInstaller, 디컴파일 없이 로그·관제·표준 명령어로만 분석)
- 환경: macOS + OrbStack → `ubuntu:22.04` 컨테이너 (`linux/amd64`, 6 core, 16GB), 일반 사용자 `agent`로 실행

---

## 1. 결과 요약

| 장애 | 리포트 | Before | After | 핵심 증거 |
|---|---|---|---|---|
| **OOM** | [oom-report.md](docs/oom-report.md) | `MEMORY_LIMIT=256` → **33.6초** 만에 강제 종료 (SIGKILL, exit 137) | `MEMORY_LIMIT=512` → **15분 이상 생존**, 한도 도달 시 캐시 비우고 회복 (13회) ⏳ 동일 조건 재측정 예정 | Heap 25MB/3초 선형 증가, `[MemoryGuard] Memory limit exceeded (275MB >= 256MB)` |
| **CPU** | [cpu-report.md](docs/cpu-report.md) | `CPU_MAX_OCCUPY=100` → **33.6초** 만에 종료 (SIGTERM, exit 143), 3회 재현 | `CPU_MAX_OCCUPY=30` → **15분 이상 생존**, 30%에서 자체 cooldown (25회) | 앱 Load 5% → 52% 단조 증가 후 약 50%에서 종료, `[CpuWorker] CPU Threshold Violated! (52.33%)` |
| **Deadlock** | [deadlock-report.md](docs/deadlock-report.md) | `MULTI_THREAD_ENABLE=true` → PID 살아있으나 로그 정지, CPU 0%, 91초 무응답 | `MULTI_THREAD_ENABLE=false` → ⏳ 추가 실행 예정 | 워커 스레드 2개 모두 `futex_wait`, `WAITING for [Socket_Pool_B] / [Shared_Memory_A] (BLOCKED)` |
| 보너스 | [scheduling-analysis.md](docs/scheduling-analysis.md) | 등록 A→B→C, 실행 B→C→A, 각 작업이 100% 끝난 뒤 다음 작업 시작 | | **비선점 Priority** 스케줄링으로 추론 |

> ⏳ 두 칸은 "비교 대상과 변수 하나만 다른" 재측정을 추가할 예정입니다 ([evidence/README.md](evidence/README.md#추가-실행-예정)). 현재 OOM After는 같은 메모리 한도의 정상 모드 실행(`cpu/after-30`)으로 비교했습니다.

### 실행하면서 알아낸 앱의 동작: "시나리오 선택기"

처음엔 세 장애가 한 프로세스에서 동시에 일어날 거라 생각했지만, 실제로는 **앱이 부팅 시 환경변수를 검사해 장애 시나리오를 하나만 고른다**는 걸 실행 결과로 확인했습니다.

| 우선순위 | 조건 | 선택되는 시나리오 | 확인한 실행 |
|---|---|---|---|
| 1 | `MEMORY_LIMIT` ≤ 256 (부팅 시 `WARNING: Recommend Over 256MB`) | 메모리 누수 → MemoryGuard 종료 | MEM 256 |
| 2 | `CPU_MAX_OCCUPY` > 50 (`WARNING: Recommend Under 50%`) | CPU 과점유 → Watchdog 종료 | CPU 100 (3회, 스레드 true여도 CPU가 우선) |
| 3 | `MULTI_THREAD_ENABLE=true` (`POTENTIAL DEADLOCK`) | 데드락 | MEM 512 + CPU 50 + MT true |
| - | 모두 정상 | `Healthy System Monitoring` (안정 동작 + 스케줄러 로그) | MEM 512 + CPU 30 + MT false |

그래서 **한 장애를 관찰할 때는 더 높은 우선순위 장애를 꺼두고, 비교할 변수 하나만 바꾸는 방식**으로 실험을 다시 설계했고, 처음 실행한 결과는 **실제로 재현된 장애 기준으로 폴더를 재분류**했습니다 (매핑: [evidence/README.md](evidence/README.md)).

또 하나: `CPU_MAX_OCCUPY`는 Watchdog 기준이 아니라 **작업이 스스로 멈추는 상한**이었습니다. 그래서 **낮출수록(30) 살아남고 높이면(100) 죽습니다** — 처음 예상과 반대였습니다 ([cpu-report §3](docs/cpu-report.md#3-root-cause-analysis-원인-분석)).

---

## 2. 평가 항목별 확인 위치

| 평가 항목 | 확인 위치 |
|---|---|
| [OOM] 메모리가 선형 증가하다 강제 종료되는 패턴 | [oom-report §2](docs/oom-report.md), [`evidence/oom/before-256mb/`](evidence/oom/before-256mb/) |
| [OOM] `MEMORY_LIMIT` Before & After | [oom-report §4](docs/oom-report.md), `evidence/oom/compare.png` |
| [CPU] 임계치 초과 후 종료 패턴 | [cpu-report §2](docs/cpu-report.md), [`evidence/cpu/before-100/`](evidence/cpu/before-100/) + 재현 2회 |
| [CPU] `CPU_MAX_OCCUPY` Before & After | [cpu-report §4](docs/cpu-report.md), `evidence/cpu/compare.png` |
| [Deadlock] PID 존재 + CPU/MEM 무변화 + 로그 정지 식별 | [deadlock-report §2](docs/deadlock-report.md), [`evidence/deadlock/before-mt-true/snapshots/`](evidence/deadlock/before-mt-true/snapshots/) |
| [Deadlock] `MULTI_THREAD_ENABLE` 재현/회피 비교 | [deadlock-report §4](docs/deadlock-report.md) |
| [Format] 3건 모두 현상 → 증거 → 원인 → 조치 구조 | 각 리포트 §1 ~ §4 |
| [Evidence] PID, 타임스탬프, 핵심 로그 포함 | 각 리포트 §2 (로그 발췌), 각 실행 폴더의 `monitor.log`·`summary.txt` |
| 항목 2 · 3 · 4 (설명 문항) | 이 문서 [5](#5-관제-방법-항목-2) · [6](#6-장애-원리-항목-3) · [7](#7-회고와-개선-항목-4) |
| 보너스 (스케줄링 추론) | [scheduling-analysis.md](docs/scheduling-analysis.md) |

---

## 3. 폴더 구조

```
scripts/
  setup_env.sh   앱 부트 조건(계정·디렉터리·secret.key·환경변수 범위·포트) 준비 + 사전 검증
  monitor.sh     앱 실행 + 1초 단위 관제. 종료 / 무응답 / 타임아웃까지 자동 기록
  plot.py        케이스별 Before & After 비교 그래프
evidence/README.md   실행별 조건·결과 표, 폴더 재분류 매핑
evidence/<case>/compare.png   Before & After 그래프
evidence/<case>/<label>/
  metrics.csv    수치 (RSS, 순간 CPU, ps CPU, 시스템 CPU, 스레드 수, 로그 무변화 시간 …)
  monitor.log    사람이 읽는 관제 로그 (PID 포함)
  app.log        앱 실행 로그 전체 (타임스탬프 포함)
  threads.log    ps -L 스레드 스냅샷 (5초 주기)
  snapshots/     무응답 감지 · 종료 시점의 ps -ef / ps -L / top -H / pstree / 로그 tail
  env.txt        실행 당시 환경변수와 커널·코어·메모리 정보
  summary.txt    생존 시간, 종료 사유(exit code · signal), 핵심 로그 줄
docs/            리포트 3건 + 보너스 + 트러블슈팅 기록
```

---

## 4. 실행 방법

### 사전 조건 (앱 부트 시퀀스가 검사하는 항목)

| 항목 | 조건 | 처리 |
|---|---|---|
| 실행 계정 | root 금지 | 컨테이너에서 `agent` 계정 생성 후 전환 |
| `AGENT_HOME` / `AGENT_UPLOAD_DIR` / `AGENT_KEY_PATH` / `AGENT_LOG_DIR` | 디렉터리 존재 + 로그 쓰기 권한 | `setup_env.sh`가 생성·검사 |
| `secret.key` | 내용 `agent_api_key_test` | `setup_env.sh`가 개행 없이 생성 |
| `AGENT_PORT` | 15034, `0.0.0.0` 바인딩 가능 | 이미 사용 중이면 실행 전에 중단 |
| `MEMORY_LIMIT` / `CPU_MAX_OCCUPY` / `MULTI_THREAD_ENABLE` | 50~512 / 10~100 / true·false | 범위 밖이면 실행 전에 중단 |

### 컨테이너 준비 (최초 1회)

```bash
# macOS (OrbStack 실행 상태)
cd codysseyB4_2
docker run -it --name b4 --platform linux/amd64 -v "$PWD":/workspace ubuntu:22.04 bash

# 컨테이너 root
apt-get update && apt-get install -y procps psmisc
useradd -m agent
chmod +x /workspace/agent-leak-app-x86 /workspace/scripts/*.sh
chmod -R a+w /workspace/evidence
su - agent -s /bin/bash

# 컨테이너 agent
cd /workspace && export APP_BIN=/workspace/agent-leak-app-x86
```

### 케이스별 실행 (형식: `변수=값 ./scripts/monitor.sh <case> <label> [timeout초]`)

시나리오 우선순위를 고려해, 관찰하려는 장애보다 우선순위가 높은 장애는 정상값으로 고정하고 **변수 하나만** 바꿉니다.

```bash
# OOM — 메모리 한도만 비교
MEMORY_LIMIT=256 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=false ./scripts/monitor.sh oom before-256mb-mtoff
#   After는 아래 deadlock/after-mt-false 실행을 공유 (512 / 50 / false)

# CPU — 메모리 정상, 스레드 끔, CPU 상한만 비교
MEMORY_LIMIT=512 MULTI_THREAD_ENABLE=false CPU_MAX_OCCUPY=100 ./scripts/monitor.sh cpu before-100
MEMORY_LIMIT=512 MULTI_THREAD_ENABLE=false CPU_MAX_OCCUPY=30  ./scripts/monitor.sh cpu after-30

# Deadlock — 메모리·CPU 정상, 멀티스레드만 비교
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=true  ./scripts/monitor.sh deadlock before-mt-true 300
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=false ./scripts/monitor.sh deadlock after-mt-false 600

# 그래프 (matplotlib 필요. 맥이나 다른 환경에서 실행해도 됨)
python3 scripts/plot.py
```

이미 실행한 결과와 실행 당시 이름은 [evidence/README.md](evidence/README.md)에 정리돼 있습니다.

`monitor.sh`는 다음 중 하나가 되면 스스로 끝나고 `summary.txt`에 사유를 남깁니다.

| 종료 사유 | 의미 |
|---|---|
| `EXITED by itself (exit code N = signal …)` | 앱이 스스로 종료 (MemoryGuard → 137/SIGKILL, Watchdog → 143/SIGTERM) |
| `HUNG (…)` | PID는 살아있는데 로그도 CPU도 멈춘 상태가 `STALL_SEC`(30초) 지속 → 증거 스냅샷 저장 후 60초 더 관찰하고 종료 |
| `SURVIVED (…)` | timeout까지 정상 생존 |

---

## 5. 관제 방법 (항목 2)

### Q. `monitor.sh`에서 메모리 증가 패턴을 어떻게 추적했나?

| 무엇을 | 어떻게 | 왜 |
|---|---|---|
| 대상 PID 찾기 | `$!`(앱 실행 직후 PID) + `pgrep -P`로 자식까지 재귀 수집 | PyInstaller 바이너리는 **압축 해제용 부모 + 실제 앱 자식** 2개 프로세스로 뜬다. 실측: `PID:279,285` 중 MemoryGuard 로그에 찍힌 건 자식 `285` |
| 물리 메모리 | `/proc/<pid>/status`의 `VmRSS` (kB)를 1초마다 읽어 PID 합산 | RSS = 실제 RAM에 올라와 있는 양. VSZ(예약한 가상 주소)는 누수 판단에 부정확 |
| 시스템 대비 비율 | `RSS ÷ /proc/meminfo MemTotal` | 다른 서버와 비교 가능한 % 값 |
| 기록 | `metrics.csv`(그래프용) + `monitor.log`(타임스탬프·PID 포함 텍스트) | CSV는 `plot.py`로 Before & After 그래프, 로그는 리포트 발췌용 |
| 추출 | `awk -F, '{print $2, $7}' metrics.csv` (경과 시간, RSS MB) | 증가율(MB/s) 계산: 실측 25MB / 3.05초 ≈ **8.2MB/s** 일정 → 선형 누수 |

### Q. 프로세스 CPU 사용률은 어떤 도구·옵션으로 봤나?

| 도구 | 옵션 의미 | 이 미션에서의 판단 |
|---|---|---|
| `/proc/<pid>/stat` | 14·15번째 필드 `utime`·`stime` = 프로세스가 지금까지 쓴 CPU tick | **직전 1초 동안 증가한 tick ÷ CLK_TCK ÷ 경과시간** 으로 순간 CPU 계산 → 주 지표 (`cpu_inst_pct`) |
| `ps -o %cpu= -p PID` | `-o`로 출력 컬럼 지정, `=`로 헤더 제거 | **프로세스 시작 이후 누적 평균**이라 스파이크가 희석됨. 비교용으로만 기록 (`cpu_ps_avg_pct`) |
| `top -H -b -n 1 -p PID` | `-H` 스레드 단위, `-b` 배치(파일 저장용), `-n 1` 1회, `-p` 특정 PID만 | 종료·무응답 시점 스냅샷 |
| `/proc/stat`, `/proc/loadavg` | 시스템 전체 CPU, load average | "시스템 전체 부하"인지 "특정 프로세스"인지 구분 |

실측으로 차이가 드러났습니다 (CPU 100 실행, [그래프](evidence/cpu/compare.png)):

| 구간 | 앱 Load | 순간 CPU (10초 평균) | `ps %CPU` |
|---|---|---|---|
| 0~10초 | 5% → 7% | 0.31% | 7.5% → 2.0% |
| 10~20초 | 14% → 24% | 0.53% | 1.5% → 1.2% |
| 20~34초 | 34% → 52% | **1.32%** | 1.2% → 1.3% |

- 순간값은 앱 Load와 **같은 방향으로 4배 증가**했지만, `ps`는 기동 비용이 희석되며 **계속 떨어지기만** 해서 증가를 전혀 보여주지 못했습니다. `ps`만 봤다면 "CPU 문제 아님"으로 오판했을 것입니다.
- 시스템 전체 CPU는 1~2%로 평탄 → 서버 전체가 아니라 **이 프로세스 내부 문제**입니다.
- 절대값은 작습니다(코어 1개의 2% 미만). 오히려 살아남은 30% 실행이 OS 기준 CPU를 더 썼습니다. 즉 이 앱의 **Watchdog은 OS 측정값이 아니라 앱 내부 Load 지표로 판단**합니다. 관제 도구가 보는 값과 앱이 판단하는 값이 다를 수 있다는 점을 리포트에 함께 기록했습니다.

### Q. "살아있지만 멈춘" 프로세스는 어떤 순서로 진단했나?

```
① 살아있나?      ps -ef | grep agent-leak-app        → PID 2099(부모)·2105(자식) 존재
② 일하고 있나?    monitor.log의 CPU / RSS / LOG_IDLE  → CPU 0%, RSS 19.6MB 고정, 로그 무변화 30초↑
③ 스레드는?      ps -L -o pid,lwp,stat,wchan / top -H → 스레드 전부 S(Sleep), CPU 0.0%, TIME+ 정지
④ 무엇을 기다리나? WCHAN = futex_wait                  → 커널 수준에서 락(mutex) 대기 중
⑤ 왜 기다리나?    app.log 마지막 줄                    → Thread-1은 B를, Thread-2는 A를 기다림 (BLOCKED)
⑥ 결론           대기 관계에 사이클 → 교착상태
```

- ②에서 CPU가 높았다면 무한 루프(busy-wait)를, ④에서 `do_wait`/`ep_poll`이면 자식 대기·I/O 대기를 의심했을 것입니다. `futex`이기 때문에 락 문제로 좁혔습니다.
- 이 흐름을 `monitor.sh`에 자동화해서, **로그 무변화 30초 + CPU<1%** 가 되면 ①③④⑤ 결과를 `snapshots/`에 자동 저장합니다.

---

## 6. 장애 원리 (항목 3)

### Q. 메모리 누수 시 애플리케이션이 스스로 프로세스를 종료하는 이유는?

누수는 그대로 두면 RAM → 스왑 → 커널 **OOM Killer** 순서로 번집니다. 커널 OOM Killer는 `oom_score`가 높은 프로세스를 고르기 때문에 **누수 원인이 아닌 DB나 SSH 같은 다른 프로세스가 죽을 수도** 있고, 그 전에 스왑으로 시스템 전체가 느려집니다. MemoryGuard는 그 전에 **원인 프로세스 하나만 확실하게** 끝내는 안전 퓨즈입니다. 실측에서도 RSS 270MB, 시스템 메모리 대비 1.7%에서 끊어서 호스트에는 영향이 없었습니다. 즉 **종료는 보호 동작이고, 진짜 결함은 해제되지 않는 Heap**입니다.

### Q. CPU 과점유 시 단일 프로세스를 종료하는 게 왜 시스템 보호인가?

리눅스 스케줄러(CFS)는 실행 가능한 태스크들에게 CPU 시간을 나눠줍니다. 쉬지 않고 계산만 하는 프로세스는 매번 자기 몫을 꽉 채워 쓰기 때문에, 코어 수보다 그런 태스크가 많아지면 **다른 서비스는 실행 대기열에서 기다리는 시간이 늘어납니다**(응답 지연, starvation). 원인 하나를 끊는 비용(그 작업 실패)이 모든 서비스가 느려지는 비용보다 작으므로 Watchdog이 끊습니다. 이 앱은 추가로 부팅 시 `nice=10`으로 **스스로 우선순위를 낮춰**(top에서 `NI 10`, `PR 30` 확인) 다른 프로세스에 양보하도록 설계돼 있습니다. 또한 SIGKILL이 아닌 **SIGTERM(143)** 으로 끝내 정리할 기회를 줍니다.

### Q. Deadlock이 "상호 배제"와 "순환 대기"로 어떻게 발생하나?

- **상호 배제**: `Shared_Memory_A`, `Socket_Pool_B`는 한 번에 한 스레드만 잡을 수 있는 락입니다 (`LOCK ACQUIRED ... (Holding...)`).
- **순환 대기**: Thread-1은 A를 쥔 채 B를, Thread-2는 B를 쥔 채 A를 기다립니다. 대기 관계가 1 → 2 → 1로 닫혀 있어 어느 쪽도 먼저 풀 수 없습니다.
- 여기에 **점유 대기**(쥔 락을 놓지 않고 다음 락 요청)와 **비선점**(남의 락을 빼앗을 수 없음)이 함께 성립해 4대 조건이 모두 만족됩니다. 하나만 깨도(예: 모든 스레드가 A → B 순서로만 잡기) 데드락은 생기지 않습니다.

### Q. 로그에서 A→B, B→A 순환 관계를 어떻게 추적했나?

`app.log`를 스레드 이름으로 나눠 **"보유(ACQUIRED)" 줄과 "대기(WAITING)" 줄을 짝지었습니다.**

```
09:19:47.433 [Worker-Thread-1] LOCK ACQUIRED: [Shared_Memory_A]   ← 1이 A 보유
09:19:47.435 [Worker-Thread-2] LOCK ACQUIRED: [Socket_Pool_B]     ← 2가 B 보유
09:19:49.447 [Worker-Thread-1] WAITING for [Socket_Pool_B] (BLOCKED)   ← 1이 B 대기 (B는 2가 보유)
09:19:49.448 [Worker-Thread-2] WAITING for [Shared_Memory_A] (BLOCKED) ← 2가 A 대기 (A는 1이 보유)
— 이후 로그 없음. 31초 뒤 STALL 감지, 총 91초 무응답 확인 —
```

두 `WAITING`이 1ms 차이로 찍힌 뒤 해제(RELEASED) 로그가 영원히 나오지 않았고, 같은 시점 `ps -L`에서 스레드 2개(LWP 2452, 2453)가 모두 `futex_wait`였습니다. **로그(애플리케이션 시점)와 커널 상태(OS 시점)가 같은 결론**을 가리키므로 순환 대기로 판단했습니다.

---

## 7. 회고와 개선 (항목 4)

### Q. 실제 운영 서버라면 메모리 누수를 장애 전에 잡기 위해 `monitor.sh`를 어떻게 바꾸겠나?

1. **증가율 기반 예측 알람**: 최근 N분 RSS로 기울기(MB/분)를 구해 `한도까지 남은 시간 = (한도 − 현재 RSS) ÷ 기울기`가 10분 미만이면 경고. 이번 데이터면 시작 후 몇 초 만에 "약 30초 뒤 종료 예상"을 알릴 수 있었습니다. 절대값 임계치(80%)만 쓰면 이미 늦습니다.
2. **"회복" 이벤트도 관제**: 512MB 실행처럼 캐시 비우기가 반복되면 죽지는 않아도 누수는 진행 중입니다. `MEMORY RECOVERED` 빈도를 지표로 수집.
3. **상주 서비스화 + 외부 알림**: 앱을 직접 띄우는 대신 PID를 붙잡아 감시하고 systemd 서비스로 상시 실행, 경고는 Slack/웹훅으로 전송.
4. **자동 증거 수집**: 경고 시점에 `/proc/<pid>/smaps_rollup`, 로그 tail을 자동 저장 → 재시작으로 원인이 묻히지 않게.

### Q. 세 장애 중 실서비스에서 가장 치명적인 것과 예방법은?

**Deadlock입니다.** OOM과 CPU 장애는 프로세스가 **죽기 때문에** 로그가 남고 프로세스 관리자(systemd, k8s)가 자동 재시작합니다. 데드락은 **PID도 포트도 살아있어서** "프로세스 살아있음" 수준의 헬스체크는 통과하는데 요청은 영원히 처리되지 않습니다. 이번에도 에러 로그 한 줄 없이 CPU 0%로 조용히 멈춰 있었고, 로그 정지 시간을 따로 재지 않았다면 정상으로 보였을 것입니다.
예방: ① 락 획득 순서 전역 통일, ② `acquire(timeout=)`로 무한 대기 금지, ③ 헬스체크를 "실제 작업이 진행되는가"(하트비트·처리 건수) 기준으로 설계해 정지 시 자동 재시작.

### Q. 같은 서버에서 OOM과 Deadlock이 동시에 발생하면 어떤 순서로 트러블슈팅하나?

1. **데드락 증거부터 즉시 채집** (`ps -L`, `top -H`, wchan, 로그 tail) — 수십 초면 끝나고, OOM으로 프로세스가 죽으면 스레드 상태는 **영원히 사라지는** 휘발성 증거이기 때문
2. **OOM 대응 (피해 확산 차단)** — 메모리는 시간이 지날수록 커널 OOM Killer를 통해 **다른 프로세스까지** 위협하지만, 데드락은 해당 서비스 안에 갇혀 있음. 한도 상향 또는 재시작으로 호스트부터 보호
3. **둘의 인과관계 확인** — 락을 잡고 멈춘 스레드가 버퍼를 계속 쌓거나 해제를 못 해 누수를 **유발**했을 수 있음. 데드락이 원인이면 OOM은 증상이므로 데드락 수정이 근본 해결
4. 데드락 원인 분석 → 코드 수정

판단 근거는 **영향 범위(시스템 전체 vs 서비스 하나)** 와 **증거의 휘발성**입니다.

### Q. 소스를 고칠 수 있다면 장애별로 어떤 코드 개선을 하겠나?

| 장애 | 코드 레벨 개선 |
|---|---|
| OOM | 쌓이는 캐시에 상한 (`collections.deque(maxlen=)`, `functools.lru_cache(maxsize=)`) 또는 TTL. 처리 끝난 데이터 참조 제거. 개발 단계에서 `tracemalloc`으로 할당 위치 추적 |
| CPU | 무거운 계산을 작은 단위로 쪼개 사이에 `sleep`/양보, busy-wait 루프를 이벤트·조건변수 대기로 교체, 작업 큐 + 처리량 제한(rate limit) |
| Deadlock | 모든 스레드가 같은 순서(A → B)로 락 획득, `lock.acquire(timeout=…)` 실패 시 보유 락 반납 후 재시도, 가능하면 두 자원을 하나의 락으로 통합 |

### Q. 처음부터 다시 한다면 무엇을 다르게 하겠나?

- **실행 전에 부팅 로그부터 읽기**: `Resource Check`의 WARNING 문구(`Recommend Over 256MB`, `Recommend Under 50%`)가 이미 시나리오 선택 조건과 "안전한 방향"을 알려주고 있었습니다. 이를 무시하고 세 장애가 동시에 일어난다고 가정해 6번 중 3번이 의도와 다른 장애를 재현했고, CPU는 Before/After를 반대로 잡았습니다.
- **한 번에 변수 하나만 바꾸기**: Before와 After 사이에 변수가 둘 이상 다르면 "무엇 때문에 달라졌는지" 말할 수 없습니다.
- **관제 도구부터 검증**: 가짜 앱으로 스크립트를 먼저 시험했지만, 실제 앱이 PID 2개로 뜨는 것까지는 예상하지 못해 CSV 칸이 밀리는 버그가 생겼습니다. 실제 대상으로 짧게 한 번 돌려보고 시작했어야 했습니다.
- **`ps %CPU`를 믿지 않기**: 누적 평균이라 스파이크를 놓칩니다. 처음부터 순간값을 계산했습니다.

---

## 8. 제약 준수

- 바이너리 디컴파일·리버스 엔지니어링 없음. 분석은 앱 로그, `/proc`, `ps`, `top`, `pstree`, `kill` 등 리눅스 표준 도구로만 수행
- 앱은 root가 아닌 일반 사용자(`agent`, uid 1000)로 격리된 컨테이너에서 실행
- 트러블슈팅 과정 기록: [docs/troubleshooting-log.md](docs/troubleshooting-log.md)