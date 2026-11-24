#!/bin/env bash

# !
# ! .SYNOPSIS
# !     GitLab(Omnibus, gitlab-ee) 마이너 자동 업그레이드. 메이저 버전은 넘지 않는다.
# !
# ! .DESCRIPTION
# !     1. 사전 확인: 백업 상태 0·최근 백업 존재·버전 일치, 서비스 정상
# !     2. 경로 계산: 현재 버전 + 저장소 버전 + 공식 경유표·문서의 최소 패치
# !        예) 19.2.3 → 19.2 최신 패치 → 19.5 최신 패치 → 19.7.x
# !     3. 단계 반복: 모든 DB의 마이그레이션 완료 대기 → 설치 → 정상 응답·버전 확인
# !
# ! .NOTES
# !     - Ubuntu(apt), Rocky/RHEL(dnf) 지원
# !     - 실패 시 그 자리에서 멈춘다. 다운그레이드는 지원되지 않으므로 자동 롤백하지 않는다.
# !     - 마이그레이션 대기가 MAX_WAIT_MIN을 넘으면 정상 종료하고, 다음 실행에서 이어간다.
# !
# * 사용법: 03_gitlab_upgrade.sh [--dry-run]
# * cron : 0 1 * * 6 /usr/bin/env bash /root/01_gitlab_backup.sh; /usr/bin/env bash /root/03_gitlab_upgrade.sh

set -o pipefail

# ! --- [1. 기본 설정] ---
BACKUP_DIR=${BACKUP_DIR:-백업 디렉토리}
BACKUP_STATUS_FILE=${BACKUP_STATUS_FILE:-/var/log/backup/01_gitlab_backup.status}
MAX_BACKUP_AGE_H=${MAX_BACKUP_AGE_H:-24}   # @ 이 시간 안에 만들어진 백업만 인정
MAX_WAIT_MIN=${MAX_WAIT_MIN:-360}          # @ 단계 사이 마이그레이션 대기 상한
READY_WAIT_MIN=${READY_WAIT_MIN:-15}       # @ 설치 후 정상 응답 대기 상한
PATH_URL="https://gitlab.com/gitlab-org/gitlab/-/raw/master/config/upgrade_path.yml"
PATH_CACHE="/var/opt/gitlab/upgrade_path.yml"
MINIMUM_PATH_URL="https://gitlab.com/gitlab-org/gitlab/-/raw/master/doc/update/upgrade_paths.md"
MINIMUM_PATH_CACHE="/var/opt/gitlab/upgrade_path.md"
PKG=gitlab-ee
DRY_RUN=0
[[ $1 == --dry-run ]] && DRY_RUN=1

LOG_FILE="/var/log/backup/03_gitlab_upgrade.log"
STATUS_FILE="/var/log/backup/03_gitlab_upgrade.status"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

# ! --- [2. 헬퍼 함수] ---
log() {
  printf "[%s] %s\n" "$(date '+%Y-%m-%d:::%H:%M:%S')" "$*"
}

# @ 상태는 이번 실행 결과로만 기록한다. (로그 전체 grep 방식 사용 안 함)
finish() {
  local rc=$1; shift
  if (( rc == 0 )); then log "[info]: $*"; else log "[error]: $*"; fi
  (( DRY_RUN )) || echo "$rc" > "$STATUS_FILE"
  exit "$rc"
}

# @ dry-run이면 경고만 남기고 계속, 아니면 중단
fail_or_warn() {
  if (( DRY_RUN )); then log "[warn]: (dry-run 계속) $*"; else finish 1 "$*"; fi
}

if command -v apt-get >/dev/null; then PM=apt; elif command -v dnf >/dev/null; then PM=dnf; else finish 1 "apt/dnf를 찾을 수 없음"; fi

# @ 설치된 버전 (X.Y.Z)
installed_version() {
  if [[ $PM == apt ]]; then dpkg-query -W -f='${Version}' "$PKG" 2>/dev/null; else rpm -q --qf '%{VERSION}' "$PKG" 2>/dev/null; fi \
    | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+'
}

