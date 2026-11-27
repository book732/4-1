# 4-1: Linux 시스템 관제 자동화

첨부 과제의 보안·계정·권한·앱 실행·시스템 관제·cron 요구사항을 구현한 Bash 프로젝트다. 보너스인 통계 리포트와 시간 기반 로그 보존도 포함한다. 원본은 [4-1.pdf](4-1.pdf), 제출용 수행 내역서는 [docs/수행내역서.md](docs/수행내역서.md)다.

**검증 상태:** Ubuntu 26.04.1 LTS / WSL2의 일반 사용자로 격리 검증 19개를 통과했다. 추가로 제공된 `agent-app.zip`의 x86 원본 앱을 일반 사용자로 기동해 부트 5단계·READY·포트 소유권·관제를 확인했다. 원본 실행 파일은 PDF와 키 경로·파일명이 달라 호환 처리를 포함했다. 실제 Mac 배포 환경에서의 원본 앱 최종 검증은 아래 절차로 별도 수행해야 한다.

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
| `tests/systemd.sh` | 기존 일반 사용자로 실제 systemd 서비스의 포트 PID 조회 회귀 검증 |
| `tests/access.sh` | 실제 보조 그룹 쓰기와 접근 검사 결과를 비교하는 회귀 검증 |
| `tests/original.sh` | 제공된 원본 실행 파일의 부트·실행기·관제 호환성 검증 |
| `config/` | 환경변수와 일반 사용자 앱 서비스 설정 |
| `app/agent_app.py` | 원본이 없는 상태에서 사용하는 명시적 검증용 대체 앱 |
| `evidence/local-validation.log` | 이 작업에서 실제 실행한 격리 검증 원문 |
| `evidence/systemd-*.log` | 기본 그룹 불일치 오류의 systemd 재현 및 수정 후 검증 |

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

<a id="configure-agent-security"></a>

### 4. SSH·방화벽 설정을 따로 실행하기

앱 설치에서 `Installation complete`가 나왔고 `[WARNING] UFW inactive`가 보인다면 앱 설치는 끝났지만 방화벽은 아직 비활성 상태다. 설치를 반복하지 않고 아래 보안 설정부터 진행한다. 위 `_deploy_agent_lab()` 함수로 증거 수집까지 모두 완료했다면 4·5단계를 추가로 실행할 필요는 없다.

**실습용 Ubuntu의 콘솔에서** 아래 전체를 복사해 붙여넣고 실행한다. SSH 원격 접속 중이면 VM 콘솔로 전환한다. sudo가 암호를 요구하면 Ubuntu 로그인 계정의 암호를 입력하며, 입력 중 문자가 표시되지 않는 것은 정상이다.

```bash
_configure_agent_security() {
    cd "$HOME/4-1" &&
    sudo bash scripts/configure-security.sh --dedicated-lab
}

_configure_agent_security
```

이 함수는 프로젝트 폴더로 이동해 보안 설정 스크립트를 실행한다. SSH 포트를 TCP 20022로 변경하고 root 원격 로그인을 차단한다. UFW를 활성화하며 기본 수신 정책은 거부, 허용 TCP 포트는 20022·15034로 구성한다.

출력에 `Status: active`와 마지막 안내 `SSH:20022, PermitRootLogin:no, UFW:deny incoming with TCP 20022/15034 allowed.`가 보이면 완료다. 기존 UFW 규칙이나 SSH 설정 충돌로 `[ERROR]`가 나오면 오류 내용을 확인하고 이 단계에서 중단한다.

### 5. 최종 증거 수집

보안 설정을 완료한 뒤 같은 Ubuntu 콘솔에서 아래 함수를 실행한다. 실제 계정·권한·앱 부트·방화벽·cron 자동 실행을 검사하고 결과를 파일로 저장한다.

```bash
_collect_agent_evidence() {
    cd "$HOME/4-1" &&
    sudo bash scripts/collect-evidence.sh \
        "$HOME/4-1/evidence/deployment-evidence.txt"
}

_collect_agent_evidence
```

cron 검증을 위해 최대 약 78초 동안 기다린다. 기다리는 동안 다른 터미널에서 수동 관제를 실행하지 않는다. 마지막에 `ALL DEPLOYMENT CHECKS PASSED`가 나오면 완료이며, 증거 파일은 `~/4-1/evidence/deployment-evidence.txt`다. 읽을 때는 `sudo less "$HOME/4-1/evidence/deployment-evidence.txt"`를 사용하고 `q`로 나간다. 이 증거는 현재 설치한 앱을 대상으로 하므로 `--demo`로 설치했다면 대체 앱의 검증 결과다.

