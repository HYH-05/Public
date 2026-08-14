#!/bin/env bash

set -e

set -o pipefail

LOG_FILE="/data/backup/auto/01_gitlab_upgrade.log"
LOG_FILE_DIR=$(dirname "$LOG_FILE")
if [ ! -d "${LOG_FILE_DIR}" ]; then mkdir -p "${LOG_FILE_DIR}"; fi

# @ 모든 표준, 에러-> LOG_FILE
exec > >(tee -a "$LOG_FILE") 2>&1

echo "업그레이드 시작 시간: $(date)"

# 16.x 버전 수동 업그레이드
declare -a versions16=(
  "16.3.9"
  "16.7.10"
  "16.11.10"
)

for version in "${versions16[@]}"; do
  echo "===================================="
  echo "Installing GitLab EE ${version} (manual)"
  url="https://packages.gitlab.com/gitlab/gitlab-ee/packages/ubuntu/jammy/gitlab-ee_${version}-ee.0_amd64.deb/download.deb"
  wget --content-disposition "$url"
  file=$(ls gitlab-ee_${version}-ee.0_amd64.deb)
  sudo dpkg -i "$file"
  rm "$file"
done

# 17.x 버전 apt 업그레이드
declare -a versions17=(
  "17.1.8"
  "17.3.7"
  "17.5.5"
  "17.8.7"
  "17.11.3"
)

for version in "${versions17[@]}"; do
  echo "===================================="
  echo "Installing GitLab EE ${version} (APT)"
  sudo apt update
  sudo apt install -y gitlab-ee="${version}-ee.0"
done

echo "업그레이드 종료 시간: $(date)"