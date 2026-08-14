<#
# ! 중요 정보, 코드 요약 등
# @ 일반 정보(로직 설명)
# * 규칙, 정책 등
# // 폐기(미사용) 코드
# TODO: 해야할 일(작업 리스트)
#>

<#
.SYNOPSIS
  # ! Windows 서버의 핵심 시스템 상태, 보안, 로그를 종합적으로 점검하고,
  # ! 한눈에 보기 쉬운 요약 보고서를 생성합니다.

.DESCRIPTION
  # ! 1. 시스템 재부팅 여부, 부하, 디스크, 메모리 등 핵심 리소스 상태를 점검합니다.
  # ! 2. 실행 중인 프로세스와 리스닝 포트 상태를 확인합니다.
  # ! 3. 임시 디렉토리, 사용자 계정 등 기본적인 보안 항목을 점검합니다.
  # ! 4. 시스템 및 보안 이벤트 로그에서 주요 오류나 경고, 로그인 시도를 요약합니다.

.NOTES
  # ! - [중요] 이 스크립트 파일을 저장할 때, 인코딩을 반드시 'UTF-8 with BOM'으로 지정해야 한글이 깨지지 않고 정상적으로 실행됩니다.
    # ! - [대안] 영어로 수정
  # ! - [참고] 이 스크립트 파일을 실행할 때, 관리자 권한으로 실행해야 로그인 시도 기록이 보입니다.
    # ! - powershell.exe -ExecutionPolicy Bypass -File "C:\경로\스크립트_이름.ps1"
#>

# ! --- [1. 기본 설정] ---

# @ 디스크 및 메모리 사용량 경고 임계값 (%)
$WarningThreshold = 80
$CriticalThreshold = 90

# ! --- [2. 헬퍼 함수] ---

# @ 헤더 출력 함수
function Print-Header($title) {
    Write-Host "`n>> $($title)" -ForegroundColor Yellow
    Write-Host "================================================="
}

# ! --- [3. 메인 실행부] ---

Clear-Host
Write-Host "================================================="
Write-Host " Windows 서버 일일 시스템 상태 점검 보고서"
Write-Host "================================================="
Write-Host "보고서 생성 시각: $(Get-Date)"

# ! --- 1. 시스템 기본 상태 및 리소스 ---
Print-Header "1. 시스템 기본 상태 및 리소스"

# @ 재부팅 여부 확인
$osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
$uptime = (Get-Date) - $osInfo.LastBootUpTime
Write-Host "최근 재부팅 시각: $($osInfo.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "서버 가동 시간:   $($uptime.Days)일 $($uptime.Hours)시간 $($uptime.Minutes)분"
Write-Host ""
Write-Host "-------------------------------------------------"
Write-Host ""

# @ 시스템 부하 확인 (Processor Queue Length)
$procQueue = (Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_System).ProcessorQueueLength
$cpuCores = (Get-CimInstance -ClassName Win32_Processor).NumberOfLogicalProcessors
Write-Host "논리 프로세서(코어) 수: $cpuCores"
Write-Host "시스템 부하 (Processor Queue Length): $procQueue"
Write-Host "(참고: CPU 코어 수보다 지속적으로 높을 경우 부하가 심한 상태)"
Write-Host "    (과거 지표는 zabbix 등 참고)"
Write-Host ""
Write-Host "-------------------------------------------------"
Write-Host ""


# @ 메모리 사용량 확인
$totalMemoryGB = [math]::Round($osInfo.TotalVisibleMemorySize / 1MB, 2)
$freeMemoryGB = [math]::Round($osInfo.FreePhysicalMemory / 1MB, 2)
$usedMemoryGB = $totalMemoryGB - $freeMemoryGB
$memUsagePercent = [math]::Round(($usedMemoryGB / $totalMemoryGB) * 100)

Write-Host "메모리 사용량:"
Write-Host "  전체: $($totalMemoryGB) GB"
Write-Host "  사용 중: $($usedMemoryGB) GB"
Write-Host "  사용 가능: $($freeMemoryGB) GB"

if ($memUsagePercent -ge $CriticalThreshold) {
    Write-Host "메모리 사용 상태: $($memUsagePercent)% " -NoNewline; Write-Host "[CRITICAL]" -ForegroundColor Red
} elseif ($memUsagePercent -ge $WarningThreshold) {
    Write-Host "메모리 사용 상태: $($memUsagePercent)% " -NoNewline; Write-Host "[WARNING]" -ForegroundColor Yellow
} else {
    Write-Host "메모리 사용 상태: $($memUsagePercent)% " -NoNewline; Write-Host "[OK]" -ForegroundColor Green
}
Write-Host ""

# @ 스왑(페이지 파일) 사용량 확인
Write-Host "스왑(페이지 파일) 사용량:"
$pageFiles = Get-CimInstance -ClassName Win32_PageFileUsage
if ($pageFiles) {
    foreach ($pageFile in $pageFiles) {
        $totalPageFileMB = $pageFile.AllocatedBaseSize
        $usedPageFileMB = $pageFile.CurrentUsage
        $pageFileUsagePercent = if ($totalPageFileMB -gt 0) { [math]::Round(($usedPageFileMB / $totalPageFileMB) * 100) } else { 0 }

        if ($pageFileUsagePercent -ge $CriticalThreshold) {
            $status = "[CRITICAL]"; $color = "Red"
        } elseif ($pageFileUsagePercent -ge $WarningThreshold) {
            $status = "[WARNING]"; $color = "Yellow"
        } else {
            $status = "[OK]"; $color = "Green"
        }
        Write-Host "  $($pageFile.Name) | 전체: $($totalPageFileMB)MB | 사용 중: $($usedPageFileMB)MB | 사용률: $($pageFileUsagePercent)% " -NoNewline
        Write-Host $status -ForegroundColor $color
    }
} else {
    Write-Host "  (페이지 파일이 구성되지 않았습니다.)"
}
Write-Host ""
Write-Host "-------------------------------------------------"
Write-Host ""

