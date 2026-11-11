#!/usr/bin/env bash

# ! 중요 정보, 코드 요약 등
# @ 일반 정보(로직 설명)
# * 규칙, 정책 등
# // 폐기(미사용) 코드
# TODO: 해야할 일(작업 리스트)

# !
# ! .SYNOPSIS
# !     리눅스 서버의 핵심 시스템 상태, 보안, 로그를 종합적으로 점검하고,
# !     한눈에 보기 쉬운 요약 보고서를 생성합니다.
# !
# ! .DESCRIPTION
# !     1. 시스템 재부팅 여부, 부하, 디스크, 메모리 등 핵심 리소스 상태를 점검합니다.
# !     2. 실행 중인 프로세스 트리와 네트워크 포트 상태를 확인합니다.
# !     3. /tmp 디렉토리, 사용자 계정 등 기본적인 보안 항목을 점검합니다.
# !     4. 시스템 및 접속 로그에서 주요 오류나 경고, 비정상 접근 시도를 요약합니다.
# !
# ! .NOTES
# !     - [중요] 이 스크립트 파일을 저장할 때, 인코딩을 반드시 'UTF-8'로 지정해야
# !       리눅스 환경에서 한글이 깨지지 않고 정상적으로 실행됩니다.
# !     - [03] 원본 대비 변경점: /etc/shadow 해시값 마스킹 (AI 전송 대비)
# !     - [03] 주간 점검: 첫 번째 인자로 점검 기간(일)을 받는다. (기본 7)
# !       부하/메모리 이력, 커널/시스템 로그, 로그인 기록을 이 기간으로 제한한다.
# !     - [03] 마지막에 비교용 SNAPSHOT 블록을 출력한다. (compare.py가 지난 점검과 비교)
# !     - [03] 포트는 netstat 대신 ss(iproute2, 기본 설치), SSH 실패는 시도당 1건으로 센다.
# !       시간 동기화, inode, 실패한 서비스 항목 추가. /tmp 탐색에 /var/tmp, /dev/shm, 숨김 파일 포함.
# !

set -o pipefail
CHECK_ERRORS=0
export LC_ALL=C
export S_TIME_FORMAT=ISO
# 실패한 항목은 SNAPSHOT_FIELD_FAILED로 표시해 이전 값의 제거로 오인하지 않는다.

# 항목별로 실패를 기록하고 마지막 종료 코드에 반영한다.
query_failed() {
    CHECK_ERRORS=$((CHECK_ERRORS + 1))
    echo "[조회 실패] $*"
}

# sysstat 버전에 따라 열 위치가 달라지므로 헤더 이름으로 읽는다.
sar_memory() {
    awk -v day="$1" -v warn=80 '
      /%memused/ {for(i=1;i<=NF;i++) if($i=="%memused") col=i; next}
      col && $1 ~ /^[0-9][0-9]:/ && $col ~ /^[0-9.]+$/ {
        v=$col+0; if(v<0 || v>100) exit 1
        sum+=v; count++; if(count==1 || v>max) {max=v; at=$1}
      }
      END {if(count) printf "  %s  평균 %.2f%% / 최대 %.2f%% (%s)%s\n", day,sum/count,max,at,(max>warn ? "  [경고 임계값 초과]" : ""); else exit 1}
    '
}

# ! --- [1. 기본 설정] ---

# @ 점검 기간(일)
CHECK_DAYS=${1:-7}
[[ $CHECK_DAYS =~ ^[0-9]+$ ]] || CHECK_DAYS=7
readonly CHECK_DAYS
readonly SINCE="${CHECK_DAYS} days ago"

# @ 디스크 및 메모리 사용량 경고 임계값 (%)
readonly WARNING_THRESHOLD=80
readonly CRITICAL_THRESHOLD=90

# @ 색상 코드
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m' # No Color

# ! --- [2. 헬퍼 함수] ---

