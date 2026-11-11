# Windows OpenSSH Server 구성 절차 (Ansible 점검용)

* 접속 주체: Ansible 서버 `<ANSIBLE_IP>`, 계정 `Administrator`, 키는 Ansible 서버의 기존 RSA 키(`/root/.ssh/id_rsa`)
* 대상: Windows Server `<WINDOWS_IP>`
* Windows 명령은 모두 **관리자 PowerShell**에서 실행한다.

## 0. 사전 확인

```powershell
Get-WindowsCapability -Online -Name OpenSSH* | Select Name, State
Get-Service wuauserv | Select Name, Status, StartType
```

* `OpenSSH.Server`가 `NotPresent`면 설치가 필요하다.
* `wuauserv`가 `Disabled`면 `Add-WindowsCapability`가 `0x80070422` 오류로 실패한다. 이때는 1-B(MSI)로 설치한다.

## 1. 설치

### 1-A. Windows 기능으로 설치 (Windows Update가 살아 있는 서버)

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
```

* 결과의 `RestartNeeded`가 `False`면 재부팅이 필요 없다.

### 1-B. MSI로 설치 (Windows Update가 꺼진 서버, 재부팅 없음)

1. PC에서 GitHub `PowerShell/Win32-OpenSSH` 저장소의 Releases 페이지에 들어가 `OpenSSH-Win64-v<버전>.msi`를 받는다.
2. 받은 파일을 서버의 `C:\temp`로 복사한다.
3. 아래 명령으로 설치한다.

```powershell
msiexec /i C:\temp\OpenSSH-Win64-v<버전>.msi ADDLOCAL=Server /qn
Get-Service sshd
```

* `ADDLOCAL=Server`는 서버 기능만 설치한다는 뜻이다. 기본으로 설치된 Client와 충돌하지 않는다.
* Client만으로는 들어오는 접속을 받을 수 없다. 접속을 받는 것은 `sshd`다.

## 2. 서비스 실행 및 자동 시작 등록

```powershell
Set-Service sshd -StartupType Automatic
Start-Service sshd
Get-Service sshd | Select Name, Status, StartType
Get-NetTCPConnection -LocalPort 22 -State Listen
```

* 정상 결과
    * `Status`가 `Running`이고 `StartType`이 `Automatic`이다.
    * 22번 포트가 Listen 상태다.
* `Start-Service`는 지금 한 번만 실행한다. 재부팅 후에도 자동으로 켜지게 하는 것은 `-StartupType Automatic`이다.
* 서비스가 처음 시작될 때 `C:\ProgramData\ssh` 폴더가 생긴다. 이 폴더에 `sshd_config`와 호스트 키가 만들어진다.

## 3. 기본 셸을 PowerShell로 지정

```powershell
New-ItemProperty -Path HKLM:\SOFTWARE\OpenSSH -Name DefaultShell -PropertyType String -Force `
  -Value C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
```

## 4. 공개키 등록

### Ansible 서버에서 공개키 확인

```bash
cat /root/.ssh/id_rsa.pub
```

* 출력되는 `ssh-rsa AAAA... root@<호스트명>` 한 줄 전체를 복사한다.
* 비밀키 `id_rsa`는 옮기지 않는다.

### Windows에서 등록

```powershell
$f   = 'C:\ProgramData\ssh\administrators_authorized_keys'
$key = 'from="<ANSIBLE_IP>" ssh-rsa AAAA...붙여넣기... root@<호스트명>'
Set-Content -Path $f -Value $key -Encoding ascii
icacls $f /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"
icacls $f /remove *S-1-5-11
icacls $f
```

* 마지막 `icacls` 결과에는 `NT AUTHORITY\SYSTEM:(F)`와 `BUILTIN\Administrators:(F)` **두 줄만** 있어야 한다.
* `icacls $f /remove *S-1-5-11`은 `Authenticated Users`의 직접 권한을 지운다. `/inheritance:r`은 상속된 권한만 지우기 때문에 이 줄이 따로 필요하다.
* `from="<ANSIBLE_IP>"`를 붙이면 키가 유출되어도 Ansible 서버가 아닌 곳에서는 이 키로 접속할 수 없다.
* 인코딩은 반드시 `-Encoding ascii`로 지정한다.
    * `echo >`나 `Out-File`로 만들면 파일이 UTF-16으로 저장된다.
    * sshd는 UTF-16 파일을 읽지 못하고, 오류 없이 키 인증만 실패한다.
* Administrator처럼 Administrators 그룹에 속한 계정은 `C:\Users\<계정>\.ssh\authorized_keys`를 읽지 않는다. 이 사실은 다음 명령으로 확인한다.

```powershell
Select-String -Path C:\ProgramData\ssh\sshd_config -Pattern 'Match Group administrators' -Context 0,1
```

