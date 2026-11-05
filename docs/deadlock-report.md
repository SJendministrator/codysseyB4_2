# [Bug] Deadlock - 멀티스레드 모드에서 두 워커가 서로의 락을 기다려 프로세스 무응답

| 항목 | 내용 |
|---|---|
| 심각도 | Critical — 프로세스·포트는 살아 있어 "정상"처럼 보이지만 작업은 영원히 멈춤. 에러 로그 없음 |
| 환경 | Ubuntu 22.04 컨테이너 (OrbStack, linux/amd64, 6 core, 16GB), 실행 계정 `agent`(uid 1000) |
| 재현 조건 | `MULTI_THREAD_ENABLE=true` (메모리 `512`, CPU `50`으로 다른 장애는 배제) |
| 증거 | Before [`deadlock/before-mt-true/`](../evidence/deadlock/before-mt-true/) (스냅샷: [`snapshots/`](../evidence/deadlock/before-mt-true/snapshots/)) · After [`deadlock/after-mt-false/`](../evidence/deadlock/after-mt-false/) |

## 1. Description (현상 설명)

- **언제**: 2026-11-05 09:19:40 실행 → **09:19:49 마지막 로그** 이후 출력 없음
- **무엇이**: `agent-leak-app`(부모 PID 2099 / 앱 본체 PID 2105)이 종료되지 않은 채 아무 일도 하지 않음
- **어떻게 관측됐나**: 로그가 멈춘 지 30초 시점(09:20:20)에 관제가 `STALL DETECTED`를 띄움. 그 뒤 60초를 더 지켜봐도 로그·CPU·메모리 변화 없음 → 09:21:20 관제가 강제 종료 (총 무응답 91초)
- **특징**: OOM·CPU 장애와 달리 **스스로 죽지 않는다.** MemoryGuard도 Watchdog도 반응하지 않았고, 에러 로그도 한 줄 없다

## 2. Evidence & Logs (증거 자료)

### 2-1. PID 존재 증거 (`ps -ef`, 09:20:20 무응답 감지 시점)

```
$ ps -ef | grep agent-leak-app | grep -v grep
agent       2099    2079  0 09:19 pts/0    00:00:00 /workspace/agent-leak-app-x86
agent       2105    2099  0 09:19 pts/0    00:00:00 /workspace/agent-leak-app-x86

$ pstree -p 2099
agent-leak-app-(2099)---agent-leak-app-(2105)-+-{agent-leak-app-}(2452)
                                              `-{agent-leak-app-}(2453)
```

부모 2099 아래 앱 본체 2105가 있고, 그 안에 워커 스레드 2개(2452, 2453)가 살아 있다.

### 2-2. CPU/MEM 정체 증거 (`monitor.log`)

```
[2026-11-05 09:19:47] PROCESS:agent-leak-app PID:2099,2105 STATE:SS THREADS:4 CPU:0.0% MEM:0.12% RSS:19.6MB ... LOG_IDLE:0s
[2026-11-05 09:19:51] PROCESS:agent-leak-app PID:2099,2105 STATE:SS THREADS:4 CPU:0.0% MEM:0.12% RSS:19.6MB ... LOG_IDLE:2s
[2026-11-05 09:20:20] !!! STALL DETECTED: PID alive, log idle 30s, CPU 0.0%
[2026-11-05 09:20:21] PROCESS:agent-leak-app PID:2099,2105 STATE:SS THREADS:4 CPU:0.0% MEM:0.12% RSS:19.6MB ... LOG_IDLE:32s
[2026-11-05 09:21:20] END  reason=HUNG (no response for 90s, killed by monitor)
```

![Deadlock](../evidence/deadlock/compare.png)

- 위: 파랑(Before)은 마지막 로그 이후 경과 시간이 **직선으로 계속 증가** (로그 완전 정지). 주황(After)은 0~2초에 머묾
- 가운데: Before는 프로세스 CPU **100초 내내 0.0%** (무한 루프였다면 높게 나왔을 것). After는 수 % 단위로 계속 오르내림
- 아래: Before는 RSS 증가 없음 (After는 정상 모드의 메모리 워커가 돌아 톱니 모양). 72초 시점의 1회 감소(19.6 → 12.5MB)는 같은 시각 `top`의 SHR(공유 메모리)이 9.4 → 2.2MB로 줄어든 것과 크기가 같다 → 앱 작업이 아니라 **커널이 쓰이지 않는 공유 라이브러리 페이지를 RAM에서 내린 것**

### 2-3. 스레드 상태 (`ps -L`, `top -H`) — 60초 간격 두 스냅샷

**09:20:20 (무응답 감지)**

```
    PID     LWP STAT %CPU %MEM WCHAN                    COMMAND
   2099    2099 S+    0.2  0.0 do_wait                  agent-leak-app-
   2105    2105 SNl+  0.1  0.1 futex_wait               agent-leak-app-
   2105    2452 SNl+  0.0  0.1 futex_wait               agent-leak-app-
   2105    2453 SNl+  0.0  0.1 futex_wait               agent-leak-app-
