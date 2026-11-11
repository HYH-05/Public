# ai-server-check

Ansible로 Linux·Windows 서버 점검 데이터를 수집하고, 지난 점검 원본과 기계적으로 비교한 뒤 Claude(`claude -p`)가 서버별 분석·종합 보고서를 만들어 Slack으로 보낸다.

## 흐름

```
run.sh
 ├─ collect.yml          대상 서버에서 점검 스크립트 실행 → reports/<시각>/raw/<호스트>.txt
 │                         Linux: files/health_check.sh  /  Windows: files/health_check.ps1
 ├─ report_status.py     수집 상태 판정 (ok / partial / failed)
 ├─ compare.py           baseline/<호스트>.txt 와 비교 (디스크·포트·계정·관리자 권한·재부팅·로그인 실패·하드웨어 오류·오류 로그 유형)
 ├─ claude -p            서버별 분석 (도구 비활성화)
 │                         Linux: prompts/server.md  /  Windows: prompts/server_windows.md
 ├─ claude -p            prompts/summary.md 로 종합
 ├─ report_status.py     분석 검증·등급 집계, baseline 갱신
 └─ notify_slack.py      Slack 전송
```

* 지난 AI 분석 결과는 다음 분석에 넣지 않는다. 비교는 수집 데이터끼리만 한다.
* `/etc/shadow` 해시는 수집 단계에서 알고리즘 ID만 남기고 마스킹한다.
* 두 스크립트의 출력 구조(섹션, `### SNAPSHOT ###` 블록, `### COLLECTION_ERRORS N ###` 표식)는 같다. 그래서 비교·집계·알림 단계는 OS 구분 없이 공통으로 쓴다.
* 서버별 분석 프롬프트는 원본의 `점검 대상 OS: Windows` 줄로 고른다.

## 구성 파일

| 파일 | 설명 |
|---|---|
| `run.sh` | 전체 실행 (flock 중복 방지, 단계별 실패 기록) |
| `collect.yml` | 점검 스크립트 배포·실행·결과 회수. `windows` 그룹 여부로 Linux/Windows 블록을 나눈다 |
| `files/health_check.sh` | Linux 점검 스크립트 |
| `files/health_check.ps1` | Windows 점검 스크립트 (**UTF-8 BOM 으로 저장**, 없으면 PowerShell 5.1 에서 한글 파싱 실패) |
| `compare.py` | 지난 점검 대비 변화 계산 |
| `report_status.py` | 수집/분석 상태 판정, 등급 집계 |
| `notify_slack.py` | Slack 메시지·보고서 업로드 |
| `prompts/` | Linux·Windows 서버별 분석, 종합 분석 프롬프트 |
| `tests/check_pipeline.py` | 파이프라인 검증 |
| `docs/windows-openssh-setup.md` | Windows 대상 OpenSSH Server 구성 절차 |

## Linux / Windows 점검 항목 비교

| 항목 | Linux | Windows | 차이 |
|---|---|---|---|
| 재부팅/가동시간 | `uptime -s` | `LastBootUpTime` + 재부팅/종료 이벤트(41, 1074, 6005, 6006, 6008) | Windows는 종료 요청자(1074)와 비정상 종료(41/6008)까지 본다 |
| 시간 동기화 | `timedatectl` 동기화 여부 | W32Time 서비스 상태 + `w32tm /query /status` | 같은 목적 |
| CPU 부하 | sar **기간 내 일별 평균/최대** | **현재값만** (1초 간격 5회) | Windows는 기본 이력이 없다 |
| 메모리 | 현재값 + sar **일별 이력** | 현재값, 커밋 사용률, 페이지 파일 | Windows는 기본 이력이 없다 |
| 디스크 | `df` (마운트별) | 드라이브별 사용률 | 같은 목적 |
| inode | `df -i` | 없음 | NTFS에는 해당 개념이 없다 |
| 프로세스 | 개수 + 전체 프로세스 트리 | 개수 + 메모리 상위 15개 | Windows는 부모-자식 관계를 보지 않는다 |
| 포트 | `ss -tulnp` | TCP Listen + UDP (49152 이상 동적 포트 제외) | 같은 목적 |
| 서비스 | `systemctl --failed` | 자동 시작인데 멈춘 서비스 + 종료 코드 | Windows는 정상 중지(트리거 시작 등)가 섞여 종료 코드로 구분한다 |
| 임시 디렉토리 | /tmp, /var/tmp, /dev/shm 파일 목록 300건 + lsof | 폴더별 파일 수·크기 + 기간 내 실행형 파일 | Windows는 범위를 좁혔고 사용 중인 파일은 보지 않는다 |
| 계정 | 셸을 가진 시스템 계정, UID 1000 이상, shadow(해시 마스킹) | 로컬 계정 (활성 여부, 마지막 로그온, 비밀번호 변경일) | Windows는 비밀번호 해시를 다루지 않는다 |
| 관리자 권한 | sudoers | Administrators, Remote Desktop Users 구성원 | 같은 목적 |
| 커널 로그 | 커널 warning 이상 | System 로그 경고 요약 | 대응 항목 |
| 시스템 오류 로그 | journal err 이상 요약 + 원문 | System·Application 치명/오류 요약 + 원문 | Windows는 앱 오류 수준이 이벤트 로그에 남아 앱 오류도 잡힌다 |
| 로그인 성공 | `last` 전체 | 4624 중 대화형·네트워크·잠금해제·RDP·캐시 | 서비스/시스템 로그온 제외 |
| 로그인 실패 | SSH 실패 | 4625 전체 (SSH, RDP, 네트워크) | Windows가 범위가 더 넓다 |
| 업데이트·백신 | 없음 | 마지막 업데이트 설치일, Defender 상태 | Windows에만 있다 |
| 장비 정보 | DMI 제조사·모델·BIOS, `systemd-detect-virt` | `Win32_ComputerSystem`·`Win32_BIOS` | 가상 머신이면 아래 하드웨어 항목은 건너뛴다 |
| 메모리 ECC | EDAC 컨트롤러·DIMM별 수정/수정 불가 건수 (부팅 이후 누적) | WHEA 90일: 구성 요소·오류 유형별 건수, 월별 추세, 위치값(Node/Card/Module) + 메모리 모듈 목록 | Windows는 기간 추세, Linux는 부팅 이후 누적. EDAC 미로드 장비는 확인 불가 |
| 하드웨어 오류 로그 | 커널 로그 90일 (EDAC, MCE, I/O error, ATA/NVMe 오류, md 이상) 유형별·월별 | WHEA (위와 같음) | |
| RAID | `/proc/mdstat` + 하드웨어 RAID 컨트롤러 (storcli/perccli/arcconf/ssacli 있으면 상태) | MR_MONITOR(MegaRAID 계열) 90일 경고 이상 | 관리 도구·모니터가 없으면 확인 불가로 표시 |
| 디스크 상태 | `smartctl` 판정 + 재할당·대기·수정불가 섹터, NVMe 경고·마모 | `Get-PhysicalDisk` 상태 | RAID 컨트롤러 뒤 디스크는 가상 디스크로만 보인다 |

