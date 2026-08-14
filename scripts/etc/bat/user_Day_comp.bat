@echo off
setlocal enabledelayedexpansion

:: 작업 폴더
set "ROOT_FOLDER=D:\Backup\Backup\CC\DB"

:: 압축 저장 위치
set "OUTPUT_FOLDER=D:\Backup\Backup\CC\DB_BAK"
if not exist "%OUTPUT_FOLDER%" mkdir "%OUTPUT_FOLDER%"

:: 7-Zip
set "SEVENZIP=C:\Program Files\7-Zip\7z.exe"

:: 로그 폴더 및 로그 파일
set "LOG_FOLDER=D:\Backup\Backup_Log\user"
set "LOG_FILE=%LOG_FOLDER%\user_BAK.log"
if not exist "%LOG_FOLDER%" mkdir "%LOG_FOLDER%"

:: 작업 시작 시간
set "START_TIME=%DATE% %TIME%"

echo 작업 시작: %START_TIME%
echo 작업 시작: %START_TIME% >> "%LOG_FILE%"
echo ============================== >> "%LOG_FILE%"

:: 작업 폴더 아래 폴더들 순회
for /d %%B in ("%ROOT_FOLDER%\*") do (
    if not "%%~nxB"=="Compressed" (
        echo 처리 중: %%~nxB
		echo 처리 중: %%~nxB >> "%LOG_FILE%"
        pushd "%%B"

        set "B_FOLDER_NAME=%%~nxB"
        set "ERROR_OCCURRED=0"

        :: 일별 그룹
        for %%F in (*.*) do (
            for /f "tokens=1-3 delims=/- " %%a in ("%%~tF") do (
                set "yyyy=%%c"
                set "mm=%%a"
                set "dd=%%b"
                set "DATESTR=!yyyy!-!mm!-!dd!"

                set "LISTFILE=files_!DATESTR!.txt"
				
				echo "%%F"
                echo "%%F" >> "!LISTFILE!"
            )
        )

        :: 파일 목록 기준으로 압축
        for %%L in (files_*.txt) do (
            set "DATESTR=%%~nL"
            set "DATESTR=!DATESTR:~6!"

            set "ZIPFILE=%OUTPUT_FOLDER%\!B_FOLDER_NAME!_!DATESTR!.zip"
			
			echo   압축: !ZIPFILE!
            echo   압축: !ZIPFILE! >> "%LOG_FILE%"

            "%SEVENZIP%" a "!ZIPFILE!" @%%L >> "%LOG_FILE%" 2>&1
            if errorlevel 1 (
				echo   오류 발생: %%L 압축 실패
                echo   오류 발생: %%L 압축 실패 >> "%LOG_FILE%"
                set "ERROR_OCCURRED=1"
            )
            del %%L
        )

        if "!ERROR_OCCURRED!"=="0" (
            echo   완료: %%~nxB
			echo   완료: %%~nxB >> "%LOG_FILE%"
        ) else (
            echo   일부 오류 발생:
			echo   일부 오류 발생: %%~nxB >> "%LOG_FILE%"
        )

        popd
    )
)

:: 작업 종료 시간
set "END_TIME=%DATE% %TIME%"
echo ============================== >> "%LOG_FILE%"
echo 작업 종료:
echo 작업 종료: %END_TIME% >> "%LOG_FILE%"
echo. >> "%LOG_FILE%"

pause
