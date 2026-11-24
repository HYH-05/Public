#!/usr/bin/env bash
# 수집 → 비교 → 서버별 분석 → 종합 분석 → 알림. 원본은 보고서와 함께 보관한다.
set -o pipefail
umask 077
cd "$(dirname "$(readlink -f "$0")")" || exit 1
exec 9>.run.lock
flock -n 9 || { echo '이미 점검 실행 중'; exit 1; }
export CLAUDE=${CLAUDE:-/root/.local/bin/claude}
export MODEL=${MODEL:-sonnet} TIMEOUT=${TIMEOUT:-600}
PARALLEL=${PARALLEL:-4}
CHECK_DAYS=${CHECK_DAYS:-7}
RETENTION_DAYS=${RETENTION_DAYS:-90}
COLLECT_TIMEOUT=${COLLECT_TIMEOUT:-600}
for value in "$PARALLEL" "$CHECK_DAYS" "$RETENTION_DAYS" "$TIMEOUT" "$COLLECT_TIMEOUT"; do
    [[ $value =~ ^[1-9][0-9]*$ ]] || { echo '설정은 양의 정수여야 한다'; exit 1; }
done
for arg in "$@"; do
    case "$arg" in --list-*|--syntax-check|--check|-C|--step|--start-at-task|--tags|-t|--skip-tags|-e|--extra-vars|--extra-vars=*|-e*) echo "지원하지 않는 실행 옵션: $arg"; exit 1;; esac