```

**09:21:20 (60초 후)** — `top -H`

```
    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
   2099 agent     20   0    3000   1940   1676 S   0.0   0.0   0:00.10 agent-l+
   2105 agent     30  10  170172  10820   2224 S   0.0   0.1   0:00.05 agent-l+
   2452 agent     30  10  170172  10820   2224 S   0.0   0.1   0:00.00 agent-l+
   2453 agent     30  10  170172  10820   2224 S   0.0   0.1   0:00.00 agent-l+
```

| 관찰 | 의미 |
|---|---|
| 모든 스레드 `S`(Sleeping) | 실행 중(`R`)도, 종료(`Z`)도 아님 — 무언가를 **기다리며 잠듦** |
| `TIME+`가 60초 동안 전혀 안 늘어남 (2452·2453은 `0:00.00`) | 워커 스레드는 **CPU를 단 한 번도 쓰지 않은 채** 멈춰 있음 → busy-wait(스핀) 아님 |
| `WCHAN = futex_wait` | 커널 안에서 **futex** 대기. futex는 리눅스가 mutex/lock 대기를 구현하는 시스템 콜 → **락을 얻으려고 잠든 상태** |
| 2099의 `do_wait` | 부모는 자식 종료를 기다리는 정상 상태 (PyInstaller 부트로더) |
| 2105(메인)의 `futex_wait` | 메인 스레드는 워커 종료를 기다림 (`Waiting for worker threads to complete transactions...`) → 워커가 안 끝나니 메인도 영원히 대기 |

같은 프로세스의 시간순 기록(`threads.log`)에서 멈추는 순간도 보인다:

```
### 09:19:46 (6.3s)   2105  2105 SN+   0.8 do_select     ← 워커 생성 전, 서버 대기(정상)
### 09:19:51 (11.5s)  2105  2105 SNl+  0.4 futex_wait    ← 워커 2개 생성, 전부 락 대기로 전환
                      2105  2452 SNl+  0.0 futex_wait
                      2105  2453 SNl+  0.0 futex_wait
```

### 2-4. 마지막 로그 지점 (`app.log`)

```
 [ THREAD ] Concurrency: True 		[ WARNING ]
 >>> SYSTEM WARNING: POTENTIAL DEADLOCK IN CONCURRENT MODE.
