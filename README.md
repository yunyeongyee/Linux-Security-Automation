# Linux-Security-Automation

KISA 주요정보통신기반시설 보안 가이드를 기반으로 
Linux 서버 취약점 점검·자동 조치·백업·롤백·증빙 수집·Excel 보고서 생성을 통합한 보안 자동화 도구

## 폴더 구조

```text
linux_vuln_fix/
├── linux_vuln_fix.sh
├── lib/
└── README.md
```

- `linux_vuln_fix.sh` : 메인 실행 파일
- `lib/` : Excel 보고서 생성 등에 필요한 내부 파일
- 메인 스크립트와 `lib` 폴더는 같은 위치에 두기
- `lib` 안의 파일명이나 위치 변경하지 않기

## 실행 권한

```bash
cd /linux_vuln_fix
chmod +x linux_vuln_fix.sh
```

## 전체 점검 및 조치

```bash
./linux_vuln_fix.sh
```

U-01~U-67 항목 점검 후 취약 항목별로 조치 여부 선택

## CSV 기준으로 실행

```bash
./linux_vuln_fix.sh /경로/report.csv
```

기존 CSV에서 취약으로 나온 항목만 불러와서 다시 점검·조치

## 롤백

```bash
./linux_vuln_fix.sh --rollback
```

백업 목록에서 복원할 시점 선택

롤백 대상:

- 설정 파일
- 파일 권한·소유권
- 계정·그룹 변경
- 서비스 상태
- 방화벽 상태
- 조치 과정에서 생성된 파일

실제 복원 전에 현재 상태를 `pre_rollback` 백업으로 한 번 더 저장

백업 파일을 옮길 때는 아래 파일도 같이 옮기기

```text
.tar.gz
.tar.gz.sha256
.tar.gz.records
```

## 도움말

```bash
./linux_vuln_fix.sh --help
```

## 실행 후 생성되는 폴더

```text
/linux_vuln_fix/
├── backup/
├── report/
└── rollback/
```

### backup

```text
/linux_vuln_fix/backup/
```

- 조치 전 백업
- 롤백 직전 안전 백업
- SHA-256 파일
- 롤백용 records 파일

### report

```text
/linux_vuln_fix/report/
```

- Excel 보고서
- TXT 보고서
- CSV 결과
- 누적 실행 이력

누적 이력:

```text
/linux_vuln_fix/report/vulnFixHistory.log
```

### rollback

```text
/linux_vuln_fix/rollback/
```

- 롤백 실행 로그
- 롤백 후 확인 결과
- U-23 허용·제한 목록

## 결과 상태

| 상태 | 의미 |
|---|---|
| 이미 양호 | 현재 설정이 기준을 충족 |
| 조치 완료 | 설정 변경 후 재확인 통과 |
| 수동 확인 | 운영 정책이나 환경 확인 필요 |
| 사용자 건너뜀 | 조치하지 않고 넘어간 항목 |
| 해당 없음 | 관련 서비스나 설정 없음 |
| 조치 실패 | 명령 실행 또는 재확인 실패 |

## 롤백 종료 코드

| 코드 | 의미 |
|---:|---|
| `0` | 복원 완료 |
| `1` | 복원 또는 주요 확인 실패 |
| `2` | 주요 복원 완료, 일부 직접 확인 필요 |

종료 코드 확인:

```bash
echo $?
```

## 실행 전 확인

- root 권한으로 실행
- SSH 접속 세션 하나는 계속 유지
- 조치 시작 전 백업 생성 여부 확인
- SSH, PAM, 계정, 방화벽 항목은 특히 주의
- 같은 서버에서 스크립트 중복 실행하지 않기
- 운영 서버 적용 전 테스트 서버에서 먼저 실행
- 결과 보고서와 로그에 서버 정보가 들어갈 수 있으므로 GitHub에 올리지 않기

## GitHub 제외 파일

`.gitignore`

```gitignore
backup/
report/
rollback/

*.log
*.csv
*.xlsx
*.txt
*.tar
*.tar.gz
*.sha256
*.records
*.tmp
*.bak

__pycache__/
```

---