# @ 상태에 따라 색상을 반환하는 함수
get_color() {
    local value=$1
    if (( value >= CRITICAL_THRESHOLD )); then
        echo -en "${RED}"
    elif (( value >= WARNING_THRESHOLD )); then
        echo -en "${YELLOW}"
    else
        echo -en "${GREEN}"
    fi
}

print_header() {
    echo -e "\n${YELLOW}>> $1${NC}"
    echo "================================================="
}

# @ 점검 기간의 sar 일별 파일을 "날짜 파일경로"로 출력한다. (오래된 날부터, 오늘 포함)
# * 같은 일자 이름(saDD)의 지난달 파일이 남아 있을 수 있어 수정 시각으로 한 번 더 거른다.
sa_files() {
    local dir=/var/log/sa i day f
    [[ -d $dir ]] || dir=/var/log/sysstat
    for (( i = CHECK_DAYS; i >= 0; i-- )); do
        day=$(date -d "-${i} day" +%Y%m%d)
        f="$dir/sa$day"
        [[ -f $f ]] || f="$dir/sa${day:6:2}"
        [[ -f $f ]] || continue
        (( $(date +%s) - $(stat -c %Y "$f") < (CHECK_DAYS + 2) * 86400 )) || continue
        echo "$(date -d "$day" +%F) $f"
    done
}

# ! --- [3. 메인 실행부] ---

echo "================================================="
echo " 주간 시스템 상태 점검 보고서"
echo "================================================="
echo "보고서 생성 시각: $(date)"
echo "점검 기간: 최근 ${CHECK_DAYS}일 ($(date -d "$SINCE" '+%F %T') 부터)"

# ! --- 1. 시스템 기본 상태 및 리소스 ---
print_header "1. 시스템 기본 상태 및 리소스"

# @ 재부팅 여부 확인
echo "최근 재부팅 시각: $(uptime -s)"
echo "서버 가동 시간:   $(uptime -p)"
# @ 시간이 어긋나면 로그 기간 판단과 인증서 검증이 틀어진다.
# * timedatectl show 가 없는 구버전 systemd(CentOS 7)는 status 의 "synchronized" 줄을 읽는다.
ntp_sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null \
    || timedatectl status 2>/dev/null | awk -F': ' '/[Ss]ynchronized/ { print $2; exit }')
echo "시간 동기화(NTP): ${ntp_sync:-확인 불가}"

echo ""
echo "-------------------------------------------------"
echo ""

# @ Load Average 확인
echo "시스템 부하 평균:"
if command -v sar &> /dev/null; then
    # CPU 코어 수 확인
    core_count=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
    echo "  (CPU Cores: ${core_count})"
    echo ""
    echo "  [최신 값]"
    # @ sar -q (LC_ALL=C): $1 시각, $2 runq-sz, $3 plist-sz, $4 ldavg-1, $5 ldavg-5, $6 ldavg-15
    awk '{print "  현재 부하: 1분 " $1 " / 5분 " $2 " / 15분 " $3}' /proc/loadavg || query_failed '현재 부하 조회 실패'
    echo ""

    # @ 기간 내 일별 1분 부하: 평균 / 최대(발생 시각), 최대가 코어 수를 넘으면 표시
    echo "  [최근 ${CHECK_DAYS}일 일별 1분 부하 (평균 / 최대)]"
    load_history=$(sa_files | while read -r day f; do
        LC_ALL=C sar -q -f "$f" 2>/dev/null | awk -v day="$day" -v cores="$core_count" '
            $1 ~ /^[0-9][0-9]:/ && $4 ~ /^[0-9.]+$/ { if ($4 + 0 > max) { max = $4 + 0; at = $1 } }
            $1 == "Average:" { avg = $4 }
            END { if (avg != "") printf "  %s  평균 %s / 최대 %s (%s)%s\n", day, avg, max, at, (max > cores ? "  [코어 수 초과]" : "") }'
    done)
    echo "${load_history:-  (기간 내 sar 기록 없음: sysstat 수집 $(systemctl is-enabled sysstat 2>/dev/null || echo 미설치))}"
