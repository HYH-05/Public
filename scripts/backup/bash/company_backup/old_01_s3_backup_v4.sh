#!/usr/bin/env bash

  # @ 이 스크립트는 로컬 서버의 특정 디렉토리에서 변경된 파일을 감지하고, 이를 AWS S3 버킷으로 백업하는 자동화 스크립트입니다.
  # @ 백업 방식은 'sync' (압축 없이 동기화)와 'comp' (압축 후 동기화) 두 가지 모드를 지원합니다.
  # @ 스크립트의 중복 실행을 방지하고, 실행 전 시스템 상태를 점검하며, 백업 완료 후 임시 파일을 정리하는 기능을 포함합니다.

# ! 스크립트 중복 실행 방지 (flock)
  # @ 이 스크립트가 이미 실행 중인 경우, 새로운 스크립트 인스턴스는 즉시 종료됩니다.
  # @ 스크립트가 어떤 이유로든 (정상 종료, 오류, 강제 종료 등) 끝나면, 'trap' 명령어를 통해 `cleanup` 함수가 항상 실행됩니다.

# ! 정리 로직
  # @ 'cleanup' 함수는 작업 중에 생성된 임시 파일 등 불필요한, 또는 손상된 파일을 삭제하여 깨끗한 상태를 유지합니다.
  # @ 'flock' 잠금은 스크립트 종료 시 자동으로 해제됩니다.

# ! 백업 전 필수 점검 항목
  # @ S3 연결 테스트: AWS S3 버킷에 정상적으로 접근하고 통신할 수 있는지 확인합니다.
  # @ 디스크 용량 확인: 현재 시스템의 디스크 사용량이 90%를 초과하지 않았는지 확인합니다.
    # @ 만약 90%를 초과하면, 추가 백업으로 인한 디스크 부족 문제를 방지하기 위해 스크립트가 종료됩니다.
  # // 오래된 데이터 정리: 360일이 지난 오래된 백업 파일을 로컬에서 삭제하는 기능입니다.
    # @ 현재는 비활성화되어 있으나, 필요에 따라 활성화하여 로컬 저장 공간을 관리할 수 있습니다.

# ! 백업 프로세스 개요
  # @ 스크립트 하단에 정의된 's3_backup' 함수 호출 목록을 순서대로 실행합니다.
  # @ 각 's3_backup' 호출은 특정 경로의 파일을 지정된 모드(sync 또는 comp)로 백업합니다.
  # @ 예시: s3_backup "comp" "GZ" "/backup/game3/log" "*"

# ! 변경 사항 감지 로직 (핵심 기능)
  # @ 1. 현재 파일 목록 생성: 지정된 백업 경로(`backup_path`) 내의 현재 파일 목록을 생성 시간 기준으로 만듭니다.
  # @ 2. 이전 목록과 비교: 이전에 백업된 파일 목록(`previous_list`)과 현재 목록(`current_list`)을 비교합니다.
  # @ 3. 변경된 파일 식별: `comm -23` 명령어를 사용하여 `current_list`에만 존재하는 파일(새로 추가되거나 변경된 파일)을 식별합니다.
  # @ 4. 백업 중지: 만약 변경된 파일이 하나도 없다면, 불필요한 백업 작업을 방지하기 위해 로그를 남기고 해당 백업 작업은 중지됩니다.

# ! 'sync' 모드 (압축 없이 동기화)
  # @ 변경된 파일만 S3로 직접 업로드합니다.
  # @ 로컬 파일 시스템의 디렉토리 구조를 S3 버킷 내에 그대로 유지합니다.
  # @ `aws s3 sync` 명령어를 사용하여 효율적으로 동기화합니다.
  # @ 업로드 후에는 로컬 파일과 S3 객체의 크기를 비교하여 데이터 무결성을 검증합니다  .

# ! 'comp' 모드 (압축 후 동기화)
  # @ 변경된 파일들을 월별로 그룹화하여 `.tar.zst` 형식으로 압축합니다.
  # @ 압축된 파일은 S3 버킷으로 업로드됩니다.
  # @ 이미 해당 월의 압축 파일이 존재하는 경우, `tar --update` 옵션을 사용하여 기존 아카이브에 변경된 파일만 추가합니다.
  # @ 압축 및 업로드 후에는 로컬 압축 파일과 S3 객체의 크기를 비교하여 데이터 무결성을 검증합니다.

# * =================== 스크립트 상태 코드 목록 ===================
# * 스크립트의 종료 상태를 나타내는 코드입니다. 각 코드는 특정 오류 또는 정상 상태를 의미합니다.
# * 0 : 정상 종료 (오류 없이 스크립트가 완료됨)
# * 1 : 디스크 용량 90% 이상 초과 (백업 진행 불가)
# * 2 : 파일 삭제 실패 (예: `xargs rm` 명령어 오류)
# * 3 : 백업할 새로운 파일 없음 (변경 사항이 감지되지 않음)
# * 4 : S3 `sync` 또는 `cp` 명령 실패 (S3 통신 또는 파일 전송 오류)
# * 5 : 압축 파일이 이미 존재함 (동일한 이름의 압축 파일이 이미 있어 충돌 발생, 현재는 `tar --update`로 처리되어 발생 가능성 낮음)
# * 6 : 압축 실패 (예: `tar` 명령어 오류)
# * 7 : 스크립트가 이미 동작 중 (flock에 의해 중복 실행 방지)
# * 8 : AWS S3 통신 실패 (AWS CLI 설정 또는 네트워크 문제)
# * 9 : 압축 파일 검증 실패 (압축된 파일이 원본과 일치하지 않음)
# * 9 : 압축 후 압축 파일 검증 실패(원본과 다름)

