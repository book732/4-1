# systemd 앱 관제의 포트 소유권 오류 수정

2026-11-27 전달받은 실행 화면에는 부트 검사 5개 [OK]와 `Agent READY`가 있었지만 설치 검증은 `TCP 15034 is not owned by application PID ...`로 실패했다. 화면만으로 포트 충돌이나 앱 종료를 확정하지 않고 실제 서비스 설정으로 재현했다.

## 원인과 변경

기존 서비스는 `User=agent-admin`, `Group=agent-core`로 실행했다. 관제와 cron은 agent-admin의 기본 그룹으로 실행한다. Linux의 `/proc/PID/fd` 접근 검사는 UID뿐 아니라 GID도 비교하므로 두 실행의 기본 GID가 다르면 같은 UID여도 소켓 파일 디스크립터 조회가 거부될 수 있다. 일반 사용자 `ss -p`에서 소유 PID가 누락되면 기존 관제는 포트 소유권을 확인하지 못해 종료 코드 1을 반환한다.

근거는 [proc_pid_fd(5)](https://man7.org/linux/man-pages/man5/proc_pid_fd.5.html)의 PTRACE_MODE_READ_FSCREDS 접근 검사와 [ptrace(2)](https://man7.org/linux/man-pages/man2/ptrace.2.html)의 UID/GID 일치 조건이다.

서비스의 `Group=agent-core`를 제거해 User 계정의 기본 그룹을 사용하고 `agent-core`는 보조 그룹에 명시했다. 기존 `agent-common` 보조 그룹, 파일 권한, 포트 소유권 검사, systemd 격리 설정은 유지한다. 관제를 root로 바꾸거나 추가 sudo 권한을 부여하지 않는다.

## 재현 및 검증 범위

`tests/systemd.sh`는 root로 기존 비root 사용자 1명을 인수로 받아 실제 서비스 설정의 계정·경로·실행 명령만 테스트용으로 치환한다. 수정 전 설정의 Group은 테스트 사용자의 기존 보조 그룹에 대응시켜 앱과 관제의 기본 GID 차이를 재현한다. 수정 후에는 서비스의 기본 그룹이 사용자 기본 그룹과 같아지는지 실제 PID와 관제 결과로 확인한다.

테스트는 WSL Ubuntu의 systemd에서 수행한다. 임시 유닛은 `/run/systemd/system/`에 생성해 실행 후 제거하며 프로젝트 계정·SSH·방화벽·cron은 설치하거나 변경하지 않는다. 이는 전체 설치 스크립트를 적용한 최종 배포 검증이나 Mac에서의 실측을 대신하지 않는다.

수정 전 결과는 [systemd-before-fix.log](../evidence/systemd-before-fix.log), 수정 후 결과는 [systemd-after-fix.log](../evidence/systemd-after-fix.log)에 보존한다. 수정 전에는 root의 ss 조회에 앱 PID가 보이고 같은 UID의 일반 사용자 조회에는 PID가 없었으며 관제가 종료 코드 1을 반환했다. 수정 후에는 일반 사용자 조회에 실제 앱 PID가 표시되고 관제가 로그를 기록해야 통과한다.

실측에서 앱 UID는 수정 전후 모두 1000이었다. 앱 기본 GID는 수정 전 4, 수정 후 1000이었고 관제 사용자의 기본 GID는 1000이었다. 수정 후 실제 앱 PID 630을 일반 사용자 ss와 관제가 모두 확인하고 종료 코드 0으로 로그를 기록했다. 기존 일반 사용자 테스트 19개도 재실행해 모두 통과했으며 결과는 [service-fix-validation.log](../evidence/service-fix-validation.log)에 보존한다.

## 기존 설치 복구

프로젝트에서 최신 main을 받고 설치 시 사용했던 앱 인수로 `scripts/install.sh`를 다시 실행한다. 설치기가 서비스 파일을 갱신하고 daemon-reload·재시작·관제 검증을 수행한다. 대체 앱은 `--demo`, 원본 앱은 기존 `--app /절대/경로`를 사용한다. 앱 데이터와 관련 없는 별도 파일을 삭제할 필요는 없다.