else
    echo "/bin/sar가 없습니다.(uptime 사용)"
    uptime | awk -F'load average: ' '{print "  " $2}'
fi

echo ""
echo "-------------------------------------------------"
echo ""

# @ 메모리 사용량 확인
echo "메모리 사용량:"
# 현재 사용률은 이력 수집 여부와 무관하게 /proc에서 계산한다.
if mem_usage_percent=$(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2; found=1} END {if(t>0 && found) printf "%.0f",100*(t-a)/t; else exit 1}' /proc/meminfo); then
    echo "  현재 메모리 사용률 (MemAvailable 기준): ${mem_usage_percent}%"
else
    query_failed "현재 메모리 사용률 조회 불가"
fi
echo ""
echo "  [최근 ${CHECK_DAYS}일 일별 메모리 사용률 %memused (평균 / 최대)]"
if command -v sar >/dev/null; then
    history_count=0
    while read -r day f; do
        history_count=$((history_count + 1))
        if ! LC_ALL=C sar -r -f "$f" | sar_memory "$day"; then
            query_failed "$day 메모리 이력 파싱 실패"
        fi
    done < <(sa_files)
    (( history_count > 0 )) || query_failed "기간 내 sar 메모리 기록 없음"
else
    query_failed "sar 미설치: 메모리 이력 확인 불가"
fi

echo ""
echo "-------------------------------------------------"
echo ""

# @ 디스크 사용량 확인
echo "디스크 사용량:"
# @ -P: 장치 이름이 길어도 한 줄로 출력 (컬럼 어긋남 방지)
df -hPT | head -n 1 # @ 헤더 출력
df -hPT | grep -vE '^Filesystem|tmpfs|cdrom' | while read -r line; do
    usage_percent=$(echo "$line" | awk '{print $6}' | tr -d '%')
    color=$(get_color "$usage_percent")
    echo -e "${color}${line}${NC}"
done

# @ 디스크 여유가 있어도 inode가 차면 파일을 만들 수 없다.
echo "inode 사용률 (${WARNING_THRESHOLD}% 이상):"
inode_high=$(df -iP -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk -v warn="$WARNING_THRESHOLD" 'NR > 1 && $5 + 0 >= warn')
echo "${inode_high:-  (해당 없음)}"
echo ""

# ! --- 2. 프로세스 및 네트워크 상태 ---
print_header "2. 프로세스 및 네트워크 상태"

# @ 총 프로세스 개수 확인
total_processes=$(ps -e --no-headers | wc -l)
echo "총 프로세스 개수: $total_processes"
echo ""

# @ 전체 프로세스 트리 확인
echo "프로세스 트리 (부모-자식 관계):"
pstree -s
echo ""
echo "-------------------------------------------------"
echo ""

# @ 리스닝 포트 확인
echo "연결 대기중인 네트워크 포트 (TCP/UDP):"
# @ iproute2(기본 설치). net-tools(netstat)는 최신 배포판 기본 설치에 없다.
# * 터미널이 아니면 ss가 줄 끝을 공백으로 길게 채우므로 지운다. (AI 입력 분량 절약)
# * 워커 프로세스가 많으면 users:((...)) 가 수천 자가 되므로 프로세스 이름(중복 제거)과 건수로 줄인다.
ss -tulnp | awk '{
    sub(/[[:space:]]+$/, "")
    if (match($0, /users:\(\(.*\)\)/)) {
        head = substr($0, 1, RSTART - 1)
        n = split(substr($0, RSTART, RLENGTH), part, "\"")
        names = ""; cnt = 0; split("", seen)
        for (i = 2; i <= n; i += 2) {
            cnt++
            if (!(part[i] in seen)) { seen[part[i]]; names = names (names == "" ? "" : ",") part[i] }
        }
        $0 = head names " (" cnt "건)"
    }
    print
}'

