@ECHO OFF
SETLOCAL EnableDelayedExpansion

cd D:\Backup\00_infra_utils\cwrsync\bin

REM --- 전역 설정 (Global Settings) ---
SET "BASE_SOURCE_DIR=D:\Backup"
SET "BASE_SENT_DIR=D:\Backup\sent_log"
SET "BASE_STATUS_DIR=D:\Backup\00_infra_utils\user"
SET "MAX_AGE_DAYS=150"

REM PRIMARY는 백업 파일 전송할 서버 / SECONDARY는 상태 파일 전송할 서버
SET "REMOTE_HOST_PRIMARY=xx.xx.xx.xx"
SET "REMOTE_HOST_SECONDARY=xx.xx.xx.xx"

REM rsync 제외 목록 파일 경로 설정 (Windows 및 Cygwin 형식)
SET "EXCLUDE_LIST_WIN=%BASE_STATUS_DIR%\rsync_exclude.txt"
SET "EXCLUDE_LIST_CYG=/cygdrive/d/Backup/00_infra_utils/user/rsync_exclude.txt"
REM --- 수동으로 제외할 파일/패턴 목록 파일 ---
SET "MANUAL_EXCLUDE_LIST=%BASE_STATUS_DIR%\manual_exclude.txt"

REM --- 백업 작업 호출 (Backup Job Calls) ---
REM 사용법: CALL :ProcessBackup "작업이름" "원본하위경로" "원격모듈" "원격하위경로"
CALL :ProcessBackup "SR_Game_AuthServer"    "Server\AuthServer\ZoneServer_KR_Log"      "game_log_sr" "AuthServer"
CALL :ProcessBackup "SR_Game_BareaServer"   "Server\BareaServer\ZoneServer_KR_Log"     "game_log_sr" "BareaServer"
CALL :ProcessBackup "SR_Game_GameServer"    "Server\GameServer\ZoneServer_KR_Log"      "game_log_sr" "GameServer"
CALL :ProcessBackup "SR_Game_RankServer"    "Server\RankServer\ZoneServer_KR_Log"      "game_log_sr" "RankServer"
CALL :ProcessBackup "SR_Game_TrafficServer" "Server\TrafficServer\TrafficAgent_Log"    "game_log_sr" "TrafficServer"
CALL :ProcessBackup "SR_Game_LobbyServer"   "Server\LobbyServer\ZoneServer_KR_Log"     "game_log_sr" "LobbyServer"

ENDLOCAL
GOTO :EOF

REM =================================================================
REM 백업 서브루틴 (Backup Subroutine)
REM =================================================================
:ProcessBackup
SET "JOB_NAME=%~1"
SET "SOURCE_SUB_DIR=%~2"
SET "REMOTE_MODULE=%~3"
SET "REMOTE_SUB_DIR=%~4"

ECHO.
ECHO --- 작업 시작: %JOB_NAME% ---

REM --- 이 작업에 대한 경로 설정 ---
SET "SOURCE_LOG_DIR=%BASE_SOURCE_DIR%\%SOURCE_SUB_DIR%"
SET "SENT_LOG_DIR=%BASE_SENT_DIR%\%SOURCE_SUB_DIR%"
SET "SRV_FILE_NAME=%JOB_NAME%.txt"
SET "LOCAL_STATUS_FILE=%BASE_STATUS_DIR%\%SRV_FILE_NAME%"

REM --- rsync를 위한 Cygwin 경로 변환 ---
SET "SOURCE_CYG_PATH=/cygdrive/!SOURCE_LOG_DIR::=!"
SET "SOURCE_CYG_PATH=!SOURCE_CYG_PATH:\=/!/"

REM --- 전송 완료된 로그를 이동시킬 폴더 생성 ---
if not exist "%SENT_LOG_DIR%" (
    ECHO 디렉터리 생성: %SENT_LOG_DIR%
    mkdir "%SENT_LOG_DIR%"
)