<a id="show-agent-result"></a>

### 6. 검증 성공 후 결과 확인 및 제출 자료 정리

`ALL DEPLOYMENT CHECKS PASSED`를 확인한 뒤 아래 전체를 Ubuntu 콘솔에 붙여넣어 실행한다. 저장된 증거 파일을 화면에 출력하므로 내용을 복사할 수 있다.

```bash
_show_agent_result() {
    sudo cat "$HOME/4-1/evidence/deployment-evidence.txt"
}

_show_agent_result
```

이 함수는 증거 파일을 읽어 출력한다. 출력 전체를 복사하거나 `deployment-evidence.txt` 파일을 첨부해 검토에 사용한다. 성공 화면도 캡처해 보관하고, 이 기록을 근거로 [수행 내역서](docs/수행내역서.md)에 실제 실행 환경과 검증 결과를 반영한다.

`--demo`로 설치했다면 대체 앱 기준의 검증 결과임을 제출 자료에 명시한다. 과제에서 원본 앱 실행을 요구한다면 원본 앱으로 설치한 뒤 증거를 다시 수집해야 한다.

<a id="install-original-app"></a>

### 원본 앱으로 교체하고 검증하기: Intel Mac / OrbStack

먼저 제공받은 `agent-app.zip`을 **Mac의 다운로드 폴더에 같은 이름으로 저장**한다. 아래 함수는 Ubuntu 홈의 `~/agent-app.zip`을 우선 찾고, 없으면 OrbStack이 공유한 Mac 다운로드 폴더에서 찾는다. Mac 파일은 Linux의 `/mnt/mac` 아래에서 접근할 수 있다. [OrbStack 공식 파일 공유 안내](https://docs.orbstack.dev/machines/file-sharing)

그다음 **Ubuntu 콘솔**에서 아래 전체를 실행한다. 기존 x86-64 Ubuntu에서 최신 호환 코드를 받은 뒤 x86 앱만 압축 해제하고 대체 앱 서비스를 원본 앱으로 교체한다. 기존에 완료한 SSH·방화벽 설정은 재실행하지 않는다.

```bash
_install_original_agent() {
    local _zip="$HOME/agent-app.zip"
    local _directory="$HOME/agent-original"
    local _mac_home

    if [[ ! -f $_zip ]]; then
        _mac_home=$(mac sh -c 'printf "%s" "$HOME"') || return
        _zip="/mnt/mac$_mac_home/Downloads/agent-app.zip"
    fi
    if [[ ! -f $_zip ]]; then
        printf 'agent-app.zip was not found in Ubuntu home or Mac Downloads.\n' >&2
        return 1
    fi

    cd "$HOME/4-1" &&
    git pull --ff-only origin main &&
    sudo apt-get install -y unzip &&
    mkdir -p "$_directory" &&
    unzip -o "$_zip" agent-app-linux-x86 -d "$_directory" &&
    sudo bash scripts/install.sh --app "$_directory/agent-app-linux-x86" &&
    sudo bash scripts/collect-evidence.sh \
        "$HOME/4-1/evidence/deployment-evidence-original.txt"
}

_install_original_agent
```

`Installation complete` 이후 증거 수집까지 진행하며 cron 확인을 위해 최대 약 78초 기다린다. 마지막 `ALL DEPLOYMENT CHECKS PASSED`가 성공 기준이다. 새 결과는 `~/4-1/evidence/deployment-evidence-original.txt`에 저장되어 기존 대체 앱 증거와 구분된다. 공개 저장소에는 원본 ZIP·실행 파일을 배포하지 않으며 Git 제외 규칙을 적용했다.

제공된 실행 파일의 실제 부트 검사는 `AGENT_KEY_PATH`에 키 디렉터리를 요구하고 그 안의 `secret.key`를 읽는다. PDF와 대체 앱은 `api_keys/t_secret.key` 파일 경로를 요구한다. 설치기는 원본 파일명 `agent-app-linux-x86` 또는 `agent-app-linux-arm64`일 때 두 키 파일을 같은 과제용 문자열로 생성한다. 실행기는 이 두 원본 파일에 한해 자식 프로세스의 키 경로를 디렉터리로 변환한다. `/etc/agent-app.env`의 PDF 형식 경로는 유지하며, 이 차이는 제공 앱과 문서의 불일치에 대한 호환 처리다. 원본 실행 파일명을 임의로 변경하지 않는다.

WSL의 원본 기동 검증은 `bash tests/original.sh /절대/경로/agent-app-linux-x86`로 수행했다. 임시 경로에서 부트·포트·관제만 검증했으며 전체 설치 검증은 아니다. 원본 앱은 별도로 `/var/log/agent-app/agent_app.log`를 열려고 하므로 운영 경로가 없는 격리 테스트에서는 콘솔 로깅 전환 경고가 나올 수 있다. 설치 스크립트는 해당 운영 로그 디렉터리를 준비한다. 원본 앱 자체의 자원 부하로 임계값 경고가 발생해도, 관제는 요구사항에 따라 수집을 계속한다.

### 설치 중 포트 소유권 오류가 발생한 경우

이전 서비스 설정은 `Group=agent-core`로 앱의 기본 그룹을 바꿨다. 관제는 `agent-admin`의 원래 기본 그룹으로 실행되어 같은 UID여도 `/proc/PID/fd` 접근 검사가 거부될 수 있었다. 그 결과 앱이 `Agent READY`와 LISTEN 상태여도 관제가 `TCP 15034 is not owned by application PID ...`로 실패했다. 현재 설정은 `Group=` 지정을 제거해 계정의 기본 그룹을 사용하며 `agent-core`는 보조 그룹으로 유지한다. 디렉터리·파일의 그룹 권한과 systemd 격리 설정은 그대로 적용한다.

대체 앱 설치 중 이 오류가 발생했다면 아래 함수로 최신 변경을 받아 설치를 다시 실행한다. `git pull`에서 로컬 수정 충돌이 발생하면 덮어쓰지 않고 중단한다. 원본 앱을 설치했다면 `--demo` 대신 기존 `--app` 인수를 사용해야 한다.

```bash
_repair_agent_lab() {
    cd "$HOME/4-1" &&
    git pull --ff-only origin main &&
    sudo bash scripts/install.sh --demo
}

_repair_agent_lab
```

추가 회귀 검증은 systemd가 실행 중인 Linux에서 `sudo bash tests/systemd.sh "$USER"`로 수행한다. 기존 일반 사용자와 임시 systemd 유닛을 사용하며 사용자 계정·SSH·방화벽은 변경하지 않는다. TCP 15034가 이미 사용 중이면 중단한다. 이 검증은 일반 사용자 테스트 19개와 별도이며, 실행이 끝나면 임시 서비스를 제거한다. 실패 진단용 파일은 `/run/agent-app-regression.*`에 남으며 재부팅 시 정리된다. 자세한 원인과 실측은 [서비스 관제 오류 수정 기록](docs/systemd-monitor-fix.md)을 참고한다.

### 증거 수집에서 agent-dev 접근 오류가 발생한 경우

그룹 소속과 폴더 권한이 맞는데 `agent-dev lacks required access to /opt/agent-app/upload_files`가 나온다면 외부 `test` 명령의 판정 문제일 수 있다. Ubuntu 26.04 환경에서 보조 그룹으로 실제 파일 생성·쓰기는 성공하지만 외부 `test -r/-w/-x`는 실패하는 경우를 재현했다. 현재 증거 수집기는 해당 사용자로 Bash의 접근 검사를 실행해 보조 그룹과 ACL이 적용된 권한을 확인한다. 보안 디렉터리의 접근 차단 검사와 공유 파일 기본 ACL 검사도 유지한다.

아래 함수로 최신 변경을 받은 뒤 증거 수집만 다시 실행한다. 계정 재설치나 권한 변경은 필요하지 않다. 최종 `ALL DEPLOYMENT CHECKS PASSED`가 나와야 완료이며, 실제 권한 부족이 있으면 수정 후에도 검사는 실패한다.

```bash
_retry_agent_evidence() {
    cd "$HOME/4-1" &&
    git pull --ff-only origin main &&
    sudo bash scripts/collect-evidence.sh \
        "$HOME/4-1/evidence/deployment-evidence.txt"
}

_retry_agent_evidence
```

추가 회귀 검증은 기존 보조 그룹이 있는 일반 사용자 계정으로 `sudo bash tests/access.sh "$USER"`를 실행한다. 실제 쓰기·읽기와 접근 허용·차단을 `/run`의 임시 폴더에서 검사하며 계정이나 운영 경로 권한은 바꾸지 않는다. 자세한 원인과 전후 검증은 [접근 검사 오류 수정 기록](docs/access-check-fix.md)을 참고한다.

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

systemd는 앱을 `agent-admin` 계정의 기본 그룹으로 실행하고 `agent-common`·`agent-core`를 보조 그룹으로 사용한다. 파일시스템 쓰기는 업로드·로그 디렉터리로 제한한다. 서비스 재시작 정책은 비정상 종료 시 3초 간격이다. 이 서비스 구성은 원본 앱이 과제에 명시된 디렉터리만 사용하는 것을 전제로 한다.
