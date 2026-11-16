# 개인정보 분리 인프라

서울 리전(`ap-northeast-2`)에서 라이브 개인정보 처리, 라이브 운영툴, QA를 VPC 3개로 분리하는 Terraform 코드다. 아래 구성은 코드에 정의된 생성 결과물이다.

## 코드 구조

```text
privacy-management/
├── versions.tf                     Terraform·AWS Provider 버전과 리전
├── variables.tf                    입력값과 유효성 검사
├── locals.tf                       서버·서브넷·포트·연결 관계
├── network.tf                      VPC·서브넷·라우팅·피어링·임시 NAT
├── security.tf                     역할별 보안 그룹과 송수신 규칙
├── compute.tf                      AMI 조회·EC2·EBS·VPN용 EIP
├── load-balancers.tf               내부 ALB·HTTPS 리스너·대상 그룹
├── dns.tf                          선택적으로 생성하는 기존 영역의 DNS 레코드
├── outputs.tf                      리소스 ID·서버 주소·DNS 설정값 출력
├── templates/
│   └── linux-bootstrap.sh.tftpl     Linux 최초 부팅 공통 설정
├── scripts/
│   └── mount-data-disk.sh           데이터 디스크 식별·초기화·자동 마운트
├── tests/
│   ├── infrastructure.tftest.hcl    Terraform 모의 테스트
│   ├── test_bootstrap.py            Bash·프롬프트·Vim 동작 검사
│   └── test_mount_data_disk.py      디스크 보존·마운트 실패 모의 검사
├── terraform.tfvars.example         가상 값으로 작성한 환경 설정 예시
├── backend.tf.example               선택적 S3 state backend 선언 예시
├── backend.hcl.example              선택적 S3 state backend 설정 예시
├── .terraform.lock.hcl              AWS Provider 버전·체크섬 고정
├── .gitignore                      로컬 변수·state·plan 등 제외
├── AMI_SELECTION.md                 Rocky 이미지 선정 근거
├── SOFTETHER.md                     SoftEther 별도 구성 참고 문서
└── README.md
```

Terraform 최소 버전은 1.11.0이다. 실제 CIDR·도메인·운영 마운트 경로는 Git에서 제외되는 로컬 `terraform.tfvars`에 분리한다. backend 예시 파일은 `.tf`로 활성화하기 전까지 리소스 구성에 적용되지 않는다.

## 생성 리소스

| 리소스 | 기본 생성 수 | 구성 |
|---|---:|---|
| VPC | 3 | live, admin, qa |
| 서브넷 | 18 | VPC마다 public 2개·private 2개·LB용 2개 |
| 라우팅 테이블 | 9 | VPC마다 public·private·LB용 각 1개 |
| Internet Gateway | 3 | VPC마다 1개 |
| VPC 피어링 | 2 | live ↔ admin, live ↔ qa |
| EC2 | 9 | Linux 8대·Windows 1대 |
| 별도 데이터 EBS | 6 | Linux 5개·Windows 1개 |
| 내부 ALB | 2 | live·qa 각 1개 |
| HTTPS 리스너 | 4 | ALB마다 8443·8444 |
| 대상 그룹 | 4 | 환경별 PMS 8080·8090 |
| 보안 그룹 | 11 | 서버 역할별 9개·ALB용 2개 |
| VPN용 EIP | 3 | VPC마다 1개 |
| 임시 NAT Gateway | 3 | 활성화 시 VPC마다 1개 |
| NAT용 EIP | 3 | 임시 NAT 활성화 시 생성 |
| DNS 레코드 | 기본 0 | 기존 Route 53 영역 ID를 지정한 서비스만 생성 |

## 서버 구성

