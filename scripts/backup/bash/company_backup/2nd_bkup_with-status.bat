REM cd D:\Backup\00_infra_utils\cwrsync\bin
REM rsync -avz --bwlimit=10240 /cygdrive/D/Backup/Server/Log/ root@::log_ao/deka
REM 원본: 내부 rsync 서버 IP들 (10.11.32.xxx)

@ECHO OFF
SETLOCAL EnableDelayedExpansion

cd D:\Backup\00_infra_utils\cwrsync\bin

SET SRV_FILE_NAME="AO_Deca_Srv.txt"
SET LOCAL_STATUS_FILE="D:\Backup\00_infra_utils\user\%SRV_FILE_NAME%"

REM rsync 제외 목록 파일 경로 설정 (Windows 및 Cygwin 형식)
SET EXCLUDE_LIST_WIN="D:\Backup\00_infra_utils\user\rsync_exclude.txt"
SET EXCLUDE_LIST_CYG="/cygdrive/D/Backup/00_infra_utils/user/rsync_exclude.txt"

SET SOURCE_LOG_DIR=D:\Backup\Server\Log
SET SENT_LOG_DIR=D:\Backup\sent_log
rem 보낸 파일을 이동시킬 폴더가 없으면 생성
if not exist "%SENT_LOG_DIR%" (
    mkdir "%SENT_LOG_DIR%"
)

rem 삭제할 파일의 기준 나이 (일 단위)
set MAX_AGE_DAYS=150

rem forfiles 명령어로 오래된 파일 삭제 실행
rem /S : 하위 폴더까지 모두 검색
rem /M *.* : 모든 파일을 대상으로 함 (*.log 등 특정 확장자만 지정 가능)
rem /D -%MAX_AGE_DAYS% : 오늘로부터 MAX_AGE_DAYS일 이전에 수정된 파일을 찾음
rem /C "cmd /c del @path" : 찾은 파일의 전체 경로(@path)를 대상으로 삭제(del) 명령 실행
forfiles /P %SENT_LOG_DIR% /S /M *.* /D -%MAX_AGE_DAYS% /C "cmd /c del @path"

REM --- 1. rsync에서 제외할 오늘 날짜 파일 목록 생성 ---
IF EXIST %EXCLUDE_LIST_WIN% DEL %EXCLUDE_LIST_WIN%

REM PowerShell을 사용해 오늘 생성된 파일의 상대 경로를 찾고, 경로 구분자를 '/'로 변경하여 리스트 파일에 저장
powershell -NoProfile -Command "Get-ChildItem -Path '%SOURCE_LOG_DIR%' -Recurse -File | Where-Object { $_.CreationTime.Date -eq (Get-Date).Date } | ForEach-Object { $_.FullName.Substring([System.IO.Path]::GetFullPath('%SOURCE_LOG_DIR%').TrimEnd('\').Length).TrimStart('\').Replace('\', '/') }" > %EXCLUDE_LIST_WIN%

REM --- 2. rsync 명령어 실행 (오늘 날짜 파일 제외) ---
rsync -avzh --bwlimit=10240 --exclude-from=%EXCLUDE_LIST_CYG% /cygdrive/D/Backup/Server/Log/ ::log_ao/Deka
REM 원본 위: 내부 rsync 서버 IP (x.x.x.x)

REM rsync 명령어의 종료 코드를 확인
rem --- 3. rsync 성공 시 전송된 파일만 이동 (폴더 구조는 유지) ---
IF %ERRORLEVEL% EQU 0 (
    REM 성공 -> rsync를 사용하여 오늘 생성된 파일을 제외하고 sent_log 폴더로 이동
    REM --remove-source-files : 전송 성공 후 원본 파일을 삭제
    rsync -a --remove-source-files --exclude-from=%EXCLUDE_LIST_CYG% /cygdrive/D/Backup/Server/Log/ /cygdrive/D/Backup/sent_log/

    REM 임시 제외 목록 파일 삭제
    IF EXIST %EXCLUDE_LIST_WIN% DEL %EXCLUDE_LIST_WIN%
) ELSE (
    REM 실패 -> 상태 파일을 생성
    ECHO %ERRORLEVEL% > "%LOCAL_STATUS_FILE%"

    REM 상태 파일을 백업 서버2로 전송
    rsync -avzh --bwlimit=10240 "/cygdrive/D/Backup/00_infra_utils/user/%SRV_FILE_NAME%" ::backupuser  # 원본: rsync 모듈명
    REM 원본 위: 내부 rsync 서버 IP (x.x.x.x)

    REM 이전 상태 파일 삭제
	IF %ERRORLEVEL% EQU 0 (
		DEL "%LOCAL_STATUS_FILE%"
	)
)

ENDLOCAL