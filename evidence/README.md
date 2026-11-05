# evidence — 실행별 증거 자료

각 폴더는 `scripts/monitor.sh` 한 번 실행의 결과입니다. 파일 구성은 [루트 README §3](../README.md#3-폴더-구조) 참고.

## 폴더 ↔ 실행 조건

| 폴더 | MEMORY_LIMIT | CPU_MAX_OCCUPY | MULTI_THREAD | 앱이 고른 시나리오 | 결과 | 쓰이는 곳 |
|---|---|---|---|---|---|---|
| `oom/before-256mb` | 256 | 50 | true | 메모리 누수 | 33.6초, SIGKILL(137) | OOM Before |
| `cpu/before-100` | 512 | 100 | false | CPU 과점유 | 33.6초, SIGTERM(143) | CPU Before |
| `cpu/repeat-100-mt-true` | 512 | 100 | true | CPU 과점유 | 33.6초, SIGTERM(143) | CPU 재현 2 |
| `cpu/repeat-100-mt-false` | 512 | 100 | false | CPU 과점유 | 36.8초, SIGTERM(143) | CPU 재현 3 |
| `cpu/after-30` | 512 | 30 | false | Healthy | 900초 생존(타임아웃) | CPU After, OOM After(임시), 스케줄링 |
| `deadlock/before-mt-true` | 512 | 50 | true | 데드락 | 로그 정지 → 90초 무응답, 관제가 종료 | Deadlock Before |

## 폴더 이름이 실행 당시 label과 다른 이유

처음 6번 실행은 "세 장애가 한 프로세스에서 동시에 일어난다"는 가정으로 설계했는데, 실행해보니 앱이 **부팅 시 환경변수 우선순위(메모리 > CPU > 스레드)로 시나리오를 하나만 고른다**는 것이 드러났습니다. 그래서 의도한 장애와 실제로 재현된 장애가 다른 실행이 생겼고, 분석 후 **실제로 재현된 장애 기준으로 폴더를 재분류**했습니다.

증거 원본은 수정하지 않았기 때문에 각 폴더의 `summary.txt` · `monitor.log`에 적힌 `label`은 실행 당시 이름 그대로입니다.

| 현재 폴더 | 실행 당시 label |
|---|---|
| `deadlock/before-mt-true` | `oom/after-512mb` |
| `cpu/before-100` | `cpu/after-100` |
| `cpu/after-30` | `cpu/before-30` |
| `cpu/repeat-100-mt-true` | `deadlock/before-mt-true` |
| `cpu/repeat-100-mt-false` | `deadlock/after-mt-false` |

### 원본에서 바꾼 것 (1건)

`metrics.csv`의 `pids` 컬럼: 앱이 PID 2개로 떠서 `279,285`처럼 쉼표가 들어가 이후 컬럼이 한 칸씩 밀렸습니다. 쉼표를 `;`로 바꿔 컬럼을 복구했고 **값 자체는 바꾸지 않았습니다** (`monitor.sh`도 같은 방식으로 수정).

## 추가 실행 예정

| 폴더 | 조건 | 목적 |
|---|---|---|
| `oom/before-256mb-mtoff` | 256 / 50 / false | OOM Before를 After와 **메모리 한도만** 다르게 맞추기 |
| `deadlock/after-mt-false` | 512 / 50 / false | Deadlock After (Before와 스레드 설정만 다름) + OOM After |
