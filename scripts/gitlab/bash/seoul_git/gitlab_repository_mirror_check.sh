#!/usr/bin/env bash

# ! gitlab에서 Mirroring repositories 기능을 사용한 push 미러링이 잘 되는지 체크
# ! 먼저 디스크 용량 체크
# ! GitLab 프로젝트 전체 목록 수집(API)
# ! Mirroring repositories 설정 안되어있는 프로젝트 선별
# ! Mirroring repositories 설정된 프로젝트 선별
# ! 선별된 프로젝트 정리해서 Slack 알람

# @ e: 어떤 명령이 실패하면 즉시 스크립트를 종료
# @ u: 초기화되지 않은 변수를 사용하려고 하면 오류를 발생시키고 종료
# @ o: 파이프라인(|)에서 중간 명령 중 하나라도 실패하면 전체 파이프라인이 실패
set -o pipefail

SEVEN_DAYS_AGO=$(date -d "7 day ago" +%s) # @ 7일 전

# ! 테스트용(실전은 하드코딩 하지 말 것)
# // SLACK_URL="" # @ Slack 웹훅 URL
# // GITLAB_ACCESS_TOKEN="" # @ 액세스 토큰
# // GITLAB_HOST="" # @ gitlab 주소(호스트)

LOG_FILE="/var/log/infra/00_repositories_mirror_check.log"
LOG_FILE_DIR=$(dirname "$LOG_FILE")
if [ ! -d "${LOG_FILE_DIR}" ]; then mkdir -p "${LOG_FILE_DIR}"; fi

# @ 모든 표준, 에러-> LOG_FILE
exec > >(tee -a "$LOG_FILE") 2>&1

# @ 공통 로그 함수
log() {
  printf "[%s] %s\n" "$(date '+%Y-%m-%d:::%H:%M:%S')" "$*"
}

log "===== Script started ====="

# @ 용량 체크
log "Checking disk usage..."
MOUNT_ARRAY=()
PERCENT_ARRAY=()
while read -r use mount; do
  percent=${use%\%}
  if ((percent >= 90)); then
    MOUNT_ARRAY+=("$mount")
    PERCENT_ARRAY+=("$percent")
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

# @ GitLab 프로젝트 목록 수집
log "Fetching GitLab project IDs..."

if ! PROJECT_IDS=$(curl -s --header "PRIVATE-TOKEN: $GITLAB_ACCESS_TOKEN" "$GITLAB_HOST/api/v4/projects?per_page=100" | jq -r '.[].id') || [ -z "$PROJECT_IDS" ]; then
  log "ERROR: Failed to fetch project IDs from GitLab."
  exit 1
fi
log "Retrieved project IDs: $(echo "$PROJECT_IDS" | tr '\n' ' ')"

STATUS_ARRAY=()
PROJECT_URL_ARRAY=()
LAST_UPDATE_ARRAY=()
PROJECT_NAMES_ARRAY=()

#for project_id in "${PROJECT_IDS[@]}"; do
while IFS= read -r project_id; do
  log "Checking project ID: $project_id"
  if ! MIRRORS=$(curl -s --header "PRIVATE-TOKEN: $GITLAB_ACCESS_TOKEN" "$GITLAB_HOST/api/v4/projects/$project_id/remote_mirrors"); then
    log "ERROR: Failed to fetch remote_mirrors for project $project_id"
    continue
  fi

  mirror_count=$(echo "$MIRRORS" | jq 'length')
  log " - Found $mirror_count remote mirrors"

  if [[ "$mirror_count" -gt 0 ]]; then
    for i in $(seq 0 $((mirror_count - 1))); do
      last_update=$(echo "$MIRRORS" | jq -r ".[$i].last_successful_update_at // empty")
      status=$(echo "$MIRRORS" | jq -r ".[$i].update_status")
      url=$(echo "$MIRRORS" | jq -r ".[$i].url" | cut -d'@' -f2-)

      if [[ -n "$last_update" && "$last_update" != "null" ]]; then
        last_update_ts=$(date -d "${last_update/Z/}" +%s 3>/dev/null || echo 0)
      else
        last_update_ts=0
      fi

      log "   - Mirror[$i] url=$url status=$status last_update=$last_update"

      if [[ "$last_update_ts" -ge "$SEVEN_DAYS_AGO" && "$last_update_ts" -ne 0 ]]; then
        STATUS_ARRAY+=("$status")
        PROJECT_URL_ARRAY+=("$url")
        LAST_UPDATE_ARRAY+=("$last_update")
      fi
    done
  else
    if ! project_name=$(curl -s --header "PRIVATE-TOKEN: $GITLAB_ACCESS_TOKEN" "$GITLAB_HOST/api/v4/projects/$project_id" | jq -r '.name'); then
      log "ERROR: Failed to get project name for $project_id"
    else
      PROJECT_NAMES_ARRAY+=("$project_name")
      log " - Project $project_id has no mirrors. Name: $project_name"
    fi
  fi
