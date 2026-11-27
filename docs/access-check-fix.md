# 보조 그룹 접근 검사 오탐 수정

2026-11-27 전달받은 증거 수집 화면에서 SSH·UFW 검사는 통과했으나 `agent-dev lacks required access to /opt/agent-app/upload_files`가 발생했다. 화면의 그룹 소속과 업로드 폴더 모드는 공유 접근 정책에 부합해 보였으므로 권한을 넓히지 않고 검사 구현을 격리 재현했다.

## 재현

WSL Ubuntu 26.04에서 기존 일반 사용자 last_와 기존 보조 그룹 adm을 사용했다. root:adm, 모드 2770인 `/run` 임시 폴더에 대해 다음 결과를 얻었다.

- 실제 파일 생성·쓰기·읽기: 성공
- 같은 사용자로 실행한 외부 `/usr/bin/test -r`, `-w`, `-x`: 모두 종료 코드 1
- 기존 `_assert_access()`의 공유 접근 허용 검사: 실패

당시 `/usr/bin/test`는 Rust coreutils 구현을 가리켰다. 이 실험은 사용자 화면의 개별 경로를 직접 조사한 결과는 아니며, 동일한 오류와 보조 그룹 판정 문제를 로컬에서 재현한 것이다. 별도로 Ubuntu 26.04의 외부 test가 ACL을 잘못 판정하는 문제도 [GitHub runner-images 이슈](https://github.com/actions/runner-images/issues/15004)에 보고되어 있다.

## 변경

`collect-evidence.sh`에서 외부 `test` 대신 대상 사용자의 `/bin/bash` 내부 `[[ -r ... && -w ... && -x ... ]]`로 검사한다. 디렉터리당 세 번 실행하던 runuser도 한 번으로 줄었다. 제한 경로의 탐색 차단 검사와 생성한 공유 파일의 쓰기 권한 검사도 같은 Bash 방식으로 통일했다. 계정·그룹·디렉터리 권한은 변경하지 않는다.

## 검증 및 복구

`tests/access.sh`는 실제 파일 쓰기·읽기, 공유 디렉터리 허용, 제한 디렉터리 차단, 제한 디렉터리를 허용으로 오판하지 않는지를 검사한다. root로 기존 일반 사용자 이름을 인수로 받으며 사용자 계정이나 운영 디렉터리는 변경하지 않는다. 수정 전 결과는 `evidence/access-before-fix.log`, 수정 후 결과는 `evidence/access-after-fix.log`에 보존한다. 기존 일반 사용자 테스트 결과는 `evidence/access-fix-validation.log`에 별도로 기록한다.

기존 설치에서는 최신 main을 받은 뒤 증거 수집 스크립트만 다시 실행한다. 설치 스크립트나 보안 설정을 다시 적용할 필요는 없다. 이 검증은 전체 배포 검사의 대체가 아니므로 실제 환경에서 `ALL DEPLOYMENT CHECKS PASSED`를 확인해야 한다.
