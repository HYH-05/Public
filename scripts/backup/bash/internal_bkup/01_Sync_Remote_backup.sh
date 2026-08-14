#!/usr/bin/bash
#### 30 01 * * *  /usr/bin/bash /root/01_Sync_backup.sh
#### 30 00 * * 6  /usr/bin/bash /root/01_Sync_backup.sh
export LANG=en
count=$(cat /root/variable/NUM_01.txt)

if [[ $count -ge 5 ]]; then
    count=0
else
    count=$((count + 1))
fi
echo $count > /root/variable/NUM_01.txt

backup_dir="/backup/LMS-Live/sync_$count"
backup_dir2="/backup/sprint-Live/sync_$count"
log_file="/var/log/remote/01_Sync_Remote_backup.sh.log"

if [ ! -d "/var/log/remote" ] ; then mkdir -p "/var/log/remote" ; fi

RSYNC_SERVER_1=""  # 원본: 외부 rsync 서버 IP
RSYNC_SERVER_2=""  # 원본: 외부 rsync 서버 IP

function sync_bak {
  from=$1
  to=$2
  if [ ! -d "$to" ] ; then mkdir -p $to ; fi
  echo "$(date '+%Y-%m-%d %H:%M:%S') - yh_scripts [info]: rsync -av --delete $RSYNC_SERVER_1::infra/backup/sync/today$from $to" >> $log_file
  rsync -av --delete $RSYNC_SERVER_1::infra/backup/sync/today$from $to 2>> $log_file
  if [ $? -ne 0 ]; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') - yh_scripts [error]: rsync error while syncing from $from to $to" >> $log_file
  else
      echo "$(date '+%Y-%m-%d %H:%M:%S') - yh_scripts [info]: rsync completed successfully from $from to $to" >> $log_file
  fi

  if [ -z "$(cat "$log_file" | grep -v "{\|}" | grep -i "error\|failed")" ] ; then
      echo "0" > /var/log/remote/01_Sync_backup.status
  else
      echo "1" > /var/log/remote/01_Sync_backup.status
  fi
}

function sync_bak2 {
  from=$1
  to=$2
  if [ ! -d "$to" ] ; then mkdir -p $to ; fi
  echo "$(date '+%Y-%m-%d %H:%M:%S') - yh_scripts [info]: rsync -av --delete $RSYNC_SERVER_1::infra/backup/sync/today$from $to" >> $log_file
  rsync -av --delete $RSYNC_SERVER_2::infra/backup/sync/today$from $to 2>> $log_file
  if [ $? -ne 0 ]; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') - yh_scripts [error]: rsync error while syncing from $from to $to" >> $log_file
  else
      echo "$(date '+%Y-%m-%d %H:%M:%S') - yh_scripts [info]: rsync completed successfully from $from to $to" >> $log_file
  fi

  if [ -z "$(cat "$log_file" | grep -v "{\|}" | grep -i "error\|failed")" ] ; then
      echo "0" > /var/log/remote/01_Sync_backup.status
  else
      echo "1" > /var/log/remote/01_Sync_backup.status
  fi
}

rm -f /backup/sprint-Live/today
rm -f /backup/LMS-Live/today

ln -sf $backup_dir2  /backup/sprint-Live/today
ln -sf $backup_dir /backup/LMS-Live/today

sync_bak /usr-local/ $backup_dir/usr-local/
sync_bak /etc/ $backup_dir/etc/
sync_bak /root/ $backup_dir/root/
sync_bak /var/ $backup_dir/var/
sync_bak /home/ $backup_dir/home/
sync_bak /data/ $backup_dir/data/

sync_bak2 /usr-local/ $backup_dir2/usr-local/
sync_bak2 /etc/ $backup_dir2/etc/
sync_bak2 /root/ $backup_dir2/root/
sync_bak2 /var/ $backup_dir2/var/
sync_bak2 /home/ $backup_dir2/home/
sync_bak2 /data/ $backup_dir2/data/


find $backup_dir -type f -name "" -not -name "$(date +%Y%m%d)" -delete
echo $(date +%Y%m%d) > $backup_dir/$(date +%Y%m%d)

find $backup_dir2 -type f -name "" -not -name "$(date +%Y%m%d)" -delete
echo $(date +%Y%m%d) > $backup_dir2/$(date +%Y%m%d)


#echo $(date +%Y%m%d) > $backup_dir/$(date +%Y%m%d)
#echo $(date +%Y%m%d) > $backup_dir2/$(date +%Y%m%d)

## restore list : /etc/elasticsearch/ /etc/graylog/ /etc/nginx/

#touch $backup_dir
#touch $backup_dir2



#if [ -z "$(cat /var/log/gitlab/gitlab-backup.log | grep -v "{\|}" | grep -i "error\|failed")" ] ; then
#        echo "0" > /var/log/remote/backup.status
#else
#        echo "1" > /var/log/remote/backup.status
#fi

