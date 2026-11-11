<#
# ! 중요 정보, 코드 요약 등
# @ 일반 정보(로직 설명)
# * 규칙, 정책 등

# ! .SYNOPSIS
# !     Windows 서버의 핵심 시스템 상태, 보안, 로그를 점검한다. health_check.sh 의 Windows 판이다.
# ! .NOTES
# !     - [중요] UTF-8 with BOM 으로 저장해야 Windows PowerShell 5.1 에서 한글이 깨지지 않는다.
# !     - 첫 번째 인자로 점검 기간(일)을 받는다. (기본 7)
# !     - 출력 구조는 리눅스판과 같다: 섹션 머리말, "시스템 오류 이상 로그 요약", SNAPSHOT 블록, COLLECTION_ERRORS 표식.
# !       compare.py / report_status.py 가 그대로 읽는다.
# !     - 카운터 이름은 OS 언어에 따라 바뀌므로 Get-Counter 대신 CIM 클래스를 쓴다.
#>
param([int]$CheckDays = 7)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($CheckDays -lt 1) { $CheckDays = 7 }
$script:CheckErrors = 0
$Since = (Get-Date).AddDays(-$CheckDays)
$WarningThreshold = 80
$Fmt = 'yyyy-MM-dd HH:mm:ss'

# @ 항목별로 실패를 기록하고 마지막 종료 코드에 반영한다.
function Query-Failed([string]$msg) {
    $script:CheckErrors++
    "[조회 실패] $msg"
}

function Print-Header([string]$title) {
    ''
    ">> $title"
    '================================================='
}

function Separator { ''; '-------------------------------------------------'; '' }

# @ 결과가 없을 때 Get-WinEvent 가 내는 오류는 0건으로 본다.
function Get-Events([hashtable]$Filter, [int]$Max = 5000) {
    try { @(Get-WinEvent -FilterHashtable $Filter -MaxEvents $Max -ErrorAction Stop) }
    catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { @() } else { throw }
    }
}

# @ 외부 명령(w32tm 등)은 OEM 코드페이지로 출력하므로 그 인코딩으로 읽는다.
function Invoke-Native([scriptblock]$Block) {
    $saved = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
        & $Block 2>&1 | ForEach-Object { "$_" }
    } finally { [Console]::OutputEncoding = $saved }
}

# @ 같은 메시지를 묶기 위해 첫 줄만 쓰고 숫자는 # 으로 바꾼다.
function Event-Key($e) {
    $msg = if ($e.Message) { ($e.Message -split "`r?`n")[0] } else { '(메시지 없음)' }
    "$($e.ProviderName) [$($e.Id)] " + ($msg -replace '\d+', '#')
}

function Event-Line($e) {
    $msg = if ($e.Message) { ($e.Message -split "`r?`n")[0] } else { '(메시지 없음)' }
    "$($e.TimeCreated.ToString($Fmt)) $($e.LevelDisplayName) $($e.ProviderName) [$($e.Id)] $msg"
}

function Group-Count($items, [int]$Top) {
    $items | Group-Object | Sort-Object Count -Descending | Select-Object -First $Top |
        ForEach-Object { '{0,7} {1}' -f $_.Count, $_.Name }
}

'================================================='
' 주간 시스템 상태 점검 보고서'
'================================================='
"점검 대상 OS: Windows"
"보고서 생성 시각: $((Get-Date).ToString($Fmt))"
"점검 기간: 최근 ${CheckDays}일 ($($Since.ToString($Fmt)) 부터)"

# ! --- 1. 시스템 기본 상태 및 리소스 ---
Print-Header '1. 시스템 기본 상태 및 리소스'

$os = $null
try {
    $os = Get-CimInstance Win32_OperatingSystem
    "운영체제: $($os.Caption) (빌드 $($os.BuildNumber))"
    "최근 재부팅 시각: $($os.LastBootUpTime.ToString($Fmt))"
    $up = (Get-Date) - $os.LastBootUpTime
    "서버 가동 시간:   $($up.Days)일 $($up.Hours)시간 $($up.Minutes)분"
} catch { Query-Failed "운영체제 정보 조회 실패: $_" }