| 환경 | 서버 | 인스턴스 | vCPU | OS | OS 디스크 | 데이터 디스크 |
|---|---|---|---:|---|---:|---:|
| VPC1 / live | PMS | c6i.2xlarge | 8 | Rocky Linux 10.2 | 30GiB | 128GiB |
| VPC1 / live | MySQL | c6i.xlarge | 4 | Rocky Linux 10.2 | 30GiB | 128GiB |
| VPC1 / live | 배포·SVN | t3.small | 2 | Windows Server 2022 | 40GiB | 30GiB |
| VPC1 / live | VPN | t3.micro | 2 | Rocky Linux 10.2 | 20GiB | 없음 |
| VPC2 / admin | NodeJS 운영툴 | t3.small | 2 | Rocky Linux 10.2 | 30GiB | 128GiB |
| VPC2 / admin | VPN | t3.micro | 2 | Rocky Linux 10.2 | 20GiB | 없음 |
| VPC3 / qa | PMS + MySQL | t3.small | 2 | Rocky Linux 10.2 | 30GiB | 100GiB |
| VPC3 / qa | 운영툴 | t3.small | 2 | Rocky Linux 10.2 | 30GiB | 64GiB |
| VPC3 / qa | VPN | t3.micro | 2 | Rocky Linux 10.2 | 20GiB | 없음 |

용량은 OS와 데이터를 분리한 값이며, 모든 EBS는 gp3·암호화로 구성한다. 요청된 Core 수는 vCPU로 해석한다. VPC2 NodeJS 인스턴스 유형은 임시 기본값이다.

Linux는 Rocky 공식 계정의 `Rocky Linux 10.2 EC2 Base / 20260525.0 / x86_64 / 비-LVM` 이미지를 조회한다. GUI 없는 클라우드 기본 구성이며 cloud-init을 포함한다. ISO의 Minimal Install과 패키지 구성이 완전히 동일한 이미지는 아니다. 지정된 OS 디스크가 AMI의 최소 root 용량보다 작으면 생성을 차단한다.

Windows AMI를 별도로 지정하지 않으면 AWS 공식 Windows Server 2022 최신 이미지를 조회한다. 상세 이미지 선정 내용은 [AMI_SELECTION.md](AMI_SELECTION.md)에 정리되어 있다.

## 네트워크 구성

```text
VPC1 / live
  public-1  : VPN
  private-1 : PMS, MySQL, 배포·SVN
  lb-1/2    : 내부 ALB

VPC2 / admin
  public-1  : VPN
  private-1 : NodeJS 운영툴

VPC3 / qa
  public-1  : VPN
  private-1 : PMS + MySQL, 운영툴
  lb-1/2    : 내부 ALB
```

각 /22 VPC의 서브넷 배치는 다음과 같다. 이름이 없던 나머지 세 /25 구간은 예약 영역으로 남긴다.

| 서브넷 | /22 안의 위치 | 가용 영역 | 인터넷 기본 경로 |
|---|---|---|---|
| public-1 | 첫 번째 /25 | ap-northeast-2a | IGW |
| public-2 | 두 번째 /25 | ap-northeast-2c | IGW |
| private-1 | 세 번째 /25 | ap-northeast-2a | 임시 NAT 활성 시에만 생성 |
| private-2 | 네 번째 /25 | ap-northeast-2c | 임시 NAT 활성 시에만 생성 |
| lb-1 | 마지막 /25의 첫 /26 | ap-northeast-2a | 없음 |
| lb-2 | 마지막 /25의 두 번째 /26 | ap-northeast-2c | 없음 |

공인 IP는 VPN 서버에만 연결하며 PMS·DB·운영툴·배포 서버는 private 서브넷에 배치한다. ALB는 `internal` 유형이다. VPC2에도 LB용 서브넷은 생성하지만 ALB는 생성하지 않는다.

서버는 역할별 단일 인스턴스다. ALB와 서브넷을 두 AZ에 배치해도 서버가 이중화되는 것은 아니다.

## 서비스 연결

