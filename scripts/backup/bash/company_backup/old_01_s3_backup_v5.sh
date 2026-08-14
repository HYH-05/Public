#!/usr/bin/env bash

# * ==================================================================================================
# *                                    SCRIPT EXIT CODES (스크립트 종료 코드)
# * ==================================================================================================
# * 0 : 정상 종료 (오류 없이 스크립트가 완료됨)
# * 1 : 디스크 용량 90% 이상 초과
# * 2 : 파일 삭제 실패 (예: `xargs rm` 명령어 오류)
# * 3 : 백업할 새로운 파일 없음 (변경 사항이 감지되지 않음)
# * 4 : AWS S3로 파일을 동기화/복사하거나, 업로드 후 검증하는 과정에서 실패
# // 5 : 압축 파일이 이미 존재함 (동일한 이름의 압축 파일이 이미 있어 충돌 발생
# * 6 : 압축 실패 (예: `tar` 명령어 오류)
# * 7 : 스크립트가 이미 동작 중 (flock에 의해 중복 실행 방지)
# * 8 : AWS S3 통신 실패 (AWS CLI 설정(key) 또는 네트워크 문제 등)
# * 9 : 압축 파일 검증 실패 (압축된 파일이 원본과 일치하지 않음)

# * ==================================================================================================

# ! 파이프라인(예: command1 | command2)으로 연결된 명령어들 중 하나라도 0이 아닌 종료 코드를 반환하면, 즉시 스크립트 전체를 중단시킵니다.
# ! 이는 파이프라인의 중간에서 오류가 발생했을 때, 의도치 않은 동작으로 이어지는 것을 방지하는 중요한 설정입니다.
set -o pipefail

# ! ==================================================================================================
# !                                    CONFIGURATION (설정)
# !                            "모드|태그|백업할 경로|포함할 파일 패턴"
# ! ==================================================================================================
# ! 이 스크립트가 수행할 모든 백업 작업을 배열 형태로 정의합니다. 스크립트는 이 배열을 순회하며 각 작업을 처리합니다.
# @ 모드: 백업 방식을 결정합니다.
  # @ "sync": 원본 디렉토리와 S3를 직접 동기화합니다. 파일들을 개별적으로 S3에 업로드합니다. -> 압축 필요 없는 DB(풀백업)
  # @ "comp": 원본 파일들을 월별/디렉토리별로 그룹화하여 zst 압축 파일로 만든 후 S3에 업로드합니다. -> 압축 필요한 log 파일
# @ 태그: 각 작업을 식별하기 위한 고유한 이름입니다. 로그 메시지와 임시 파일 이름에 사용되어 추적을 용이하게 합니다. -> 프로덕트 네임
# @ 경로: 백업할 파일들이 위치한 로컬 서버의 절대 경로입니다.
# @ 패턴: 해당 경로 내에서 백업 대상으로 포함할 파일들을 지정하는 include 패턴입니다. (예: "*.bak", "*")
readonly BACKUP_JOBS=(
  "comp|ac_log|/backup/game5/log|*"
  "comp|cc_srv_log|/backup/game6/srv_log|*"
  "comp|fh_log_data|/backup/game7/log_data|*"
  "sync|lh_log|/backup/game8/log|*"
  "comp|sr_game_log|/backup/game9/game_log|*"

  # "comp|AO_LOG|/backup/game1/log|*"
  # "comp|DK_LOG|/backup/game2/log|*"
  # "comp|GZ_LOG|/backup/game3/log|*"
  # "comp|PT_LOG|/backup/game4/db|*"
)

# ! --- 디버깅 및 테스트 설정 (Debugging & Testing) ---
# @ 특정 월(YYYYMM)의 데이터만 처리하려면 값을 지정합니다. (예: "202507")
# @ 비워두면 ("") 모든 월을 정상적으로 처리합니다.
readonly DEBUG_MONTH="202507"

# ! --- 전역 상수 (Global Constants) ---
readonly BACKUP_ROOT="/backup"              # @ 모든 백업 대상 경로의 최상위 루트 디렉토리.
readonly FILE_LISTS_DIR="/infra_utils/.file_lists"        # @ 백업 변경 사항을 추적하는 데 사용되는 디렉토리입니다.
LOG_FILE="/var/log/backup-log/01_s3_backup_$(date '+%Y%m%d').log"  # @ 스크립트 동작을 기록하는 로그 파일의 위치입니다.
readonly LOCK_FILE="/var/run/01_s3_backup.lock"           # @ 스크립트 중복 실행을 방지하기 위한 잠금 파일의 위치입니다.
readonly S3_BUCKET_NAME="example-backup-bucket"                   # @ 백업 파일이 저장될 AWS S3 버킷의 이름입니다.

# @ 스크립트 실행 시작 시점의 타임스탬프 파일을 저장할 변수. cleanup 함수에서 사용됩니다.
START_TIMESTAMP_FILE=""

# @ 실패한 작업의 압축 파일 경로를 기록하기 위한 임시 로그 파일.
FAILED_ARCHIVES_LOG_FILE=""

# @ 공통 로그 처리
# @ 모든 표준, 에러-> LOG_FILE
exec > >(tee -a "$LOG_FILE") 2>&1

