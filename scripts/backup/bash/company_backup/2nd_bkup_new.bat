@ECHO OFF
SETLOCAL EnableDelayedExpansion

cd D:\Backup\00_infra_utils\cwrsync\bin

REM --- Global Settings ---
SET EXCLUDE_LIST_WIN="D:\Backup\00_infra_utils\user\rsync_exclude.txt"
SET EXCLUDE_LIST_CYG="/cygdrive/D/Backup/00_infra_utils/user/rsync_exclude.txt"
rem 삭제할 파일의 기준 나이 (일 단위)
set MAX_AGE_DAYS=150

REM --- Backup Job Calls ---
CALL :ProcessBackup "DK_Solo_Srv_RDBLogServer_CsvLogPath" "_Server_Solo\RDBLogServer\CsvLogPath" "Solo/RDBLogServer/CsvLogPath"
CALL :ProcessBackup "DK_Solo_Srv_RDBLogServer_Log" "_Server_Solo\RDBLogServer\Log" "Solo/RDBLogServer/Log"
CALL :ProcessBackup "DK_Solo_Srv_RGameServer" "_Server_Solo\RGameServer\Log" "Solo/RGameServer"
CALL :ProcessBackup "DK_Solo_Srv_RPcBangServer" "_Server_Solo\RPcBangServer\Log" "Solo/RPcBangServer"

GOTO :EOF

REM =================================================================
REM Backup Subroutine
REM =================================================================
:ProcessBackup
SET "SRV_FILE_NAME_BASE=%~1"
SET "SOURCE_SUB_DIR=%~2"
SET "REMOTE_SUB_DIR=%~3"

SET "SRV_FILE_NAME=%SRV_FILE_NAME_BASE%.txt"
SET "LOCAL_STATUS_FILE=D:\Backup\00_infra_utils\user\%SRV_FILE_NAME%"
SET "SOURCE_LOG_DIR=D:\Backup\%SOURCE_SUB_DIR%"
SET "SENT_LOG_DIR=D:\Backup\sent_log\%SOURCE_SUB_DIR%"

rem 보낸 파일을 이동시킬 폴더가 없으면 생성
if not exist "%SENT_LOG_DIR%" (
    mkdir "%SENT_LOG_DIR%"
)

rem 오래된 파일 삭제 (이동된 폴더 대상)
forfiles /P "%SENT_LOG_DIR%" /S /M *.* /D -%MAX_AGE_DAYS% /C "cmd /c del @path"

REM --- 1. rsync에서 제외할 오늘 날짜 파일 목록 생성 ---
IF EXIST %EXCLUDE_LIST_WIN% DEL %EXCLUDE_LIST_WIN%
powershell -NoProfile -Command "Get-ChildItem -Path '%SOURCE_LOG_DIR%' -Recurse -File | Where-Object { $_.CreationTime.Date -eq (Get-Date).Date } | ForEach-Object { $_.FullName.Substring([System.IO.Path]::GetFullPath('%SOURCE_LOG_DIR%').TrimEnd('\').Length).TrimStart('\').Replace('\', '/') }" > %EXCLUDE_LIST_WIN%

REM --- 2. rsync 명령어 실행 (오늘 날짜 파일 제외) ---
SET "SOURCE_CYG_PATH=/cygdrive/d/Backup/%SOURCE_SUB_DIR%"
SET "SOURCE_CYG_PATH=!SOURCE_CYG_PATH:\=/!"
rsync -avzh --bwlimit=10240 --exclude-from=%EXCLUDE_LIST_CYG% "!SOURCE_CYG_PATH!/" ::log_dk/%REMOTE_SUB_DIR%
REM 원본 위: 내부 rsync 서버 IP (x.x.x.x)

REM rsync 명령어의 종료 코드를 확인
rem --- 3. rsync 성공 시 전송된 파일만 이동 (폴더 구조는 유지) ---
IF !ERRORLEVEL! EQU 0 (
    REM 성공 -> rsync를 사용하여 오늘 생성된 파일을 제외하고 sent_log 폴더로 이동
    SET "SENT_CYG_PATH=/cygdrive/d/Backup/sent_log/%SOURCE_SUB_DIR%"
    SET "SENT_CYG_PATH=!SENT_CYG_PATH:\=/!"
    rsync -a --remove-source-files --exclude-from=%EXCLUDE_LIST_CYG% "!SOURCE_CYG_PATH!/" "!SENT_CYG_PATH!/"

    REM 임시 제외 목록 파일 삭제
    IF EXIST %EXCLUDE_LIST_WIN% DEL %EXCLUDE_LIST_WIN%
) ELSE (
    REM 실패 -> 상태 파일을 생성
    ECHO !ERRORLEVEL! > "%LOCAL_STATUS_FILE%"

    REM 상태 파일을 백업 서버2로 전송
    rsync -avzh --bwlimit=10240 "/cygdrive/D/Backup/00_infra_utils/user/%SRV_FILE_NAME%" ::backupuser  # 원본: rsync 모듈명
    REM 원본 위: 내부 rsync 서버 IP (x.x.x.x)

    REM 상태 파일 전송 성공 시 로컬 파일 삭제
    IF !ERRORLEVEL! EQU 0 (
        DEL "%LOCAL_STATUS_FILE%"
    )
)
GOTO :EOF

endlocal
