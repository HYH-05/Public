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
# !

set -o pipefail

# ! --- [1. 기본 설정] ---

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

# ! --- [3. 메인 실행부] ---

# echo "================================================="
# echo " Daily System Health Check Report"
# echo "================================================="
# echo "Report generated on: $(date)"
echo "================================================="
echo " 일일 시스템 상태 점검 보고서"
echo "================================================="
echo "보고서 생성 시각: $(date)"

# ! --- 1. 시스템 기본 상태 및 리소스 ---
# print_header "1. System Status & Resources"
print_header "1. 시스템 기본 상태 및 리소스"

# @ 재부팅 여부 확인
# echo "Last Reboot: $(uptime -s)"
# echo "Uptime:      $(uptime -p)"
echo "최근 재부팅 시각: $(uptime -s)"
echo "서버 가동 시간:   $(uptime -p)"

echo ""
echo "-------------------------------------------------"
echo ""

# @ Load Average 확인
# echo "Load Average:"
echo "시스템 부하 평균:"
if command -v sar &> /dev/null; then
    # CPU 코어 수 확인
    core_count=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
    echo "  (CPU Cores: ${core_count})"
    echo ""
    echo "  [최신 값]"
    LC_ALL=C sar -q | tail -n 2 | head -n 1 | awk '{print "  " $1 " | 1분:", $5, " | 5분:", $6, " | 15분:", $7}'
    echo ""

    # @ 과거 기록 중 비정상 부하 탐지
    echo "  [과거 이력 중 비정상 부하 감지 (1분 평균 > 코어 수)]"
    # @ sar -q 출력에서 헤더(3줄)와 평균(마지막줄)을 제외하고, 1분 평균 부하($4)가 코어 수보다 높은 라인을 찾음
    abnormal_loads=$(LC_ALL=C sar -q | tail -n +4 | head -n -1 | awk -v cores="$core_count" 'int($5) > cores')

    if [[ -n "$abnormal_loads" ]]; then
        echo -e "${RED}"
        # @ 헤더를 다시 출력하고, 문제가 된 라인들을 보여줌
        sar -q | head -n 3 | tail -n 1
        echo "$abnormal_loads"
        echo -e "${NC}"
    else
        echo -e "  ${GREEN}(감지된 비정상 부하 없음)${NC}"
    fi
else
    echo "/bin/sar가 없습니다.(uptime 사용)"
    uptime | awk -F'load average: ' '{print "  " $2}'
fi

echo ""
echo "-------------------------------------------------"
echo ""

# @ 메모리 사용량 확인
# echo "Memory Usage:"
echo "메모리 사용량:"
if command -v sar &> /dev/null; then
    echo "  [최신 값 (sar -r)]"
    # @ 헤더와 최신 값(마지막 데이터 라인)을 함께 표시
    (LC_ALL=C sar -r | head -n 3 | tail -n 1; LC_ALL=C sar -r | tail -n 2 | head -n 1) | sed 's/^/  /'

    mem_usage_percent=$(LC_ALL=C sar -r | tail -n 2 | head -n 1 | awk '{print $5}' | cut -d. -f1)
    color=$(get_color "$mem_usage_percent")
    echo -e "  메모리 사용 상태: ${color}${mem_usage_percent}%${NC}"
    echo ""

    echo "  [과거 이력 중 높은 사용률 감지 (%memused > ${WARNING_THRESHOLD}%)]"
    abnormal_mem_usage=$(LC_ALL=C sar -r | tail -n +4 | head -n -1 | awk -v threshold="$WARNING_THRESHOLD" 'int($5) > threshold')

    if [[ -n "$abnormal_mem_usage" ]]; then
        echo -e "${YELLOW}"
        LC_ALL=C sar -r | head -n 3 | tail -n 1
        echo "$abnormal_mem_usage"
        echo -e "${NC}"
    else
        echo -e "  ${GREEN}(감지된 높은 메모리 사용률 없음)${NC}"
    fi
else
    echo "  (/bin/sar가 없습니다. free 사용)"
    free -h
    mem_usage_percent=$(free | grep Mem | awk '{print $3/$2 * 100.0}' | cut -d. -f1)
    color=$(get_color "$mem_usage_percent")
    echo -e "  메모리 사용 상태: ${color}${mem_usage_percent}%${NC}"
fi

echo ""
echo "-------------------------------------------------"
echo ""

# @ 디스크 사용량 확인
# echo "Disk Usage:"
echo "디스크 사용량:"
df -hT | head -n 1 # @ 헤더 출력
df -hT | grep -vE '^Filesystem|tmpfs|cdrom' | while read -r line; do
    usage_percent=$(echo "$line" | awk '{print $6}' | tr -d '%')
    color=$(get_color "$usage_percent")
    echo -e "${color}${line}${NC}"