# ! ==================================================================================================
# !                                    CORE FUNCTIONS (핵심 함수)
# ! ==================================================================================================

# ! 일관된 형식으로 로그를 기록하고, 오류 발생 시 스크립트를 즉시 종료하는 중앙 집중식 로깅 함수입니다.
  # @ $1: code - 종료 코드. 0 (성공) 또는 그 외의 오류 코드(위의 사용자 정의 코드)를 받습니다.
  # @ $2: msg - 로그 파일에 기록될 메세지입니다.
  # @ $3: tag - 어떤 백업 작업 또는 시스템 프로세스에서 로그가 발생했는지 식별하는 태그입니다.
log_and_status() {
  local code="$1"
  local msg="$2"
  local tag="$3"
  local log_level="info"

  # @ 종료 코드가 0이 아니면(오류 상황), 로그 레벨을 'error'로 변경합니다.
  if [[ "$code" -ne 0 ]]; then
    log_level="error"
  fi

  # @ "YYYY-MM-DD HH:MM:SS [태그] [로그레벨] code:종료코드 메시지" 형식으로 로그 파일에 한 줄을 추가합니다.
  echo "$(date '+%Y-%m-%d %H:%M:%S') [${tag}] [${log_level}] code:${code} ${msg}"
  # @ ex) "2025-07-07 18:35:58 [AC] [info] code:0 작업 시작: [AC] | 모드: [comp] | 경로: [/backup/game5/log]"

  # @ 종료 코드가 0이 아니면,
  if [[ "$code" -ne 0 ]]; then
    # @ 현재 스크립트의 최종 상태를 나타내는 파일에 종료 코드를 기록합니다.
    # @ 이 파일은 cleanup 함수에서 스크립트가 정상 종료되었는지, 오류로 종료되었는지 판단하는 데 사용됩니다.
    echo "$code" > "${LOG_DIR}/01_s3_backup.status"
    # @ 스크립트를 해당 종료 코드로 즉시 중단합니다.
    exit "$code"
  fi
}

# ! @ 스크립트가 종료될 때(정상 종료, 오류, 인터럽트 등) 항상 실행되어 임시 파일을 정리하는 함수입니다.
  # @ main 함수 시작 부분의 'trap' 명령어에 의해 등록됩니다.
cleanup() {
  # @ 파일 목록을 저장하는 디렉토리가 존재하는 경우
  if [[ -d "$FILE_LISTS_DIR" ]]; then
    log_and_status 0 "스크립트 종료. 임시 파일들을 정리합니다..." "cleanup"
    # @ diff, current, sorted_diff 등 작업 중에 생성된 임시 목록 파일들을 찾아 삭제합니다.
    find "$FILE_LISTS_DIR" -type f \( -name "*_current.txt" -o -name "*_diff.txt" -o -name "*_sorted_diff.txt" \) -delete
  fi

  local exit_status
  # @ 01_s3_backup.status 파일에서 최종 종료 코드를 읽어옵니다.
  exit_status=$(cat "${LOG_DIR}/01_s3_backup.status")

  # @ 스크립트가 오류로 종료된 경우 (종료 코드가 0이 아님)
  if [[ "$exit_status" -ne 0 ]]; then
    log_and_status 0 "스크립트가 오류($exit_status)로 종료되었습니다. 실패한 작업의 압축 파일만 선별하여 정리합니다..." "cleanup"
    # @ 실패 로그 파일이 존재하고 내용이 있는 경우에만 정리 작업을 수행합니다.
    if [[ -s "$FAILED_ARCHIVES_LOG_FILE" ]]; then
      # @ 실패 로그에 기록된 각 압축 파일을 읽어 삭제합니다.
      while IFS= read -r file_to_delete; do
        if [[ -n "$file_to_delete" && -f "$file_to_delete" ]]; then
          log_and_status 0 "실패한 작업의 아티팩트 삭제: $file_to_delete" "cleanup"
          rm -f "$file_to_delete"
        fi
      done < "$FAILED_ARCHIVES_LOG_FILE"
    fi
  fi

  # @ 시작 시점 타임스탬프 임시 파일 삭제
  rm -f "$START_TIMESTAMP_FILE"
  # @ 실패한 아카이브 로그 파일 삭제
  rm -f "$FAILED_ARCHIVES_LOG_FILE"
  log_and_status 0 "======================= 스크립트 종료 ========================" "system"
}