# @ 죽어 있는 서비스는 리소스 지표로 드러나지 않는다.
echo "실패한 서비스 (systemctl --failed):"
if failed_units=$(systemctl --failed --no-legend --no-pager 2>/dev/null); then
    echo "${failed_units:-  (없음)}"
else
    query_failed "실패 서비스 목록 조회 불가"
fi
echo ""

# ! --- 3. 보안 및 이상 징후 점검 ---
print_header "3. 보안 및 이상 징후 점검"

# @ 임시 디렉토리 내 파일 확인 (숨김 파일, 하위 3단계, 메모리 tmp 포함)
# * 악성 파일이 자주 숨는 위치. 많을 때는 최근 수정 순으로 TMP_SHOW건만 보이고 총 건수를 함께 낸다.
TMP_SHOW=300
echo "임시 디렉토리 내 파일 (/tmp /var/tmp /dev/shm, 하위 3단계, 최근 수정 순):"
file_list_tmp=$(find /tmp /var/tmp /dev/shm -xdev -maxdepth 3 -type f \
    -printf '%TY-%Tm-%Td %TH:%TM  %u:%g  %m  %10s  %p\n' 2>/dev/null | sort -r)
if [[ -n "$file_list_tmp" ]]; then
    tmp_total=$(wc -l <<< "$file_list_tmp")
    echo "  총 ${tmp_total}건$( (( tmp_total > TMP_SHOW )) && echo ", 최근 ${TMP_SHOW}건만 표시")"
    head -n "$TMP_SHOW" <<< "$file_list_tmp"
else
    echo "(발견된 파일 없음)"
fi

echo ""
echo "-------------------------------------------------"
echo ""

# @ /tmp 파일을 사용 중인 프로세스 확인
echo "/tmp 디렉토리 파일을 사용중인 프로세스:"
if command -v lsof &> /dev/null; then
  lsof_output=$(timeout 30 lsof +D /tmp/ 2>/dev/null); lsof_rc=$? # @ 파일이 많으면 재귀 탐색이 오래 걸려 제한
  if (( lsof_rc > 1 )); then
      query_failed "lsof 실행 실패 또는 시간 초과 (rc=$lsof_rc)"
  elif [[ -n "$lsof_output" ]]; then
      echo "$lsof_output"
  else
      echo "(발견된 프로세스 없음)"
  fi
