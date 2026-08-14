#!/usr/bin/bash
export LANG=en
count=$(cat /root/variable/NUM_02.txt)

if [[ $count -ge 5 ]]; then
    count=0
else
    count=$((count + 1))
fi
echo $count > /root/variable/NUM_02.txt

backup_dir="/backup/zabbix/sync_$count"
log_file="/var/log/remote/03_zabbix_sync.log"

if [ ! -d "/var/log/remote" ] ; then mkdir -p "/var/log/remote" ; fi

RSYNC_SERVER=""  # 원본: 외부 rsync 서버 IP (x.x.x.x)

function sync_bak {
  from=$1
  to=$2
  if [ ! -d "$to" ] ; then mkdir -p $to ; fi
  echo "$(date '+%Y-%m-%d %H:%M:%S') - yh_scripts [info]: rsync -av --delete $RSYNC_SERVER::sjyun/data/sync/today$from $to" >> $log_file
  rsync -av --delete $RSYNC_SERVER::sjyun/backup/sync/today$from $to  2>> $log_file
  if [ $? -ne 0 ]; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') - yh_scripts [error]: rsync error while syncing from $from to $to" >> $log_file
  else
      echo "$(date '+%Y-%m-%d %H:%M:%S') - yh_scripts [info]: rsync completed successfully from $from to $to" >> $log_file
  fi

  if [ -z "$(cat "$log_file" | grep -v "{\|}" | grep -i "error\|failed")" ] ; then
      echo "0" > /var/log/remote/03_zabbix_sync.status
  else
      echo "1" > /var/log/remote/03_zabbix_sync.status
  fi
}

rm -f /backup/zabbix/today

ln -sf $backup_dir /backup/zabbix/today

sync_bak /etc/ $backup_dir/etc/
sync_bak /home/ $backup_dir/home/
sync_bak /root/ $backup_dir/root/
sync_bak /usr-local/ $backup_dir/usr-local/
sync_bak /var/ $backup_dir/var/


find $backup_dir -type f -name "" -not -name "$(date +%Y%m%d)" -delete
echo $(date +%Y%m%d) > $backup_dir/$(date +%Y%m%d)
