#!/usr/bin/env bash

# --- 설정 ---
# 대상 S3 버킷 이름
S3_BUCKET="example-backup-bucket"

# 동기화할 로컬 폴더 경로 목록 (배열)
SOURCE_DIRS=(
  "/backup/2025/game1/game_log"
  "/backup/2025/game2/game_log"
  "/backup/2025/game3/game_log"
)
# S3 버킷 내에서 파일이 저장될 경로 목록 (배열, SOURCE_DIRS와 순서 일치)
S3_DESTINATION_PATHS=(
  "2025/game1/game_log"
  "2025/game2/game_log"
  "2025/game3/game_log"
)

# --- 함수 ---

# AWS CLI 설치 여부 및 설정 확인 함수
check_aws_cli() {
  if ! command -v aws &> /dev/null; then
    echo "오류: AWS CLI가 설치되어 있지 않습니다. 스크립트를 실행하려면 먼저 설치해주세요." >&2
    return 1
  fi

  if ! aws sts get-caller-identity &> /dev/null; then
    echo "오류: AWS CLI 인증 정보가 올바르지 않습니다. 'aws configure'를 실행하여 설정을 확인해주세요." >&2
    return 1
  fi
  return 0
}

# S3에 폴더를 동기화하는 함수
# 인자: $1 = 소스 디렉토리, $2 = S3 버킷, $3 = S3 내 목적지 경로
sync_to_s3() {
  local source_path="$1"
  local bucket_name="$2"
  local destination_path="$3"
  local s3_uri="s3://${bucket_name}/${destination_path}"

  # --- 소스 폴더 유효성 검사 ---
  if [ ! -d "$source_path" ]; then
    echo "오류: 소스 폴더 '$source_path'가 존재하지 않거나 디렉토리가 아닙니다." >&2
    return 1
  fi

  echo "'$source_path' 폴더의 내용을 '$s3_uri'(으)로 동기화를 시작합니다..."

  # --- S3 동기화 ---
  # aws s3 sync 명령어는 지정된 폴더의 내용만 동기화합니다.
  if aws s3 sync "$source_path" "$s3_uri"; then
    echo "S3 동기화가 성공적으로 완료되었습니다: $s3_uri"
  else
    echo "오류: S3 동기화에 실패했습니다." >&2
    return 1
  fi
}

# --- 실행 ---

# 1. AWS CLI 상태 확인
check_aws_cli
if [ $? -ne 0 ]; then
  exit 1
fi

echo "S3 동기화 작업을 시작합니다."

# 2. SOURCE_DIRS와 S3_DESTINATION_PATHS 배열의 길이가 같은지 확인
if [ ${#SOURCE_DIRS[@]} -ne ${#S3_DESTINATION_PATHS[@]} ]; then
  echo "오류: SOURCE_DIRS와 S3_DESTINATION_PATHS 배열의 길이가 일치하지 않습니다." >&2
  exit 1
fi

# 3. 각 경로 쌍에 대해 동기화 함수 실행
for i in "${!SOURCE_DIRS[@]}"; do
  echo "--- 작업 ${i} 시작 ---"
  sync_to_s3 "${SOURCE_DIRS[$i]}" "$S3_BUCKET" "${S3_DESTINATION_PATHS[$i]}"
  if [ $? -ne 0 ]; then
    echo "오류: ${SOURCE_DIRS[$i]} 동기화 중 문제가 발생했습니다. 다음 작업을 계속 진행합니다." >&2
  fi
  echo "--- 작업 ${i} 완료 ---"
done

echo "모든 동기화 작업이 완료되었습니다."
exit 0
