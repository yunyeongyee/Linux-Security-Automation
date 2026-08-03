# Linux-Security-Automation

KISA 주요정보통신기반시설 보안 가이드를 기반으로 
Linux 서버 취약점 점검·자동 조치·백업·롤백·증빙 수집·Excel 보고서 생성을 통합한 보안 자동화 도구

## 폴더 구조

```text
linux_vuln_fix/
├── linux_vuln_fix.sh
└── lib/
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

### rollback

```text
/linux_vuln_fix/rollback/
```