# @ 파이프라인 오류 처리: 파이프(|)로 연결된 명령어 중 하나라도 실패하면 전체 파이프라인을 실패로 간주하고 즉시 종료합니다.
set -o pipefail

# ! --- 전역 경로 및 상수 선언 ---
# @ 스크립트 전반에 걸쳐 사용되는 중요한 경로와 상수들을 정의합니다.
readonly BACKUP_ROOT="/backup"             # @ 백업 대상 파일들이 위치한 최상위 로컬 디렉토리 경로
readonly FILE_LISTS_DIR="/infra_utils/.file_lists"       # @ 변경분 비교를 위해 생성되는 임시 파일 목록들이 저장될 디렉토리 경로
readonly LOG_FILE="/var/log/backup_log/01_s3_backup.log" # @ 스크립트 실행 로그가 기록될 파일의 전체 경로
readonly LOCK_FILE="/var/run/s3_backup.lock"             # @ 스크립트 중복 실행을 방지하기 위한 락 파일의 경로
readonly S3_BUCKET_NAME="example-backup-bucket"                  # @ 백업 파일을 업로드할 대상 S3 버킷의 이름

# @ 로그 파일 디렉토리 생성
# @ 로그 파일이 저장될 디렉토리(`LOG_DIR`)가 존재하지 않으면, `mkdir -p` 명령어를 사용하여 생성합니다.
LOG_DIR=$(dirname "$LOG_FILE")
if [[ ! -d "$LOG_DIR" ]]; then
  mkdir -p "$LOG_DIR"
fi
# @ 스크립트 시작 시 상태 초기화
# @ 스크립트가 시작될 때, `backup.status` 파일에 '0' (정상)을 기록하여 이전 실행의 오류 상태를 초기화합니다.
echo "0" > "${LOG_DIR}/backup.status"

# ! ============= cleanup 함수: 스크립트 종료 시 임시 파일 및 당일 생성된 압축 파일 정리 =============
# @ 이 함수는 스크립트가 어떤 방식으로든 종료될 때(정상 종료, Ctrl+C, kill 시그널 등) 자동으로 호출됩니다.
cleanup() {
  # @ 변경분 비교를 위해 생성된 임시 목록 파일 삭제
  # @ `FILE_LISTS_DIR` 디렉토리가 존재하면, 해당 디렉토리 내에서 `_current.txt` 또는 `_diff.txt`로 끝나는 모든 파일을 찾아 삭제합니다.
  if [[ -d "$FILE_LISTS_DIR" ]]; then
    log_and_status 0 "Cleaning up intermediate list files (*_current.txt, *_diff.txt)..." "cleanup"
    find "$FILE_LISTS_DIR" -type f \( -name "*_current.txt" -o -name "*_diff.txt" \) -delete
  fi

  # @ 스크립트 종료 상태 확인
  local exit_status
  exit_status=$(cat "${LOG_DIR}/backup.status")

  # @ 스크립트가 오류로 종료된 경우에만 당일 생성된 압축 파일 삭제
  if [[ "$exit_status" -ne 0 ]]; then
    log_and_status 0 "Script exited with an error (status: ${exit_status}). Cleaning up today's .tar.zst archive files..." "cleanup"
    # @ find 옵션 설명:
      # @ -daystart: mtime(수정 시간) 계산 기준을 파일이 수정된 시점이 아닌, 당일 00:00 (자정)으로 설정합니다.
      # @ -mtime 0: 오늘 (0일 전) 수정된 파일을 검색합니다.
      # @ -print0: 찾은 파일 경로의 끝에 NULL 문자를 붙여서 출력합니다. 이는 파일명에 공백이나 특수 문자가 포함되어 있어도 'xargs'가 안전하게 처리할 수 있도록 합니다.
    # @ xargs 명령어 옵션 설명:
      # @ -0: 입력을 NULL 문자로 구분하여 읽습니다. (`-print0`과 함께 사용되어야 합니다.)
      # @ -r`: `xargs`로 전달될 입력이 없을 경우 `rm` 명령어를 실행하지 않습니다. (불필요한 오류 방지)
    if ! find "${BACKUP_ROOT}" -type f -name "*.tar.zst" -daystart -mtime 0 -print0 | xargs -0 -r rm; then
      log_and_status 2 "An error occurred during today's archive file cleanup. Please check manually." "cleanup"
    fi
    log_and_status 0 "Cleanup of today's archive files is complete." "cleanup"
  fi
}
# @ `trap` 명령어: 스크립트 종료 시 `cleanup` 함수 실행 설정
# @ `trap cleanup EXIT INT TERM`은 스크립트가 다음 시그널을 받을 때 `cleanup` 함수를 실행하도록 설정합니다.
# @ - `EXIT`: 스크립트가 정상적으로 종료될 때.
# @ - `INT`: `Ctrl+C`와 같은 인터럽트 시그널을 받을 때.
# @ - `TERM`: `kill` 명령어로 종료 시그널을 받을 때.
# @ 이 설정을 통해 스크립트가 어떤 상황에서든 종료될 때 항상 정리 작업이 수행되도록 보장합니다.
trap cleanup EXIT INT TERM