| 출발지 | 목적지 | 허용 포트·처리 |
|---|---|---|
| 허용된 외부 주소 | 각 VPN | TCP 10443 |
| 초기 설정용 외부 주소 | 각 VPN | SSH 22 |
| live VPN | live 내부 ALB | HTTPS 8443·8444 |
| VPC2 NodeJS | live 내부 ALB | HTTPS 8444만 허용 |
| live 내부 ALB | live PMS | HTTPS 8443 → HTTP 8080 |
| live 내부 ALB | live PMS | HTTPS 8444 → HTTP 8090 |
| live PMS | live MySQL | TCP 3306 |
| admin VPN | NodeJS 운영툴 | SSH 22·HTTPS 443 |
| qa VPN | qa 내부 ALB | HTTPS 8443·8444 |
| qa 운영툴 | qa 내부 ALB | HTTPS 8444 |
| qa 내부 ALB | qa PMS | HTTPS 8443 → HTTP 8080 |
| qa 내부 ALB | qa PMS | HTTPS 8444 → HTTP 8090 |
| qa VPN | qa 운영툴 | SSH 22·HTTPS 443 |
| 배포 서버 | live·qa 애플리케이션 서버 | SSH 22 |
| live·qa 애플리케이션 서버 | 배포·SVN 서버 | SVN 3690 |

각 VPN에서 해당 환경 Linux 서버의 SSH 접근을 허용한다. live VPN에서는 배포 서버의 RDP 3389·SVN 3690도 허용한다. QA MySQL은 통합 서버 내부에서 사용하며 외부 3306 수신 규칙을 생성하지 않는다.

live-admin과 live-qa는 피어링으로 연결한다. admin-qa 직접 피어링은 없다. 다른 VPC의 보안 그룹을 참조하는 규칙은 피어링 활성화 후 생성하도록 의존성을 지정한다.

ALB에서 HTTPS를 종료하고 PMS에는 HTTP로 전달한다. 기본 443 리스너는 없으며, PMS 접근 시 지정 포트를 사용한다. HTTPS 443을 사용하는 NodeJS·QA 운영툴의 서버 인증서 구성은 별도다.

VPN은 SoftEther SecureNAT 사용자 모드를 전제로 한다. 내부 서버에는 VPN 서버의 사설 IP로 접근하는 구조다. 상세 구성 참고는 [SOFTETHER.md](SOFTETHER.md)에 정리되어 있다.

## Linux 공통 설정

Linux 8대의 최초 부팅 시 root 권한으로 공통 스크립트를 실행한다. Windows에는 Linux 공통 스크립트를 적용하지 않는다.

| 항목 | 생성·적용 결과 |
|---|---|
| 저장소 | CRB 활성화·EPEL 설치 |
| 시간대 | Asia/Seoul |
| 시간 동기화 | chrony·AWS 내부 Time Sync |
| 호스트명 | 접두사와 서버 역할로 구성 |
| Bash alias | `ll='ls -al'`, `vi='vim'` |
| 프롬프트 | 사용자명·호스트명을 live·admin은 빨강, qa는 노랑으로 표시 |
| Vim | 들여쓰기·검색·상태바·단축키·마지막 커서 위치 복원 |
| 기존 계정 | root·일반 계정의 기존 Vim 설정을 보존하고 공통 설정 연결 |
| 신규 계정 | `/etc/skel/.vimrc`에 공통 설정 연결 |
| 서비스 | crond·rsyslog·vnstat·chronyd·sysstat 활성화 |
| 타이머 | sysstat 수집·요약 및 logrotate 활성화 |

설치 패키지는 다음과 같다. `vim`은 `vim-enhanced`, `iotop`은 Rocky 10의 `iotop-c`로 설치한다.

```text
vim-enhanced less net-tools nmap iputils cronie rsyslog unzip psmisc
sysbench vnstat htop sysstat man-db iotop-c telnet rsync lsof tree nmon
parted smartmontools zstd zip

설정·마운트 보조 패키지:
dnf-plugins-core epel-release chrony util-linux xfsprogs logrotate
```