2026-11-05 09:19:42,406 [WARNING] [System] CAUTION: Strict resource locking is enabled.
2026-11-05 09:19:47,433 [INFO] [Worker-Thread-1] Process Started. Attempting to lock [Shared_Memory_A]...
2026-11-05 09:19:47,433 [INFO] [AgentWorker][Worker-Thread-1] LOCK ACQUIRED: [Shared_Memory_A]. (Holding...)
2026-11-05 09:19:47,434 [INFO] [AgentWorker][Worker-Thread-2] Process Started. Attempting to lock [Socket_Pool_B]...
2026-11-05 09:19:47,434 [INFO] [AgentWorker][Worker-Thread-1] Processing critical data in Memory A...
2026-11-05 09:19:47,434 [INFO] [AgentWorker] Waiting for worker threads to complete transactions...
2026-11-05 09:19:47,435 [INFO] [AgentWorker][Worker-Thread-2] LOCK ACQUIRED: [Socket_Pool_B]. (Holding...)
2026-11-05 09:19:47,435 [INFO] [AgentWorker][Worker-Thread-2] Establishing network connections in Pool B...
2026-11-05 09:19:49,447 [INFO] [AgentWorker][Worker-Thread-1] Need resource [Socket_Pool_B] to finish job.
2026-11-05 09:19:49,447 [INFO] [AgentWorker][Worker-Thread-1] WAITING for [Socket_Pool_B]... (Status: BLOCKED)
2026-11-05 09:19:49,447 [INFO] [AgentWorker][Worker-Thread-2] Need resource [Shared_Memory_A] to write logs.
2026-11-05 09:19:49,448 [INFO] [AgentWorker][Worker-Thread-2] WAITING for [Shared_Memory_A]... (Status: BLOCKED)
                                                         ← 이후 로그 없음 (91초)
```

## 3. Root Cause Analysis (원인 분석)

### 로그로 대기 관계 추적

로그를 스레드별로 나눠 **"보유(LOCK ACQUIRED)" 줄과 "대기(WAITING)" 줄을 짝지었다.**

| 스레드 | 보유 (09:19:47) | 대기 (09:19:49) | 기다리는 자원의 주인 |
|---|---|---|---|
| Worker-Thread-1 | `Shared_Memory_A` | `Socket_Pool_B` | Worker-Thread-2 |
| Worker-Thread-2 | `Socket_Pool_B` | `Shared_Memory_A` | Worker-Thread-1 |

```
   Worker-Thread-1 ──보유──▶ [Shared_Memory_A]
         ▲                          │
       대기                        대기
         │                          ▼
   [Socket_Pool_B] ◀──보유── Worker-Thread-2