done
export BASE=$PWD BASELINE=$PWD/baseline PROMPTS=$PWD/prompts
mkdir -p "$BASELINE" reports || exit 1
SLACK_ENV=${SLACK_ENV:-/root/.config/ai_check/slack.env}
TS=$(date +%Y%m%d_%H%M%S)
export OUT=$PWD/reports/$TS
mkdir "$OUT" || exit 1
mkdir "$OUT/raw" "$OUT/analysis" "$OUT/diff" "$OUT/errors" || exit 1
agent() {
    local prompt=$1 work rc
    work=$(mktemp -d /tmp/ai_check_agent.XXXXXX) || return 1
    (cd "$work" && timeout --kill-after=10 "$TIMEOUT" "$CLAUDE" -p "$prompt" --model "$MODEL" \
      --tools "" --no-session-persistence --strict-mcp-config --setting-sources user --safe-mode)
    rc=$?
    rm -rf -- "$work" "$HOME/.claude/projects/$(sed 's/[^A-Za-z0-9]/-/g' <<< "$work")"
    return "$rc"
}
analyze_host() {
    local raw=$1 host prompt
    host=$(basename "$raw" .txt)
    if grep -q '^\[수집 실패\]' "$raw"; then
        printf '# %s\n**종합 등급:** 수집실패\n**한줄 요약:** 원본·수집 로그 확인 필요\n' "$host" > "$OUT/analysis/$host.md"
        return 1
    fi
    if ! python3 "$BASE/compare.py" "$raw" "$BASELINE/$host.txt" > "$OUT/diff/$host.md" 2> "$OUT/errors/$host.compare.log"; then
        touch "$OUT/pipeline.failed" "$OUT/errors/$host.compare.failed"
        echo '비교 실패: 과거 대비 변화 판단 불가' > "$OUT/diff/$host.md"
    fi
    prompt_file=server.md
    grep -q '^점검 대상 OS: Windows$' "$raw" && prompt_file=server_windows.md
    prompt=$(cat "$PROMPTS/$prompt_file"); prompt=${prompt//\{\{HOST\}\}/$host}
    if cat "$OUT/diff/$host.md" <(echo) "$raw" | agent "$prompt" > "$OUT/analysis/$host.md.tmp" 2> "$OUT/errors/$host.agent.log" \
        && python3 "$BASE/report_status.py" validate "$OUT/analysis/$host.md.tmp"; then
        mv "$OUT/analysis/$host.md.tmp" "$OUT/analysis/$host.md" || return 1
        echo "[완료] $host"
    else
        printf '# %s\n**종합 등급:** 분석실패\n**한줄 요약:** AI 실행 또는 출력 검증 실패\n' "$host" > "$OUT/analysis/$host.md"
        return 1
    fi
}
export -f agent analyze_host
# 초기 실패를 포함해 실행 결과와 알림을 한 곳에서 처리한다.
finish_run() {
    local exit_rc=$?
    trap - EXIT
    if (( exit_rc != 0 )); then
        printf '실패 단계: %s\n' "$STAGE" > "$OUT/failure.txt"
    fi
    if [[ -f $SLACK_ENV ]]; then
        (set -a; . "$SLACK_ENV"; set +a; python3 "$BASE/notify_slack.py" "$OUT") || { echo '[Slack] 전송 실패'; exit_rc=1; }
    fi
    printf '%s\n' "$exit_rc" > "$OUT/exit.status"
    echo "보고서: $OUT, 종료 코드: $exit_rc"
    exit "$exit_rc"
}
STAGE=대상조회
trap finish_run EXIT
rc=0
if ! ansible-playbook collect.yml --list-hosts "$@" > "$OUT/targets.log" 2>&1; then
    echo "대상 조회 실패: $OUT/targets.log"; exit 1
fi
target_count=$(python3 report_status.py targets "$OUT") || exit 1
# 서버별 제한과 별개로 전체 실행 상한을 둔다. 기본값은 직렬 실행까지 허용한다.
TOTAL_COLLECT_TIMEOUT=${TOTAL_COLLECT_TIMEOUT:-$((target_count * (COLLECT_TIMEOUT + 60) + 120))}
[[ $TOTAL_COLLECT_TIMEOUT =~ ^[1-9][0-9]*$ ]] || exit 1
STAGE=수집
 echo "### 수집: $OUT (전체 제한 ${TOTAL_COLLECT_TIMEOUT}초)"
timeout --kill-after=30 "$TOTAL_COLLECT_TIMEOUT" ansible-playbook collect.yml "$@" \
    -e "out_dir=$OUT/raw" -e "check_days=$CHECK_DAYS" -e "collect_timeout=$COLLECT_TIMEOUT" > "$OUT/ansible.log" 2>&1 || touch "$OUT/pipeline.failed"
shopt -s nullglob
raws=("$OUT"/raw/*.txt)
if (( ${#raws[@]} )); then sed -i -E 's/\x1b\[[0-9;]*m//g; s/\r$//' "${raws[@]}"; fi
python3 report_status.py prepare "$OUT" || { echo "대상/수집 검증 실패: $OUT"; exit 1; }
STAGE=서버별분석
find "$OUT/raw" -maxdepth 1 -name '*.txt' -print0 | xargs -0 -r -P "$PARALLEL" -I{} bash -o pipefail -c 'analyze_host "$1"' _ {} || touch "$OUT/pipeline.failed"
STAGE=종합분석
prompt=$(cat "$PROMPTS/summary.md"); prompt=${prompt//\{\{TS\}\}/$TS}
if cat "$OUT"/analysis/*.md | agent "$prompt" > "$OUT/summary.md" 2> "$OUT/errors/summary.agent.log"; then
    touch "$OUT/summary.ok"
fi
python3 report_status.py finalize "$OUT" || rc=1
cat "$OUT/summary.md"
# 전체 결과·Slack과 독립적으로 정상 수집 및 분석된 서버만 기준선을 갱신한다.
STAGE=기준선갱신
for raw in "$OUT"/raw/*.txt; do
    host=$(basename "$raw" .txt)
    if ! grep -qE '^\[(수집 실패|부분 수집)\]' "$raw" \
        && [[ ! -f $OUT/errors/$host.compare.failed ]] \
        && python3 report_status.py validate "$OUT/analysis/$host.md"; then
        cp -p "$raw" "$BASELINE/.$host.txt.tmp" && mv "$BASELINE/.$host.txt.tmp" "$BASELINE/$host.txt" || rc=1
    fi
done
STAGE=보관기간정리
find "$PWD/reports" -mindepth 1 -maxdepth 1 -type d -name '20*' ! -path "$OUT" -mtime +"$RETENTION_DAYS" -exec rm -rf -- {} + || rc=1
STAGE=결과확인
exit "$rc"
