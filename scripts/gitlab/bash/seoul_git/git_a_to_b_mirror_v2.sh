#!/bin/bash

# 인터페이스 이름
NET_IFACE="eth0"
# GitLab 호스트(서울) 주소
GITLAB_HOST=""  # 원본: GitLab 호스트 내부 IP
# 생성한 개인 접근 토큰
PRIVATE_TOKEN=""  # 원본: GitLab 개인 접근 토큰 (glpat-...)
# dev 그룹용 미러 대상
mirror_url_base_dev=""  # 원본: 미러 대상 서버 주소 (git@IP)
# design 그룹용 미러 대상
mirror_url_base_design=""  # 원본: 미러 대상 서버 주소 (git@IP)

# 최대 리트라이 횟수
MAX_RETRIES=3

FAILED_LIST_FILE="/data/infra/failed_projects.txt"
FAILED_LIST_DIR=$(dirname "$FAILED_LIST_FILE")
if [ ! -d "${FAILED_LIST_DIR}" ]; then mkdir -p ${FAILED_LIST_DIR} ;fi

LOG_FILE="/var/log/infra/00_seoul_busan_mirror.log"
LOG_FILE_DIR=$(dirname "$LOG_FILE")
if [ ! -d "${LOG_FILE_DIR}" ]; then mkdir -p ${LOG_FILE_DIR} ;fi

SLACK_URL=""  # 원본: Slack Webhook URL

# 슬랙 알람 함수
send_slack() {
  local blocks="$1"
  curl -X POST -H 'Content-type: application/json' \
    --data "{\"blocks\": $blocks}" \
    $SLACK_URL 2>> $LOG_FILE
}

# 대역폭 제한 시작
setup_bandwidth_limit() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [info] Setting bandwidth limit..." >> $LOG_FILE
  sudo tc qdisc add dev "$NET_IFACE" root tbf rate 100mbps burst 128kbit latency 400ms
}

# 대역폭 제한 해제
remove_bandwidth_limit() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [info] Removing bandwidth limit..." >> $LOG_FILE
  sudo tc qdisc del dev "$NET_IFACE" root || true
}

# 용량 체크
check_disk_space() {
  while read -r use mount; do
    percent=${use%\%}
    if (( percent >= 90 )); then
      curl -X POST -H 'Content-type: application/json' \
        --data "{\"text\": \":rotating_light: *Disk Usage Alert!* :rotating_light:\n\n*Disk:* \`${mount}\`\n*Usage:* *${percent}%*\"}"\
        $SLACK_URL 2>> $LOG_FILE
      exit 1
    fi
  done < <(df -h | grep "/dev/" | awk '{print $5 " " $6}')
}

PER_PAGE=100
projects=()
# 오늘
now=$(date -u +%s)
# 7일 전 (초 단위)
seven_days_ago=$((now - 7*24*60*60))

page=1
while :; do
  response=$(curl -s --header "PRIVATE-TOKEN: $PRIVATE_TOKEN" \
    "${GITLAB_HOST}/api/v4/projects?per_page=$PER_PAGE&page=$page")

  # response가 빈 배열이면 종료
  if [ "$(echo "$response" | jq length)" -eq 0 ]; then
    break
  fi

  # ssh_url_to_repo 와 그룹명(namespace.full_path) 추출 ★ 수정
  mapfile -t recent_projects < <(
    echo "$response" | jq -r --arg cutoff "$seven_days_ago" '
      .[] | select(.last_activity_at != null) |
      select((
        .last_activity_at
        | sub("\\.\\d{3}.*$"; "Z")
        | fromdateiso8601
      ) >= ($cutoff | tonumber)) |
      [.ssh_url_to_repo, .namespace.full_path] | @tsv
    '
  )

  # projects 배열에 "repo_url|group" 형식으로 추가 ★ 수정
  for entry in "${recent_projects[@]}"; do
    IFS=$'\t' read -r project group <<< "$entry"
    projects+=("$project|$group")
  done

  page=$((page + 1))
done

# 실패/변경없음/성공/시간 기록용
failed_projects=()
no_changes_projects=()
success_projects=()
declare -A push_times

# 용량 체크
check_disk_space

# 대역폭 설정
remove_bandwidth_limit
setup_bandwidth_limit