# ! =================== log_and_status 함수: 로그 기록 및 스크립트 상태 관리 ===================
# @ 이 함수는 스크립트의 실행 상태를 로그 파일에 기록하고, 오류 발생 시 스크립트를 종료하는 역할을 합니다.
log_and_status() {
    local code="$1"         # @ 첫 번째 인자: 스크립트 상태 코드 (0은 정상, 0이 아니면 오류를 의미)
    local msg="$2"          # @ 두 번째 인자: 로그 메시지 (예: "S3 connection OK.")
    local tag="$3"          # @ 세 번째 인자: 로그 태그 (예: "system", "GZ", "AO" 등, 어떤 모듈/영역에서 발생한 로그인지 식별)
    local log_level="info"  # @ 기본 로그 레벨은 'info'로 설정

    # @ 상태 코드에 따른 로그 레벨 설정
    # @ 전달된 `code`가 0이 아니면 (즉, 오류가 발생했으면), 로그 레벨을 'error'로 변경합니다.
    if [[ "$code" -ne 0 ]]; then
        log_level="error"
    fi

    # @ 로그 파일에 메시지 기록
    # @ `LOG_FILE`에 현재 날짜와 시간, 태그, 로그 레벨, 상태 코드, 메시지 형식으로 로그를 추가합니다.
    # @ `>>`는 기존 파일 내용에 이어서 추가하는 리다이렉션입니다.
    echo "$(date '+%Y-%m-%d %H:%M:%S') [${tag}] [${log_level}] code:${code} ${msg}" >> "$LOG_FILE"

    # @ 오류 발생 시 스크립트 즉시 종료
    # @ `code`가 0이 아닌 경우 (오류 상태), `backup.status` 파일에 해당 오류 코드를 기록하고,
    # @ `exit "$code"` 명령어를 사용하여 스크립트를 즉시 종료합니다.
    # @ 이는 심각한 오류 발생 시 더 이상의 작업을 중단하고 문제 해결을 유도하기 위함입니다.
    if [[ "$code" -ne 0 ]]; then
        echo "$code" > "${LOG_DIR}/backup.status"
        exit "$code"
    fi
}

# ! =================== pre_run_checks 함수: 스크립트 실행 전 필수 시스템 점검 ===================
# @ 이 함수는 백업 작업을 시작하기 전에 시스템의 안정성과 S3 연결 상태를 확인합니다.
pre_run_checks() {
    # @ 1. AWS S3 통신 상태 확인
    # @ `aws s3 ls` 명령어를 실행하여 AWS S3 버킷에 대한 접근 권한과 네트워크 연결 상태를 테스트합니다.
    # @ `> /dev/null 2>&1`은 명령어의 표준 출력(stdout)과 표준 에러(stderr)를 모두 `/dev/null`로 리다이렉션하여 화면에 아무것도 출력되지 않도록 합니다.
    # @ `if ! ...; then` 구문은 명령어가 실패했을 경우 (종료 코드가 0이 아닐 경우) 내부 블록을 실행합니다.
    if ! aws s3 ls > /dev/null 2>&1; then
        log_and_status 8 "S3 connection failed. Check credentials or network." "system-check"
    fi
    log_and_status 0 "S3 connection OK." "system-check"

    # # @ 2. 오래된 파일 삭제
    # # 이 섹션은 360일 이상 된 파일을 `BACKUP_ROOT` 경로에서 찾아 삭제하는 기능입니다.
    # # 현재는 주석 처리되어 비활성화되어 있습니다. 필요에 따라 주석을 해제하여 사용할 수 있습니다.
    # log_and_status 0 "Starting to delete files older than 360 days." "cleanup"
    # if ! find "$BACKUP_ROOT" -type f -mtime +360 -print0 | xargs -0 -r rm; then
    #     log_and_status 2 "An error occurred during old file cleanup. Check permissions." "cleanup"
    # fi
    # log_and_status 0 "Old file cleanup process finished." "cleanup"

    # @ 3. 디스크 용량 확인
    local threshold=90 # 디스크 사용량 임계값을 90%로 설정합니다.
    local over_limit_partitions="" # 임계치를 초과한 파티션 목록을 저장할 변수입니다.

    # @ `df -h` 명령어로 디스크 사용량 정보를 가져오고, `awk`로 사용률(%)과 마운트 지점만 추출합니다.
    # @ `NR>1`은 `awk`에게 헤더 라인(첫 번째 줄)을 건너뛰도록 지시합니다.
    # @ `while read -r use mount; do ... done < <(...)` 구문은 `df -h`와 `awk`의 출력을 한 줄씩 읽어 `use`와 `mount` 변수에 할당합니다.
    while read -r use mount; do
        local percent="${use%\%}" # @ `95%`와 같은 문자열에서 `%` 기호를 제거하고 숫자만 추출합니다.
        if ((percent >= threshold)); then
            # @ 현재 파티션의 사용률이 임계값(`threshold`) 이상이면, 해당 파티션 정보를 `over_limit_partitions` 변수에 추가합니다.
            over_limit_partitions+="${mount}(${percent}%) "
        fi
    done < <(df -h | awk 'NR>1 {print $5 " " $6}')

    # @ 임계치를 초과한 파티션이 하나라도 있는지 확인
    # @ `[[ -n "$over_limit_partitions" ]]`는 `over_limit_partitions` 변수가 비어있지 않은지 (즉, 임계치를 초과한 파티션이 있는지) 확인합니다.
    # @ 만약 임계치를 초과한 파티션이 있다면, 로그를 기록하고 스크립트를 종료합니다.
    if [[ -n "$over_limit_partitions" ]]; then
        log_and_status 1 "Disk usage over ${threshold}%. Partitions: ${over_limit_partitions}" "system-check"
    fi
    log_and_status 0 "Disk space OK." "system-check"
}

