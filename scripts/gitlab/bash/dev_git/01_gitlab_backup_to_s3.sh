#!/bin/env bash

# @ 로그 파일, 폴더 생성
LOG_FILE="/var/log/backup/02_gitlab_backup_to_s3.log"
LOG_FILE_DIR=$(dirname "$LOG_FILE")
if [ ! -d "${LOG_FILE_DIR}" ]; then mkdir -p "${LOG_FILE_DIR}"; fi

# @ 모든 표준, 에러-> LOG_FILE
exec > >(tee -a "$LOG_FILE") 2>&1

# @ 로그 함수
log() {
  printf "[%s] %s\n" "$(date '+%Y-%m-%d:::%H:%M:%S')" "$*"
}

S3_BUCKET="s3://example-git-bucket/Dev"  # @ S3 버킷
BACKUP_PATH="/backup/auto"
LATEST_BACKUP_FILE=$(find "$BACKUP_PATH" -maxdepth 1 -type f -name "*.tar" -printf "%T@ %p\n" | sort -nr | head -n1 | cut -d' ' -f2-)

if [[ -n "${LATEST_BACKUP_FILE}" ]]; then
  log "[info]: Uploading ${LATEST_BACKUP_FILE} to S3 bucket: $S3_BUCKET"

  if aws s3 cp "${LATEST_BACKUP_FILE}" "$S3_BUCKET/"; then
    log "[info]: S3 upload successful."
  else
    log "[error]: S3 upload failed."
  fi
else
  log "[error]: No backup file found to upload."
fi

if grep -i "error\|fail" "$LOG_FILE" >/dev/null 2>&1; then
  echo "1" > /var/log/backup/02_gitlab_backup_to_s3.status
else
  echo "0" > /var/log/backup/02_gitlab_backup_to_s3.status
fi