elif command -v fuser &> /dev/null; then
  fuser_output=$(fuser -v /tmp/* 2>/dev/null)
  if [[ -n "$fuser_output" ]]; then
      echo "$fuser_output"
  else
      echo "(발견된 프로세스 없음)"
  fi
else
  echo "  (lsof 또는 fuser 명령어가 없어 확인 불가)"
fi

echo ""
echo "-------------------------------------------------"
echo ""

# @ 사용자 계정 확인
echo "의심스러운 시스템 계정 확인 (로그인 셸 소유):"
suspicious_system_accounts=$(awk -F: '($3 < 1000 && $3 != 0) && ($7 ~ /\/bin\/(bash|sh|zsh|csh|ksh|tcsh)$/) {print}' /etc/passwd)
if [[ -n "$suspicious_system_accounts" ]]; then
    echo -e "${RED}[경고] UID 1000 미만의 시스템 계정 중 로그인 셸을 가진 계정이 발견되었습니다. (정밀 점검 필요)${NC}"
    echo "$suspicious_system_accounts"
else
    echo -e "${GREEN}(시스템 계정 중 로그인 셸을 가진 의심스러운 계정 없음)${NC}"
fi
echo ""
echo "-------------------------------------------------"
echo ""

echo "사용자 계정 확인 (UID >= 1000):"
awk -F: '($3 >= 1000) {print}' /etc/passwd

echo ""
echo "-------------------------------------------------"
echo ""

echo "사용자 그룹 확인 (GID >= 1000):"
awk -F: '($3 >= 1000) {print}' /etc/group

echo ""
echo "-------------------------------------------------"
echo ""

echo "암호화된 패스워드 확인 (UID >= 1000 사용자):"
# @ 해시값은 외부(AI)로 전송되므로 알고리즘 ID만 남기고 마스킹한다. (!, *, 빈 값 등 잠금 상태는 유지)
awk -F: 'NR==FNR { if ($3 >= 1000) users[$1]; next } ($1 in users) { print }' /etc/passwd /etc/shadow \
    | sed -E 's/^([^:]*):(!*)\$([^$:]+)\$[^:]*:/\1:\2$\3$<masked>:/'
echo ""


# ! --- 4. 로그 및 이벤트 분석 ---
print_header "4. 로그 및 이벤트 분석"

# @ 커널 메시지 확인 (하드웨어 오류 등)
# * journalctl -k 는 현재 부팅 이후만 보이므로 _TRANSPORT=kernel 로 기간 전체를 본다.
echo "최근 ${CHECK_DAYS}일 커널 경고 이상 메시지 (최근 100건):"
[[ -d /var/log/journal ]] || echo "  (journal 휘발성 저장: 마지막 재부팅 이전 로그 없음)"
if command -v journalctl &> /dev/null; then
    journalctl _TRANSPORT=kernel -p warning --since "$SINCE" --no-pager -o short-iso 2>/dev/null | tail -n 100 || query_failed "커널 로그 조회 실패"
else
    echo "  (journalctl 없음: 기간 제한 없이 dmesg 마지막 100건)"
    dmesg -T 2>/dev/null | tail -n 100
fi

echo ""
echo "-------------------------------------------------"
echo ""

# @ 시스템 로그 내 주요 오류 확인
# @ 기간이 길어 원문만으로는 분량이 넘치므로, 같은 메시지를 묶은 요약과 최근 원문을 함께 낸다.
if ! system_errors=$(journalctl -p emerg..err --since "$SINCE" --no-pager -o short-iso 2>/dev/null); then
    query_failed "시스템 오류 로그 조회 실패"
    system_errors="(조회 실패)"
fi
echo "최근 ${CHECK_DAYS}일 시스템 오류 이상 로그 요약 (같은 메시지 묶음, 숫자는 #, 많은 순 50종):"
if command -v journalctl &> /dev/null; then
    printf '%s\n' "$system_errors" \
        | grep -v '^-- ' | cut -d' ' -f3- | sed -E 's/[0-9]+/#/g' | sort | uniq -c | sort -rn | head -n 50
    echo ""
    echo "최근 ${CHECK_DAYS}일 시스템 오류 이상 로그 원문 (최근 50건):"
    printf '%s\n' "$system_errors" | tail -n 50
else
    echo "  (journalctl 없음: 기간 제한 없이 /var/log/messages 마지막 100건)"
    grep -i "error\|warn\|fail" /var/log/messages | tail -n 100
fi

echo ""
echo "-------------------------------------------------"
echo ""

# @ 기간 내 로그인 기록 확인
echo "최근 ${CHECK_DAYS}일 성공한 로그인:"
if command -v last &> /dev/null; then
    # * CentOS 7(util-linux 2.23)의 last 는 -s 를 지원하지 않아 기간 필터 없이 읽는다.
    if ! last_out=$(last -i -s "-${CHECK_DAYS}days" 2>/dev/null); then
        echo "  (last -s 미지원: 기간 필터 없이 전체 기록 기준)"
        last_out=$(last -i 2>/dev/null)
    fi
    # @ 자동화(Ansible 등) 접속이 최근 목록을 채워 다른 접속이 가려지지 않도록 계정·접속지별 건수를 먼저 낸다.
    echo "  [계정 / 접속지별 건수]"
    awk 'NF >= 3 && $1 != "reboot" && $1 != "wtmp" { print "  " $1, $3 }' <<< "$last_out" | sort | uniq -c | sort -rn
    echo "  [최근 50건]"
    head -n 50 <<< "$last_out"
else
    echo "  (last 명령어 없음)"
fi
echo ""

# @ 기간 내 SSH 로그인 실패 건수 (OpenSSH 9.8 이후는 sshd-session 프로세스가 기록)
# * 시도 1회당 1건: 없는 계정은 "Invalid user", 있는 계정은 "Failed password"로 센다.
# *   ("Failed password for invalid user"와 PAM "authentication failure"는 같은 시도의 중복 줄이라 제외)
ssh_log=$(journalctl --since "$SINCE" --no-pager -o cat _COMM=sshd _COMM=sshd-session 2>/dev/null)
ssh_rc=$?
if (( ssh_rc != 0 )); then query_failed "SSH 로그 조회 실패"; fi
ssh_invalid=$(grep -c 'Invalid user' <<< "$ssh_log" || true)
ssh_badpw=$(grep 'Failed password for ' <<< "$ssh_log" | grep -vc 'invalid user' || true)
ssh_fail=$(( ssh_invalid + ssh_badpw ))
if (( ssh_rc == 0 )); then
    echo "최근 ${CHECK_DAYS}일 SSH 로그인 실패 건수: ${ssh_fail} (없는 계정 ${ssh_invalid}, 비밀번호 틀림 ${ssh_badpw})"
else
    ssh_fail=unknown
    echo "SSH 로그인 실패 건수: 확인 불가"
fi
echo ""

# ! --- 5. 비교용 SNAPSHOT ---
# @ compare.py가 지난 점검과 비교하는 값. 한 줄에 "키 값" 형식, 키: disk port user sudo boot sshfail
echo "### SNAPSHOT ###"
df -P -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR > 1 { sub("%", "", $5); print "disk", $6, $5 }' || { query_failed '디스크 스냅샷 조회 실패'; echo 'SNAPSHOT_FIELD_FAILED disk'; }
ss -Htuln 2>/dev/null | awk '{ print "port", $1, $5 }' | sort -u || { query_failed '포트 스냅샷 조회 실패'; echo 'SNAPSHOT_FIELD_FAILED port'; }
awk -F: '$3 >= 1000 && $3 < 65534 { print "user", $1 }' /etc/passwd || { query_failed '계정 스냅샷 조회 실패'; echo 'SNAPSHOT_FIELD_FAILED user'; }
# 점(.)·백업 접미사 파일은 sudo의 includedir 규칙에 맞춰 제외한다.
sudo_files=(/etc/sudoers)
if [[ -d /etc/sudoers.d ]]; then
    while IFS= read -r -d '' entry; do sudo_files+=("$entry"); done < <(find /etc/sudoers.d -maxdepth 1 -type f ! -name '*.*' ! -name '*~' -print0)
fi
if ! awk '!/^[[:space:]]*(#|$)/ {print "sudo", $0}' "${sudo_files[@]}" | sort -u; then
    query_failed 'sudoers 스냅샷 조회 실패'
    echo 'SNAPSHOT_FIELD_FAILED sudo'
fi
if boot_time=$(uptime -s); then echo "boot $boot_time"; else
    query_failed '부팅 시각 조회 실패'; echo 'SNAPSHOT_FIELD_FAILED boot'
fi
if (( ssh_rc == 0 )); then echo "sshfail $ssh_fail"; else echo 'SNAPSHOT_FIELD_FAILED sshfail'; fi
echo "### END SNAPSHOT ###"
echo ""

echo "================================================="
echo "보고서 생성이 완료되었습니다."
echo "================================================="

# 수집 완전성은 표식과 종료 코드로 함께 전달한다.
echo "### COLLECTION_ERRORS ${CHECK_ERRORS} ###"
(( CHECK_ERRORS == 0 ))
