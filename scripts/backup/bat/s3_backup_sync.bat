@echo off
setlocal enabledelayedexpansion

for /f "tokens=1-4 delims=/ " %%a in ("%date%") do (
    set logdate=%%a-%%b-%%c
)
for /f "tokens=1-2 delims=: " %%a in ("%time%") do (
    set logtime=%%a-%%b
)

set LOGFILE="D:\Backup\Infra Utils\user\transfer_Log.txt"

echo ==================================== >> %LOGFILE%
echo [%logdate% %logtime%] script start. >> %LOGFILE%

:: %1 = 태그 / %2 = 로컬경로 / %3 = S3 경로 / %4 = include 패턴

:: AO
call :Backup AO     D:\Backup\Backup\Game1\DB\        		s3://example-db-bucket/game1/         *.bak
call :Backup AO_LOG D:\Backup\Backup\Game1\Log\       		s3://example-log-bucket/game1/               *

:: DK
call :Backup DK     D:\Backup\Backup\Game2\DB\        		s3://example-db-bucket/game2/          *.bak
call :Backup DK_LOG D:\Backup\Backup\Game2\Log\       		s3://example-log-bucket/game2/                *

:: GZ
call :Backup GZ     D:\Backup\Backup\Game3\DB_MYSQL\  		s3://example-db-bucket-mysql/game3         *.tar.gz
call :Backup GZ_LOG D:\Backup\Backup\Game3\Log\       		s3://example-log-bucket/game3/                    *

:: NX
call :Backup NX     D:\Backup\Backup\Game10\DB\        		s3://example-db-bucket/game10/           *

:: PT
set "folder=00_Test 01_Fury 02_Babel 03_Casa 04_Ariel"
call :Backup PT		D:\Backup\Backup\Game4\DB\		   		s3://example-db-bucket/game4/       *.bak
call :Backup PT		D:\Backup\Backup\Game4\BackupFile\		s3://example-db-bucket/game4/       *.zip
for %%f in (%folder%) do (
    call :Backup PT 	D:\Backup\Backup\Game4\Log\%%f\BackupFile_Result 	s3://example-log-bucket/game4/%%f/	*
)





echo [%logdate% %logtime%] script done. >> %LOGFILE%
echo ==================================== >> %LOGFILE%


:: 함수 정의
:Backup
:: %1 = 태그 / %2 = 로컬경로 / %3 = S3 경로 / %4 = include 패턴

echo [%logdate% %logtime%] [%1] backup start. >> %LOGFILE%

aws s3 sync %2 %3 --exclude "*" --include "%4" >> %LOGFILE% 2>&1
if errorlevel 1 (
    echo [%logdate% %logtime%] [%1] [ERROR] backup failed - %2 >> %LOGFILE%
) else (
    echo [%logdate% %logtime%] [%1] [OK] backup done. - %2 >> %LOGFILE%
)
EXIT /B %ERRORLEVEL%

endlocal