# 실패 목록 우선 처리
if [ -f "$FAILED_LIST_FILE" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') [info] Found previous failed project list, prioritizing..." >> $LOG_FILE
  mapfile -t failed_before < "$FAILED_LIST_FILE"
  project_names=("${failed_before[@]}")
else
  project_names=()
fi

# 실패 목록 + 전체 목록 합치기 (중복 제거)
for project_entry in "${projects[@]}"; do
  project="${project_entry%%|*}"
  repo_name=$(basename "$project" .git)
  if [[ ! " ${project_names[@]} " =~ " ${repo_name} " ]]; then
    project_names+=("$repo_name")
  fi
done

# 미러링 작업
for repo_name in "${project_names[@]}"; do
  project=""
  group=""
  for project_entry in "${projects[@]}"; do
    proj_url="${project_entry%%|*}"
    proj_group="${project_entry##*|}"
    if [[ "$(basename "$proj_url" .git)" == "$repo_name" ]]; then
      project="$proj_url"
      group="$proj_group"
      break
    fi
  done

  cd $FAILED_LIST_DIR

  if [ -z "$project" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [error] Project $repo_name not found in projects list. Skipping." >> $LOG_FILE
    continue
  fi

  echo "$(date '+%Y-%m-%d %H:%M:%S') [info] Processing $repo_name (group: $group)" >> $LOG_FILE

  if [[ "$group" =~ Design$ ]]; then
    mirror_target="${mirror_url_base_dev}:${group}/${repo_name}.git"
  else
    mirror_target="${mirror_url_base_design}:${group}/${repo_name}.git"
  fi

  attempt=1
  while [ $attempt -le $MAX_RETRIES ]; do
    echo "$(date '+%Y-%m-%d %H:%M:%S') [info] Attempt $attempt for $repo_name" >> $LOG_FILE

    start_time=$(date +%s)

    if [ -d "$repo_name" ]; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') [info] Directory $repo_name exists, update..." >> $LOG_FILE
      cd "$repo_name"
      git remote update 2>>$LOG_FILE  || {
        echo "$(date '+%Y-%m-%d %H:%M:%S') [error] update failed for $repo_name" >> $LOG_FILE
        cd ..
        attempt=$((attempt + 1))
        continue
      }
      git remote set-url --push origin "$mirror_target" 2>>$LOG_FILE
    else
      echo "$(date '+%Y-%m-%d %H:%M:%S') [info] Cloning $repo_name..." >> $LOG_FILE
      if ! git clone --mirror "$project" "$repo_name" 2>>$LOG_FILE; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [error] Clone failed for $repo_name" >> $LOG_FILE
        attempt=$((attempt + 1))
        continue
      fi
      cd "$repo_name"
      git remote set-url --push origin "$mirror_target" 2>>$LOG_FILE
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') [info] Pushing mirror for $repo_name..." >> $LOG_FILE
    if ! output=$(git push --mirror 2>&1); then
      echo "$(date '+%Y-%m-%d %H:%M:%S') [error] Push failed for $repo_name" >> $LOG_FILE
      echo "$output" >> $LOG_FILE
      cd ..
      attempt=$((attempt + 1))
      continue
    fi

    end_time=$(date +%s)
    elapsed=$((end_time - start_time))
    push_times["$repo_name"]="$elapsed sec"

    if echo "$output" | grep -q "Everything up-to-date"; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') [info] No changes to push for $repo_name" >> $LOG_FILE
      no_changes_projects+=("$repo_name")
    else
      success_projects+=("$repo_name")
    fi

    cd ..
    break
  done

  if [ $attempt -gt $MAX_RETRIES ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [info] All attempts failed for $repo_name" >> $LOG_FILE
    failed_projects+=("$repo_name")
  fi
done

remove_bandwidth_limit

if [ ${#failed_projects[@]} -gt 0 ]; then
  printf "%s\n" "${failed_projects[@]}" > "$FAILED_LIST_FILE"
else
  rm -f "$FAILED_LIST_FILE"
fi

generate_slack_blocks() {
  local blocks="[
    {\"type\": \"header\", \"text\": {\"type\": \"plain_text\", \"text\": \"📋 Git Mirroring Results\"}}
  "

  if [ ${#success_projects[@]} -gt 0 ]; then
    local text="✅ *Success* ✅\n"
    for p in "${success_projects[@]}"; do
      text+="• ${p} (${push_times[$p]})\n"
    done
    blocks+=", {\"type\": \"section\", \"text\": {\"type\": \"mrkdwn\", \"text\": \"$text\"}}"
  fi

  if [ ${#no_changes_projects[@]} -gt 0 ]; then
    local text="⚠️ *No Changes ⚠️*\n"
    for p in "${no_changes_projects[@]}"; do
      text+="• ${p}\n"
    done
    blocks+=", {\"type\": \"section\", \"text\": {\"type\": \"mrkdwn\", \"text\": \"$text\"}}"
  fi

  if [ ${#failed_projects[@]} -gt 0 ]; then
    local text="❌ *Failed* ❌\n"
    for p in "${failed_projects[@]}"; do
      text+="• ${p}\n"
    done
    blocks+=", {\"type\": \"section\", \"text\": {\"type\": \"mrkdwn\", \"text\": \"$text\"}}"
  fi

  blocks+="]"

  echo "$blocks"
}

blocks=$(generate_slack_blocks)
send_slack "$blocks"
