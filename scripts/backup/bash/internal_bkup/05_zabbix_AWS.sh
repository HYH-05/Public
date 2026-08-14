#!/bin/bash
Date=$(date +%Y%m%d)
backup_dir="/backup"
s3_bucket="s3://example-infra-bucket/zabbix"
log_file="/var/log/remote/05_zabbix_AWS.log"
if [ ! -d "/var/log/remote" ] ; then mkdir -p "/var/log/remote" ; fi


zabbix_Latest=$(ls -lt "$backup_dir/zabbix" | tail -n +2 | head -n 1 | awk '{print $9}')
zabbix_DB_Latest=$(ls -lt "$backup_dir/zabbix_DB" | tail -n +2 | head -n 1 | awk '{print $9}')

# 오늘 날짜 정보 가져오기
today=$(date +%Y-%m-%d)

backupload() {
    local folder_name="$1"          # 로컬 폴더 이름
    local latest="$2"               # 최신 디렉토리
    local s3_subfolder="$3"         # S3 하위 폴더
    local tar_file="${backup_dir}/${folder_name}_${Date}.tar.gz"

    echo "$(date '+%Y-%m-%d %H:%M:%S') - Compressing ${folder_name} to ${tar_file}..." >> "$log_file"
    tar -cf - -C "$(dirname "$latest")" "$(basename "$latest")" | pigz -p 4 -c > "$tar_file" 2>> "$log_file"

    echo "$(date '+%Y-%m-%d %H:%M:%S') - Uploading ${tar_file} to ${s3_bucket}/${s3_subfolder}/${folder_name}_${Date}.tar.gz..." >> "$log_file"
    aws s3 cp "$tar_file" "${s3_bucket}/${s3_subfolder}/${folder_name}_${Date}.tar.gz" 2>> "$log_file"

    echo "$(date '+%Y-%m-%d %H:%M:%S') - Removing local tar file ${tar_file}..." >> "$log_file"
    rm "$tar_file" 2>> "$log_file"
}


day_of_month=$(date +%d)
day_of_week=$(date +%w)

# 첫 번째 일요일인지 확인
if [[ "$day_of_week" -eq 0 && "$day_of_month" -le 7 ]]; then
  echo "###############################  $(date '+%Y-%m-%d %H:%M:%S') start. ###############################################################" >> "$log_file"

  backupload "zabbix" "$backup_dir/zabbix/$zabbix_Latest" "zabbix"
  backupload "zabbix_DB" "$backup_dir/zabbix_DB/$zabbix_DB_Latest" "zabbix_DB"

  echo "###############################  $(date '+%Y-%m-%d %H:%M:%S') end. ###############################################################" >> "$log_file"
else
  echo "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@  $(date '+%Y-%m-%d %H:%M:%S') Not First Sunday of the month. @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@" >> "$log_file"
fi