# @ 시간이 어긋나면 로그 기간 판단과 인증서 검증이 틀어진다.
'시간 동기화(w32tm /query /status):'
try {
    $w32svc = Get-Service W32Time
    "  W32Time 서비스: $($w32svc.Status) (시작 유형 $($w32svc.StartType))"
    # * 서비스가 멈춰 있으면 w32tm 조회 자체가 실패한다. 수집 실패가 아니라 동기화 중지로 기록한다.
    if ($w32svc.Status -ne 'Running') { throw [System.OperationCanceledException]'W32Time 중지' }
    $w32 = Invoke-Native { w32tm /query /status }
    if ($LASTEXITCODE -ne 0) { Query-Failed "w32tm 조회 실패 (종료 코드 $LASTEXITCODE)" }
    $w32 | Where-Object { $_.Trim() } | ForEach-Object { "  $_" }
} catch [System.OperationCanceledException] { '  시간 동기화: 안 됨 (W32Time 서비스 중지)' }
catch { Query-Failed "시간 동기화 조회 실패: $_" }
Separator

# @ Windows 는 sar 같은 기본 이력이 없어 현재값만 수집한다.
'시스템 부하 (현재값, 1초 간격 5회):'
'  (Windows: 기간 이력 미수집. 일별 부하·메모리 이력 없음)'
try {
    $cores = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    $samples = 1..5 | ForEach-Object {
        $cpu = (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
        $q = (Get-CimInstance Win32_PerfFormattedData_PerfOS_System).ProcessorQueueLength
        Start-Sleep -Seconds 1
        [pscustomobject]@{ Cpu = $cpu; Queue = $q }
    }
    "  논리 코어 수: $cores"
    "  CPU 사용률(%): " + (($samples | ForEach-Object Cpu) -join ', ')
    "  프로세서 대기열 길이: " + (($samples | ForEach-Object Queue) -join ', ') + "  (코어 수의 2배 이상이 지속되면 과부하)"
} catch { Query-Failed "CPU 부하 조회 실패: $_" }
Separator

'메모리 사용량:'
try {
    $total = [double]$os.TotalVisibleMemorySize; $free = [double]$os.FreePhysicalMemory
    $pct = [math]::Round(100 * ($total - $free) / $total)
    $mark = if ($pct -ge $WarningThreshold) { '  [경고 임계값 초과]' } else { '' }
    "  현재 메모리 사용률: ${pct}% (전체 $([math]::Round($total/1MB,1))GB / 사용 가능 $([math]::Round($free/1MB,1))GB)$mark"
    $commitPct = [math]::Round(100 * ($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / $os.TotalVirtualMemorySize)
    "  커밋 사용률(물리+페이지 파일): ${commitPct}%"
    Get-CimInstance Win32_PageFileUsage | ForEach-Object {
        "  페이지 파일 $($_.Name): 할당 $($_.AllocatedBaseSize)MB / 현재 $($_.CurrentUsage)MB / 최대 $($_.PeakUsage)MB"
    }
} catch { Query-Failed "메모리 조회 실패: $_" }
Separator

'디스크 사용량 (로컬 고정 디스크):'
$disks = $null
try {
    $disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3')
    '  드라이브  파일시스템  전체(GB)  여유(GB)  사용률'
    foreach ($d in $disks) {
        if (-not $d.Size) { continue }
        $p = [math]::Round(100 * ($d.Size - $d.FreeSpace) / $d.Size)
        $mark = if ($p -ge 90) { '  [위험]' } elseif ($p -ge $WarningThreshold) { '  [경고]' } else { '' }
        '  {0,-8}  {1,-10}  {2,8:N1}  {3,8:N1}  {4,5}%{5}' -f $d.DeviceID, $d.FileSystem, ($d.Size/1GB), ($d.FreeSpace/1GB), $p, $mark
    }
} catch { Query-Failed "디스크 조회 실패: $_" }

# ! --- 2. 프로세스 및 네트워크 상태 ---
Print-Header '2. 프로세스 및 네트워크 상태'

try {
    $procs = @(Get-Process)
    "총 프로세스 개수: $($procs.Count)"
    ''
    '메모리 사용 상위 15개 프로세스 (WorkingSet MB / 누적 CPU 초):'
    $procs | Sort-Object WorkingSet64 -Descending | Select-Object -First 15 | ForEach-Object {
        $cpuSec = if ($_.CPU) { [math]::Round($_.CPU) } else { 0 }
        '  {0,-30} PID {1,-7} {2,8:N0}MB {3,10}s' -f $_.ProcessName, $_.Id, ($_.WorkingSet64/1MB), $cpuSec
    }
} catch { Query-Failed "프로세스 조회 실패: $_" }
Separator

# @ 프로세스 이름별로 묶어 한 줄로 낸다. (리눅스판과 같은 방식)
$procName = @{}
try { Get-Process | ForEach-Object { $procName[[int]$_.Id] = $_.ProcessName } } catch { }
$portLines = @()
'리스닝 포트 (프로토콜 주소:포트 프로세스):'
try {
    $tcp = Get-NetTCPConnection -State Listen | ForEach-Object { [pscustomobject]@{ P = 'tcp'; A = $_.LocalAddress; Port = $_.LocalPort; Pid = $_.OwningProcess } }
    $udp = Get-NetUDPEndpoint | ForEach-Object { [pscustomobject]@{ P = 'udp'; A = $_.LocalAddress; Port = $_.LocalPort; Pid = $_.OwningProcess } }
    # * UDP 동적 포트(49152 이상)는 실행 때마다 바뀌어 비교 잡음이 되므로 뺀다.
    $portLines = @($tcp) + @($udp) | Where-Object { $_.P -eq 'tcp' -or $_.Port -lt 49152 } | ForEach-Object {
        $addr = if ($_.A -match ':') { "[$($_.A)]:$($_.Port)" } else { "$($_.A):$($_.Port)" }
        $name = if ($procName.ContainsKey([int]$_.Pid)) { $procName[[int]$_.Pid] } else { "pid$($_.Pid)" }
        [pscustomobject]@{ Key = "$($_.P) $addr"; Name = $name; P = $_.P; Port = $_.Port }
    } | Sort-Object P, Port, Key -Unique
    $portLines | ForEach-Object { '  {0,-32} {1}' -f $_.Key, $_.Name }
} catch { Query-Failed "포트 조회 실패: $_" }
Separator

# @ 자동 시작인데 멈춘 서비스. 종료 코드가 0이 아닌 것이 실제 실패다.
'자동 시작이지만 실행 중이 아닌 서비스 (종료 코드 0 이 아닌 것 먼저):'
try {
    $svc = @(Get-CimInstance Win32_Service -Filter "StartMode='Auto' AND State<>'Running'")
    if ($svc.Count -eq 0) { '  없음' }
    $svc | Sort-Object @{ e = { $_.ExitCode -eq 0 } }, Name | ForEach-Object {
        '  {0,-32} 종료코드 {1,-6} {2}' -f $_.Name, $_.ExitCode, $_.DisplayName
    }
} catch { Query-Failed "서비스 조회 실패: $_" }

# ! --- 3. 보안 및 이상 징후 점검 ---
Print-Header '3. 보안 및 이상 징후 점검'

# @ 임시 디렉토리: 디렉토리별 파일 수·크기, 점검 기간 안에 생긴 실행형 파일
'임시 디렉토리 현황:'
$tempDirs = @("$env:SystemRoot\Temp") + @(Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName 'AppData\Local\Temp' } | Where-Object { Test-Path $_ })
$execExt = '.exe', '.dll', '.ps1', '.bat', '.cmd', '.vbs', '.js', '.hta', '.scr', '.msi'
$recentExec = @()
foreach ($dir in $tempDirs) {
    try {
        $files = @(Get-ChildItem $dir -File -Recurse -Force -ErrorAction SilentlyContinue)
        $size = ($files | Measure-Object Length -Sum).Sum
        '  {0}: {1}개 / {2:N1}MB' -f $dir, $files.Count, ($size/1MB)
        # * 실행 중인 점검 스크립트 자신(임시 파일)은 뺀다.
        $recentExec += $files | Where-Object { $_.LastWriteTime -ge $Since -and $execExt -contains $_.Extension.ToLower() -and $_.FullName -ne $PSCommandPath }
    } catch { Query-Failed "임시 디렉토리 조회 실패 ${dir}: $_" }
}
''
"최근 ${CheckDays}일 임시 디렉토리에 생긴 실행형 파일 (최근 100건, 총 $($recentExec.Count)건):"
if ($recentExec.Count -eq 0) { '  없음' }
$recentExec | Sort-Object LastWriteTime -Descending | Select-Object -First 100 | ForEach-Object {
    '  {0}  {1,10:N0}B  {2}' -f $_.LastWriteTime.ToString($Fmt), $_.Length, $_.FullName
}
Separator

'로컬 계정:'
$users = @()
try {
    $users = @(Get-LocalUser)
    $users | ForEach-Object {
        $last = if ($_.LastLogon) { $_.LastLogon.ToString($Fmt) } else { '없음' }
        $pw = if ($_.PasswordLastSet) { $_.PasswordLastSet.ToString($Fmt) } else { '없음' }
        '  {0,-20} 활성 {1,-5} 마지막 로그온 {2,-19} 비밀번호 변경 {3,-19} 비밀번호 필요 {4}' -f $_.Name, $_.Enabled, $last, $pw, $_.PasswordRequired
    }
} catch { Query-Failed "로컬 계정 조회 실패: $_" }
''
$admins = @()
foreach ($g in 'Administrators', 'Remote Desktop Users') {
    "$g 그룹 구성원:"
    try {
        $m = @(Get-LocalGroupMember -SID $(if ($g -eq 'Administrators') { 'S-1-5-32-544' } else { 'S-1-5-32-555' }))
        if ($g -eq 'Administrators') { $admins = $m }
        if ($m.Count -eq 0) { '  없음' }
        $m | ForEach-Object { "  $($_.Name) ($($_.ObjectClass), $($_.PrincipalSource))" }
    } catch { Query-Failed "$g 그룹 조회 실패: $_" }
}
Separator

'보안 업데이트 / 백신:'
try {
    $hf = @(Get-HotFix | Where-Object InstalledOn | Sort-Object InstalledOn -Descending)
    if ($hf.Count) { "  마지막 업데이트 설치: $($hf[0].InstalledOn.ToString('yyyy-MM-dd')) ($($hf[0].HotFixID)), 최근 5건: " + (($hf | Select-Object -First 5 | ForEach-Object HotFixID) -join ', ') }
    else { '  설치 기록 없음' }
} catch { Query-Failed "업데이트 기록 조회 실패: $_" }
if (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue) {
    try {
        $mp = Get-MpComputerStatus
        "  Defender 실시간 보호: $($mp.RealTimeProtectionEnabled), 백신 정의 갱신: $($mp.AntivirusSignatureLastUpdated.ToString($Fmt))"
    } catch { "  Defender 상태 확인 불가: $($_.Exception.Message)" }
} else { '  Defender 모듈 없음 (다른 백신 사용 여부는 수집하지 않음)' }

# ! --- 4. 로그 및 이벤트 분석 ---
Print-Header '4. 로그 및 이벤트 분석'

# @ 재부팅·종료 관련 이벤트: 6005 시작, 6006 정상 종료, 6008 비정상 종료, 41 전원 손실, 1074 종료 요청자
"최근 ${CheckDays}일 재부팅/종료 이벤트 (최근 30건):"
try {
    $boot = Get-Events @{ LogName = 'System'; Id = 41, 1074, 6005, 6006, 6008; StartTime = $Since } 200
    if ($boot.Count -eq 0) { '  없음' }
    $boot | Select-Object -First 30 | ForEach-Object { '  ' + (Event-Line $_) }
} catch { Query-Failed "재부팅 이벤트 조회 실패: $_" }
Separator

# @ 리눅스판의 커널 경고 자리에 System 로그 경고를 묶어 낸다.
"최근 ${CheckDays}일 System 로그 경고 요약 (같은 메시지 묶음, 숫자는 #, 많은 순 20종):"
try {
    $warn = Get-Events @{ LogName = 'System'; Level = 3; StartTime = $Since } 5000
    Group-Count ($warn | ForEach-Object { Event-Key $_ }) 20
} catch { Query-Failed "System 경고 로그 조회 실패: $_" }
Separator

# @ 기간이 길어 원문만으로는 분량이 넘치므로, 같은 메시지를 묶은 요약과 최근 원문을 함께 낸다.
$errors = @()
try {
    $errors = @(Get-Events @{ LogName = 'System', 'Application'; Level = 1, 2; StartTime = $Since } 5000 | Sort-Object TimeCreated -Descending)
} catch { Query-Failed "시스템 오류 로그 조회 실패: $_" }
"최근 ${CheckDays}일 시스템 오류 이상 로그 요약 (System·Application 치명/오류, 같은 메시지 묶음, 숫자는 #, 많은 순 50종):"
Group-Count ($errors | ForEach-Object { Event-Key $_ }) 50
''
"최근 ${CheckDays}일 시스템 오류 이상 로그 원문 (최근 50건):"
$errors | Select-Object -First 50 | ForEach-Object { '  ' + (Event-Line $_) }
Separator

# @ 로그인 성공: 4624 중 사람이 관여하는 유형만 (2 대화형, 3 네트워크, 7 잠금해제, 10 원격데스크톱, 11 캐시)
# * 컴퓨터 계정($)과 익명 로그온은 제외한다.
$logonTypes = @{ '2' = '대화형'; '3' = '네트워크'; '7' = '잠금해제'; '10' = '원격데스크톱'; '11' = '캐시' }
"최근 ${CheckDays}일 성공한 로그인:"
try {
    $ok = Get-Events @{ LogName = 'Security'; Id = 4624; StartTime = $Since } 20000 | ForEach-Object {
        $p = $_.Properties
        [pscustomobject]@{ T = $_.TimeCreated; User = "$($p[6].Value)\$($p[5].Value)"; Type = "$($p[8].Value)"; Ip = "$($p[18].Value)" }
    } | Where-Object { $logonTypes.ContainsKey($_.Type) -and $_.User -notmatch '\$$' -and $_.User -notmatch 'ANONYMOUS LOGON' }
    '  [계정 / 유형 / 접속지별 건수]'
    Group-Count ($ok | ForEach-Object { "$($_.User) $($logonTypes[$_.Type]) $($_.Ip)" }) 30
    '  [최근 50건]'
    $ok | Select-Object -First 50 | ForEach-Object { '  {0} {1} {2} {3}' -f $_.T.ToString($Fmt), $_.User, $logonTypes[$_.Type], $_.Ip }
} catch { Query-Failed "로그인 성공 기록 조회 실패: $_" }
''

# @ 로그인 실패: 4625 (SSH·원격데스크톱·네트워크 공통). 시도 1회당 1건.
$failCount = $null
try {
    $fail = @(Get-Events @{ LogName = 'Security'; Id = 4625; StartTime = $Since } 20000)
    $failCount = $fail.Count
    "최근 ${CheckDays}일 로그인 실패 건수(4625): $failCount"
    if ($failCount) {
        '  [계정 / 접속지별 건수, 상위 20]'
        Group-Count ($fail | ForEach-Object { "$($_.Properties[6].Value)\$($_.Properties[5].Value) $($_.Properties[19].Value)" }) 20
    }
} catch { Query-Failed "로그인 실패 기록 조회 실패: $_"; '로그인 실패 건수: 확인 불가' }
''

# ! --- 5. 비교용 SNAPSHOT ---
# @ compare.py가 지난 점검과 비교하는 값. 한 줄에 "키 값" 형식, 키: disk port user sudo boot sshfail
'### SNAPSHOT ###'
if ($disks) { $disks | Where-Object Size | ForEach-Object { "disk $($_.DeviceID) $([math]::Round(100 * ($_.Size - $_.FreeSpace) / $_.Size))" } }
else { Query-Failed '디스크 스냅샷 조회 실패'; 'SNAPSHOT_FIELD_FAILED disk' }
if ($portLines) { $portLines | ForEach-Object { "port $($_.Key)" } | Sort-Object -Unique }
else { Query-Failed '포트 스냅샷 조회 실패'; 'SNAPSHOT_FIELD_FAILED port' }
if ($users) { $users | ForEach-Object { "user $($_.Name)" + $(if (-not $_.Enabled) { ' (비활성)' } else { '' }) } }
else { Query-Failed '계정 스냅샷 조회 실패'; 'SNAPSHOT_FIELD_FAILED user' }
if ($admins) { $admins | ForEach-Object { "sudo Administrators $($_.Name)" } | Sort-Object -Unique }
else { Query-Failed '관리자 그룹 스냅샷 조회 실패'; 'SNAPSHOT_FIELD_FAILED sudo' }
if ($os) { "boot $($os.LastBootUpTime.ToString($Fmt))" }
else { Query-Failed '부팅 시각 조회 실패'; 'SNAPSHOT_FIELD_FAILED boot' }
if ($null -ne $failCount) { "sshfail $failCount" } else { 'SNAPSHOT_FIELD_FAILED sshfail' }
'### END SNAPSHOT ###'
''
'================================================='
'보고서 생성이 완료되었습니다.'
'================================================='

# 수집 완전성은 표식과 종료 코드로 함께 전달한다.
"### COLLECTION_ERRORS $($script:CheckErrors) ###"
exit $(if ($script:CheckErrors -eq 0) { 0 } else { 1 })
