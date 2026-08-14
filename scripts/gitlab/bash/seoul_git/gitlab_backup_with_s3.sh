#!/usr/bin/env bash

# ! gitlab-backup create 기능을 사용한 gitlab 백업 스크립트
# ! 1. 디스크 용량 체크
# ! 2. 백업시 gitlab.rb 등 설정 파일도 백업
# ! 3. 그 후 s3 업로드
# ! 실패시 슬랙을 통한 알람 기능


# @ e: 어떤 명령이 실패하면 즉시 스크립트를 종료
# @ u: 초기화되지 않은 변수를 사용하려고 하면 오류를 발생시키고 종료
# @ o: 파이프라인(|)에서 중간 명령 중 하나라도 실패하면 전체 파이프라인이 실패
set -o pipefail

BACKUP_PATH="/backup/auto"  # @ GitLab 백업 경로


# ! 테스트용(실전은 하드코딩 하지 말 것)
# // SLACK_URL="" # @ Slack 웹훅 URL
# // GITLAB_ACCESS_TOKEN="" # @ 액세스 토큰
# // S3_BUCKET=""  # @ S3 버킷

# @ 로그 폴더 생성
LOG_FILE="/var/log/infra/01_gitlab_backup_with_s3.log" # @ 로그 파일 경로
LOG_FILE_DIR=$(dirname "$LOG_FILE")
mkdir -p "${LOG_FILE_DIR}"

# @ 모든 표준, 에러-> LOG_FILE
exec > >(tee -a "$LOG_FILE") 2>&1

# @ 로그 기록용 함수
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# @ 슬랙 알람용 함수
send_slack() {
  local message="$1"
  response=$(curl -s -X POST -H 'Content-type: application/json' --data "{\"text\": \"$message\"}" "$SLACK_URL")
  if [[ "$response" != "ok" ]]; then
    log "ERROR: Slack webhook response (unexpected): ${response}\n"
  fi
}

log "===== GitLab Backup Started ====="

# @ 디스크 용량 체크
log "Checking disk usage..."
MOUNT_ARRAY=()
PERCENT_ARRAY=()
while read -r use mount; do
  PERCENT=${use%\%}
  if ((PERCENT >= 90)); then
    MOUNT_ARRAY+=("$mount")
    PERCENT_ARRAY+=("$PERCENT")
  fi
done < <(df -h | grep "/dev/" | awk '{print $5 " " $6}')

if [ ${#MOUNT_ARRAY[@]} -gt 0 ]; then
  log "Disk usage exceeded threshold:"
  for i in "${!MOUNT_ARRAY[@]}"; do
    log " - ${MOUNT_ARRAY[$i]} : ${PERCENT_ARRAY[$i]}%"
  done

  # @ Slack 전송
  MESSAGE_BODY="*Disk Usage Alert!*\n\n"
  for i in "${!MOUNT_ARRAY[@]}"; do
    MESSAGE_BODY+="*Mounted here:* \`${MOUNT_ARRAY[$i]}\`   &&   *Usage:* \`${PERCENT_ARRAY[$i]}%\`\n"
  done
  PAYLOAD=$(printf '{"text": ":rotating_light: %s"}' "$MESSAGE_BODY")

  if ! response=$(curl -s -X POST -H 'Content-type: application/json' --data "$PAYLOAD" "$SLACK_URL"); then
    # @ curl 명령이 실패 했을 경우
    log "ERROR: Failed to send disk usage alert to Slack (curl command failed)."
    exit 1
  else
    # @ curl 명령이 성공 했을 경우
    if [[ "$response" != "ok" ]]; then
      # @ Slack API 레벨의 오류
      log "ERROR: Slack webhook response unexpected: $response"
    else
      # @ 최종 성공
      log "Disk usage alert sent to Slack successfully."
    fi
  fi
else
  log "No disk usage over threshold."
fi

# @ GitLab 백업 실행
log "Starting GitLab backup..."

if /opt/gitlab/bin/gitlab-backup create; then
  log "GitLab backup completed successfully."
  # @ 최신 백업 파일 서치
  latest_backup_file=$(find "$BACKUP_PATH" -maxdepth 1 -type f -name "*.tar" -printf "%T@ %p\n" | sort -nr | head -n1 | cut -d' ' -f2-)

  if [[ -n "${latest_backup_file}" ]]; then
    log "Creating combined tar including GitLab config files..."
    if tar --append --file="${latest_backup_file}" -C / etc/gitlab/gitlab.rb etc/gitlab/gitlab-secrets.json; then
      log "Config files appended into existing backup tar successfully."
    else
      log "ERROR: Failed to append config files into tar."
      send_slack ":x: *Failed to append config files to GitLab backup tar* at $(date "+%Y-%m-%d %H:%M:%S")"
    fi

    log "Uploading ${latest_backup_file} to S3 bucket: $S3_BUCKET"

    if aws s3 cp "${latest_backup_file}" "$S3_BUCKET/"; then
      log "S3 upload successful."
    else
      log "ERROR: S3 upload failed."
      send_slack ":x: *GitLab backup S3 upload FAILED* at $(date "+%Y-%m-%d %H:%M:%S")\nBackup: \`${BACKUP_PATH}${latest_backup_file}\`"
    fi
  else
    log "ERROR: No backup file found to upload."
    send_slack ":x: *GitLab backup file not found for S3 upload* at $(date "+%Y-%m-%d %H:%M:%S")"
  fi
else
  log "ERROR: GitLab backup failed."
  send_slack ":x: *GitLab backup FAILED* at $(date "+%Y-%m-%d %H:%M:%S")"
fi

log "===== GitLab Backup Script Completed ====="