# ! =================== s3_backup 함수: 메인 백업 로직 실행 ===================
# @ 이 함수는 실제 백업 작업을 수행하는 핵심 함수입니다.
# @ 인자로 받은 모드(sync/comp), 태그, 로컬 백업 경로, 파일 패턴에 따라 백업을 진행합니다.
s3_backup() {
    # @ 함수 인자 할당
    local mode="$1"             # @ 백업 모드: "sync" (동기화) 또는 "comp" (압축 후 동기화)
    local tag="$2"              # @ 로그 및 파일 목록 관리에 사용될 태그 (예: "AO", "GZ")
    local backup_path="$3"      # @ 백업할 파일이 있는 로컬 시스템의 절대 경로
    local include_pattern="$4"  # @ 백업 대상 파일을 필터링할 glob 패턴 (예: "*", "*.bak")

    # @ 파일 목록 관리 경로 설정
    # @ 각 태그별로 현재, 이전, 변경된 파일 목록을 저장할 디렉토리와 파일 경로를 정의합니다。
    local list_dir="${FILE_LISTS_DIR}/${tag}"             # @ 태그별 파일 목록 디렉토리
    local current_list="${list_dir}/${tag}_current.txt"   # @ 현재 백업 시점의 파일 목록
    local previous_list="${list_dir}/${tag}_previous.txt" # @ 이전 백업 시점의 파일 목록
    local diff_list="${list_dir}/${tag}_diff.txt"         # @ 이전 백업 이후 변경된 파일 목록

    # @ 파일 목록 저장 디렉토리 생성
    # @ `mkdir -p`는 필요한 상위 디렉토리까지 한 번에 생성합니다.
mkdir -p "$list_dir"

    # @ 1. 현재 파일 목록 생성 (생성 시간 기준)
    # @ `find` 명령어를 사용하여 `backup_path` 내에서 `include_pattern`에 해당하는 파일을 찾습니다。
    # @ `! -name "*.tar.zst"`는 이미 압축된 파일은 제외합니다.
    # @ `-print0`과 `while IFS= read -r -d '' filepath; do ... done`은 파일명에 공백이나 특수 문자가 있어도 안전하게 처리하기 위한 표준 패턴입니다.
    find "$backup_path" -type f -name "$include_pattern" ! -name "*.tar.zst" -print0 | while IFS= read -r -d '' filepath; do
        local timestamp
        # @ rsync 환경을 고려하여, 파일의 수정 시간(mtime)을 기준으로 타임스탬프를 기록합니다.
        timestamp=$(stat -c %Y "$filepath")
        # @ `echo "$timestamp $filepath"`는 타임스탬프와 파일 경로를 `current_list` 파일에 기록합니다.
        echo "$timestamp $filepath" >> "$current_list"
    done
    # @ 생성된 목록 정렬
    # @ `sort -o`는 정렬된 결과를 원본 파일(`current_list`)에 덮어씁니다.
sort -o "$current_list" "$current_list"

    # @ 2. 이전 파일 목록과 비교하여 변경된 파일 목록(`diff_list`) 생성
    if [[ -f "$previous_list" ]]; then
        # @ `previous_list` 파일이 존재하면, `comm` 명령어를 사용하여 `current_list`와 `previous_list`를 비교합니다.
        # @ `comm -23`:
        # @   - `-2`: 두 번째 파일(`previous_list`)에만 있는 라인을 출력하지 않습니다.
        # @   - `-3`: 두 파일 모두에 있는 라인을 출력하지 않습니다.
        # @ 결과적으로, 첫 번째 파일(`current_list`)에만 있는 라인, 즉 새로 추가되거나 변경된 파일의 목록만 `diff_list`에 저장됩니다.
        comm -23 "$current_list" "$previous_list" > "$diff_list"
    else
        # @ `previous_list` 파일이 없으면 (스크립트 최초 실행 또는 이전 목록이 삭제된 경우),
        # @ `current_list`의 모든 파일을 변경된 것으로 간주하고 `diff_list`로 복사합니다.
        cp "$current_list" "$diff_list"
    fi

    # @ 변경된 파일 목록이 비어있지 않은 경우에만 백업 진행
    # @ `[[ -s "$diff_list" ]]`는 `diff_list` 파일의 크기가 0보다 큰지 (즉, 내용이 있는지) 확인합니다.
    if [[ -s "$diff_list" ]]; then
        if [[ "$mode" == "sync" ]]; then
            # @ --- 'sync' 모드: 압축 없이 S3로 동기화 ---
            # @ S3 대상 키 및 URI 생성
            # @ `s3_target_key`는 로컬 경로에서 `BACKUP_ROOT` 부분을 제거하여 S3 버킷 내의 상대 경로를 만듭니다.
            # @ `s3_target_uri`는 S3 버킷과 대상 키를 조합하여 S3 URI를 완성합니다.
            local s3_target_key="${backup_path#${BACKUP_ROOT}/}"
            local s3_target_uri="s3://${S3_BUCKET_NAME}/${s3_target_key}"

            log_and_status 0 "Starting S3 sync for '$tag' to ${s3_target_uri}" "$tag"
            # @ `aws s3 sync` 명령어 실행
            # @ `aws s3 sync`는 로컬 디렉토리와 S3 버킷 간의 파일 동기화를 수행합니다.
            # @ - `--exclude "*.tar.zst"`: `.tar.zst` 확장자를 가진 파일은 동기화에서 제외합니다.
            # @ - `--exclude "infra_utils/*"`: `infra_utils` 디렉토리 내의 파일은 동기화에서 제외합니다.
            # @ - `2>>"$LOG_FILE"`: 표준 에러(stderr)를 `LOG_FILE`에 추가합니다.
            if ! aws s3 sync "$backup_path" "$s3_target_uri" --exclude "*.tar.zst" --exclude "infra_utils/*" 2>>"$LOG_FILE"; then
                log_and_status 4 "S3 sync failed for path: ${backup_path}" "$tag"
            else
                log_and_status 0 "S3 sync completed for path: ${backup_path}. Starting verification..." "$tag"

                local verification_failed=false # @ 검증 실패 여부를 추적하는 플래그
                # @ S3 업로드 파일 검증
                # @ `diff_list`에서 파일 경로만 추출하여 각 파일에 대해 S3 업로드 검증을 수행합니다。
                # @ `awk '{print $2}' "$diff_list"`는 `diff_list` 파일에서 두 번째 필드(파일 경로)만 추출합니다.
                # @ `while IFS= read -r filepath; do ... done < <(...)`는 추출된 각 파일 경로를 `filepath` 변수에 할당하여 루프를 실행합니다.
                while IFS= read -r filepath; do
                    if [[ -z "$filepath" ]]; then
                        continue # @ 빈 줄은 건너뜁니다.
                    fi
                    # @ 파일 존재 여부 최종 확인
                    # @ 검증 직전에 파일이 삭제되었을 수 있으므로, 실제 파일이 존재하는지 다시 확인합니다.
                    if [[ ! -f "$filepath" ]]; then
                        log_and_status 4 "[ERROR] File disappeared before verification, skipping: $filepath" "$tag"
                        continue
                    fi

                    local local_size
                    # @ `stat -c%s "$filepath"`: 로컬 파일의 크기(바이트)를 가져옵니다.
                    local_size=$(stat -c%s "$filepath")

                    # @ S3 키 생성
                    # @ 로컬 파일 경로에서 `BACKUP_ROOT` 부분을 제거하여 S3 객체 키를 만듭니다.
                    # @ 예: `/backup/game1/db/file.bak` -> `ao/db/file.bak`
                    local s3_key="${filepath#${BACKUP_ROOT}/}"

                    local s3_size
                    # @ `aws s3api head-object`: S3 객체를 다운로드하지 않고 메타데이터(예: `ContentLength` - 크기)만 조회합니다.
                    # @ `--query ContentLength --output text`: `ContentLength` 필드만 텍스트 형식으로 추출합니다.
                    s3_size=$(aws s3api head-object --bucket "$S3_BUCKET_NAME" --key "$s3_key" --query ContentLength --output text 2>>"$LOG_FILE")

                    # @ 로컬 파일과 S3 객체 크기 비교
                    if [[ "$local_size" != "$s3_size" ]]; then
                        # @ 크기가 다르면 검증 실패로 간주하고 에러 로그를 직접 기록합니다。
                        # @ `log_and_status` 함수를 직접 호출하면 스크립트가 종료되므로, 여기서는 직접 `echo`로 로그를 남깁니다。
                        echo "$(date '+%Y-%m-%d %H:%M:%S') [${tag}] [error] code:4 S3 verification FAILED for: $filepath. Local size: ${local_size}, S3 size: ${s3_size}" >> "$LOG_FILE"
                        verification_failed=true # @ 검증 실패 플래그 설정
                        break # @ 하나라도 실패하면 더 이상 검증할 필요 없이 루프를 중단합니다。
                    fi
                done < <(cut -d' ' -f2- "$diff_list")

                # @ 모든 파일 검증 결과 처리
                if [[ "$verification_failed" == false ]]; then
                    # @ 모든 파일이 성공적으로 검증되었을 경우
                    log_and_status 0 "S3 sync for '$tag' VERIFIED." "$tag"
                    # @ 다음 실행을 위해 현재 파일 목록을 이전 파일 목록으로 복사하여 업데이트합니다。
                    cp "$current_list" "$previous_list"
                else
                    # @ 하나라도 검증에 실패했을 경우
                    log_and_status 4 "S3 sync verification failed for '$tag'. File list not updated." "$tag"
                fi
            fi

        elif [[ "$mode" == "comp" ]]; then
            # @ --- 'comp' 모드: 압축 후 S3로 동기화 ---
            local all_uploads_successful=true # @ 모든 압축/업로드 작업의 성공 여부를 추적하는 플래그
                      # @ 4. 변경된 파일들을 압축 그룹으로 묶기 위해 데이터 가공 및 정렬
                      # @ `diff_list`에서 파일 경로만 추출하여 각 파일에 대해 "부모디렉토리|월|전체경로" 형식으로 가공합니다.
                      # @ `sort` 명령어를 통해 디렉토리와 월 순서로 정렬하여 파일들을 그룹화할 준비를 합니다.
                      local sorted_diff_list="${list_dir}/${tag}_sorted_diff.txt"
                      cut -d' ' -f2- "$diff_list" | sort | while IFS= read -r filepath; do
                          # @ comp 모드에서 stat 오류를 방지하기 위해 파일 존재 여부 확인
                          if [[ ! -f "$filepath" ]]; then
                              continue
                          fi
                          local parent_dir
                          parent_dir=$(dirname "$filepath") # @ 파일의 부모 디렉토리 경로 추출
                          local month
                          local timestamp
                          # @ rsync 환경을 고려하여, 파일의 수정 시간(mtime)을 기준으로 타임스탬프를 기록합니다.
                          timestamp=$(stat -c %Y "$filepath")
                          # @ 타임스탬프를 "YYYY-MM" 형식으로 변환하여 월별 그룹화를 준비합니다.
                          month=$(date -d "@$timestamp" "+%Y-%m")
                          echo "${parent_dir}|${month}|${filepath}"
                      done | sort > "$sorted_diff_list" # @ 정렬된 결과를 임시 파일에 저장

                      local current_group_key=""      # @ 현재 처리 중인 압축 그룹의 키 (예: "/backup/game1/log|2025-07")
                      local files_for_current_group=() # @ 현재 그룹에 속한 파일들의 목록을 담을 배열

                      # @ 5. 정렬된 목록을 읽어 압축 그룹 처리
                      # @ `sorted_diff_list` 파일을 한 줄씩 읽어 `parent_dir`, `month`, `filepath` 변수에 할당합니다.
                      while IFS='|' read -r parent_dir month filepath; do
                          # @ 파일 존재 여부 최종 확인
                          # @ 처리 직전에 파일이 삭제되었을 수 있으므로, 실제 파일이 존재하는지 다시 확인합니다.
                          if [[ ! -f "$filepath" ]]; then
                              log_and_status 6 "[ERROR] File removed before processing, skipping: $filepath" "$tag"
                              continue
                          fi

                          local group_key="${parent_dir}|${month}" # @ 현재 파일의 그룹 키 생성

                          # @ 새로운 압축 그룹 시작 또는 첫 번째 파일 처리
                          if [[ -z "$current_group_key" ]]; then
                              current_group_key="$group_key" # @ 첫 그룹 키 설정
                          elif [[ "$current_group_key" != "$group_key" ]]; then
                              # @ 현재 그룹 키가 이전 그룹 키와 다르면, 이전 그룹에 모아둔 파일들을 압축/업로드합니다.
                              process_archive_group "$tag" "$current_group_key" "${files_for_current_group[@]}"
                              local process_status=$? # @ `process_archive_group` 함수의 종료 코드 확인
                              if [[ $process_status -ne 0 ]]; then
                                  all_uploads_successful=false # @ 하나라도 실패하면 전체 성공 플래그를 false로 설정
                              fi

                              # @ 새로운 그룹을 위해 현재 그룹 정보 초기화
                              current_group_key="$group_key"
                              files_for_current_group=()
                          fi

                          # @ 현재 파일 경로를 현재 그룹의 배열에 추가
                          files_for_current_group+=("$filepath")

                      done < "$sorted_diff_list"

                      # @ 6. 루프 종료 후, 마지막으로 처리되던 그룹에 대한 압축/업로드 수행
                      # @ `while` 루프가 끝난 후, `files_for_current_group` 배열에 남아있는 파일들이 있다면 (즉, 마지막 그룹이 처리되지 않았다면),
                      # @ 해당 그룹에 대해 `process_archive_group` 함수를 호출하여 압축 및 업로드를 수행합니다.
                    if [[ ${#files_for_current_group[@]} -gt 0 ]]; then
                        process_archive_group "$tag" "$current_group_key" "${files_for_current_group[@]}"
                        local process_status=$?
                        if [[ $process_status -ne 0 ]]; then
                            all_uploads_successful=false
                        fi
                    fi

                    rm "$sorted_diff_list" # @ 정렬에 사용된 임시 파일 삭제

                    # @ 모든 압축/업로드 작업 결과 처리
                    if [[ "$all_uploads_successful" == true ]]; then
                        # @ 모든 작업이 성공했을 때만 다음 실행을 위해 파일 목록을 업데이트합니다。
                        log_and_status 0 "All compression tasks for '$tag' completed successfully." "$tag"
                        cp "$current_list" "$previous_list"
                    else
                        # @ 하나라도 실패했을 경우, 파일 목록을 업데이트하지 않고 오류를 기록합니다。
                        log_and_status 4 "One or more tasks failed for '$tag'. File list not updated." "$tag"
                    fi
                fi

            else
                # @ 변경된 파일이 없을 경우
                # @ `diff_list`가 비어있으면 (즉, 변경된 파일이 없으면), 로그를 남기고 해당 백업 작업은 종료됩니다.
                log_and_status 3 "No new files to backup for '$tag' in path: $backup_path" "$tag"
            fi
}

# ! =================== process_archive_group 함수: 압축 및 S3 업로드 처리 ===================
# @ 이 함수는 특정 그룹의 파일들을 압축하고 S3로 업로드하는 작업을 수행합니다.
process_archive_group() {
    local tag="$1"        # @ 로그 및 태그에 사용될 태그 (예: "AO", "GZ")
    local group_key="$2"  # @ 현재 처리할 그룹의 키 (예: "/backup/game1/log|2025-07")
    shift 2               # @ 첫 두 개의 인자(`tag`, `group_key`)를 제거하여 나머지 인자들을 파일 목록으로 받습니다.
    local files_to_archive=("$@") # @ 나머지 모든 인자를 압축할 파일 목록 배열로 받습니다.

    # @ 그룹 키에서 부모 디렉토리와 월 정보 분리
    local parent_dir
    parent_dir=$(echo "$group_key" | cut -d'|' -f1) # @ 그룹 키에서 첫 번째 필드(부모 디렉토리) 추출
    local month
    month=$(echo "$group_key" | cut -d'|' -f2)      # @ 그룹 키에서 두 번째 필드(월) 추출

    # @ 압축 파일 이름 생성
    # @ 예: `AO_MatchAgent_2023-08.tar.zst`
    local archive_name
    archive_name="${tag}_$(basename "$parent_dir")_${month}.tar.zst"
    local archive_path="${parent_dir}/${archive_name}" # @ 압축 파일이 저장될 로컬 경로

    # @ 압축할 파일 목록을 임시 파일에 저장
    # @ `tar` 명령어의 `-T` 옵션은 파일 목록을 파일에서 읽어오도록 합니다.
    # @ 파일 목록이 많을 경우 명령줄 길이 제한을 피하기 위해 이 방법을 사용합니다.
    local list_file
    list_file=$(mktemp) # @ 안전하고 고유한 임시 파일 생성
    # @ 파일명에 공백이 포함된 경우를 안전하게 처리하기 위해 NULL 문자로 각 파일 경로를 구분하여 임시 파일에 기록합니다.
    printf "%s\0" "${files_to_archive[@]}" > "$list_file"

    local tar_options=() # @ `tar` 명령어 옵션을 저장할 배열
    local action_log=""  # @ 로그 메시지에 사용할 작업 설명

    # @ 압축 모드 결정: 새로 생성 또는 업데이트
    if [[ -f "$archive_path" ]]; then
        # @ 이미 해당 월의 압축 파일이 존재하면, `--update` 옵션을 사용하여 기존 아카이브에 변경된 파일만 추가합니다。
        tar_options=("--zstd" "--update" "-f" "$archive_path")
        action_log="Updating archive"
    else
        # @ 압축 파일이 없으면, `-cf` 옵션을 사용하여 새로운 아카이브를 생성합니다。
        tar_options=("--zstd" "-cf" "$archive_path")
        action_log="Creating new archive"
    fi

    log_and_status 0 "${action_log}: ${archive_path}" "$tag"
    # @ `tar` 명령어 실행
    # @ `--null` 옵션: `-T`로 지정된 파일 목록(`list_file`)이 NULL 문자로 구분되어 있음을 `tar`에 알립니다.
    # @ `tar "${tar_options[@]}" --null -T "$list_file"`: `tar_options` 배열의 모든 요소와 `--null`, `-T` 옵션으로 지정된 파일 목록을 사용하여 `tar` 명령어를 실행합니다.
    # @ `2>>"$LOG_FILE"`: 표준 에러를 로그 파일에 추가합니다.
    if ! tar "${tar_options[@]}" --null -T "$list_file" 2>>"$LOG_FILE"; then
        rm "$list_file" # @ 압축 실패 시 임시 파일을 먼저 삭제합니다.
        log_and_status 6 "tar command FAILED for: $archive_path" "$tag"
    fi

    # @ 압축 파일 무결성 검증
    log_and_status 0 "Verifying archive integrity: ${archive_path}" "$tag"
    if ! tar -tf "$archive_path" &> /dev/null; then
        rm "$list_file" # @ 검증 실패 시 임시 파일을 먼저 삭제합니다.
        log_and_status 9 "Archive verification FAILED: ${archive_path}" "$tag"
    fi
    log_and_status 0 "Archive integrity VERIFIED: ${archive_path}" "$tag"

    # @ S3 업로드 및 검증
    # @ S3 대상 키 접두사 및 URI 생성
    local s3_target_key_prefix="${parent_dir#${BACKUP_ROOT}/}"
    local s3_target_uri="s3://${S3_BUCKET_NAME}/${s3_target_key_prefix}/"

    log_and_status 0 "Uploading: $archive_path to $s3_target_uri" "$tag"
    # @ `aws s3 cp` 명령어로 압축 파일 S3 업로드
    # @ 생성 또는 업데이트된 압축 파일을 지정된 S3 URI로 복사합니다.
    if ! aws s3 cp "$archive_path" "$s3_target_uri" 2>>"$LOG_FILE"; then
        log_and_status 4 "S3 upload FAILED: $archive_path" "$tag"
    fi

    # @ 로컬 파일과 S3에 업로드된 파일의 크기 비교를 통한 업로드 검증
    local local_size
    local_size=$(stat -c%s "$archive_path") # @ 로컬 압축 파일의 크기 가져오기
    local s3_key="${s3_target_key_prefix}/${archive_name}" # @ S3 객체 키 생성

    local s3_size
    # @ `aws s3api head-object`: S3 객체를 다운로드하지 않고 메타데이터(크기)만 조회합니다.
    s3_size=$(aws s3api head-object --bucket "$S3_BUCKET_NAME" --key "$s3_key" --query ContentLength --output text 2>>"$LOG_FILE")

    # @ 크기 비교 및 검증 결과 로깅
    if [[ "$local_size" == "$s3_size" ]]; then
        log_and_status 0 "S3 upload VERIFIED: s3://${S3_BUCKET_NAME}/${s3_key}" "$tag"
    else
        log_and_status 4 "S3 verification FAILED: $archive_path. Local size: ${local_size}, S3 size: ${s3_size}" "$tag"
    fi

    # @ 원본 파일 삭제
    log_and_status 0 "Deleting original files..." "$tag"
    # @ `-0` 옵션: `xargs`가 NULL 문자를 기준으로 입력을 읽도록 설정합니다.
    # @ `-r` 옵션: 입력이 없을 경우 `rm` 명령어를 실행하지 않습니다.
    if ! xargs -0 -r -a "$list_file" rm; then
        rm "$list_file" # @ 파일 삭제 실패 시 임시 파일을 먼저 삭제합니다.
        log_and_status 2 "Failed to delete original files." "$tag"
    fi
    log_and_status 0 "Original files deleted successfully." "$tag"
}


# ! =================== 스크립트 실행부 (Main Execution Block) ===================
# @ 이 섹션은 스크립트가 시작될 때 가장 먼저 실행되는 부분입니다.
# @ `flock`을 사용한 스크립트 중복 실행 방지
# @ `exec 9>>"$LOCK_FILE"`: `LOCK_FILE`을 파일 디스크립터 9번에 쓰기 모(`>>`)로 연결합니다. 파일이 없으면 새로 생성됩니다.
exec 9>>"$LOCK_FILE"
# @ `flock -n 9`: 파일 디스크립터 9번에 대해 비블로킹(non-blocking) 잠금을 시도합니다.
# @ - `-n` 옵션은 잠금을 즉시 획득할 수 없을 경우 기다리지 않고 실패(non-zero 종료 코드)를 반환하도록 합니다.
# @ - `if ! flock -n 9; then ... fi`: 만약 다른 프로세스가 이미 락을 잡고 있어 잠금 획득에 실패하면,
# @   `log_and_status` 함수를 호출하여 스크립트가 이미 실행 중임을 로그에 기록하고 종료합니다.
if ! flock -n 9; then
    log_and_status 7 "Script is already running. Exiting." "system"
fi

log_and_status 0 "======================= SCRIPT START ======================" "system"

# @ 사전 점검 실행
# @ `pre_run_checks` 함수를 호출하여 S3 연결 상태와 디스크 용량을 확인합니다.
# @ 이 함수 내에서 오류가 발생하면 스크립트는 즉시 종료됩니다.
pre_run_checks

# ! ==================== s3_backup 함수 호출 정의
# ! 각 호출은 다음 4가지 인자를 가집니다
# ! %1 = 백업 모드 ("sync" 또는 "comp")
# ! %2 = 태그 (예: "AO", "GZ")
# ! %3 = 로컬 백업 대상 경로 (절대 경로)
# ! %4 = 대상 파일 패턴 (glob 패턴, 예: "*", "*.bak")

# @ 테스트 백업
s3_backup "comp" "AC" "/backup/game5/log" "*"

# @ AO 백업 설정
# s3_backup "sync" "AO"    "/backup/game1/db"       "*.bak"
# s3_backup "comp" "AO"   "/backup/game1/log"      "*"

# @ DK 백업 설정
# s3_backup "sync" "DK"    "/backup/game2/db"       "*.bak"
# s3_backup "comp" "DK"   "/backup/game2/log"      "*"

# @ GZ 백업 설정
# s3_backup "sync" "GZ"    "/backup/game3/db"       "*.bak"
# s3_backup "comp" "GZ"   "/backup/game3/log"      "*"

# @ NX 백업 설정
# s3_backup "sync" "NX"    "/backup/game10/db"       "*.bak"

# @ PT 백업 설정
# s3_backup "sync" "PT"  "/backup/game4/db"             "*.bak"
# readonly PT_FOLDERS=("00_Test" "01_Fury" "02_Babel" "03_Casa" "04_Ariel")
# for folder in "${PT_FOLDERS[@]}"; do
#     s3_backup "comp" "PT"   "/backup/game4/log/${folder}/BackupFile" "*"
# done

log_and_status 0 "======================= SCRIPT DONE ========================" "system"
# @ 스크립트 정상 종료 처리
# @ 스크립트가 모든 작업을 성공적으로 완료하면, `exec`로 열었던 파일 디스크립터 9번이 자동으로 닫히면서 `flock` 잠금이 해제됩니다.
# @ 이는 다음 스크립트 실행을 위해 시스템을 깨끗한 상태로 유지합니다.
