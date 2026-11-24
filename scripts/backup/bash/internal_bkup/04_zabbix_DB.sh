#!/bin/bash

REMOTE_SERVER=""  # 원본: 외부 rsync 서버 IP
REMOTE_USER="root"

REMOTE_PATH="/backup/db/"
LOCAL_PATH="/backup/zabbix_DB/"
log_file="/var/log/remote/04_zabbix_DB.log"

#latest_dir=$(sshpass -p "$REMOTE_PASSWORD" ssh "$REMOTE_USER@$REMOTE_SERVER" "ls -lt $REMOTE_PATH | tail -n +2 | head -n 1 | awk '{print \$9}'")
latest_dir=$(ssh "$REMOTE_USER@$REMOTE_SERVER" "ls -lt $REMOTE_PATH | tail -n +2 | head -n 1 | awk '{print \$9}'")

if [ ! -d "/var/log/remote" ] ; then mkdir -p "/var/log/remote" ; fi

if [ -n "$latest_dir" ]; then
    #rsync -av -e "sshpass -p $REMOTE_PASSWORD ssh" "$REMOTE_USER@$REMOTE_SERVER:$REMOTE_PATH/$latest_dir" "$LOCAL_PATH/"
    #echo "$(date '+%Y-%m-%d %H:%M:%S') - yh_scripts [info]: rsync -av x.x.x.x::infra/backup/db/$latest_dir "$LOCAL_PATH"" >> $log_file
    rsync -av $REMOTE_SERVER::sjyun/backup/db/$latest_dir "$LOCAL_PATH" 2>> $log_file
    if [ $? -ne 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - yh_scripts [error]: rsync error while syncing from $REMOTE_SERVER::sjyun/backup/db/$latest_dir to $LOCAL_PATH" >> $log_file
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - yh_scripts [info]: rsync completed successfully from $REMOTE_SERVER::sjyun/backup/db/$latest_dir to $LOCAL_PATH" >> $log_file
        find $LOCAL_PATH -maxdepth 1 -type d -mtime +42 -exec rm -r {} \;
        if [ $? -eq 0 ]; then
                echo "Deletion completed successfully."
        else
                echo "An error occurred during deletion."
        fi
    fi
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - yh_scripts [info]: $latest_dir/ 디렉토리를 찾을 수 없습니다." >> $log_file
    echo "$(date '+%Y-%m-%d %H:%M:%S') - yh_scripts [info]: rsync error while syncing from $REMOTE_SERVER::sjyun/backup/db/$latest_dir to $LOCAL_PATH" >> $log_file
fi

if [ -z "$(cat "$log_file" | grep -v "{\|}" | grep -i "error\|failed")" ] ; then
      echo "0" > /var/log/remote/04_zabbix_DB.status
else
      echo "1" > /var/log/remote/04_zabbix_DB.status
fi