```

Thread-1 → (B 필요) → Thread-2 → (A 필요) → Thread-1 로 **대기 관계가 원을 그리며 닫힌다.** 둘 다 상대가 락을 놓아야 진행할 수 있는데, 상대도 같은 이유로 놓지 않으므로 영원히 진행되지 않는다. 그 뒤로 해제(release) 로그가 한 줄도 없다는 점, 같은 시점 커널에서 두 스레드가 모두 `futex_wait`였다는 점이 **애플리케이션 시점(로그)과 OS 시점(스레드 상태) 양쪽에서** 이 결론을 뒷받침한다.

### 교착상태 4대 조건 대입

| 조건 | 이 장애에서의 근거 |
|---|---|
| 상호 배제 (Mutual Exclusion) | A·B는 한 번에 한 스레드만 잡는 락 (`Strict resource locking is enabled`) |
| 점유 대기 (Hold and Wait) | 각 스레드가 자기 락을 `Holding...` 한 채로 다른 락을 요청 |
| 비선점 (No Preemption) | 상대 락을 빼앗는 로직 없음 — 대기만 함 (`Status: BLOCKED`) |
| 순환 대기 (Circular Wait) | 1 → 2 → 1 (위 그림) — 원인: **두 스레드가 락을 반대 순서로 잡음** (1은 A → B, 2는 B → A) |

네 조건이 모두 성립했다. 하나만 깨도 교착은 생기지 않는다.

### 왜 OS·보호 정책이 알아채지 못했나

스레드들은 `S` 상태로 얌전히 잠들어 있어 스케줄러 입장에서는 "기다리는 중인 정상 스레드"다. CPU도 안 쓰고(Watchdog 무반응) 메모리도 안 늘고(MemoryGuard 무반응) 에러도 안 낸다. 그래서 **"진행되고 있는가"(로그 무변화 시간)** 라는 별도 지표로만 감지할 수 있었다. 식사하는 철학자 문제에서 모두가 왼쪽 포크를 쥐고 오른쪽 포크를 기다리는 상황과 같다.

## 4. Workaround & Verification (조치 및 검증)

### 조치: `MULTI_THREAD_ENABLE` true → false

```bash
# Before
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=true  ./scripts/monitor.sh deadlock before-mt-true 300
# After
MEMORY_LIMIT=512 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=false ./scripts/monitor.sh deadlock after-mt-false 600
```

### Before & After

| 항목 | Before (`true`) | After (`false`) |
|---|---|---|
| 부팅 판단 | `Concurrency: True [ WARNING ]` `POTENTIAL DEADLOCK` | `Concurrency: False [ OK ]` → `Healthy System Monitoring` |
| 락 경쟁 로그 | `LOCK ACQUIRED` ×2 → `WAITING … BLOCKED` ×2 | 없음 (트랜잭션 워커 자체가 생성되지 않음) |
| 스레드 상태 | 워커 2개 모두 `futex_wait`, `TIME+` 0:00.00 고정 | 워커 2개 `do_select`(작업 사이 정상 대기), %CPU 0.8~0.9 — 실제로 일하고 있음 |
| 로그 진행 | 09:19:49 이후 정지 | 600초 내내 진행, 로그 공백 최대 **2초** |
| CPU / 메모리 | 0% / 변화 없음 | 평균 1.8% / 25MB씩 증가 후 525MB에서 정리 (9회) |
| 무응답 감지 | 31초 만에 `STALL DETECTED` | **0회** |
| 결과 | `HUNG` (91초 무응답, 관제가 종료) | `SURVIVED` (600초 타임아웃까지 정상 동작) |

After 실행이 끝날 때 찍은 스레드 스냅샷 (`deadlock/after-mt-false/snapshots/104703-timeout.txt`):

```
    PID     LWP STAT %CPU %MEM WCHAN                    COMMAND
  64380   64380 S+    0.0  0.0 do_wait                  agent-leak-app-
  64386   64386 SNl+  0.0  1.0 futex_wait               agent-leak-app-   ← 메인: 워커를 기다리는 정상 대기
  64386   64503 SNl+  0.9  1.0 do_select                agent-leak-app-   ← 워커: 일하고 쉬기를 반복
  64386   64504 SNl+  0.8  1.0 do_select                agent-leak-app-
```

Before와 같은 `S` 상태라도 **무엇을 기다리는지(WCHAN)와 CPU 시간이 쌓이는지**가 다르다. Before의 워커는 락(`futex`)에서 CPU를 한 번도 못 쓰고 멈춰 있었고, After의 워커는 `select`로 잠깐 쉬었다 일하기를 반복하며 CPU를 조금씩 쓰고 있다. "잠들어 있다"만으로는 데드락이라 할 수 없고, **락 대기 + 진행 없음**이 함께 확인돼야 한다.

### 해석

- 멀티스레드를 끄면 락을 두고 경쟁할 상대가 없어 **순환 대기 조건이 원천적으로 사라진다.**
- 대가: 병렬 처리의 이점을 잃어 처리량이 줄어든다. 근본 해결이 아닌 회피책이다.

### 근본 해결 제안

```python
# 1) 락 획득 순서 전역 통일 — 모든 스레드가 A → B 순서로만 잡으면 순환 대기 불가
with lock_A:
    with lock_B:
        ...

# 2) 타임아웃 락 — 무한 대기 금지, 실패하면 보유 락 반납 후 재시도 (점유 대기 깨기)
if lock_B.acquire(timeout=2):
    try: ...
    finally: lock_B.release()
else:
    lock_A.release(); backoff(); retry()
```

- 두 자원을 함께 쓰는 구간이 짧다면 **하나의 락으로 통합**
- 운영 감시: 로그·하트비트가 N초 이상 멈추면 알람 + 스레드 덤프 자동 수집 (이 레포 `monitor.sh`의 STALL 감지처럼). "프로세스 살아있음"만 보는 헬스체크로는 잡히지 않는다