| 파일 | 역할 |
|---|---|
| `/etc/profile.d/90-pm-shell.sh` | alias·환경별 프롬프트 |
| `/etc/bashrc` | 공통 Bash 설정 연결 |
| `/etc/vim/pm-common.vim` | 공통 Vim 설정 |
| `/etc/skel/.vimrc` | 신규 계정의 Vim 설정 연결 |
| `/etc/cloud/cloud.cfg.d/99-pm-hostname.cfg` | 호스트명 유지 |
| `/var/log/pm-bootstrap.log` | 공통 초기 설정 실행 로그 |
| `/var/lib/pm-bootstrap/complete` | 초기 설정 완료 표시 |

Vim F2는 `#` 주석이 있는 줄에서만 주석을 제거하도록 보정한다. 패키지 설치로 telnet 서버를 활성화하거나 스캔·벤치마크를 자동 실행하지 않는다.

user data는 최초 부팅 시 한 번 실행된다. Terraform 생성 완료와 공통 스크립트 실행 완료는 별개다. 기존 서버의 user data 변경은 stop/start를 유발할 수 있으며 스크립트가 자동 재실행되는 것은 아니다.

## 데이터 디스크

Linux 데이터 디스크 5개를 하나의 운영 경로(`data_mount_path`)로 통일한다. 코드의 경로는 `data_mount_path`로 전달하고 실제 운영 값은 로컬 변수 파일에서 관리한다. Windows 배포 서버의 30GiB 데이터 디스크 초기화는 별도다.

```text
지정 EBS 볼륨 ID
  → NVMe serial로 장치 식별
  → 기존 파일시스템·서명·파티션 확인
  → 빈 디스크만 최초 XFS 포맷
  → UUID로 /etc/fstab 등록
  → data_mount_path 마운트
```

| 상태 | 처리 |
|---|---|
| 지정한 빈 EBS | 강제 옵션 없이 최초 XFS 포맷 |
| 기존 XFS·ext4 | 포맷 없이 재사용 |
| 파티션·LVM·알 수 없는 서명 | 자동 변경 없이 중단 |
| 기존 fstab과 충돌 | 기존 항목을 보존하고 중단 |
| 마운트 경로에 기존 파일 존재 | 파일을 가리지 않고 중단 |
| 다른 볼륨이 이미 마운트됨 | 중단 |
| 데이터 디스크 연결 지연 | 지정한 EBS를 최대 약 5분 대기 |

`nofail`로 OS는 데이터 볼륨 없이도 부팅할 수 있게 한다. 데이터 EBS에는 `prevent_destroy = true`를 적용해 삭제·교체 계획을 차단한다. 이 보호 설정은 백업을 대신하지 않는다.

live MySQL과 qa 통합 서버에는 `/etc/systemd/system/mysqld.service.d/10-data-mount.conf`를 생성한다.

| 설정 | 결과 |
|---|---|
| `RequiresMountsFor` | 데이터 마운트 이후 MySQL 시작 |
| `AssertPathIsMountPoint` | 마운트가 없으면 MySQL 시작 차단 |
| `BindsTo` | 마운트 해제 시 MySQL 중지 |

PMS·운영툴 서비스에는 디스크 의존성을 추가하지 않는다. MySQL 데이터 경로 이동도 자동 수행하지 않는다. MySQL 설치 단계에서 `<data_mount_path>/mysql` 데이터 경로와 소유권·SELinux 문맥을 구성해야 한다.

## 로그 구성

| 대상 | 보관 설정 |
|---|---|
| journald | persistent·압축, 최대 30일·1GiB |
| 일반 시스템 로그 | 일별 회전 90개·최대 보관 90일·압축 |
| 공통 초기 설정 로그 | 일별 회전 90개·최대 보관 90일·압축 |
| sysstat | 패키지 기본값 유지: 10분 수집·28일 보관 |

