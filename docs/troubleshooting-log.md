# Troubleshooting Log

미션을 진행하며 실행한 것, 막힌 것, 판단을 바꾼 지점을 시간 순으로 남긴다. 수치는 각 실행의 `summary.txt`에서 옮겼다.

## 실행 환경

| 항목 | 값 |
|---|---|
| 호스트 | macOS (클러스터 공용 맥) + OrbStack |
| 컨테이너 | `ubuntu:22.04`, `--platform linux/amd64` |
| 커널 | `Linux 7.0.14-orbstack-00380-ga7e0a2dc9535 x86_64` |
| CPU 코어 / 메모리 | 6 core / 16GB (스왑 17GB) |
| 실행 계정 | `agent` (uid 1000, root 아님) |
| 설치한 패키지 | `psmisc`(pstree) — `procps`(ps, top)는 기본 포함 |

## 실행 기록 (2026-11-05, 컨테이너 시각 UTC)

| 시작 | 현재 폴더 (실행 당시 label) | MEM / CPU / MT | 앱이 고른 시나리오 | 생존 | 종료 사유 |
|---|---|---|---|---|---|
| 09:10:36 | `oom/before-256mb` | 256 / 50 / true | 메모리 누수 | 33.6s | SIGKILL (137), MemoryGuard |
| 09:19:40 | `deadlock/before-mt-true` (`oom/after-512mb`) | 512 / 50 / true | 데드락 | 100.2s | HUNG, 로그 정지 91초 후 관제가 종료 |
| 09:24:35 | `cpu/after-30` (`cpu/before-30`) | 512 / 30 / false | Healthy | 900.4s | 타임아웃까지 생존 |
| 09:40:17 | `cpu/before-100` (`cpu/after-100`) | 512 / 100 / false | CPU 과점유 | 33.6s | SIGTERM (143), Load 52.33% |
| 09:41:22 | `cpu/repeat-100-mt-true` (`deadlock/before-mt-true`) | 512 / 100 / true | CPU 과점유 | 33.6s | SIGTERM (143), Load 54.23% |
| 09:43:55 | `cpu/repeat-100-mt-false` (`deadlock/after-mt-false`) | 512 / 100 / false | CPU 과점유 | 36.8s | SIGTERM (143), Load 50.3% |
| 10:28:42 | `oom/before-256mb-mtoff` | 256 / 50 / false | 메모리 누수 | 33.6s | SIGKILL (137), MemoryGuard — 첫 실행과 동일 |
| 10:37:02 | `deadlock/after-mt-false` | 512 / 50 / false | Healthy | 601.2s | 타임아웃까지 생존, 무응답 0회, Load 50.00%에서 cooldown 10회 |

## 막혔던 점 / 해결

| 증상 | 원인 | 해결 |
|---|---|---|
| 기존 `monitor.sh`가 모든 케이스 로그를 `evidence/oom/`에 덮어씀 | 출력 경로 하드코딩 | `<case>/<label>` 인자로 분리 |
| `ps %CPU`가 실제보다 낮고 계속 떨어지기만 함 | `ps`는 프로세스 시작 이후 **누적 평균** | `/proc/<pid>/stat`의 utime+stime 증가량으로 순간 CPU 직접 계산 |
| 맥 터미널에서 `monitor.sh` 실행 시 `bad substitution` | 맥 기본 bash 3.2 + `/proc` 없음. 스크립트는 리눅스 전용 | 컨테이너 안에서만 실행 |
| `docker run` 시 `docker.sock` 연결 실패 | OrbStack 앱이 꺼져 있었음 | `open -a OrbStack` 후 `docker context use orbstack` |
| `su - agent` 후 프롬프트가 `$`, 화살표 키 안 됨 | `useradd` 기본 셸이 `/bin/sh` | `bash` 실행 (또는 `su - agent -s /bin/bash`) |
| 6번 실행 중 3번이 의도와 다른 장애를 재현 | 앱이 부팅 시 환경변수 우선순위(메모리 > CPU > 스레드)로 **시나리오 하나만** 선택 | 관찰 대상보다 우선순위 높은 장애를 정상값으로 고정하도록 재설계, 기존 결과는 실제 재현된 장애 기준으로 폴더 재분류 ([evidence/README.md](../evidence/README.md)) |
| CPU Before/After 결과가 예상과 반대 (30이 생존, 100이 종료) | `CPU_MAX_OCCUPY`는 Watchdog 기준이 아니라 작업이 스스로 멈추는 상한. Watchdog은 약 50%로 고정 | 로그의 `Recommend Under 50%`, `Peak reached → cooldown`으로 의미를 확인하고 Before=100, After=30으로 정정 |
| `metrics.csv` 뒤쪽 컬럼이 한 칸씩 밀림 | 앱이 PID 2개(PyInstaller 부모/자식)로 떠서 `2099,2105`의 쉼표가 CSV 구분자와 충돌 | PID 구분자를 `;`로 변경, 기존 CSV는 컬럼 수 기준으로 복구 (값은 그대로) |
| CPU 장애인데 OS가 잰 CPU는 2% 미만, 살아남은 실행이 오히려 더 높음 | Watchdog이 OS 측정값이 아니라 **앱 내부 Load 지표**로 판단 | 리포트에 앱 지표와 OS 측정값을 나란히 기록하고 차이를 명시 |
| 데드락 중 RSS가 72초 시점에 19.6 → 12.5MB로 한 번 감소 | 같은 시점 `top`의 SHR이 9.4 → 2.2MB로 감소 — 커널이 쓰이지 않는 공유 라이브러리 페이지를 RAM에서 내림 | 앱 활동이 아님을 확인, "정체" 판단 유지 |
| 재실행 시 `이미 존재하는 결과 폴더` 에러 | ① 맥에서 `git pull` 전이라 옛 폴더가 남아 있었음 ② pull 후에도 **빈 `snapshots/` 폴더**가 남음 — git은 빈 폴더를 추적하지 않아 이동·삭제하지 못함 | `git pull` 후 `ls -a`로 남은 게 빈 폴더뿐인지 확인하고 `rm -rf` |