done <<< "$PROJECT_IDS"

# @ 미러링 리스트 알림
if [ ${#STATUS_ARRAY[@]} -gt 0 ]; then
  log "Sending mirror status Slack alert..."
  COUNT=0
  MESSAGE_BODY="*Mirroring repositories List*\n\n"
  # @ 타임스탬프를 초 단위로 가져옴
  CURRENT_TIMESTAMP=$(date +%s)

  for status in "${STATUS_ARRAY[@]}"; do
    # @ LAST_UPDATE_ARRAY의 각 값을 Unix 타임스탬프로 변환
    # @ LAST_UPDATE_ARRAY의 값이 "YYYY-MM-DD HH:MM:SS" 형식이라고 가정
    # @ 만약 형식이 다르다면 date -d 옵션을 조정해야 함
    LAST_UPDATE_TIMESTAMP=$(date -d "${LAST_UPDATE_ARRAY[${COUNT}]}" +%s)

    # @ 현재 시간과 마지막 업데이트 시간의 차이를 초 단위로 계산
    TIME_DIFF_SECONDS=$((CURRENT_TIMESTAMP - LAST_UPDATE_TIMESTAMP))

    # @ 1일(24시간) = 86400초
    ONE_DAY_IN_SECONDS=86400

    MESSAGE_BODY+="*URL:* \`${PROJECT_URL_ARRAY[${COUNT}]}\`\n"

    if [ "${status}" = "finished" ]; then
      # @ 1일 이상 경과했는지 확인
      if [ "${TIME_DIFF_SECONDS}" -ge "${ONE_DAY_IN_SECONDS}" ]; then
        MESSAGE_BODY+="   ->   *Status:* ${status}   ||   *Last_update:* \`$(echo "${LAST_UPDATE_ARRAY[${COUNT}]}" | cut -d'.' -f1)\` (Over 1 day old)\n"
      else
        MESSAGE_BODY+="   ->   *Status:* ${status}   ||   *Last_update:* $(echo "${LAST_UPDATE_ARRAY[${COUNT}]}" | cut -d'.' -f1)\n"
      fi
    else # @ status가 "finished"가 아닌 다른 값일 경우 (예: failed, pending 등)
      # @ 1일 이상 경과했는지 확인합니다.
      if [ "${TIME_DIFF_SECONDS}" -ge "${ONE_DAY_IN_SECONDS}" ]; then
        MESSAGE_BODY+="   ->   *Status:* \`${status}\`   ||   *Last_update:* \`$(echo "${LAST_UPDATE_ARRAY[${COUNT}]}" | cut -d'.' -f1)\` (Over 1 day old)\n"
      else
        MESSAGE_BODY+="   ->   *Status:* \`${status}\`   ||   *Last_update:* $(echo "${LAST_UPDATE_ARRAY[${COUNT}]}" | cut -d'.' -f1)\n"
      fi
    fi
    ((COUNT++))
  done

  PAYLOAD=$(printf '{"text": "📋 %s"}' "$MESSAGE_BODY")

  # @ curl 명령 종료 코드를 확인
  if ! response=$(curl -s -X POST -H 'Content-type: application/json' --data "$PAYLOAD" "$SLACK_URL"); then
    # @ curl 명령 실패했을 경우
    log "ERROR: Failed to send mirror status alert (curl command failed)."

  else
    # @ curl 명령 성공
    if [[ "$response" != "ok" ]]; then
      # @ Slack API 레벨 오류
      log "ERROR: Slack webhook response unexpected: $response"
    else
      # @ 최종 성공
      log "Mirror status alert sent to Slack successfully."
    fi
  fi
else
  log "No mirror repos updated within last 7 days."
fi

# @ 미러링 없는 프로젝트 알림
if [ ${#PROJECT_NAMES_ARRAY[@]} -gt 0 ]; then
  log "Sending no-mirror project Slack alert..."
  MESSAGE_BODY="*Projects without mirroring repositories set up*\n\n"
  for project_name in "${PROJECT_NAMES_ARRAY[@]}"; do
    MESSAGE_BODY+="* Project:* \`${project_name}\`\n"
  done
  PAYLOAD=$(printf '{"text": ":rotating_light: %s"}' "$MESSAGE_BODY")
  # @ curl 명령 종료 코드 확인
  if ! response=$(curl -s -X POST -H 'Content-type: application/json' --data "$PAYLOAD" "$SLACK_URL"); then
    # @ curl 명령 실패
    log "ERROR: Failed to send no-mirror alert (curl command failed)."

  else
    # @ curl 명령 성공
    if [[ "$response" != "ok" ]]; then
      # @ Slack API 레벨 오류
      log "ERROR: Slack webhook response unexpected: $response"
    else
      # @ 최종 성공
      log "No-mirror project alert sent to Slack successfully."
    fi
  fi
else
  log "All projects have mirrors configured."
fi

log "===== Script completed ====="