결과에 `AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys` 줄이 같이 나오면 정상이다.

## 5. 방화벽 확인 및 수정

### 22번 허용 규칙 확인

```powershell
$rule = Get-NetFirewallRule -Direction Inbound |
  Where-Object { ($_ | Get-NetFirewallPortFilter).LocalPort -eq 22 }
$rule | Select Name, DisplayName, Enabled, Profile, Action
$rule | Get-NetFirewallAddressFilter | Select RemoteAddress
Get-NetConnectionProfile | Select InterfaceAlias, NetworkCategory
```

* **사례**
    * MSI가 만든 규칙(`OpenSSH SSH Server Preview (sshd)`)이 `Private` 프로필에만 걸려 있었다.
    * 서버 네트워크는 `Domain`이나 `Public` 프로필이라, 이 규칙이 적용되지 않았다.
    * 그 결과 ping, 3389, 445는 통과하는데 22번만 timeout이 났다.

### 규칙이 있을 때: 프로필과 접속지 수정

```powershell
$rule | Set-NetFirewallRule -Enabled True -Profile Any -RemoteAddress <ANSIBLE_IP> -Action Allow
```

### 규칙이 없을 때: 새로 만들기

```powershell
New-NetFirewallRule -Name OpenSSH-Server-In-TCP -DisplayName 'OpenSSH Server' `
  -Direction Inbound -Protocol TCP -LocalPort 22 -RemoteAddress <ANSIBLE_IP> -Profile Any -Action Allow
```

### AD 가입 서버 추가 확인

```powershell
Get-NetFirewallProfile -PolicyStore ActiveStore | Select Name, AllowLocalFirewallRules
```

* `AllowLocalFirewallRules`가 `False`인 프로필에서는 GPO 때문에 로컬 규칙이 무시된다.
* 그런 서버는 22번 허용 규칙을 GPO에 추가해야 한다.

## 6. 접속 테스트 (Ansible 서버)

```bash
# 포트 도달 확인
timeout 5 bash -c '</dev/tcp/<WINDOWS_IP>/22' && echo OPEN || echo BLOCKED

# 첫 접속: 호스트 키 지문 확인 후 yes
ssh Administrator@<WINDOWS_IP> whoami

# 키 인증 확인 (비밀번호 질문 없이 성공해야 함)
ssh -o BatchMode=yes -o ConnectTimeout=5 Administrator@<WINDOWS_IP> whoami
```

* 결과가 `<호스트명>\administrator`면 성공이다.

## 7. 비밀번호 로그인 차단 (6번 성공 후)

1. `C:\ProgramData\ssh\sshd_config`에서 `#PasswordAuthentication yes` 줄을 `PasswordAuthentication no`로 바꾼다.
    * 이 줄은 `Match Group administrators` 블록 **위**에 있어야 전체 계정에 적용된다.
2. 아래 명령으로 적용하고 확인한다.

```powershell
Restart-Service sshd
Get-Service sshd | Select Name, Status
```

3. Ansible 서버에서 6번의 `BatchMode` 테스트를 다시 실행해서 키 접속이 유지되는지 확인한다.

## 8. Ansible 인벤토리

```ini
[windows]
win-host-01 ansible_host=<WINDOWS_IP>

[windows:vars]
ansible_connection=ssh
ansible_shell_type=powershell
ansible_user=Administrator
```

## 9. 문제 발생 시

| 증상 (Ansible 서버) | 원인 | 확인 |
|---|---|---|
| `Connection timed out` | 방화벽 규칙의 프로필 또는 접속지 불일치, 중간 ACL | 5번 규칙의 `Profile`, `RemoteAddress` |
| `Connection refused` | sshd 중지 | `Get-Service sshd` |
| `Host key verification failed` | 첫 접속 지문 미등록 | `BatchMode` 없이 한 번 접속 |
| `Permission denied (publickey)` | 키 파일 권한, 인코딩, `from=` 불일치 | 아래 로그 |

```powershell
Get-WinEvent -LogName OpenSSH/Operational -MaxEvents 20 | Format-Table TimeCreated, Message -Wrap
```

| 로그 문구 | 원인 |
|---|---|
| `bad ownership or modes` | 4번 권한에 다른 계정이 남아 있음 |
| `Connection from <IP>`의 IP가 Ansible 서버 IP가 아님 | NAT 구간. 방화벽 규칙과 `from=`을 실제 IP로 맞춰야 함 |
| `Failed publickey` | 키 내용 불일치 또는 UTF-16 인코딩 |

* PowerShell에서는 `sc`가 `Set-Content`의 별칭이다. 서비스 상세 정보를 볼 때는 `sc.exe qc sshd`처럼 반드시 `sc.exe`로 입력한다.
