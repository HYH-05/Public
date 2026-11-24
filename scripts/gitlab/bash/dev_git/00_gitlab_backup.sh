#!/bin/env bash

set -o pipefail

LOG_FILE="/var/log/backup/01_gitlab_backup.log"
LOG_FILE_DIR=$(dirname "$LOG_FILE")
if [ ! -d "${LOG_FILE_DIR}" ]; then mkdir -p "${LOG_FILE_DIR}"; fi

# @ 모든 표준, 에러-> LOG_FILE
exec > >(tee -a "$LOG_FILE") 2>&1

# @ 공통 로그 함수
log() {
  printf "[%s] %s\n" "$(date '+%Y-%m-%d:::%H:%M:%S')" "$*"
}

# @ 주기 컨트롤
log "[info]: find /backup/auto/ -type f -name "*gitlab_backup.tar" -mtime +14 -exec rm -rfv {} +"
if find /backup/auto/ -type f -name "*gitlab_backup.tar" -mtime +14 -exec rm -rfv {} +; then
  log "[info]: Old GitLab backups cleanup command executed."
else
  log "[error]: Failed to find or execute cleanup command for old GitLab backups."
fi

log "[info]: gitlab-backup create"
if gitlab-backup create; then
  log "[info]: GitLab backup created successfully."
else
  log "[error]: GitLab backup creation FAILED!"
fi

if grep -i "error\|failed" "$LOG_FILE" >/dev/null 2>&1; then
  echo "1" > /var/log/backup/01_gitlab_backup.status
else
  echo "0" > /var/log/backup/01_gitlab_backup.status
fi