# ! @ 백업을 본격적으로 시작하기 전에 시스템의 필수 조건들을 점검합니다.
pre_run_checks() {
  # @ 1. AWS S3 연결성 점검
  # @ aws s3 ls 명령을 실행하여 S3 버킷 목록을 가져올 수 있는지 확인합니다.
  if ! aws s3 ls > /dev/null 2>&1; then
    log_and_status 8 "S3 연결에 실패했습니다. 권한 또는 네트워크 상태를 확인하세요." "system-check"
  fi
  log_and_status 0 "S3 연결 상태 양호." "system-check"

  # @ 2. 오래된 파일 삭제
  # @ 이 부분은 180일 이상 된 압축 파일을 'BACKUP_ROOT' 경로에서 찾아 삭제하는 기능입니다.
  # log_and_status 0 "Starting to delete files older than 180 days." "cleanup"
  # if ! find "$BACKUP_ROOT" -type f -name "*.tar.zst" -mtime +180 -print0 | xargs -0 -r rm; then
  #     log_and_status 2 "An error occurred during old file cleanup. Check permissions." "cleanup"
  # fi
  # log_and_status 0 "Old file cleanup process finished." "cleanup"

  # @ 3. 디스크 사용량 점검
  local threshold=90 # @ 디스크 사용량 임계치를 90%로 설정
  local over_limit_partitions=""
  # @ df -h 결과를 파싱하여 각 마운트 지점의 사용량을 확인합니다.
  # @ awk 'NR>1 {print $5 " " $6}': 헤더(첫 번째 줄)를 제외하고, 5번째(사용량%)와 6번째(마운트 지점) 필드를 추출합니다.
  while read -r use mount; do
    local percent="${use%\%}" # @ '%' 문자를 제거하여 숫자만 추출
    if ((percent >= threshold)); then
      # @ 사용량이 임계치를 넘으면 해당 파티션 정보를 변수에 추가
      over_limit_partitions+="${mount}(${percent}%) "
    fi
  done < <(df -h | awk 'NR>1 {print $5 " " $6}')

  # @ 임계치를 넘은 파티션이 하나라도 있으면 로그를 남기고 스크립트를 종료합니다.
  if [[ -n "$over_limit_partitions" ]]; then
    log_and_status 1 "디스크 사용량이 ${threshold}%를 초과했습니다. 확인 필요한 파티션: ${over_limit_partitions}" "system-check"
  fi
  log_and_status 0 "디스크 공간 양호." "system-check"
}

# ! 현재 파일 목록과 이전 백업 시점의 파일 목록을 비교하여, 새로 추가되거나 변경된 파일들의 목록(diff)을 생성합니다.
  # @ $1: tag - 작업을 식별하는 태그.
  # @ $2: backup_path - 파일 변경을 감지할 디렉토리 경로.
  # @ $3: include_pattern - 감지할 파일의 패턴.
  # @ 성공 시 종료 코드 0과 함께 diff 파일의 경로를 표준 출력으로 반환합니다. 변경 사항이 없으면 3을 반환합니다.
generate_diff_list() {
  local tag="$1"
  local backup_path="$2"
  local include_pattern="$3"

  # @ 백업 대상 경로가 실제로 존재하는지, 디렉토리인지 확인합니다.
  if [[ ! -d "$backup_path" ]]; then
    log_and_status 6 "백업 경로를 찾을 수 없거나 디렉토리가 아닙니다: $backup_path" "$tag"
    return 6 # tar 실패 코드와 유사한 오류 코드를 사용
  fi

  local list_dir="${FILE_LISTS_DIR}/${tag}"             # @ 작업별 목록 저장 디렉토리
  mkdir -p "$list_dir"                                    # @ 디렉토리가 없으면 생성
  local current_list="${list_dir}/${tag}_current.txt"   # @ 현재 파일 목록 파일
  local previous_list="${list_dir}/${tag}_previous.txt" # @ 이전 백업 시점의 파일 목록 파일
  local diff_list="${list_dir}/${tag}_diff.txt"         # @ 변경된 파일 목록만 담을 파일

  # @ 다음 실행을 위해 현재 목록 파일을 비웁니다.
  true > "$current_list"

  # @ 'find' 명령으로 백업 경로에서 대상 파일을 찾습니다. '*.tar.zst' 파일은 제외합니다.
  # @ 'stat -c %Y'로 각 파일의 최종 수정 시간을 가져옵니다.
  # @ "타임스탬프 파일경로" 형식으로 현재 목록 파일에 기록합니다.
  find "$backup_path" -type f -name "$include_pattern" ! -name "*.tar.zst" -print0 | while IFS= read -r -d '' filepath; do
    local timestamp
    timestamp=$(stat -c %Y "$filepath")
    echo "$timestamp $filepath" >> "$current_list"
  done
  # @ 'comm' 명령어로 비교하기 위해 목록을 정렬합니다.
  sort -o "$current_list" "$current_list"

  # @ 이전 백업 목록 파일이 존재하는 경우,
  if [[ -f "$previous_list" ]]; then
    # @ 'comm -23' : 두 파일(current, previous)을 비교
        # @ '-2': 두 번째 파일(previous_list)에만 있는 라인을 출력하지 않습니다.
        # @ '-3': 두 파일 모두에 있는 라인을 출력하지 않습니다.
        # @ 결과적으로, 첫 번째 파일(current_list)에만 있는 라인만 'diff_list'에 저장됩니다.
    comm -23 "$current_list" "$previous_list" > "$diff_list"
  else
    # @ 이전 백업이 없었다면(최초 실행 등), 모든 파일을 새 파일로 간주하여 그대로 복사합니다.
    cp "$current_list" "$diff_list"
  fi

  # @ '! -s' : diff 파일의 크기가 0인지 (비어있는지) 확인합니다.
  if [[ ! -s "$diff_list" ]]; then
    return 3
  fi

  # @ 성공적으로 diff 목록을 생성했으면, diff 파일의 경로를 표준 출력으로 내보내 호출자가 사용할 수 있게 합니다.
  echo "$diff_list"
  return 0
}

