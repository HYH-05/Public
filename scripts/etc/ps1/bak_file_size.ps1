# 수정 해야할 것
$RootFolder = "D:\Backup\Backup\AO\DB"
$LogFile = "./AO_DB.txt"

# 파일 크기, 개수 저장
$TotalSize = 0
$TotalCount = 0

# 작업 폴더 아래 폴더들을 순회
Get-ChildItem -Path $RootFolder -Directory | ForEach-Object {
    $Folder = $_
    Write-Host ""
    "" | Out-File -Append $LogFile
    Write-Host "폴더: $($Folder.Name)"
    "폴더: $($Folder.Name)" | Out-File -Append $LogFile

    # .bak 파일 크기 및 개수
    $FolderSize = 0
    $FolderCount = 0
    Get-ChildItem -Path "$($Folder.FullName)\*.bak" -File | ForEach-Object {
        $File = $_
        $FolderSize += $File.Length
        $FolderCount++
        Write-Host "  - $($File.FullName) ($($File.Length) 바이트)"
        "  - $($File.FullName) ($($File.Length) 바이트)" | Out-File -Append $LogFile
    }
    Write-Host "  폴더 총 크기: $FolderSize 바이트"
    "  폴더 총 크기: $FolderSize 바이트" | Out-File -Append $LogFile
    Write-Host "  폴더 총 파일 개수: $FolderCount 개"
    "  폴더 총 파일 개수: $FolderCount 개" | Out-File -Append $LogFile

    $TotalSize += $FolderSize
    $TotalCount += $FolderCount
}

Write-Host ""
"" | Out-File -Append $LogFile
Write-Host "============================="
"=============================" | Out-File -Append $LogFile
Write-Host "전체 .bak 파일 총 크기: $TotalSize 바이트"
"전체 .bak 파일 총 크기: $TotalSize 바이트" | Out-File -Append $LogFile
Write-Host "전체 .bak 파일 총 개수: $TotalCount 개"
"전체 .bak 파일 총 개수: $TotalCount 개" | Out-File -Append $LogFile
Write-Host "============================="
"=============================" | Out-File -Append $LogFile

# (선택 사항) 더 읽기 쉽게
function Format-FileSize {
    param(
        [Parameter(Mandatory=$true)]
        [int64]$Bytes
    )
    $Units = "B", "KB", "MB", "GB", "TB", "PB"
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt $Units.Length - 1) {
        $Bytes /= 1024
        $i++
    }
    return "{0:N2} $($Units[$i])" -f $Bytes
}

#Write-Host ""
#"" | Out-File -Append $LogFile 
#Write-Host "전체 .bak 파일 총 크기 (변환): $(Format-FileSize $TotalSize)"
#"전체 .bak 파일 총 크기 (변환): $(Format-FileSize $TotalSize)" | Out-File -Append $LogFile

Pause