REM --- 'sent_log' 디렉터리에서 오래된 로그 삭제 ---
ECHO %SENT_LOG_DIR% 에서 %MAX_AGE_DAYS%일 이상된 파일 삭제 중...
forfiles /P "%SENT_LOG_DIR%" /S /M *.* /D -%MAX_AGE_DAYS% /C "cmd /c del @path"

REM --- 1. rsync에서 제외할 오늘 날짜 파일 목록 생성 ---
ECHO 오늘 생성된 파일을 제외하기 위한 목록 생성 중...
IF EXIST %EXCLUDE_LIST_WIN% DEL %EXCLUDE_LIST_WIN%
powershell -NoProfile -Command "Get-ChildItem -Path '%SOURCE_LOG_DIR%' -Recurse -File | Where-Object { ($_.CreationTime.Date -eq (Get-Date).Date) -or ($_.LastWriteTime.Date -eq (Get-Date).Date) } | ForEach-Object { $_.FullName.Substring([System.IO.Path]::GetFullPath('%SOURCE_LOG_DIR%').TrimEnd('\').Length).TrimStart('\').Replace('\', '/') }" > %EXCLUDE_LIST_WIN%

REM --- 수동 제외 목록이 존재하면, 생성된 제외 목록 파일에 추가 ---
IF EXIST "%MANUAL_EXCLUDE_LIST%" (
    ECHO 수동 제외 목록(%MANUAL_EXCLUDE_LIST%)을 추가합니다.
    type "%MANUAL_EXCLUDE_LIST%" >> "%EXCLUDE_LIST_WIN%"
)

REM --- 2. rsync로 로그 백업 실행 (오늘 날짜 파일 제외) ---
ECHO rsync 실행: %SOURCE_LOG_DIR% (오늘 생성된 파일 제외)
rsync -avz --bwlimit=10240 --no-g --no-o --exclude-from=%EXCLUDE_LIST_CYG% "!SOURCE_CYG_PATH!/" %REMOTE_HOST_PRIMARY%::%REMOTE_MODULE%/%REMOTE_SUB_DIR%

REM --- 3. rsync 결과에 따라 후속 조치 ---
IF !ERRORLEVEL! EQU 0 (
    ECHO rsync 성공. 전송된 파일을 %SENT_LOG_DIR%(으)로 이동합니다...
    REM 성공 -> rsync를 사용하여 오늘 생성된 파일을 제외하고 sent_log 폴더로 이동
    SET "SENT_CYG_PATH=/cygdrive/!SENT_LOG_DIR::=!"
    SET "SENT_CYG_PATH=!SENT_CYG_PATH:\=/!/"
    rsync -a --remove-source-files --exclude-from=%EXCLUDE_LIST_CYG% "!SOURCE_CYG_PATH!/" "!SENT_CYG_PATH!/"

    REM 임시 제외 목록 파일 삭제
    IF EXIST %EXCLUDE_LIST_WIN% DEL %EXCLUDE_LIST_WIN%
) ELSE (
    ECHO rsync 실패 (에러 코드: !ERRORLEVEL!).
    REM 에러 코드를 상태 파일에 기록
    ECHO !ERRORLEVEL! > "%LOCAL_STATUS_FILE%"

    REM 상태 파일을 2차 백업 서버로 전송
    ECHO 상태 파일을 2차 서버로 전송합니다...
    SET "STATUS_CYG_PATH=/cygdrive/!LOCAL_STATUS_FILE::=!"
    SET "STATUS_CYG_PATH=!STATUS_CYG_PATH:\=/!"
    rsync -avzh --bwlimit=10240 "!STATUS_CYG_PATH!" %REMOTE_HOST_SECONDARY%::backupuser  # 원본: rsync 모듈명

    REM 상태 파일 전송 성공 시에만 로컬 파일 삭제
    IF !ERRORLEVEL! EQU 0 (
        ECHO 상태 파일 전송 성공. 로컬 복사본을 삭제합니다.
        DEL "%LOCAL_STATUS_FILE%"
    ) ELSE (
        ECHO 상태 파일 전송 실패. 로컬 상태 파일을 유지합니다.
    )
)
ECHO --- 작업 완료: %JOB_NAME% ---
GOTO :EOF