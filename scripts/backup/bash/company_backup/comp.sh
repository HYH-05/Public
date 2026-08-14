#!/usr/bin/env bash

#
# 설명: 이 스크립트는 지정된 여러 폴더를 각각 '.tar.zst' 형식으로 압축합니다.
# 사용법: 스크립트 내의 TARGET_DIRS와 ARCHIVE_PATHS 배열을 설정한 후 실행합니다.
#

# --- 설정 ---
# 압축할 폴더 경로 목록 (배열)
TARGET_DIRS=(
  #! "/backup/game1/game_log/Bishop/ChattingLog"

  "/backup/game9/game_log/AuthServer"
  "/backup/game9/game_log/BareaServer"
  "/backup/game9/game_log/GameServer"
  "/backup/game9/game_log/LobbyServer"
  "/backup/game9/game_log/RankServer"
  "/backup/game9/game_log/TrafficServer"

)

# 압축 파일이 저장될 경로와 파일 이름 목록 (배열, TARGET_DIRS와 순서 일치)
ARCHIVE_PATHS=(
  #! "/backup/2025/game1/game_log/Bishop/ChattingLog/ao_game_log_Bishop_ChattingLog.tar.zst"

  "/backup/2025/game9/game_log/AuthServer/sr_game_log_AuthServer.tar.zst"
  "/backup/2025/game9/game_log/BareaServer/sr_game_log_BareaServer.tar.zst"
  "/backup/2025/game9/game_log/GameServer/sr_game_log_GameServer.tar.zst"
  "/backup/2025/game9/game_log/LobbyServer/sr_game_log_LobbyServer.tar.zst"
  "/backup/2025/game9/game_log/RankServer/sr_game_log_RankServer.tar.zst"
  "/backup/2025/game9/game_log/TrafficServer/sr_game_log_TrafficServer.tar.zst"
)


# --- 함수 ---

# 압축 함수
# 인자: $1 = 압축할 폴더 경로, $2 = 압축 파일이 저장될 경로와 파일 이름
create_archive() {
  local source_dir="$1"
  local output_archive_path="$2"

  # 파이프라인으로 연결된 명령어 중 하나라도 실패하면 즉시 스크립트를 중단합니다.
  set -o pipefail

  # --- 대상 폴더 유효성 검사 ---
  # 제공된 경로0가 실제로 존재하는 디렉토리인지 확인합니다.
  if [ ! -d "$source_dir" ]; then
    echo "오류: '$source_dir'는 존재하지 않거나 디렉토리가 아닙니다." >&2
    return 1 # 함수 실패 시 반환
  fi

  # --- 압축 파일 경로 확인 ---
  # 압축 파일이 저장될 디렉토리가 존재하는지 확인하고, 없으면 생성합니다.
  local archive_dir
  archive_dir=$(dirname "$output_archive_path")
  if [ ! -d "$archive_dir" ]; then
    echo "알림: 압축 파일 저장 경로 '$archive_dir'가 존재하지 않아 새로 생성합니다."
    mkdir -p "$archive_dir" || { echo "오류: 디렉토리 '$archive_dir' 생성에 실패했습니다." >&2; return 1; }
  fi

  echo "'$source_dir' 폴더를 '$output_archive_path'(으)로 압축을 시작합니다..."

  # --- 폴더 압축 ---
  # tar 명령어를 사용하여 폴더를 zstd 형식으로 압축합니다.
  # --zstd: zstd 압축 알고리즘을 사용합니다.
  # -c: 새로운 아카이브를 생성합니다.
  # -f: 아카이브 파일 이름을 지정합니다.
  if tar --zstd -cf "$output_archive_path" -C "$(dirname "$source_dir")" "$(basename "$source_dir")"; then
    echo "압축이 성공적으로 완료되었습니다: $output_archive_path"
  else
    echo "오류: '$source_dir' 폴더 압축에 실패했습니다." >&2
    return 1 # 함수 실패 시 반환
  fi
}

# --- 실행 ---
# TARGET_DIRS와 ARCHIVE_PATHS 배열의 길이가 같은지 확인
if [ ${#TARGET_DIRS[@]} -ne ${#ARCHIVE_PATHS[@]} ]; then
  echo "오류: TARGET_DIRS와 ARCHIVE_PATHS 배열의 길이가 일치하지 않습니다." >&2
  exit 1
fi

# 각 경로 쌍에 대해 압축 함수 실행
for i in "${!TARGET_DIRS[@]}"; do
  create_archive "${TARGET_DIRS[$i]}" "${ARCHIVE_PATHS[$i]}"
  if [ $? -ne 0 ]; then
    echo "오류: ${TARGET_DIRS[$i]} 압축 중 문제가 발생했습니다. 다음 압축을 건너뜁니다." >&2
    # exit 1 # 모든 압축이 중요하면 이 줄의 주석을 해제하여 즉시 종료
  fi
done

echo "모든 압축 작업이 완료되었습니다."
exit 0