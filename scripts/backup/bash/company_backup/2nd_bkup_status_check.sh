#!/usr/bin/env bash

readonly STATUS_DIR="/root/user/backup_srv1_status"
readonly SLACK_WEBHOOK_URL=""  # 원본: Slack Webhook URL

find "$STATUS_DIR" -type f -name "*.txt" -print0 | while IFS= read -r -d '' status_file; do
    # @ 파일 이름과 에러 코드 추출
    filename=$(basename "$status_file")
    error_code=$(cat "$status_file")
    hostname=${filename//.txt/}         # @ 파일명에서 확장자 제거

    echo "$hostname"

    # @ 슬랙에 보낼 메시지 구성
    message="2차 백업 실패 알림\n\n서버: \`${hostname}\`\n*오류 코드:* \`${error_code}\`"

    # @ JSON 페이로드 생성
    json_payload=$(printf '{"text": "%s"}' "$message")

    # @ curl을 사용하여 슬랙으로 알림 전송
    curl -X POST -H 'Content-type: application/json' --data "$json_payload" "$SLACK_WEBHOOK_URL"

    # @ 알림을 보낸 후에는 상태 파일을 삭제하여 중복 알림 방지
    rm -f "$status_file"
done