# ! 'sync' 모드(직접 동기화) 백업을 처리합니다.
  # @ $1: tag -> 작업 태그.
  # @ $2: backup_path -> 동기화할 원본 로컬 디렉토리.
  # @ $3: diff_list -> 검증에 사용할, 변경된 파일 목록이 담긴 파일 경로.
  # @ 성공 시 0, 실패 시 4를 반환합니다.
handle_sync_mode() {
  local tag="$1"
  local backup_path="$2"
  local diff_list="$3"
  local year
  year=$(date '+%Y')

  local files_to_process_list
  files_to_process_list=$(mktemp)

  if [[ -n "$DEBUG_MONTH" ]]; then
    log_and_status 0 "DEBUG_MONTH=${DEBUG_MONTH}가 설정되어, 해당 월의 파일만 처리합니다." "$tag"
    while IFS= read -r line; do
      local filepath="${line#* }"
      if [[ -z "$filepath" || ! -f "$filepath" ]]; then continue; fi
      local month
      month=$(date -d "@$(stat -c %Y "$filepath")" "+%Y%m")
      if [[ "$month" == "$DEBUG_MONTH" ]]; then
        echo "$line" >> "$files_to_process_list"
      fi
    done < "$diff_list"
  else
    cp "$diff_list" "$files_to_process_list"
  fi

  if [[ ! -s "$files_to_process_list" ]]; then
    log_and_status 3 "처리할 새로운 백업 파일이 없습니다 (필터: DEBUG_MONTH=${DEBUG_MONTH:-'없음'}). 경로: $backup_path" "$tag"
    rm "$files_to_process_list"
    return 0
  fi

  if [[ -z "$DEBUG_MONTH" ]]; then
    local s3_target_uri="s3://${S3_BUCKET_NAME}/${year}/${backup_path#${BACKUP_ROOT}/}"
    log_and_status 0 "'$tag' 작업의 S3 동기화를 시작합니다. 대상: ${s3_target_uri}" "$tag"
    if ! aws s3 sync "$backup_path" "$s3_target_uri" --exclude "*.tar.zst" --exclude "infra_utils/*" 2>>"$LOG_FILE"; then
      rm "$files_to_process_list"; return 4
    fi
  else
    log_and_status 0 "'$tag' 작업의 S3 개별 파일 업로드를 시작합니다 (DEBUG_MONTH=${DEBUG_MONTH})." "$tag"
    while IFS= read -r line; do
      local filepath="${line#* }"
      if [[ -z "$filepath" || ! -f "$filepath" ]]; then continue; fi
      local s3_key="${year}/${filepath#${BACKUP_ROOT}/}"
      local s3_uri="s3://${S3_BUCKET_NAME}/${s3_key}"
      if ! aws s3 cp "$filepath" "$s3_uri" 2>>"$LOG_FILE"; then
        log_and_status 4 "S3 업로드 실패: $filepath" "$tag"
        rm "$files_to_process_list"; return 4
      fi
    done < "$files_to_process_list"
  fi

  log_and_status 0 "'$tag' 작업의 S3 업로드가 완료되었습니다. 업로드된 파일 검증 및 이동 준비를 시작합니다..." "$tag"
  local verification_failed=false
  local move_list_file
  move_list_file=$(mktemp)

  while IFS= read -r line; do
    local filepath="${line#* }"
    if [[ -z "$filepath" || ! -f "$filepath" ]]; then continue; fi

    local s3_key="${year}/${filepath#${BACKUP_ROOT}/}"
    if ! verify_s3_upload "$tag" "$filepath" "$s3_key"; then
      verification_failed=true; break
    fi
    printf "%s\0" "$filepath" >> "$move_list_file"
  done < "$files_to_process_list"

  rm "$files_to_process_list"

  if [[ "$verification_failed" == true ]]; then
    rm "$move_list_file"
    return 4 # @ 검증 실패
  fi

  log_and_status 0 "'$tag' 작업의 S3 업로드가 성공적으로 검증되었습니다." "$tag"

  # @ 검증이 완료된 파일들을 이동합니다.
  if ! move_original_files "$tag" "$move_list_file" "$year"; then
    rm "$move_list_file"
    return 2 # @ 이동 실패
  fi

  rm "$move_list_file"
  return 0
}

