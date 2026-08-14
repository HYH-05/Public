# Infra Tech

인프라 운영을 위한 스크립트 및 프로젝트 모음

## 구조

```
.
├── projects/                        # 독립 프로젝트
│   ├── monitoring-dashboard/        # 통합 모니터링 GUI (Python/Tkinter)
│   └── password-manager/            # 패스워드 관리 도구
│
└── scripts/                         # 운영 스크립트
    ├── backup/                      # 백업 자동화
    │   ├── bash/
    │   │   ├── internal_bkup/       # 내부 백업 (DB, Zabbix, AWS)
    │   │   └── company_backup/         # S3 백업, 2차 백업
    │   └── bat/                     # Windows 백업 스크립트
    │
    ├── gitlab/                      # GitLab 관리
    │   └── bash/
    │       ├── dev_git/             # 백업, 복구, 업그레이드
    │       └── seoul_git/           # 미러링, S3 백업
    │
    ├── monitoring/                  # 시스템 헬스체크
    │   ├── bash/
    │   │   └── system_health_check.sh
    │   └── ps1/
    │       └── system_health_check.ps1
    │
    ├── install/                     # 설치 스크립트
    │   └── bash/
    │       ├── ELK_install.sh       # ELK Stack 설치
    │       └── softether.sh         # SoftEther VPN 설치
    │
    └── etc/                         # 기타 유틸리티
        ├── bat/
        └── ps1/
```

## 주요 프로젝트

### monitoring-dashboard

여러 서버/서비스의 상태를 실시간으로 모니터링하고 장애 발생 시 SMS 알림을 발송하는 통합 모니터링 시스템

- 포트 상태 실시간 모니터링
- 장애/복구 시 SMS 자동 알림 (DirectSend API)
- 그룹 기반 서비스 관리
- 히트맵 시각화

### password-manager

서버 계정 패스워드를 안전하게 관리하는 도구

- MySQL 연동 패스워드 저장
- 암호화 저장 및 조회
- 백업 및 동기화

## 주요 스크립트

### scripts/backup

- **2차 백업**: 게임 서버 → IDC (rsync)
- **3차 백업**: IDC → S3 (zstd 압축, 무결성 검증)
- **내부 백업**: DB, Zabbix, AWS 설정 백업

### scripts/gitlab

- GitLab 백업/복구 자동화
- 레포지토리 미러링 (A → B 서버)
- S3 백업 연동

### scripts/monitoring

- 시스템 리소스 점검 (CPU, Memory, Disk)
- 프로세스 및 네트워크 포트 확인
- 보안 점검 및 로그 요약

### scripts/install

- ELK Stack 자동 설치
- SoftEther VPN 설치

## 기술 스택

- **언어**: Bash, Python, PowerShell, Batch
- **인프라**: AWS (S3, EC2), IDC, Linux, Windows Server
- **도구**: ELK Stack, Zabbix, GitLab, rsync, MySQL

## 사용 방법

```bash
# 실행 권한 부여
chmod +x script_name.sh

# 실행
./script_name.sh
```

## 라이선스

MIT License