journald는 기간·용량·여유 공간 조건에 따라 오래된 기록을 먼저 정리하므로 30일분 보존을 보장하지 않는다. 서비스 표준 출력이 journald에만 기록되면 같은 제한을 받는다.

일반 시스템 로그는 rsyslog의 cron·mail·messages·secure·spooler 로그를 대상으로 한다. 개별 MySQL·SoftEther·PMS 로그와 audit 로그의 보관 설정은 자동 변경하지 않는다.

| sysstat 항목 | 확인한 기본값 |
|---|---|
| 수집 | `OnCalendar=*:00/10` |
| 보관 | `HISTORY=28` |
| 전날 요약 | 매일 00:07 |
| 저장 경로 | `/var/log/sa` |
| 압축 기준 | `COMPRESSAFTER=31` |

sysstat 기본값은 Rocky 10.2의 `12.7.6-4.el10` 패키지 기준이다. 향후 패키지 버전에 따라 달라질 수 있다.

## 임시 아웃바운드

```text
private 서버 → NAT Gateway → Internet Gateway → 인터넷
public VPN   → Internet Gateway → 인터넷
```

`enable_temporary_nat = true`이면 VPC마다 NAT 1대와 EIP 1개를 생성하고, 서버의 인터넷 TCP 80·443 송신을 허용한다. private-2도 2a의 NAT를 사용한다.

`false`이면 NAT·NAT용 EIP·private 인터넷 기본 경로·서버 인터넷 송신 규칙을 제거한다. VPN용 EIP·IGW·내부 통신 경로는 유지한다. 초기 패키지 설치에는 임시 인터넷 경로가 필요하다.

## 출력값

| 출력 | 내용 | 표시 제한 |
|---|---|---|
| `rocky_image` | 조회된 AMI ID·이름·공식 계정·최소 root 용량 | 없음 |
| `vpc_ids` | 환경별 VPC ID | 없음 |
| `server_private_ips` | 서버별 사설 IP | sensitive |
| `vpn_public_ips` | VPN별 공인 IP | sensitive |
| `data_volume_ids` | 서버별 데이터 EBS ID | 없음 |
| `dns_configuration` | 서비스별 DNS 이름·종류·대상 | sensitive |

`dns_zone_ids`가 비어 있으면 DNS 레코드를 생성하지 않고 필요한 설정값만 출력한다. 기존 Route 53 영역 ID를 지정한 서비스는 PMS의 A Alias 또는 운영툴의 A 레코드를 생성한다. Private Hosted Zone의 VPC 연결은 별도 구성 대상이다.

sensitive 출력도 state에는 저장된다. 기본 state는 로컬이며, `.terraform/`·state·plan·실제 변수 파일은 Git 제외 대상이다.

## 자동화 범위와 검증

| 자동 구성 | 별도 구성 |
|---|---|
| VPC·서브넷·라우팅·보안 그룹·ALB | 기존 DNS 시스템 및 Private Hosted Zone 연결 |
| EC2·OS 이미지·EBS·VPN용 공인 IP | SoftEther 설치·가상 허브·사용자·서버 인증서 |
| Linux 공통 패키지·Bash·Vim·시간·로그 | PMS·MySQL·NodeJS·SVN 설치·배포 |
| Linux 데이터 마운트·MySQL 마운트 의존성 | MySQL 데이터 경로·소유권·SELinux 문맥 |
| 임시 NAT와 인터넷 송신 규칙 | Windows 데이터 디스크 초기화 |

Terraform 모의 테스트 7개와 Bash·Vim·디스크 보존 모의 검사 10개를 포함한다. AWS 호출 없이 구성값·포트 매핑·서브넷·NAT 제거·이미지 최소 디스크·초기 설정 연결·기존 데이터 보존 분기를 검증한다.

실제 AMI 조회·인스턴스 부팅·패키지 설치·서비스 기동·DNS 해석·애플리케이션 통신은 별도 실환경 확인 대상이다.
