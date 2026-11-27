# 4-1: Linux 시스템 관제 자동화

첨부 과제의 보안·계정·권한·앱 실행·시스템 관제·cron 요구사항을 구현한 Bash 프로젝트다. 보너스인 통계 리포트와 시간 기반 로그 보존도 포함한다. 원본은 [4-1.pdf](4-1.pdf), 제출용 수행 내역서는 [docs/수행내역서.md](docs/수행내역서.md)다.

**검증 상태:** Ubuntu 26.04.1 LTS / WSL2의 일반 사용자로 격리 검증 19개를 통과했다. 호스트의 계정·SSH·방화벽·crontab은 변경하지 않았다. 원본 `agent-app.zip`은 제공되지 않아 `app/agent_app.py`라는 검증용 대체 앱으로 테스트했다. 원본 앱과 실제 서버 설정의 검증은 전용 실습 VM에서 아래 설치 및 증거 수집을 완료해야 한다.

## 파일 구성

| 파일 | 역할 |
| --- | --- |
| `bin/monitor.sh` | 프로세스·포트 소유권, 방화벽, 시스템 자원, 임계값, 로그 회전 |
| `bin/report.sh` | 현재 `monitor.log`의 CPU/MEM/DISK 평균·최대·최소·시각·샘플 수 |
| `bin/archive.sh` | 7일 지난 비활성 로그 압축·이동, 30일 지난 아카이브 삭제 |
| `bin/run-app.sh` | 일반 사용자로 원본 Python 앱 또는 Linux 실행 파일 실행 |
| `scripts/install.sh` | 의존 도구·계정·그룹·ACL·환경변수·systemd·cron 설치 |
| `scripts/configure-security.sh` | 전용 VM의 SSH 20022, root 원격 로그인 차단, UFW 구성 |
| `scripts/collect-evidence.sh` | 실제 배포 설정·접근 권한·부트·자동 cron 실행을 검증하고 기록 |
| `scripts/validate.sh`, `tests/run.sh` | 일반 사용자 격리 테스트 및 검증 기록 저장 |
| `config/` | 환경변수와 일반 사용자 앱 서비스 설정 |
| `app/agent_app.py` | 원본이 없는 상태에서 사용하는 명시적 검증용 대체 앱 |
| `evidence/local-validation.log` | 이 작업에서 실제 실행한 격리 검증 원문 |

## 일반 사용자 검증

Linux에서 프로젝트 루트로 이동한 후 `bash scripts/validate.sh`를 실행한다. Windows에서는 `wsl -d Ubuntu --cd /mnt/d/Codissey/4-1 -- bash scripts/validate.sh`로 실행할 수 있다.

필요 도구는 Bash 4.4+, Python 3.10+, `ss`, `pgrep`, `flock`, GNU coreutils·awk·find·gzip이다. 테스트는 TCP 15034가 이미 사용 중이면 중단하며 기존 프로세스를 종료하지 않는다. 임시 파일은 `.test-runtime/`에 보존한다. 실행 중인 테스트 앱은 종료 시 정리한다. 결과는 `evidence/local-validation.log`에 기록된다.

검증용 앱은 부트 검사 5개를 통과하면 `Agent READY`를 출력하고 `0.0.0.0:15034`에서 간단한 상태 응답을 제공한다. 이 결과를 원본 앱의 실행 증거로 제출해서는 안 된다.

## Mac에서 실행하기

Mac에서는 UTM 안에 Ubuntu 가상머신을 만들고 그 안에서 실행한다. 이 프로젝트는 Linux의 `/proc`, systemd, UFW를 사용하므로 Ubuntu 환경이 필요하다. Mac의 Ubuntu VM에서 실제 실행한 검증 결과는 아직 없으며, 기존 19개 통과 기록은 Windows의 WSL 환경에서 얻은 것이다.

### 1. UTM 및 Ubuntu 준비

