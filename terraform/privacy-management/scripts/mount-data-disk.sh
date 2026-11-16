#!/bin/bash
set -Eeuo pipefail

volume_id="${1:?EBS volume ID is required}"
mount_path="${2:?Mount path is required}"

fail() {
  echo "$*" >&2
  exit 1
}

[[ "$volume_id" =~ ^vol-[0-9a-f]{8}([0-9a-f]{9})?$ ]] || fail 'Invalid EBS volume ID.'
[[ "$mount_path" =~ ^(/[a-zA-Z0-9_-]+)+$ ]] || fail 'Invalid mount path.'
case "$mount_path/" in
  /etc/*|/usr/*|/var/*|/home/*|/root/*|/boot/*|/dev/*|/proc/*|/sys/*|/run/*|/tmp/*)
    fail 'System paths cannot be used as data mount points.' ;;
esac
[[ $(realpath -m "$mount_path") == "$mount_path" ]] || fail 'Symlink mount paths are not allowed.'
expected_serial="${volume_id//-/}"

# 장치 순서가 아니라 Terraform에서 생성한 EBS ID로 식별한다.
device=''
for attempt in $(seq 1 60); do
  matches=$(lsblk -dn -o PATH,SERIAL | awk -v serial="$expected_serial" '$2 == serial {print $1}')
  if [[ -n "$matches" ]]; then
    [[ $(printf '%s\n' "$matches" | wc -l) -eq 1 ]] || fail 'Multiple devices match the EBS ID.'
    device="$matches"
    break
  fi
  sleep 5
done
[[ -n "$device" ]] || fail "EBS device did not appear: $volume_id"
[[ $(lsblk -dn -o TYPE "$device") == disk ]] || fail 'The selected device is not a whole disk.'

# 파티션·LVM이 있는 디스크는 자동 변경하지 않는다.
[[ $(lsblk -nr -o TYPE "$device" | wc -l) -eq 1 ]] || fail 'Partitioned or mapped disks require manual review.'

existing_entry=$(awk -v path="$mount_path" '$1 !~ /^#/ && $2 == path {print $1}' /etc/fstab)

if filesystem=$(blkid -p -s TYPE -o value "$device"); then
  case "$filesystem" in
    xfs|ext4) ;;
    *) fail "Unsupported existing filesystem: $filesystem. No formatting was performed." ;;
  esac
else
  status=$?
  [[ "$status" -eq 2 ]] || fail 'Could not safely identify the filesystem.'
  [[ -z "$existing_entry" ]] || fail 'fstab already references this mount path, but no filesystem was found.'
  signatures=$(wipefs --no-act --noheadings --output TYPE "$device")
  [[ -z "$signatures" ]] || fail 'Existing disk signatures found. No formatting was performed.'
  [[ -z $(lsblk -nr -o MOUNTPOINTS "$device" | tr -d '[:space:]') ]] || fail 'The disk is already mounted.'
  # 서명·파티션·마운트가 없는 지정 EBS만 최초 XFS 포맷한다. -f는 사용하지 않는다.
  mkfs.xfs -q "$device"
  filesystem=xfs
fi

uuid=$(blkid -s UUID -o value "$device")
[[ "$uuid" =~ ^[0-9a-fA-F-]+$ ]] || fail 'Invalid filesystem UUID.'

if [[ -n "$existing_entry" && "$existing_entry" != "UUID=$uuid" ]]; then
  fail 'An existing fstab entry points to a different source. No fstab changes were made.'
fi

if mountpoint -q "$mount_path"; then
  [[ $(findmnt -n -o UUID --target "$mount_path") == "$uuid" ]] || fail 'A different filesystem is mounted at the target.'
else
  [[ -z $(findmnt -rn -S "$device" -o TARGET) ]] || fail 'The data filesystem is mounted elsewhere.'
  install -d -m 0755 "$mount_path"
  [[ -z $(ls -A "$mount_path") ]] || fail 'The mount directory contains files. Refusing to hide existing data.'
fi

if [[ -z "$existing_entry" ]]; then
  pass=0
  [[ "$filesystem" != ext4 ]] || pass=2
  printf 'UUID=%s %s %s defaults,nofail,x-systemd.device-timeout=120s 0 %s\n' \
    "$uuid" "$mount_path" "$filesystem" "$pass" >> /etc/fstab
fi

systemctl daemon-reload
if ! mountpoint -q "$mount_path"; then
  mount "$mount_path"
fi
mountpoint -q "$mount_path" || fail 'The data filesystem was not mounted.'
[[ $(findmnt -n -o UUID --target "$mount_path") == "$uuid" ]] || fail 'The mounted UUID does not match the data disk.'
echo "Data disk mounted: $volume_id -> $mount_path ($filesystem)"