# @ 디스크 사용량 확인
Write-Host "디스크 사용량:"
Get-CimInstance -ClassName Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 } | ForEach-Object {
    $diskSizeGB = [math]::Round($_.Size / 1GB, 2)
    $freeSpaceGB = [math]::Round($_.FreeSpace / 1GB, 2)
    $usagePercent = [math]::Round((($diskSizeGB - $freeSpaceGB) / $diskSizeGB) * 100)

    if ($usagePercent -ge $CriticalThreshold) {
        $status = "[CRITICAL]"
        $color = "Red"
    } elseif ($usagePercent -ge $WarningThreshold) {
        $status = "[WARNING]"
        $color = "Yellow"
    } else {
        $status = "[OK]"
        $color = "Green"
    }
    Write-Host "$($_.DeviceID) | 파일시스템: $($_.FileSystem) | 전체: $($diskSizeGB)GB | 사용 가능: $($freeSpaceGB)GB | 사용률: $($usagePercent)% " -NoNewline
    Write-Host $status -ForegroundColor $color
}
Write-Host ""

# ! --- 2. 프로세스 및 네트워크 상태 ---
Print-Header "2. 프로세스 및 네트워크 상태"

# @ 총 프로세스 개수 확인
$totalProcesses = (Get-Process).Count
Write-Host "총 프로세스 개수: $totalProcesses"
Write-Host ""

# @ 상위 프로세스 확인 (pstree 대안)
Write-Host "CPU 사용량 상위 10개 프로세스:"
Get-Process | Sort-Object CPU -Descending | Select-Object -First 10 | Format-Table -AutoSize
Write-Host ""
Write-Host "메모리(WS) 사용량 상위 10개 프로세스:"
Get-Process | Sort-Object WS -Descending | Select-Object -First 10 | Format-Table -AutoSize
Write-Host ""
Write-Host "-------------------------------------------------"
Write-Host ""

# @ 리스닝 포트 확인
Write-Host "연결 대기중인 네트워크 포트 (TCP):"
Get-NetTCPConnection -State Listen | Select-Object LocalAddress, LocalPort, OwningProcess | Format-Table -AutoSize
Write-Host ""

# ! --- 3. 보안 및 이상 징후 점검 ---
Print-Header "3. 보안 및 이상 징후 점검"

# // # @ 임시 디렉토리 내 파일 확인
# // Write-Host "임시 디렉토리($($env:TEMP)) 내 파일 (숨김 파일/디렉토리 제외):"
# // $tempFiles = Get-ChildItem -Path $env:TEMP -File -Force
# // if ($tempFiles) {
# //     $tempFiles | Select-Object Name, Length, LastWriteTime
# // } else {
# //     Write-Host "  (발견된 파일 없음)"
# // }
# // Write-Host ""
# // Write-Host "-------------------------------------------------"
# // Write-Host ""

# @ 임시 디렉토리를 사용 중인 프로세스 확인 (lsof 대안)
Write-Host "임시 디렉토리 파일을 사용중인 프로세스 (간략):"
Write-Host "  (정밀한 확인은 외부 도구 사용)"
Get-Process | Where-Object { $_.Path -like "$($env:TEMP)\*" } | Select-Object Name, Path | Format-Table -AutoSize
Write-Host ""
Write-Host "-------------------------------------------------"
Write-Host ""

# @ 사용자 계정 확인
Write-Host "로컬 사용자 계정 목록:"
Get-LocalUser | Format-Table Name, Enabled, LastLogon
Write-Host ""
Write-Host "-------------------------------------------------"
Write-Host ""

Write-Host "로컬 그룹 목록:"
Get-LocalGroup | Format-Table Name
Write-Host ""

# ! --- 4. 로그 및 이벤트 분석 ---
Print-Header "4. 로그 및 이벤트 분석"

# @ 시스템 로그 내 주요 오류/경고 확인 (dmesg, /var/log/messages 대안)
Write-Host "최근 시스템 오류/경고 이벤트 (상위 50개):"
Get-WinEvent -FilterHashtable @{LogName='System'; Level=1,2,3;} | Select-Object -First 50 | Format-Table TimeCreated, ProviderName, Message -Wrap -AutoSize
Write-Host ""

# @ 최근 로그인 기록 확인 (last 대안)
Write-Host "최근 성공한 로그인 50건 (이벤트 ID 4624):"
try {
    Get-WinEvent -FilterHashtable @{LogName='Security'; ID=4624; StartTime=(Get-Date).AddDays(-1)} -ErrorAction Stop | Select-Object -First 50 | Select-Object TimeCreated, @{N='User';E={$_.Properties[5].Value}}, @{N='LogonType';E={$_.Properties[8].Value}}, @{N='SourceIP';E={$_.Properties[18].Value}} | Format-Table -AutoSize
}
catch {
    Write-Warning "보안 로그를 읽는 중 오류가 발생했습니다. 스크립트를 관리자 권한으로 실행했는지 확인해주세요."
    Write-Warning "오류 메시지: $($_.Exception.Message)"
}
Write-Host ""

Write-Host "================================================="
Write-Host "보고서 생성이 완료되었습니다."

pause