[UTM 공식 사이트](https://mac.getutm.app/)에서 Mac용 UTM을 설치하고, Mac 종류에 맞는 Ubuntu 22.04 Server ISO를 받는다.

| Mac 종류 | Ubuntu 설치 파일 | 원본 앱 사용 시 |
| --- | --- | --- |
| Apple Silicon(M1·M2 등) | [ARM64 다운로드](https://cdimage.ubuntu.com/releases/22.04/release/)의 `live-server-arm64.iso` | ARM64용 Linux 앱 |
| Intel Mac | [AMD64 다운로드](https://releases.ubuntu.com/22.04/)의 `live-server-amd64.iso` | x86-64용 Linux 앱 |

UTM에서 `＋ → Virtualize → Linux`를 선택하고 ISO를 지정한다. 실습용 자원 설정 예시는 CPU 2개, 메모리 4GB, 디스크 25GB다. Ubuntu 설치 과정에서 `student`처럼 프로젝트 계정과 다른 일반 사용자 계정을 만든다. 설치 후 재부팅하고 해당 계정으로 로그인한다. 설치 화면으로 다시 돌아오면 UTM에서 설치 ISO를 분리한다. 자세한 화면 순서는 [UTM 공식 Ubuntu 설치 안내](https://docs.getutm.app/guides/ubuntu/)를 참고한다.

이후 명령은 모두 **UTM 창 안의 Ubuntu 콘솔**에서 실행한다. 프로젝트는 Ubuntu의 홈 디렉터리에 내려받으며 Mac 공유 폴더에서 실행하지 않는다. Ubuntu Server는 기본적으로 그래픽 데스크톱 없이 콘솔로 사용할 수 있다.

### 2. 프로젝트 다운로드 및 격리 테스트

새 Ubuntu VM의 일반 사용자 셸에서 아래 함수를 정의하고 실행한다. 의존 도구 설치, 저장소 다운로드, 프로젝트 테스트를 순서대로 수행하며 앞 단계가 실패하면 다음 단계로 진행하지 않는다.

```bash
_prepare_agent_lab() {
    sudo apt-get update &&
    sudo apt-get install -y git python3 procps iproute2 util-linux gawk gzip coreutils findutils &&
    git clone https://github.com/book732/4-1.git "$HOME/4-1" &&
    cd "$HOME/4-1" &&
    bash scripts/validate.sh
}

_prepare_agent_lab
```

정상 완료 기준은 `RESULT: 19 checks passed`다. 결과는 `~/4-1/evidence/local-validation.log`에 저장된다. 이 단계는 임시 경로의 대체 앱을 검증하며, 실제 계정·SSH·방화벽·cron 설정은 적용하지 않는다. 테스트는 일반 사용자로 실행해야 하므로 `validate.sh` 전체에 sudo를 붙이지 않는다. 이미 `~/4-1`을 내려받았다면 다시 clone하지 않고 해당 폴더에서 `bash scripts/validate.sh`를 실행한다.

### 3. 대체 앱으로 전체 실습 환경 설치

아래 함수는 계정·권한·앱·cron 설치, SSH·UFW 설정, 실제 배포 증거 수집을 순서대로 수행한다. **전용 실습 VM의 UTM 콘솔에서 실행한다.** SSH 포트를 20022로 바꾸므로 이 단계는 SSH 원격 세션에서 진행하지 않는다.

```bash
_deploy_agent_lab() {
    cd "$HOME/4-1" &&
    sudo bash scripts/install.sh --demo &&
    sudo bash scripts/configure-security.sh --dedicated-lab &&
    sudo bash scripts/collect-evidence.sh \
        "$HOME/4-1/evidence/deployment-evidence.txt"
}

_deploy_agent_lab
```

마지막 단계는 cron이 새 로그를 기록하는지 확인하므로 최대 약 78초 동안 기다린다. 이때 다른 터미널에서 수동 관제를 실행하지 않는다. 정상 완료 기준은 `ALL DEPLOYMENT CHECKS PASSED`이며 증거는 `~/4-1/evidence/deployment-evidence.txt`에 저장된다. 이 파일은 sudo 권한으로 생성되므로 필요하면 `sudo less "$HOME/4-1/evidence/deployment-evidence.txt"`로 읽는다. 단계가 실패하면 해당 오류를 확인하며 성공 증거로 간주하지 않는다.

`--demo`는 저장소에 포함된 Python 대체 앱을 설치한다. 원본 앱으로 최종 검증하려면 Mac 아키텍처에 맞는 원본 Linux 앱을 준비하고, 아래 전용 VM 설치 절차의 `--app` 방식으로 설치한 뒤 증거를 다시 수집한다. `agent-admin`의 SSH 인증키 등록은 별도 작업이며, 위 절차는 UTM 콘솔만으로 완료할 수 있다.

## 전용 Ubuntu 실습 VM 설치

Ubuntu 22.04 LTS 이상, systemd로 부팅한 전용 VM을 사용한다. 이 프로젝트를 VM에 복사하고 **VM 콘솔에서** 진행한다. 일반 컨테이너와 Windows 파일시스템 경로는 최종 계정·ACL·방화벽 검증 대상으로 적합하지 않다.

1. 원본 패키지를 별도로 풀어 아키텍처에 맞는 실행 파일을 준비한다. 예를 들어 `sudo bash scripts/install.sh --app /absolute/path/agent-app-linux-x86`로 설치한다. Python 원본이면 해당 `.py` 파일의 절대 경로를 전달한다. 부속 파일이 필요한 원본 패키지는 앱 요구사항에 따라 함께 배치해야 한다. 대체 앱만 검증하려면 `sudo bash scripts/install.sh --demo`를 사용한다.
2. `sudo bash scripts/configure-security.sh --dedicated-lab`을 실행한다. 기존 UFW에 이 과제 이외의 사용자 규칙이 있으면 삭제하지 않고 중단한다. 충돌하는 SSH 설정도 유효 설정 검사 후 중단한다. SSH socket activation은 비활성화하고 `ssh.service`를 사용한다.
3. `sudo bash scripts/collect-evidence.sh /absolute/path/deployment-evidence.txt`로 실제 설정과 동작을 확인한다. 수동 관제 1회 후 최대 78초 동안 기다려 cron만으로 새 로그가 추가되는지 확인한다. 이때 다른 터미널에서 수동 관제를 실행하지 않는다. 최종 `ALL DEPLOYMENT CHECKS PASSED`와 증거 파일을 확인한다.

설치 계정은 `agent-admin`, `agent-dev`, `agent-test`다. 새 계정의 암호는 잠겨 있으므로 SSH 접속이 필요하면 콘솔에서 `agent-admin`의 공개키를 별도로 등록한다. 계정에 전체 sudo 권한을 부여하지 않는다. `agent-admin`에는 방화벽 상태를 읽는 `/usr/sbin/ufw status`만 암호 없는 sudo로 허용한다.

설치된 환경변수는 `/etc/agent-app.env`에 있다. 수동 실행은 `agent-admin` 셸에서 이 파일을 `source`한 다음 `/opt/agent-app/bin/monitor.sh`를 실행한다. `report.sh`는 선택적으로 `"YYYY-MM-DD HH:MM:SS"` 형식의 시작·종료 시각을 인수로 받으며 양쪽 경계 시각을 포함한다. `archive.sh`는 매일 03:15, `monitor.sh`는 매분 `agent-admin`의 crontab에서 실행한다. cron의 콘솔 출력은 `logger`를 거쳐 시스템 로그로 보낸다.

## 코드 동작과 운영 기준

`monitor.sh`의 `_find_pid()`는 같은 사용자 프로세스의 전체 명령 인수를 비교한다. `_health_check()`는 일치하는 후보 중 실제 15034 리스너를 가진 PID를 선택하므로 런처와 작업 프로세스가 같은 이름을 쓰는 앱도 처리한다. 관리 계정으로 실행한 앱을 동일한 `agent-admin` 계정이 관제하는 구성이며, 다른 사용자의 앱이나 PID 정보가 숨겨진 환경은 정상으로 간주하지 않는다.

`_collect_resources()`는 전체 시스템 CPU tick을 1초 간격으로 읽는다. user·nice에 이미 포함된 guest 값을 중복 합산하지 않으며, idle+iowait을 유휴 시간으로 계산한다. 메모리는 `(MemTotal-MemAvailable)/MemTotal`, 디스크는 `df -P /`의 사용률이다. CPU는 전체 코어 평균이며 특정 앱의 CPU 사용률과 구분한다. CPU>20%, MEM>10%, DISK>80%일 때만 경고한다. 방화벽 조회 실패도 비활성과 구별해 경고하며, 정상적인 상태 수집은 계속한다.

`_append_log()`는 flock 잠금 아래에서 **추가할 행의 길이를 포함해** 10MiB 초과 여부를 판단한다. 현재 `monitor.log`와 `.1`~`.9`를 합쳐 최대 10개, 각 파일은 최대 10MiB다. 이는 PDF의 10MB를 10×1024×1024바이트로 해석한 것이다. 디렉터리 권한은 전용 그룹과 기본 ACL로 제한한다. 프로세스·포트 실패는 종료 코드 1이며 성공한 자원 로그를 남기지 않는다. 실행이 겹치면 뒤 실행은 종료 코드 0으로 건너뛴다.

`report.sh`는 단일 awk 순회로 현재 로그의 통계를 계산한다. 회전된 파일과 압축 파일은 기본 집계 범위에 포함하지 않는다. `archive.sh`는 같은 잠금을 사용하며 7일 지난 일반 `.log` 및 회전 로그를 압축해 `/var/log/monitor/agent-app/archive/`로 옮긴다. 활성 `monitor.log`와 `boot.log`는 제외한다. 아카이브 생성 시각에서 30일이 지나면 삭제한다. 압축 결과를 임시 파일에 완성한 뒤 이름을 바꾸고 원본을 삭제한다.

systemd는 앱을 `agent-admin:agent-core`로 실행하고 파일시스템 쓰기를 업로드·로그 디렉터리로 제한한다. 서비스 재시작 정책은 비정상 종료 시 3초 간격이다. 이 서비스 구성은 원본 앱이 과제에 명시된 디렉터리만 사용하는 것을 전제로 한다.
