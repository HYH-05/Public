#!/usr/bin/env bash
## This script backup data to aws s3 backup script. In ubuntu-24.04.
## Created by sjyun on 2025-06-19. Version 25.6.24 Modified by sjyun on 2025-06.24.
#@# 30 1 * * * /bin/bash /root/34_idc-to-aws-db-backup.sh > /dev/null 2>&1
#@# 30 1 * * * su - root -c '/bin/bash /root/34_idc-to-aws-db-backup.sh > /dev/null 2>&1'
# set -ex

set -o pipefail

## aws s3 sync /backup/game5/db/ s3://${S3_BUCKET_NAME}/game5/db/ --no-progress  --exclude "*" --include "*.bak" --dryrun

FILE_LIST_AWS="/var/log/backup-log/file-status/01-aws-s3-list.txt"
FILE_LIST_LOCAL="/var/log/backup-log/file-status/02-aws-local-list.txt"
FILE_LIST_DIFF="/var/log/backup-log/file-status/03-diff-list.txt"
AWS_RECURSIVE_LOG="/var/log/backup-log/aws_recursive_diff.log"

LOG_DIR=$(dirname "$FILE_LIST_AWS")
if [[ ! -d "$LOG_DIR" ]]; then
    mkdir -p "$LOG_DIR"
fi

S3_BUCKET_NAME="example-backup-bucket"
BACKUP_DIR_01="/backup"
## ------------------------------------------------------------------------------------------------------------

echo "0" > "$(dirname "$AWS_RECURSIVE_LOG")/backup.status"

LOG_FILE="/var/log/backup-log/aws-backup.log"
exec > >(tee -a "$LOG_FILE") 2>&1


run_msg_info() {
    local info_code=$1
    local info_msg="$2"

    echo "$(date '+%Y-%m-%d %H:%M:%S') sj_scripts [info] code:${info_code} Executing: ${info_msg}"

    eval "$info_msg"
    local status=$?

    if [ ${status} -eq 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') sj_scripts [info] code:${info_code} success."
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') sj_scripts [error] code:${info_code} failed with status ${status}."
    fi
}

log_msg_info() {
        local info_code=$1
        local info_msg=$2

        echo "$(date '+%Y-%m-%d %H:%M:%S') sj_scripts [info] code:${info_code} ${info_msg}"
}

log_msg_error() {
        local err_code=$1
        local err_msg=$2

        echo "$(date '+%Y-%m-%d %H:%M:%S') sj_scripts [error] code:${err_code} ${err_msg}"
        echo "${err_code}" > "$(dirname "$AWS_RECURSIVE_LOG")/backup.status"
## exit "${err_code}";
}

## ------------------------------------------------------------------------------------------------------------
readarray -t product_01 < <(find /backup/ -maxdepth 1 -mindepth 1 -type d -printf "%P\n")
#product_01=($(find /backup/ -maxdepth 1 -mindepth 1 -type d -printf "%P\n" | xargs))

aws_connect_test() {
if /usr/bin/env aws s3 ls s3://${S3_BUCKET_NAME}/ &>/dev/null ; then
        log_msg_info 1 "/usr/bin/env aws s3 ls s3://${S3_BUCKET_NAME}/ success."
else
        log_msg_error 1 "/usr/bin/env aws s3 ls s3://${S3_BUCKET_NAME}/ failed."
        exit 1
fi;
}

file_check_aws_upload() {
for product_02 in "${product_01[@]}"; do
        if [ -n "$(find ${BACKUP_DIR_01}/${product_02}/db/ -type f \( -name '*.bak' -o -name '*.tar.gz' \) -mtime -7 -print -quit )" ]; then

        run_msg_info 2 "/usr/bin/env aws s3 sync ${BACKUP_DIR_01}/${product_02}/db/ s3://${S3_BUCKET_NAME}/${product_02}/db/ --exclude '*' --include '*.bak' --include '*.tar.gz' --no-progress"
        else
        log_msg_error 2 "failed ${product_02} -mtime -7 -print -quit"
        fi;
done
}

#################

aws_s3_ls_recursive() {

echo "$(date +%Y%m%d-%H:%M:%S) sj_scripts aws-backup [info]3: /usr/bin/env aws s3 ls s3://${S3_BUCKET_NAME}/ --recursive" >  ${FILE_LIST_AWS}
/usr/bin/env aws s3 ls s3://${S3_BUCKET_NAME}/ --recursive       >> ${FILE_LIST_AWS}

echo "$(date +%Y%m%d-%H:%M:%S) sj_scripts aws-backup [info]4: Finding all local DB files (excluding .trn)..." > "${FILE_LIST_LOCAL}"
find /backup/ -type d -name "db" -exec find {} -type f ! -name "*.trn" \; >> "${FILE_LIST_LOCAL}"

grep -v "sj_scripts" ${FILE_LIST_AWS}  | awk  '{print $NF}'                                                     >  ${FILE_LIST_DIFF}
grep -v "sj_scripts" ${FILE_LIST_LOCAL}  | awk -F"/backup/" '{print $NF}'        >> ${FILE_LIST_DIFF}
##################
sort ${FILE_LIST_DIFF} | uniq -c | sort | awk '{$1=$1; print}' | grep -cv "^2"  > "$(dirname "$AWS_RECURSIVE_LOG")/backup.status"
#################
} >> ${AWS_RECURSIVE_LOG} 2>&1


echo "$(date +%Y%m%d-%H:%M:%S) sj_scripts aws-backup [info]: ##### start. ###############################################################"

aws_connect_test
file_check_aws_upload
aws_s3_ls_recursive

echo "$(date +%Y%m%d-%H:%M:%S) sj_scripts aws-backup [info]: ##### end. ###############################################################"