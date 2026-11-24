@echo off
setlocal

:: 작업 폴더
set "ROOT_FOLDER=D:\Backup\Backup\CC\Srv_Log"

:: 압축 파일 저장
set "OUTPUT_FOLDER=D:\Backup\Backup\CC\Srv_Log_BAK"
if not exist "%OUTPUT_FOLDER%" mkdir "%OUTPUT_FOLDER%"

:: 7z 경로
set "SEVENZIP=C:\Program Files\7-Zip\7z.exe"

:: 로그
set "LOG_FOLDER=D:\Backup\Backup_Log\user"
set "LOG_FILE=%LOG_FOLDER%\user_BAK.log"
if not exist "%LOG_FOLDER%" mkdir "%LOG_FOLDER%"

:: 작업 시작 시간
set "START_TIME=%DATE% %TIME%"

echo 작업 시작: %START_TIME%
echo 작업 시작: %START_TIME% >> "%LOG_FILE%"
echo ============================== >> "%LOG_FILE%"

:: 하위 폴더 순회
for /d %%F in ("%ROOT_FOLDER%\*") do (
    set "FOLDER_NAME=%%~nxF"
    echo 압축 중: !FOLDER_NAME!
    echo 압축 중: !FOLDER_NAME!

    "%SEVENZIP%" a "%OUTPUT_FOLDER%\!FOLDER_NAME!.zip" "%%F\*" >> "%LOG_FILE%" 2>&1

    if errorlevel 1 (
        echo   오류 발생: !FOLDER_NAME!
        echo   오류 발생: !FOLDER_NAME!
    ) else (
        echo   완료: !FOLDER_NAME!
        echo   완료: !FOLDER_NAME!
    )
)

:: 작업 종료 시간
set "END_TIME=%DATE% %TIME%"
echo ============================== >> "%LOG_FILE%"
echo 작업 종료:
echo 작업 종료: %END_TIME% >> "%LOG_FILE%"
echo. >> "%LOG_FILE%"

pause
