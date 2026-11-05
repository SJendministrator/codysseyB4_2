# Troubleshooting Log

실행할 때마다 한 줄씩 기록. 수치는 각 실행의 `evidence/<case>/<label>/summary.txt`에서 옮긴다.

## 실행 환경

| 항목 | 값 |
|---|---|
| OS / 커널 | <!-- TODO: uname -a --> |
| 실행 방식 | <!-- TODO: Docker 이미지 이름 or 로컬 --> |
| CPU 코어 / 메모리 | <!-- TODO: nproc / free -h --> |
| 실행 계정 | <!-- TODO: 일반 사용자 이름 --> |

## 실행 기록

| 일시 | case | label | 설정 | 생존(s) | 종료 사유 | 비고 |
|---|---|---|---|---|---|---|
| | oom | before-256mb | MEMORY_LIMIT=256 | | | |
| | oom | after-512mb | MEMORY_LIMIT=512 | | | |
| | cpu | before-? | CPU_MAX_OCCUPY=? | | | |
| | cpu | after-? | CPU_MAX_OCCUPY=? | | | |
| | deadlock | before-mt-true | MULTI_THREAD_ENABLE=true | | | |
| | deadlock | after-mt-false | MULTI_THREAD_ENABLE=false | | | |

## 막혔던 점 / 해결

| 증상 | 원인 | 해결 |
|---|---|---|
| `ps` %CPU가 실제 체감보다 낮게 나옴 | `ps`는 프로세스 시작 이후 누적 평균 | `/proc/<pid>/stat` tick 증가량으로 순간 CPU 계산 (`monitor.sh`) |
| 증거 로그가 git에 안 올라감 | `.gitignore`에 `*.log`가 있었음 | `agent_home/`만 제외하도록 수정 |
| 이전 `monitor.sh`가 모든 케이스 로그를 `evidence/oom/`에 덮어씀 | 출력 경로 하드코딩 | `<case>/<label>` 인자로 분리 |
| | | |
