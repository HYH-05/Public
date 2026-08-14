#!/bin/bash
set -euo pipefail

# 인터페이스 이름
NET_IFACE="eth0"
FAILED_LIST_FILE="/data/infra/failed_projects.txt"
FAILED_LIST_DIR=$(dirname "$FAILED_LIST_FILE")
LOG_FILE="$FAILED_LIST_DIR/mirror_script.log"
MAX_RETRIES=3

if [ ! -d "${FAILED_LIST_DIR}" ]; then mkdir -p ${FAILED_LIST_DIR}; fi

# 슬랙 알람 함수
send_slack() {
  local blocks="$1"
  curl -X POST -H 'Content-type: application/json' \
       --data "{\"blocks\": $blocks}" \
       ""  # 원본: Slack Webhook URL
       2>> $LOG_FILE
}

# 용량 체크
check_disk_space() {
  while read -r use mount; do
    percent=${use%\%}
    if (( percent >= 90 )); then
      curl -X POST -H 'Content-type: application/json' \
        --data "{\"text\": \":rotating_light: *Disk Usage Alert!* :rotating_light:\n\n*Disk:* \`${mount}\`\n*Usage:* *${percent}%*\"}"\
        ""  # 원본: Slack Webhook URL
      exit 1
    fi
  done < <(df -h | grep "/dev/" | awk '{print $5 " " $6}')
}

# 대역폭 제한 함수들
setup_bandwidth_limit() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [info] Setting bandwidth limit..." >> $LOG_FILE
  sudo tc qdisc add dev "$NET_IFACE" root tbf rate 100mbps burst 128kbit latency 400ms
}

remove_bandwidth_limit() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [info] Removing bandwidth limit..." >> $LOG_FILE
  sudo tc qdisc del dev "$NET_IFACE" root || true
}

# 종료 시 대역폭 자동 해제
trap remove_bandwidth_limit EXIT

projects=(
  ""  # 원본: 내부 GitLab 저장소 주소들 (git@IP:path.git)
)

mirror_url_base=""  # 원본: 미러 대상 서버 주소 (git@IP:path)

failed_projects=()
no_changes_projects=()
success_projects=()
declare -A push_times

# 용량 확인
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
  echo "$(date '+%Y-%m-%d %H:%M:%S') [info] No previous failed list. Nothing to do." >> $LOG_FILE
  exit 0
fi

# 미러링 작업
for repo_name in "${project_names[@]}"; do
  attempt=1
  project=""
  for p in "${projects[@]}"; do
    if [[ "$(basename "$p" .git)" == "$repo_name" ]]; then
      project="$p"
      break
    fi
  done

  cd $FAILED_LIST_DIR

  if [ -z "$project" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [error] Project $repo_name not found in projects list. Skipping." >> $LOG_FILE
    continue
  fi

  while [ $attempt -le $MAX_RETRIES ]; do
    echo "$(date '+%Y-%m-%d %H:%M:%S') [info] Attempt $attempt for $repo_name" >> $LOG_FILE
    mirror_target="${mirror_url_base}/${repo_name}.git"
    start_time=$(date +%s)

    if [ -d "$repo_name" ]; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') [info] Directory $repo_name exists, fetching..." >> $LOG_FILE
      cd "$repo_name" || {
        echo "$(date '+%Y-%m-%d %H:%M:%S') [error] Cannot cd into $repo_name" >> $LOG_FILE
        attempt=$((attempt + 1))
        continue
      }
      if ! git remote update 2>>$LOG_FILE; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [error] Fetch failed for $repo_name" >> $LOG_FILE
        cd ..
        attempt=$((attempt + 1))
        continue
      fi
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
    push_times["$repo_name"]="${elapsed} sec"

    if echo "$output" | grep -q "Everything up-to-date"; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') [info] No changes to push for $repo_name" >> $LOG_FILE
      no_changes_projects+=("$repo_name")
    else
      success_projects+=("$repo_name")
    fi

    cd ..
    break  # 성공 시 retry 종료
  done

  # 재시도 끝나고 실패 처리
  if [ $attempt -gt $MAX_RETRIES ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [info] All attempts failed for $repo_name" >> $LOG_FILE
    failed_projects+=("$repo_name")
  fi
done

# 실패 목록 저장
if [ ${#failed_projects[@]} -gt 0 ]; then
  printf "%s\n" "${failed_projects[@]}" > "$FAILED_LIST_FILE"
else
  rm -f "$FAILED_LIST_FILE"
fi

generate_slack_blocks() {
  local blocks="[
    {\"type\": \"header\", \"text\": {\"type\": \"plain_text\", \"text\": \"📋 Git Mirroring Result (Redone After Failure)\"}},
    {\"type\": \"divider\"}
  "

  if [ ${#success_projects[@]} -gt 0 ]; then
    local text="✅ *Success* ✅\n"
    for p in "${success_projects[@]}"; do
      safe_p=$(echo "$p" | sed 's/"/\\"/g')
      text+="• ${safe_p} (${push_times[$p]})\n"
    done
    blocks+=", {\"type\": \"section\", \"text\": {\"type\": \"mrkdwn\", \"text\": \"$text\"}}"
  fi

  if [ ${#no_changes_projects[@]} -gt 0 ]; then
    local text="⚠️ *No Changes* ⚠️\n"
    for p in "${no_changes_projects[@]}"; do
      safe_p=$(echo "$p" | sed 's/"/\\"/g')
      text+="• ${safe_p}\n"
    done
    blocks+=", {\"type\": \"section\", \"text\": {\"type\": \"mrkdwn\", \"text\": \"$text\"}}"
  fi

  if [ ${#failed_projects[@]} -gt 0 ]; then
    local text="❌ *Failed* ❌\n"
    for p in "${failed_projects[@]}"; do
      safe_p=$(echo "$p" | sed 's/"/\\"/g')
      text+="• ${safe_p}\n"
    done
    blocks+=", {\"type\": \"section\", \"text\": {\"type\": \"mrkdwn\", \"text\": \"$text\"}}"
  fi

  blocks+="]"
  echo "$blocks"
}

blocks=$(generate_slack_blocks)
send_slack "$blocks"