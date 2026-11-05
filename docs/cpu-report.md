# [Bug] CPU Latency - 특정 프로세스 CPU 과점유로 Watchdog 보호 정책에 의한 종료

> 상태: 🟡 초안 — `<!-- TODO -->` 부분은 실측 데이터로 채움
> 증거 폴더: [`evidence/cpu/`](../evidence/cpu/)

## 1. Description (현상 설명)

- **무엇이**: `agent-leak-app` 실행 중 CPU 사용률이 급상승한 뒤 프로세스가 종료됨
- **언제**: 실행 후 약 <!-- TODO -->초, `CPU_MAX_OCCUPY=<!-- TODO -->` 조건
- **어떻게 관측됐나**: 순간 CPU가 <!-- TODO -->%까지 치솟은 직후 앱 로그에 `WATCHDOG ... SIGTERM` 출력, 프로세스 종료
- **범위**: 시스템 전체 과부하가 아니라 **이 프로세스 하나**의 과점유 (아래 2-1에서 프로세스 CPU vs 시스템 CPU로 구분)

## 2. Evidence & Logs (증거 자료)

### 2-1. 관제 데이터 — 프로세스 CPU vs 시스템 CPU

![CPU Before & After](../evidence/cpu/compare.png)

```
<!-- TODO: evidence/cpu/before-*/monitor.log 에서 평상시 → 급상승 → 종료 직전 구간 발췌 -->
```

- `CPU:` = 이 프로세스의 순간 CPU (`/proc/<pid>/stat` tick 증가량 기준, 코어 1개 = 100%)
- `SYS_CPU:` = 전체 시스템 CPU
- 프로세스 CPU가 급상승한 구간과 SYS_CPU 상승 구간이 겹침 → **시스템 부하의 원인이 이 프로세스**임을 보여줌

### 2-2. top / ps 출력

```
<!-- TODO: 급상승 구간에 다른 터미널에서 찍은 top -b -n 1 결과 (상위 프로세스 목록) -->
```

> ⚠️ `ps -o %cpu`는 프로세스 생애 전체의 **누적 평균**이라 스파이크가 희석된다. metrics.csv의 `cpu_ps_avg_pct`(ps 값)와 `cpu_inst_pct`(순간값)를 비교하면 차이가 보인다. <!-- TODO: 같은 시점 두 값 비교 예시 -->

### 2-3. 종료 로그

```
<!-- TODO: summary.txt key log lines 의 WATCHDOG / SIGTERM 줄 -->
```

종료 형태: <!-- TODO: summary.txt end_reason (exit code 143 = SIGTERM 이면 정상적인 종료 요청 신호) -->

## 3. Root Cause Analysis (원인 분석)

### 현상 → 원인 추론

1. 메모리(RSS)는 평탄한데 CPU만 급상승 → 메모리 문제가 아니라 **연산 루프가 CPU를 놓지 않는** 문제
2. 앱 로그에 Watchdog 경고 후 SIGTERM → 크래시(예외·세그폴트)가 아니라 **임계치 초과 시 의도적으로 종료하는 보호 정책**
3. 종료 코드 <!-- TODO --> → SIGKILL(강제)이 아닌 SIGTERM(정상 종료 요청)으로 정리할 기회를 준 종료

### 관련 OS 동작 원리

- **CPU 스케줄링과 타임 슬라이스**: 리눅스 CFS 스케줄러는 실행 가능한(Runnable, `R`) 태스크들에게 CPU 시간을 나눠준다. I/O나 sleep 없이 계속 계산만 하는 프로세스는 매번 자기 몫을 꽉 채워 쓰고 바로 다시 실행 대기열에 들어간다.
- **과점유가 지연을 만드는 원리**: 코어 수보다 Runnable 태스크가 많아지면 다른 프로세스는 대기열에서 기다리는 시간이 늘어난다 → 웹 요청 응답, SSH 입력 같은 것들이 느려짐(Latency). `load average`가 코어 수를 넘으면 대기 중인 태스크가 있다는 뜻.
- **Watchdog의 의미**: 한 프로세스가 CPU를 일정 비율 이상 계속 점유하면 다른 서비스가 굶는(starvation) 걸 막기 위해 스스로 중단 → 시스템 보호 조치. 종료는 증상 차단이고 진짜 원인은 **과도한 연산 로직**.

## 4. Workaround & Verification (조치 및 검증)

```bash
CPU_MAX_OCCUPY=<!-- TODO: 낮은 값 -->  ./scripts/monitor.sh cpu before-<값>
CPU_MAX_OCCUPY=<!-- TODO: 높은 값 --> ./scripts/monitor.sh cpu after-<값>
```

| 항목 | Before | After |
|---|---|---|
| CPU_MAX_OCCUPY | <!-- TODO --> % | <!-- TODO --> % |
| 최대 순간 CPU | <!-- TODO --> % | <!-- TODO --> % |
| 생존 시간 | <!-- TODO --> s | <!-- TODO --> s |
| 종료 여부 / 사유 | <!-- TODO --> | <!-- TODO --> |

**해석**: <!-- TODO: 임계치를 올리면 Watchdog 발동이 늦어지거나 사라짐. 단, 그만큼 다른 프로세스가 CPU를 못 받는 시간이 늘어나는 트레이드오프 -->

### 근본 해결 제안

- 무거운 연산을 작은 단위로 나누고 사이에 양보(sleep/yield) 넣기, 또는 작업 큐로 분리
- `nice`/`renice`로 우선순위 낮추기, cgroup `cpu.max`로 상한 걸기 (앱 대신 OS가 제한)
- 불필요한 busy-wait(바쁜 대기) 루프를 이벤트/조건변수 기반 대기로 교체