done
echo ""

# ! --- 2. 프로세스 및 네트워크 상태 ---
# print_header "2. Process & Network Status"
print_header "2. 프로세스 및 네트워크 상태"

# @ 총 프로세스 개수 확인
total_processes=$(ps -e --no-headers | wc -l)
echo "총 프로세스 개수: $total_processes"
echo ""

# @ 전체 프로세스 트리 확인
# echo "Process Tree (showing parent-child relationships):"
echo "프로세스 트리 (부모-자식 관계):"
pstree -s
echo ""
echo "-------------------------------------------------"
echo ""

# @ 리스닝 포트 확인
# echo "Listening Network Ports (TCP/UDP):"
echo "연결 대기중인 네트워크 포트 (TCP/UDP):"
# ss -tulnp
netstat -tulnp # @ ss가 더 자세하게 나오지만 가독성 위함.
echo ""

# ! --- 3. 보안 및 이상 징후 점검 ---
# print_header "3. Security & Anomaly Check"
print_header "3. 보안 및 이상 징후 점검"

# @ /tmp 디렉토리 내 파일 확인 (숨김 파일 및 디렉토리 제외)
# echo "Files in /tmp directory (excluding hidden files/dirs):"
echo "/tmp 디렉토리 내 파일 (숨김 파일/디렉토리 제외):"
file_list_tmp=$(find /tmp -maxdepth 1 -type f -ls)
if [[ -n "$file_list_tmp" ]]; then
    echo "$file_list_tmp"
else
    echo "(발견된 파일 없음)"
fi

echo ""
echo "-------------------------------------------------"
echo ""

# @ /tmp 파일을 사용 중인 프로세스 확인
# echo "Processes currently using files in /tmp:"
echo "/tmp 디렉토리 파일을 사용중인 프로세스:"
if command -v lsof &> /dev/null; then
  # @ lsof의 출력을 변수에 저장하고, 출력이 없을 경우 메시지를 표시
  lsof_output=$(lsof +D /tmp/ 2>/dev/null)
  if [[ -n "$lsof_output" ]]; then
      echo "$lsof_output"
  else
      echo "(발견된 프로세스 없음)"
  fi
elif command -v fuser &> /dev/null; then
  # @ fuser는 파일/디렉토리를 인자로 받으므로, /tmp 자체와 그 안의 파일들을 대상으로 실행
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
# echo "Suspicious System Accounts (with login shell):"
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

# echo "User Check:"
echo "사용자 계정 확인 (UID >= 1000):"
awk -F: '($3 >= 1000) {print}' /etc/passwd

echo ""
echo "-------------------------------------------------"
echo ""

# echo "Group Check:"
echo "사용자 그룹 확인 (GID >= 1000):"
awk -F: '($3 >= 1000) {print}' /etc/group

echo ""
echo "-------------------------------------------------"
echo ""

# echo "Shadow Check:"
echo "암호화된 패스워드 확인 (UID >= 1000 사용자):"
# @ /etc/passwd에서 UID가 1000 이상인 사용자 목록을 먼저 추출한 후,
# @ 해당 사용자들의 /etc/shadow 항목만 필터링하여 출력합니다.
awk -F: 'NR==FNR { if ($3 >= 1000) users[$1]; next } ($1 in users) { print }' /etc/passwd /etc/shadow
echo ""


# ! --- 4. 로그 및 이벤트 분석 ---
# print_header "4. Log & Event Analysis"
print_header "4. 로그 및 이벤트 분석"

# @ 커널 메시지 확인 (하드웨어 오류 등)
# echo "Last Kernel Messages:"
echo "최근 커널 메시지 100건:"
dmesg | head -n 100

echo ""
echo "-------------------------------------------------"
echo ""

# @ 시스템 로그 내 주요 오류/경고 확인
# echo "Recent System Errors/Warnings:"
echo "최근 시스템 오류/경고 100건:"
if command -v journalctl &> /dev/null; then
    journalctl -p err..alert --no-pager | head -n 100
else
    grep -i "error\|warn\|fail" /var/log/messages | head -n 100
fi

echo ""
echo "-------------------------------------------------"
echo ""

# @ 최근 로그인 기록 확인
# echo "Last 30 Successful Logins:"
echo "최근 성공한 로그인 30건:"
last | head -n 30
echo ""

# echo "================================================="
# echo "Report complete."
echo "================================================="
echo "보고서 생성이 완료되었습니다."
echo "================================================="