# @ 저장소 조회 실패와 빈 결과는 오류다. 안정 버전만 "X.Y.Z 패키지버전"으로 반환한다.
available_versions() {
  local raw versions
  if [[ $PM == apt ]]; then
    raw=$(apt-cache madison "$PKG") || return 1
    versions=$(awk '{print $3}' <<< "$raw")
  else
    raw=$(dnf -q list --showduplicates "$PKG") || return 1
    versions=$(awk -v p="$PKG" '$1 ~ "^"p"\\." {print $2}' <<< "$raw")
  fi
  versions=$(awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+-ee\.[0-9]+([.][[:alnum:]_]+)*$/ {
    v=$1; sub(/-.*/, "", v); print v, $1
  }' <<< "$versions" | sort -u -V) || return 1
  [[ -n $versions ]] || return 1
  printf '%s\n' "$versions"
}

# shortcut: 공식 major/minor/comments 형식만 허용한다. 형식이 바뀌면 파서를 갱신하기 전까지 중단한다.
required_stops() {
  awk -v M="$2" '
    function finish_record() { if (have_major && !have_minor) invalid=1 }
    /^[[:space:]]*$/ || /^[[:space:]]*#/ || /^---[[:space:]]*$/ {next}
    /^[[:space:]]*-[[:space:]]+major:[[:space:]]+[0-9]+[[:space:]]*$/ {
      finish_record(); major=$NF; have_major=1; have_minor=0; next
    }
    /^[[:space:]]+minor:[[:space:]]+[0-9]+[[:space:]]*$/ {
      if (!have_major || have_minor) invalid=1
      have_minor=1
      if (major == M) { if (seen[$NF]++) invalid=1; selected[$NF]=1; count++ }
      next
    }
    /^[[:space:]]+comments:/ { if (!have_major || !have_minor) invalid=1; next }
    { invalid=1 }
    END {
      finish_record()
      if (invalid || !count) exit 1
      for (minor in selected) print minor
    }
  ' "$1" | sort -n
}

version_gt() {
  [[ $1 != "$2" && $(printf '%s\n%s\n' "$2" "$1" | sort -V | tail -1) == "$1" ]]
}

# @ 공식 문서의 현재 메이저 절에서 필수 버전을 읽는다. 조건부 경유 지점도 포함한다.
# shortcut: 표의 첫 열·백틱 목록만 해석한다. 형식 변경이나 경유표와의 불일치는 중단한다.
minimum_patch_versions() {
  awk -F '|' -v M="$2" '
    function record(version, parts, n, minor, patch) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", version)
      if (version !~ /^[0-9]+\.[0-9]+(\.[0-9]+)?$/) { invalid=1; return }
      n=split(version,parts,".")
      if (parts[1] != M) { invalid=1; return }
      minor=parts[2]+0; patch=(n==3 ? parts[3]+0 : 0)
      if (!(minor in patches) || patch > patches[minor]) patches[minor]=patch
      count++
    }
    /^### Required GitLab [0-9]+ upgrade stops[[:space:]]*$/ {
      split($0,heading," "); active=(heading[4] == M)
      if (active) found=1
      next
    }
    /^#/ {active=0}
    active && /^\|[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+[[:space:]]*\|/ {record($2); next}
    active && (/^- `/ || /^Required upgrade stops occur at versions/) {
      line=$0
      while (match(line,/`[0-9]+\.[0-9]+(\.[0-9]+)?`/)) {
        record(substr(line,RSTART+1,RLENGTH-2))
        line=substr(line,RSTART+RLENGTH)
      }
    }
    END {
      if (!found || !count || invalid) exit 1
      for (minor in patches) print M "." minor "." patches[minor]
    }
  ' "$1" | sort -V
}

# @ plan에는 현재와 같은 메이저의 오름차순 패키지만 넣는다.
build_upgrade_plan() {
  local current=$1 versions=$2 minimums=$3 major current_minor target target_minor minimum stop row version effective
  plan=()
  [[ $current =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  major=${current%%.*}
  current_minor=$(cut -d. -f2 <<< "$current")
  [[ -n $minimums && -n $versions ]] || return 1
  versions=$(awk -v M="$major" '{split($1,a,"."); if(a[1]==M) print}' <<< "$versions" | sort -u -V) || return 1
  [[ -n $versions ]] || { log "[error]: 현재 메이저 $major 패키지가 저장소에 없음"; return 1; }
  row=$(tail -1 <<< "$versions")
  target=${row%% *}
  version_gt "$target" "$current" || return 0
  target_minor=$(cut -d. -f2 <<< "$target")
  for minimum in $minimums; do
    [[ $minimum =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && ${minimum%%.*} == "$major" ]] || return 1
    stop=$(cut -d. -f2 <<< "$minimum")
    (( 10#$stop >= 10#$current_minor && 10#$stop <= 10#$target_minor )) || continue
    row=$(awk -v prefix="$major.$stop." 'index($1,prefix)==1' <<< "$versions" | tail -1)
    if [[ -z $row ]]; then
      if [[ $stop == "$current_minor" ]] && ! version_gt "$minimum" "$current"; then
        continue
      fi
      log "[error]: 필수 경유 버전 $minimum 이상인 패키지가 저장소에 없음"
      return 1
    fi
    version=${row%% *}
    effective=$version
    if [[ $stop == "$current_minor" ]] && version_gt "$current" "$version"; then effective=$current; fi
    if version_gt "$minimum" "$effective"; then
      log "[error]: 필수 경유 $minimum 이상이 필요하지만 저장소의 해당 마이너 최신은 $version (현재 $current)"
      return 1
    fi
    version_gt "$version" "$current" || continue
    plan+=("$row")
  done
  row=$(tail -1 <<< "$versions")
  if (( ${#plan[@]} == 0 )) || [[ ${plan[-1]} != "$row" ]]; then
    plan+=("$row")
  fi
}

install_version() {
  if [[ $PM == apt ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$PKG=$1"
  else
    dnf install -y -q "$PKG-$1"
  fi
}

ready() {
  [[ $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost/-/readiness) == 200 ]]
}

# @ 출력: "미완료 건수 실패 건수". finished/finalized만 완료로 인정한다.
migration_counts() {
  local output counts
  if ! output=$(timeout 120s gitlab-rails runner -e production '
    pending = 0
    failed = 0
    checked_databases = 0
    Gitlab::Database.database_base_models.each do |database_name, model|
      next unless Gitlab::Database.has_database?(database_name)
      Gitlab::Database::SharedModel.using_connection(model.connection) do
        migrations = Gitlab::Database::BackgroundMigration::BatchedMigration
        raise "Missing migration table: #{database_name}" unless migrations.table_exists?
        counts = migrations.group(:status).count
        finished_statuses = [migrations.state_machines[:status].states[:finished].value,
                             migrations.state_machines[:status].states[:finalized].value]
        failed_status = migrations.state_machines[:status].states[:failed].value
        pending += counts.reject { |status, _| finished_statuses.include?(status) }.values.sum
        failed += counts.fetch(failed_status, 0)
        checked_databases += 1
      end
    end
    raise "No database checked" if checked_databases.zero?
    puts "MIGRATION_COUNTS #{pending} #{failed}"
  '); then
    log "[error]: 마이그레이션 상태 조회 실패 또는 조회 제한 120초 초과" >&2
    return 1
  fi
  counts=$(printf '%s\n' "$output" | grep '^MIGRATION_COUNTS ')
  if [[ ! $counts =~ ^MIGRATION_COUNTS[[:blank:]]+([0-9]+)[[:blank:]]+([0-9]+)$ ]]; then
    log "[error]: 마이그레이션 상태 출력 형식 오류" >&2
    return 1
  fi
  printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

# @ 0: 모든 DB 완료, 1: 실패 건 또는 조회 오류, 2: 대기 상한 초과
wait_migrations() {
  local started=$SECONDS counts pending failed elapsed remaining sleep_seconds
  [[ $MAX_WAIT_MIN =~ ^[0-9]+$ ]] || { log "[error]: MAX_WAIT_MIN은 0 이상의 정수여야 함"; return 1; }
  while :; do
    counts=$(migration_counts) || return 1
    read -r pending failed <<< "$counts"
    pending=$((10#$pending)); failed=$((10#$failed))
    (( failed > 0 )) && { log "[error]: 실패한 백그라운드 마이그레이션 ${failed}건"; return 1; }
    (( pending == 0 )) && return 0
    elapsed=$((SECONDS - started))
    remaining=$((10#$MAX_WAIT_MIN * 60 - elapsed))
    (( remaining > 0 )) || return 2
    log "[info]: 백그라운드 마이그레이션 대기 중 (${pending}건, $((elapsed / 60))분 경과)"
    sleep_seconds=600
    (( remaining < sleep_seconds )) && sleep_seconds=$remaining
    sleep "$sleep_seconds" || return 1
  done
}

# ! --- [3. 메인 실행부] ---
exec 9> /run/03_gitlab_upgrade.lock
flock -n 9 || finish 1 "이미 실행 중"

log "[info]: ===== GitLab 마이너 업그레이드 시작 (PM=$PM, dry-run=$DRY_RUN) ====="

cur=$(installed_version)
[[ -n $cur ]] || finish 1 "$PKG 패키지가 설치되어 있지 않음"
major=${cur%%.*}
log "[info]: 현재 버전 $cur"

# @ 오래된 목록으로 경유 패치를 선택하지 않도록 저장소 갱신 실패 시 중단한다.
if [[ $PM == apt ]]; then
  if ! update_out=$(LC_ALL=C apt-get update -q -o APT::Update::Error-Mode=any 2>&1); then
    printf '%s\n' "$update_out"
    finish 1 "저장소 목록 갱신 실패, 기존 목록으로 업그레이드하지 않음"
  fi
else
  dnf makecache --refresh -q || finish 1 "저장소 목록 갱신 실패, 기존 목록으로 업그레이드하지 않음"
fi

# @ 다운로드한 경유표를 검증한 뒤에만 캐시를 교체한다.
if ! curl -sf --max-time 30 "$PATH_URL" -o "$PATH_CACHE.tmp"; then
  rm -f "$PATH_CACHE.tmp"
  finish 1 "upgrade_path.yml 다운로드 실패, 경유 경로를 보장할 수 없어 중단"
fi
if ! stops=$(required_stops "$PATH_CACHE.tmp" "$major"); then
  rm -f "$PATH_CACHE.tmp"
  finish 1 "경유표 형식 오류 또는 $major 메이저의 경유 정보 없음"
fi
if ! curl -sf --max-time 30 "$MINIMUM_PATH_URL" -o "$MINIMUM_PATH_CACHE.tmp"; then
  rm -f "$PATH_CACHE.tmp" "$MINIMUM_PATH_CACHE.tmp"
  finish 1 "공식 최소 패치 문서 다운로드 실패"
fi
if ! minimums=$(minimum_patch_versions "$MINIMUM_PATH_CACHE.tmp" "$major"); then
  rm -f "$PATH_CACHE.tmp" "$MINIMUM_PATH_CACHE.tmp"
  finish 1 "공식 최소 패치 문서 형식 오류 또는 현재 메이저 정보 없음"
fi
for stop in $stops; do
  if ! awk -v prefix="$major.$stop." 'index($0,prefix)==1 {found=1} END {exit !found}' <<< "$minimums"; then
    rm -f "$PATH_CACHE.tmp" "$MINIMUM_PATH_CACHE.tmp"
    finish 1 "필수 경유 $major.$stop 의 최소 패치를 공식 문서에서 확인할 수 없음"
  fi
done
mv "$PATH_CACHE.tmp" "$PATH_CACHE" || finish 1 "경유표 캐시 저장 실패"
mv "$MINIMUM_PATH_CACHE.tmp" "$MINIMUM_PATH_CACHE" || finish 1 "최소 패치 문서 캐시 저장 실패"

# @ 현재 minor가 경유 지점이면 최신 패치도 포함한다. 필수 지점을 건너뛰는 우회는 하지 않는다.
avail=$(available_versions) || finish 1 "설치 가능 버전 조회 실패 또는 안정 버전 목록 없음"
build_upgrade_plan "$cur" "$avail" "$minimums" || finish 1 "필수 경유 경로 계산 실패"
if (( ${#plan[@]} == 0 )); then
  finish 0 "현재 메이저 $major 안에서 업그레이드 대상 없음 ($cur)"
fi
log "[info]: 경로 $cur → $(printf '%s → ' "${plan[@]%% *}" | sed 's/ → $//')"

# @ 사전 확인 1: 백업 작업 성공 여부와 복원할 파일의 시각·버전을 함께 확인한다.
if [[ ! -r $BACKUP_STATUS_FILE ]]; then
  fail_or_warn "백업 상태 파일을 읽을 수 없음 ($BACKUP_STATUS_FILE)"
elif [[ $(cat "$BACKUP_STATUS_FILE") != 0 ]]; then
  fail_or_warn "백업 상태가 정상이 아님 ($BACKUP_STATUS_FILE, 기대값 0)"
else
  log "[info]: 백업 상태 0 확인 ($BACKUP_STATUS_FILE)"
fi

backup=$(find "$BACKUP_DIR" -maxdepth 1 -name '*_gitlab_backup.tar' -mmin -$(( MAX_BACKUP_AGE_H * 60 )) -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
if [[ -z $backup ]]; then
  fail_or_warn "최근 ${MAX_BACKUP_AGE_H}시간 내 백업 없음 ($BACKUP_DIR)"
elif [[ $(basename "$backup" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1) != "$cur" ]]; then
  fail_or_warn "백업 버전 불일치: $(basename "$backup") (현재 $cur)"
else
  log "[info]: 백업 확인 $(basename "$backup")"
fi

# @ 사전 확인 2: 서비스 정상
ready || fail_or_warn "/-/readiness 비정상"

if (( DRY_RUN )); then
  finish 0 "dry-run 종료 (변경 없음)"
fi

# @ 사전 확인 3: 설정·암호키 백업 (gitlab-backup에는 포함되지 않는다)
gitlab-ctl backup-etc --backup-path "$BACKUP_DIR/config" >/dev/null \
  && log "[info]: /etc/gitlab 백업 → $BACKUP_DIR/config" \
  || finish 1 "/etc/gitlab 백업 실패"

# ! --- 단계별 업그레이드 ---
for step in "${plan[@]}"; do
  v=${step%% *}; pkgver=${step#* }

  wait_migrations; rc=$?
  (( rc == 1 )) && finish 1 "마이그레이션 문제로 중단 (현재 $(installed_version))"
  (( rc == 2 )) && finish 0 "마이그레이션 대기 ${MAX_WAIT_MIN}분 초과, 다음 실행에서 이어감 (현재 $(installed_version))"

  log "[info]: 설치 $pkgver"
  install_version "$pkgver" || finish 1 "설치 실패 $pkgver"

  [[ $(installed_version) == "$v" ]] || finish 1 "설치 후 버전 불일치 (기대 $v, 실제 $(installed_version))"

  for (( i = 0; i < READY_WAIT_MIN; i++ )); do ready && break; sleep 60; done
  ready || finish 1 "$v 설치 후 ${READY_WAIT_MIN}분 내 정상 응답 없음"
  log "[info]: $v 완료"
done

finish 0 "업그레이드 완료: $cur → $(installed_version)"