### SNAPSHOT 키 (compare.py 비교 대상)

| 키 | Linux | Windows |
|---|---|---|
| `disk` | 마운트 경로 사용률 | 드라이브 문자 사용률 |
| `port` | `tcp/udp 주소:포트` | 같은 형식 |
| `user` | UID 1000 이상 계정 | 로컬 계정 (비활성 표시) |
| `sudo` | sudoers 유효 줄 | Administrators 구성원 |
| `boot` | 부팅 시각 | 부팅 시각 |
| `sshfail` | SSH 로그인 실패 건수 | 4625 로그인 실패 건수 |
| `hwerr` | 점검 기간 커널 하드웨어 오류 건수 | 점검 기간 WHEA + RAID 경고 건수 |

### 하드웨어 점검 범위

* 수정 가능한 오류는 추세가 중요해 점검 기간(기본 7일)과 별도로 **90일**을 본다.
* BMC(IPMI SEL)는 수집하지 않는다. 팬·전원·온도·섀시 경고 같은 BMC 전용 이벤트는 각 장비의 BMC 웹 콘솔에서 확인한다.
* 분석 프롬프트의 판단 기준
    * 수정된 메모리 오류 반복 → 주의, 증가 추세나 같은 위치 집중 → 위험, 수정 불가 오류 → 위험
    * RAID 어레이 이상, SMART 실패, 재할당·대기·수정불가 섹터 → 위험 / RAID 배터리 없음·Write-Through → 주의
    * 도구·드라이버가 없어 못 본 항목은 정상이 아니라 확인 불가

### Windows 점검의 한계

* 부하·메모리는 점검 순간의 값만 본다. 점검 시각 외의 일시적 급증은 보고서에 나타나지 않는다. 이력이 필요하면 각 서버에 PerfMon 데이터 수집기를 따로 설정해야 한다.
* SSH 로그온은 4624에 접속지 IP가 `-`로 남는다.

## 준비

1. `inventory.example.ini` 를 `inventory.ini` 로 복사하고 대상 호스트를 채운다.
2. Windows 대상은 `docs/windows-openssh-setup.md` 순서로 OpenSSH Server와 키를 구성한다.
    * SSH 기본 셸을 바꾸지 않았으면 인벤토리에 `ansible_shell_type=cmd`, PowerShell로 바꿨으면 `powershell` 을 지정한다.
    * 내장 Administrator 가 비활성화된 서버는 관리자 그룹의 다른 로컬 계정을 호스트별 `ansible_user` 로 지정한다.
3. `prompts/server.md`, `prompts/server_windows.md` 의 `<ADMIN_PC_IP>` 를 관리자 PC 주소로 바꾼다. 이 주소의 원격 접속(SSH 22, RDP 3389) 로그인 성공은 정상 접속으로 분류된다.
4. Slack 설정 파일(기본 `/root/.config/ai_check/slack.env`)에 `SLACK_BOT_TOKEN`, `SLACK_CHANNEL` 을 둔다. 저장소에는 올리지 않는다.
5. `claude` CLI 로그인 후 `./run.sh` 로 실행한다. 일부만 점검할 때는 `./run.sh --limit windows` 처럼 대상을 제한한다.

`reports/`, `raw/`, `baseline/` 은 서버 점검 원본이 들어가므로 저장소에 올리지 않는다.
