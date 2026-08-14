#!/bin/env bash

LOG_FILE="/data/backup/auto/00_gitlab_restore.log"
FORCE_RESTORE="yes" # 'yes' 또는 'no'

# 시작 시간 기록
START_TIME=$(date +%s) # Unix timestamp (초 단위)
START_DATE=$(date +"%Y-%m-%d %H:%M:%S")

echo "Restore started at: ${START_DATE}" | tee -a "${LOG_FILE}"
echo "" | tee -a "${LOG_FILE}" # 한 줄 비움

# 2. GitLab 복원 실행
echo "Starting GitLab restore process..." | tee -a "${LOG_FILE}"
if [ "${FORCE_RESTORE}" = "yes" ]; then
  # force=yes 사용 시 사용자 확인 프롬프트를 건너뜀
  sudo gitlab-backup restore /data/backup/auto/1748077216_2025_05_24_16.0.1-ee_gitlab_backup.tar force=yes 2>&1 | tee -a "${LOG_FILE}"
else
  sudo gitlab-backup restore /data/backup/auto/1748077216_2025_05_24_16.0.1-ee_gitlab_backup.tar 2>&1 | tee -a "${LOG_FILE}"
fi

# 복원 명령의 종료 코드 확인
if [ $? -eq 0 ]; then
  echo "" | tee -a "${LOG_FILE}"
  echo "GitLab restore command completed successfully." | tee -a "${LOG_FILE}"
else
  echo "" | tee -a "${LOG_FILE}"
  echo "ERROR: GitLab restore command failed. Check the log file for details." | tee -a "${LOG_FILE}"
  exit 1 # 스크립트 오류 종료
fi

echo "" | tee -a "${LOG_FILE}" # 한 줄 비움

# 종료 시간 기록
END_TIME=$(date +%s) # Unix timestamp (초 단위)
END_DATE=$(date +"%Y-%m-%d %H:%M:%S")

# 총 소요 시간 계산
DURATION=$((END_TIME - START_TIME))
HOURS=$((DURATION / 3600))
MINUTES=$(( (DURATION % 3600) / 60 ))
SECONDS=$(( DURATION % 60 ))

echo "Restore finished at: ${END_DATE}" | tee -a "${LOG_FILE}"
echo "Total duration: ${HOURS} hours ${MINUTES} minutes ${SECONDS} seconds" | tee -a "${LOG_FILE}"