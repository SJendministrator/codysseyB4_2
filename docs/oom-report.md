# [Bug] OOM - 메모리 누수로 MEMORY_LIMIT 도달 시 MemoryGuard에 의한 강제 종료

> 상태: 🟡 초안 — `<!-- TODO -->` 부분은 실측 데이터로 채움
> 증거 폴더: [`evidence/oom/`](../evidence/oom/)

## 1. Description (현상 설명)

- **무엇이**: `agent-leak-app` 프로세스가 사용자 조작 없이 실행 중 스스로 종료됨
- **언제**: 실행 후 약 <!-- TODO: N -->초 경과 시점 (`MEMORY_LIMIT=256`)
- **어떻게 관측됐나**: 관제상 물리 메모리(RSS)가 시간에 따라 계속 증가하다가 종료 직전 <!-- TODO -->MB에 도달, 앱 로그에 `MemoryGuard` / `SELF-TERMINATED` 출력 후 프로세스 사라짐
- **재현 조건**: 같은 설정으로 다시 실행하면 같은 시점에 반복 종료됨 (재현율 <!-- TODO: n/n -->)

## 2. Evidence & Logs (증거 자료)

### 2-1. 관제 데이터 — RSS 증가 추이 (`monitor.sh`)

![OOM Before & After](../evidence/oom/compare.png)

```
<!-- TODO: evidence/oom/before-256mb/monitor.log 에서 시작 / 중간 / 종료 직전 줄 5개 정도 발췌 -->
```

| 경과 시간 | RSS (MB) | 순간 CPU (%) |
|---|---|---|
| <!-- TODO --> | | |

→ CPU는 낮고 안정적인데 RSS만 단조 증가 → **CPU 연산 문제가 아니라 메모리를 계속 잡고 놓지 않는 문제**

### 2-2. 프로그램 실행 로그 (종료 직전/직후)

```
<!-- TODO: evidence/oom/before-256mb/summary.txt 의 key log lines 에서 MemoryGuard / SELF-TERMINATED 줄 발췌 -->
```

### 2-3. 종료 형태

```
<!-- TODO: summary.txt 의 end_reason (exit code / signal) -->
```

## 3. Root Cause Analysis (원인 분석)

### 현상 → 원인 추론

1. RSS가 일정 간격으로 거의 같은 크기만큼 계단식으로 증가 → 주기적으로 데이터를 할당하고 **해제하지 않는** 패턴 (메모리 누수)
2. 종료 시점의 RSS가 `MEMORY_LIMIT` 값과 일치 → 우연한 크래시가 아니라 **한도 도달 시 의도적으로 동작하는 보호 로직**
3. 앱 로그에 `MemoryGuard ... Memory limit exceeded` → `SELF-TERMINATED` 순서로 출력 → 커널 OOM Killer가 아니라 **애플리케이션 내부 정책에 의한 자체 종료**

### 관련 OS 동작 원리

- **프로세스 메모리 구조**: Code / Data / **Heap** / Stack. 런타임에 동적으로 만든 객체(리스트, 캐시, 버퍼)는 Heap에 쌓인다. Python은 참조가 남아 있는 객체를 GC가 회수하지 않으므로, 전역 리스트·캐시에 계속 append만 하면 누수가 된다.
- **VSZ vs RSS**: VSZ는 예약한 가상 주소 공간 전체, RSS는 실제로 물리 RAM에 올라와 있는 양. 누수는 실제로 페이지를 쓰기 때문에 RSS가 같이 올라간다.
- **누수가 시스템 전체에 주는 영향**: 한 프로세스가 RAM을 계속 먹으면 → 페이지 캐시 축소 → 스왑 발생(있다면) → 모든 프로세스의 디스크 I/O 대기 증가 → 최종적으로 커널 **OOM Killer**가 `oom_score`가 높은 프로세스를 SIGKILL. 이때 엉뚱한 프로세스(DB 등)가 죽을 수도 있다.
- **MemoryGuard의 의미**: 커널 OOM Killer까지 가기 전에 앱이 스스로 한도를 정해두고 먼저 종료 → 다른 프로세스를 지키는 일종의 "안전 퓨즈". 즉 종료 자체는 버그가 아니라 보호 동작이고, **진짜 버그는 누수**다.

## 4. Workaround & Verification (조치 및 검증)

### 조치

```bash
# Before
MEMORY_LIMIT=256 ./scripts/monitor.sh oom before-256mb
# After (상향)
MEMORY_LIMIT=512 ./scripts/monitor.sh oom after-512mb
```

### Before & After

| 항목 | Before (256MB) | After (512MB) |
|---|---|---|
| 생존 시간 | <!-- TODO --> s | <!-- TODO --> s |
| 종료 직전 RSS | <!-- TODO --> MB | <!-- TODO --> MB |
| 종료 사유 | <!-- TODO --> | <!-- TODO --> |
| 누수 속도 (MB/s) | <!-- TODO --> | <!-- TODO --> |

**해석**: 누수 속도는 그대로이고 한도만 늘었기 때문에 생존 시간이 늘어난 것 → **증상을 늦춘 것이지 고친 게 아님**. 누수 속도가 일정하다면 생존 시간 ≈ (MEMORY_LIMIT − 초기 RSS) ÷ 누수 속도로 예측 가능하다. <!-- TODO: 예측값과 실측값 비교 -->

### 근본 해결 제안

- 누적되는 캐시/리스트에 상한(LRU, `maxlen`)이나 TTL 적용, 처리 끝난 데이터는 참조 제거
- `tracemalloc` 등으로 할당 위치를 추적해 누수 지점 특정
- 운영에서는 cgroup 메모리 제한 + RSS 증가율 알람으로 한도 도달 전에 감지
