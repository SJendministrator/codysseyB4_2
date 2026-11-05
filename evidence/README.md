# evidence — 실행별 증거 자료

각 폴더는 `scripts/monitor.sh` 한 번 실행의 결과입니다. 파일 구성은 [루트 README §3](../README.md#3-폴더-구조) 참고.

## 폴더 ↔ 실행 조건

| 폴더 | MEMORY_LIMIT | CPU_MAX_OCCUPY | MULTI_THREAD | 앱이 고른 시나리오 | 결과 | 쓰이는 곳 |
|---|---|---|---|---|---|---|
| `oom/before-256mb-mtoff` | 256 | 50 | false | 메모리 누수 | 33.6초, SIGKILL(137) | **OOM Before** |
| `oom/before-256mb` | 256 | 50 | true | 메모리 누수 | 33.6초, SIGKILL(137) | OOM 재현 2 |
| `cpu/before-100` | 512 | 100 | false | CPU 과점유 | 33.6초, SIGTERM(143) | CPU Before |
| `cpu/repeat-100-mt-true` | 512 | 100 | true | CPU 과점유 | 33.6초, SIGTERM(143) | CPU 재현 2 |
| `cpu/repeat-100-mt-false` | 512 | 100 | false | CPU 과점유 | 36.8초, SIGTERM(143) | CPU 재현 3 |
| `cpu/after-30` | 512 | 30 | false | Healthy | 900초 생존(타임아웃) | **CPU After**, 스케줄링 표본 1 |
| `deadlock/before-mt-true` | 512 | 50 | true | 데드락 | 로그 정지 → 91초 무응답, 관제가 종료 | **Deadlock Before** |
| `deadlock/after-mt-false` | 512 | 50 | false | Healthy | 600초 생존(타임아웃), 무응답 0회 | **Deadlock After**, **OOM After**, CPU 경계값(50%), 스케줄링 표본 2 |

**변수 하나만 다른 비교 쌍**

| 비교 | Before | After | 달라진 변수 |
|---|---|---|---|
| OOM | `oom/before-256mb-mtoff` | `deadlock/after-mt-false` | `MEMORY_LIMIT` 256 → 512 |
| CPU | `cpu/before-100` | `cpu/after-30` | `CPU_MAX_OCCUPY` 100 → 30 |
| Deadlock | `deadlock/before-mt-true` | `deadlock/after-mt-false` | `MULTI_THREAD_ENABLE` true → false |

## 폴더 이름이 실행 당시 label과 다른 이유

아래 5개 폴더가 해당합니다. 처음 6번 실행은 "세 장애가 한 프로세스에서 동시에 일어난다"는 가정으로 설계했는데, 실행해보니 앱이 **부팅 시 환경변수 우선순위(메모리 > CPU > 스레드)로 시나리오를 하나만 고른다**는 것이 드러났습니다. 그래서 의도한 장애와 실제로 재현된 장애가 다른 실행이 생겼고, 분석 후 **실제로 재현된 장애 기준으로 폴더를 재분류**했습니다.

증거 원본은 수정하지 않았기 때문에 각 폴더의 `summary.txt` · `monitor.log`에 적힌 `label`은 실행 당시 이름 그대로입니다.

| 현재 폴더 | 실행 당시 label |
|---|---|
| `deadlock/before-mt-true` | `oom/after-512mb` |
| `cpu/before-100` | `cpu/after-100` |
| `cpu/after-30` | `cpu/before-30` |
| `cpu/repeat-100-mt-true` | `deadlock/before-mt-true` |
| `cpu/repeat-100-mt-false` | `deadlock/after-mt-false` (지금의 `deadlock/after-mt-false`는 이후 새로 실행한 별개 실행) |

### 원본에서 바꾼 것 (1건)

처음 6번 실행의 `metrics.csv` `pids` 컬럼: 앱이 PID 2개로 떠서 `279,285`처럼 쉼표가 들어가 이후 컬럼이 한 칸씩 밀렸습니다. 쉼표를 `;`로 바꿔 컬럼을 복구했고 **값 자체는 바꾸지 않았습니다** (`monitor.sh`도 같은 방식으로 수정).