# ! 'comp' 모드(압축 후 업로드) 백업을 처리합니다.
# @ $1: tag - 작업 태그.
# @ $2: diff_list - 변경된 파일 목록이 담긴 파일 경로.
# @ 성공 시 0, 실패 시 0이 아닌 값을 반환합니다.
handle_comp_mode() {
  local tag="$1"
  local diff_list="$2"

  local sorted_diff_list="${diff_list%_diff.txt}_sorted_diff.txt"
  # @ 1. 압축할 파일들을 그룹화하기 위해, diff 목록을 가공하여 새로운 정렬된 목록을 만듭니다.
  # @ 'cut | sort | while' 파이프라인을 통해 이 작업을 수행합니다.
  cut -d' ' -f2- "$diff_list" | sort | while IFS= read -r filepath; do
    if [[ ! -f "$filepath" ]]; then continue; fi
    local parent_dir
    parent_dir=$(dirname "$filepath") # @ 파일이 속한 부모 디렉토리
    local month
    # @ 파일의 최종 수정 시간을 기준으로 "YYYYMM" 형식의 월을 추출합니다.
    month=$(date -d "@$(stat -c %Y "$filepath")" "+%Y%m")

    # @ 디버깅용: 특정 월만 처리하도록 필터링
    if [[ -n "$DEBUG_MONTH" && "$month" != "$DEBUG_MONTH" ]]; then
      continue # @ 지정된 월이 아니면 건너뛰기
    fi

    # @ "부모디렉토리|월|파일경로" 형식으로 출력합니다. 이 형식은 나중에 그룹화의 기준이 됩니다.
    echo "${parent_dir}|${month}|${filepath}"
  done | sort > "$sorted_diff_list" # @ 부모디렉토리와 월 순서로 정렬하여 파일에 저장

  local all_uploads_successful=true
  local current_group_key="" # @ 현재 처리 중인 그룹을 식별하는 키 (예: "/backup/game3/log|2025-07")
  local files_for_current_group=() # @ 현재 그룹에 속한 파일들의 목록을 담는 배열

  # @ 2. 정렬된 목록을 한 줄씩 읽으며, 동일한 그룹(부모디렉토리+월)에 속한 파일들을 모아 압축 파일 처리를 합니다.
  while IFS='|' read -r parent_dir month filepath; do
    if [[ ! -f "$filepath" ]]; then continue; fi

    local group_key="${parent_dir}|${month}"
    # @ 첫 번째 파일인 경우, 현재 그룹 키를 설정합니다.
    if [[ -z "$current_group_key" ]]; then
      current_group_key="$group_key"
    # @ 그룹 키가 이전 라인과 달라진 경우, 이전까지 모았던 그룹의 압축 파일 처리를 시작합니다.
    elif [[ "$current_group_key" != "$group_key" ]]; then
      process_archive_group "$tag" "$current_group_key" "${files_for_current_group[@]}"
      if [[ $? -ne 0 ]]; then all_uploads_successful=false; fi # @ 처리 실패 시 플래그 설정

      # @ 다음 그룹을 위해 현재 그룹 키를 새로 설정하고 파일 목록 배열을 초기화합니다.
      current_group_key="$group_key"
      files_for_current_group=()
    fi
    # @ 현재 파일을 현재 그룹의 파일 목록 배열에 추가합니다.
    files_for_current_group+=("$filepath")
  done < "$sorted_diff_list"

  # @ 3. 루프가 끝난 후, 마지막으로 남아있는 그룹에 대한 압축 파일 처리를 수행합니다.
  if [[ ${#files_for_current_group[@]} -gt 0 ]]; then
    process_archive_group "$tag" "$current_group_key" "${files_for_current_group[@]}"
    if [[ $? -ne 0 ]]; then all_uploads_successful=false; fi
  fi

  rm "$sorted_diff_list" # @ 작업이 끝난 임시 목록 파일을 삭제합니다.

  if [[ "$all_uploads_successful" == false ]]; then
    return 4 # @ 하나라도 업로드에 실패했다면 전체 작업 실패로 간주
  fi
  return 0
}

# ! 하나의 파일 그룹을 받아 압축, S3 업로드, 검증, 원본 삭제의 전체 과정을 처리합니다.
# @ $1: tag - 작업 태그.
# @ $2: group_key - 처리할 그룹의 키 (예: "/path/to/dir|YYYY-MM").
# @ $@: files_to_archive - 그룹에 속한 모든 파일 경로들의 배열.
process_archive_group() {
  local tag="$1"
  local group_key="$2"
  shift 2 # @ 첫 두 개의 인자(tag, group_key)를 제거하여, 나머지 모든 인자를 파일 목록으로 쉽게 다룰 수 있게 합니다.
  local files_to_archive=("$@") # @ 나머지 인자들을 배열로 저장

  local parent_dir
  parent_dir=$(echo "$group_key" | cut -d'|' -f1) # @ 그룹 키에서 부모 디렉토리 추출
  local month
  month=$(echo "$group_key" | cut -d'|' -f2)    # @ 그룹 키에서 월(YYYYMM) 추출
  local year
  year=${month:0:4} # @ YYYYMM 형식에서 앞 4자리(연도)를 추출

  # @ 최종 압축 파일 파일의 이름을 생성합니다.
  # @ ex) "GZ_LOG_202507_log.tar.zst"
  local archive_name
  archive_name="${tag}_${month}_$(basename "$parent_dir").tar.zst"
  local archive_path="${parent_dir}/${archive_name}"

  # @ 'tar' 명령어에 파일 목록을 안전하게 전달하기 위해, 파일 경로들을 NULL 문자로 구분하여 임시 파일에 저장합니다.
  local list_file
  list_file=$(mktemp) # @ 고유한 이름의 임시 파일을 생성
  printf "%s\0" "${files_to_archive[@]}" > "$list_file"

  # @ 1. 압축 파일 생성 또는 업데이트
  create_or_update_archive "$tag" "$archive_path" "$list_file"
  local archive_status=$?
  if [[ $archive_status -ne 0 ]]; then
    # @ 압축/검증 실패 시, 정리 대상 파일로 경로를 기록합니다.
    echo "$archive_path" >> "$FAILED_ARCHIVES_LOG_FILE"
    rm "$list_file"; return $archive_status;
  fi

  # @ S3에 업로드할 객체 키를 생성합니다. 이 경로는 생성된 압축 파일의 위치를 기준으로 합니다.
  local s3_key="${year}/${archive_path#${BACKUP_ROOT}/}"

  # @ 2. S3에 업로드 및 검증
  upload_and_verify_s3 "$tag" "$archive_path" "$s3_key"
  local upload_status=$?
  if [[ $upload_status -ne 0 ]]; then
    # @ 업로드/검증 실패 시, 정리 대상 파일로 경로를 기록합니다.
    echo "$archive_path" >> "$FAILED_ARCHIVES_LOG_FILE"
    rm "$list_file"; return $upload_status;
  fi

  # @ 3. 압축 파일 이동
  local dest_path="${BACKUP_ROOT}/${year}/${archive_path#${BACKUP_ROOT}/}"
  local dest_dir
  dest_dir=$(dirname "$dest_path")

  if ! mkdir -p "$dest_dir"; then
    log_and_status 2 "압축 파일 이동 대상 디렉토리 생성 실패: $dest_dir" "$tag"; rm "$list_file"; return 2;
  fi

  if ! mv "$archive_path" "$dest_path"; then
    log_and_status 2 "압축 파일 이동 실패: $archive_path -> $dest_path" "$tag"; rm "$list_file"; return 2;
  fi
  log_and_status 0 "압축 파일을 성공적으로 이동했습니다: $dest_path" "$tag"

  # @ 4. 원본 파일 삭제
  delete_original_files "$tag" "$list_file"
  local delete_status=$?

  rm "$list_file" # @ 사용이 끝난 임시 파일 삭제
  return $delete_status
}

# @ 파일 목록을 받아 '.tar.zst' 압축 파일을 생성하거나, 기존 파일에 내용을 추가(업데이트)합니다.
# @ $1: tag - 작업 태그.
# @ $2: archive_path - 생성/업데이트할 압축 파일의 전체 경로.
# @ $3: list_file - 압축할 파일 목록이 담긴 임시 파일 (NULL 문자로 구분됨).
# @ 성공 시 0, tar 실패 시 6, 압축 파일 검증 실패 시 9를 반환합니다.
create_or_update_archive() {
  local tag="$1"
  local archive_path="$2"
  local list_file="$3"

  local tar_options=()
  local action_log=""
  # @ 동일한 월에 대한 압축 파일 파일이 이미 존재하는 경우,
  if [[ -f "$archive_path" ]]; then
    # @ 'tar --update (-u)'': 기존 압축 파일에 있는 파일보다 더 최신 파일만 추가합니다.
    tar_options=("--zstd" "--update" "-f" "$archive_path")
    action_log="기존 압축 파일에 파일 추가"
  else
    # @ 압축 파일 파일이 없으면 새로 생성합니다.
    # @ 'tar --create (-c)'': 새로운 압축 파일를 생성합니다.
    tar_options=("--zstd" "-cf" "$archive_path")
    action_log="새 압축 파일 생성"
  fi

  log_and_status 0 "${action_log}: ${archive_path}" "$tag"
  # @ 'tar' 명령어 실행.
  # @ '--null -T "$list_file"': NULL 문자로 구분된 파일 목록을 읽어 처리하므로, 파일 이름에 공백이나 특수문자가 있어도 안전합니다.
  if ! tar "${tar_options[@]}" --null -T "$list_file" 2>>"$LOG_FILE"; then
    log_and_status 6 "tar 명령어 실행 실패: $archive_path" "$tag"
    return 6
  fi

  log_and_status 0 "압축 파일 무결성 검증 중: ${archive_path}" "$tag"
  # @ 'tar -tf': 압축 파일의 내용을 읽어 목록을 출력합니다. 이 과정에서 파일이 손상되었다면 오류가 발생합니다.
  # @ '&> /dev/null': 정상적인 경우의 출력은 필요 없으므로 버립니다.
  if ! tar -tf "$archive_path" &> /dev/null; then
    log_and_status 9 "압축 파일 파일이 손상되었을 수 있습니다: ${archive_path}" "$tag"
    return 9
  fi
  log_and_status 0 "압축 파일 무결성 검증 완료: ${archive_path}" "$tag"
  return 0
}

# @ 단일 파일을 S3에 업로드하고 검증합니다.
# @ $1: tag - 작업 태그.
# @ $2: local_file_path - S3에 업로드할 로컬 파일의 경로.
# @ $3: s3_key - S3에 저장될 객체 키.
# @ 성공 시 0, 실패 시 4를 반환합니다.
upload_and_verify_s3() {
  local tag="$1"
  local local_file_path="$2"
  local s3_key="$3"
  local s3_uri="s3://${S3_BUCKET_NAME}/${s3_key}"

  log_and_status 0 "S3 업로드 시작: $local_file_path -> $s3_uri" "$tag"
  # @ 'aws s3 cp': 단일 파일을 S3에 복사합니다.
  if ! aws s3 cp "$local_file_path" "$s3_uri" 2>>"$LOG_FILE"; then
    log_and_status 4 "S3 업로드 실패: $local_file_path" "$tag"
    return 4 # 업로드 실패
  fi

  # @ 업로드 후 검증
  if ! verify_s3_upload "$tag" "$local_file_path" "$s3_key"; then
    return 4 # 검증 실패
  fi

  return 0 # 성공
}

# @ S3에 업로드된 객체의 크기를 로컬 파일과 비교하여 검증합니다.
# @ $1: tag - 작업 태그.
# @ $2: local_file_path - 검증할 로컬 파일의 경로.
# @ $3: s3_key - 검증할 S3 객체의 키.
# @ 성공 시 0, 실패 시 4를 반환합니다.
verify_s3_upload() {
  local tag="$1"
  local local_file_path="$2"
  local s3_key="$3"

  # @ 로그 출력을 위해 S3 URI를 생성합니다.
  local s3_uri="s3://${S3_BUCKET_NAME}/${s3_key}"

  local local_size
  local_size=$(stat -c%s "$local_file_path")
  local s3_size
  s3_size=$(aws s3api head-object --bucket "$S3_BUCKET_NAME" --key "$s3_key" --query ContentLength --output text 2>>"$LOG_FILE")

  if [[ "$local_size" == "$s3_size" ]]; then
    log_and_status 0 "S3 업로드 검증 완료: $s3_uri" "$tag"
    return 0
  else
    log_and_status 4 "S3 검증 실패 (크기 불일치): $local_file_path. 로컬: ${local_size}, S3: ${s3_size}" "$tag"
    return 4
  fi
}

# @ 성공적으로 S3에 백업된 원본 파일들을 삭제합니다.
# @ $1: tag - 작업 태그.
# @ $2: list_file - 삭제할 파일 목록이 담긴 임시 파일 (NULL 문자로 구분됨).
# @ 성공 시 0, 실패 시 2를 반환합니다.
delete_original_files() {
  local tag="$1"
  local list_file="$2"

  log_and_status 0 "백업 완료된 원본 파일들을 삭제합니다..." "$tag"
  # @ 'xargs'를 사용하여 파일 목록을 'rm' 명령어에 전달하여 삭제합니다.
  # @ -0: 입력이 NULL 문자로 구분되었음을 명시합니다.
  # @ -r: 입력이 비어있으면 `rm`을 실행하지 않습니다.
  # @ -a: 표준 입력 대신 파일에서 입력을 읽습니다.
  if ! xargs -0 -r -a "$list_file" rm; then
    log_and_status 2 "원본 파일 삭제에 실패했습니다. 파일 권한 등을 확인하세요." "$tag"
    return 2
  fi
  log_and_status 0 "원본 파일들을 성공적으로 삭제했습니다." "$tag"
  return 0
}

# @ 성공적으로 S3에 백업된 원본 파일들을 연도별 디렉토리로 이동합니다.
# @ $1: tag - 작업 태그.
# @ $2: list_file - 이동할 파일 목록이 담긴 임시 파일 (NULL 문자로 구분됨).
# @ $3: year - 파일을 이동할 대상 연도(YYYY).
# @ 성공 시 0, 실패(디렉토리 생성 또는 이동 실패) 시 2를 반환합니다.
move_original_files() {
  local tag="$1"
  local list_file="$2"
  local year="$3"

  log_and_status 0 "백업 완료된 원본 파일들을 이동합니다..." "$tag"

  local move_failed=false
  while IFS= read -r -d '' filepath; do
    if [[ -z "$filepath" || ! -f "$filepath" ]]; then continue; fi

    # @ 이동할 대상 경로를 구성합니다. 예: /backup/2025/game1/db/file.bak
    local dest_path="${BACKUP_ROOT}/${year}/${filepath#${BACKUP_ROOT}/}"
    local dest_dir
    dest_dir=$(dirname "$dest_path")

    # @ 대상 디렉토리가 없으면 생성합니다.
    if ! mkdir -p "$dest_dir"; then
      log_and_status 2 "이동 대상 디렉토리 생성 실패: $dest_dir" "$tag"; move_failed=true; break;
    fi

    # @ 파일을 이동합니다.
    if ! mv "$filepath" "$dest_path"; then
      log_and_status 2 "원본 파일 이동 실패: $filepath -> $dest_path" "$tag"; move_failed=true; break;
    fi
  done < "$list_file"

  if [[ "$move_failed" == true ]]; then return 2; fi

  log_and_status 0 "원본 파일들을 성공적으로 이동했습니다." "$tag"
  return 0
}

# ! ==================================================================================================
# !                                    MAIN EXECUTION (메인 실행 로직)
# ! ==================================================================================================
main() {
  # @ --- 중복 실행 방지 (Mutual Exclusion) ---
  # @ exec 9>>"$LOCK_FILE": 파일 디스크립터 9번을 잠금 파일에 쓰기+추가 모드로 연결합니다.
  # @ 스크립트가 종료될 때까지 이 파일 디스크립터는 유지됩니다.
  exec 9>>"$LOCK_FILE"
  # @ flock -n 9: 파일 디스크립터 9번에 대해 non-blocking 잠금을 시도합니다.
    # @ 성공 시: 잠금을 획득하고 즉시 다음 코드를 실행합니다. (다른 프로세스가 잠금을 잡고 있지 않음)
    # @ 실패 시: 즉시 0이 아닌 종료 코드를 반환합니다. (다른 프로세스가 이미 잠금을 잡고 있음)
  # @ 스크립트 시작 시점 기록을 위한 임시 파일 생성
  START_TIMESTAMP_FILE=$(mktemp)
  # @ 실패한 압축 파일 목록을 기록할 임시 파일 생성 및 변수 export
  FAILED_ARCHIVES_LOG_FILE=$(mktemp)
  export FAILED_ARCHIVES_LOG_FILE

  if ! flock -n 9; then
    log_and_status 7 "스크립트가 이미 실행 중입니다. 새로운 실행을 중단합니다." "system"
  fi

  # @ --- 로깅 및 정리(cleanup) 설정 ---
  LOG_DIR=$(dirname "$LOG_FILE")
  mkdir -p "$LOG_DIR" # @ 로그 디렉토리가 없으면 생성
  echo "0" > "${LOG_DIR}/01_s3_backup.status" # @ 스크립트 시작 시, 상태를 '성공(0)'으로 초기화
  # @ trap cleanup EXIT INT TERM: 스크립트가 어떤 이유로든(정상종료-EXIT, Ctrl+C-INT, kill-TERM) 종료될 때 'cleanup' 함수를 실행하도록 예약합니다.
  trap cleanup EXIT INT TERM

  log_and_status 0 "======================= 스크립트 시작 ======================" "system"
  pre_run_checks # @ 사전 점검 함수 호출

  # @ --- 모든 백업 작업 순차 처리 ---
  # @ 'BACKUP_JOBS' 배열에 정의된 각 작업을 순회합니다.
  for job in "${BACKUP_JOBS[@]}"; do
    # @ 각 작업을 서브셸에서 실행하여, 하나의 작업이 실패하더라도 다른 작업에 영향을 주지 않도록 격리합니다.
    (
      # @ 'IFS='|'' : 파이프(|)를 구분자로 하여 문자열을 필드로 나눕니다.
      # @ 'read -r ... <<< "$job"': here-string을 사용하여 job 변수의 내용을 읽어 각 변수(mode, tag 등)에 할당합니다.
      IFS='|' read -r mode tag backup_path include_pattern <<< "$job"

      log_and_status 0 "작업 시작: [${tag}] | 모드: [${mode}] | 경로: [${backup_path}]" "$tag"

      # @ 1. 변경된 파일 목록 생성
      local diff_list
      # @ 명령어 치환 '$(...)'을 사용하여 'generate_diff_list' 함수의 표준 출력을 'diff_list' 변수에 저장합니다.
      diff_list=$(generate_diff_list "$tag" "$backup_path" "$include_pattern")
      local diff_status=$? # @ `generate_diff_list` 함수의 종료 코드를 저장합니다.

      # @ 2. 변경 목록 생성 결과에 따라 분기
      if [[ $diff_status -eq 0 ]]; then # @ 성공 (변경 파일 있음)
        local backup_successful=false
        # @ 설정된 모드에 따라 적절한 핸들러 함수를 호출합니다.
        if [[ "$mode" == "sync" ]]; then
          handle_sync_mode "$tag" "$backup_path" "$diff_list" && backup_successful=true
        elif [[ "$mode" == "comp" ]]; then
          handle_comp_mode "$tag" "$diff_list" && backup_successful=true
        fi

        # @ 백업 핸들러가 성공적으로 완료되었으면,
        if [[ "$backup_successful" == true ]]; then
          log_and_status 0 "작업 '$tag'이(가) 성공적으로 완료되었습니다. 다음 백업을 위해 파일 목록을 업데이트합니다." "$tag"
          # @ 다음 실행 시 비교를 위해, 현재 파일 목록을 이전 파일 목록으로 덮어씁니다.
          local list_dir="${FILE_LISTS_DIR}/${tag}"
          cp "${list_dir}/${tag}_current.txt" "${list_dir}/${tag}_previous.txt"
        else
          # @ 백업 핸들러(sync 또는 comp)에서 오류가 발생한 경우
          log_and_status 4 "작업 '$tag'이(가) 실패했습니다. 파일 목록은 업데이트되지 않습니다." "$tag"
        fi
      elif [[ $diff_status -ne 3 ]]; then # @ 오류 (변경 없음(3)이 아닌 다른 오류)
        log_and_status "$diff_status" "작업 '$tag'의 변경 목록 생성 중 오류가 발생했습니다." "$tag"
      else
        log_and_status 3 "작업에 대한 새로운 백업 파일이 없습니다. 경로: $backup_path" "$tag"
      fi
      log_and_status 0 "작업 종료: [${tag}]" "$tag"
    )
  done
}

# @ --- 스크립트 실행 ---
# @ main 함수를 호출하여 스크립트의 모든 로직을 시작합니다.
main