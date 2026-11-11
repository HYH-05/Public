#!/usr/bin/env python3
# ! 점검 결과를 Slack 스레드로 전송한다.
# !   채널: 한 줄 부모 메시지 (위험 서버가 있을 때만 @here)
# !   스레드: summary.md 1개 + 서버별 상세 경로 (실패 시 ansible.log 마지막 부분)
# @ 사용법: notify_slack.py <보고서 디렉토리>   (SLACK_BOT_TOKEN, SLACK_CHANNEL 환경변수 필요)
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path

TOKEN = os.environ["SLACK_BOT_TOKEN"]
CHANNEL = os.environ["SLACK_CHANNEL"]
OUT = Path(sys.argv[1])
TS = OUT.name  # @ 예: 20261022_182355

# @ 등급별 표시 아이콘 (부모 메시지 표시 순서)
GRADES = {"위험": "🔴", "주의": "🟡", "수집실패": "⚪", "분석실패": "⚠️", "정상": "🟢"}


def api(method, **params):
    req = urllib.request.Request(
        f"https://slack.com/api/{method}",
        data=json.dumps(params).encode(),
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json; charset=utf-8"},
    )
    res = json.load(urllib.request.urlopen(req, timeout=30))
    if not res.get("ok"):
        raise RuntimeError(f"{method}: {res.get('error')}")
    return res


def upload(paths, thread_ts, comment):
    files = []
    for p in paths:
        data = p.read_bytes()
        # @ getUploadURLExternal은 JSON 본문을 받지 않아 form으로 보낸다.
        req = urllib.request.Request(
            "https://slack.com/api/files.getUploadURLExternal",
            data=urllib.parse.urlencode({"filename": p.name, "length": len(data)}).encode(),
            headers={"Authorization": f"Bearer {TOKEN}"},
        )
        res = json.load(urllib.request.urlopen(req, timeout=30))
        if not res.get("ok"):
            raise RuntimeError(f"files.getUploadURLExternal: {res.get('error')}")
        urllib.request.urlopen(urllib.request.Request(res["upload_url"], data=data), timeout=60)
        files.append({"id": res["file_id"], "title": p.name})
    api("files.completeUploadExternal", files=files, channel_id=CHANNEL, thread_ts=thread_ts, initial_comment=comment)


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


# ! --- 서버별 등급 수집 (AI 요약이 아닌 서버별 분석 파일에서 직접 읽는다) ---
servers = []
for f in sorted((OUT / "analysis").glob("*.md")):
    text = f.read_text(errors="replace")
    g = re.search(r"\*\*종합 등급:\*\*\s*(\S+)", text)
    grade = g.group(1) if g and g.group(1) in GRADES else "분석실패"
    servers.append((f.stem, grade))

count = {k: sum(1 for _, g in servers if g == k) for k in GRADES}
summary = OUT / "summary.md"
summary_ok = summary.exists() and "## 요약" in summary.read_text(errors="replace")
result_path = OUT / "result.json"
result = json.loads(result_path.read_text()) if result_path.exists() else {}
summary_ok = summary_ok and result.get("summary_ok", True)
count = result.get("counts", count)
partial = result.get("partial", 0)
total = result.get("total", len(servers))
early_failure = OUT / "failure.txt"
failed = early_failure.exists() or result.get("failed", False) or not servers or bool(count["분석실패"] + count["수집실패"]) or not summary_ok

# ! --- 부모 메시지 (채널에 보이는 한 줄) ---
when = f"{TS[:4]}-{TS[4:6]}-{TS[6:8]} {TS[9:11]}:{TS[11:13]}"
head = f"{'⚠️ 점검 처리 실패' if failed else '🖥️ 서버 점검'} {when} | 대상 {total}대 | " + " · ".join(f"{GRADES[k]} {k} {count[k]}" for k in GRADES)
head += f" | 부분 수집 {partial}대"
if early_failure.exists(): head += " | " + esc(early_failure.read_text().strip())
if count["위험"]: head = "🚨 <!here> " + head
parent = api("chat.postMessage", channel=CHANNEL, text=head, unfurl_links=False)
thread = parent["ts"]
(OUT / "slack-thread.txt").write_text(thread)

# ! --- 스레드: 내용은 종합 보고서 파일에서 확인 ---
detail = f"📂 서버별 상세: `{os.uname().nodename}:{(OUT / 'analysis').resolve()}/`"
if summary.exists() and summary.stat().st_size:
    upload([summary], thread, detail)
else:
    log = OUT / "ansible.log"
    if not log.exists(): log = OUT / "targets.log"
    tail = log.read_text(errors="replace").splitlines()[-15:] if log.exists() else ["(ansible.log 없음)"]
    text = "*종합 보고 생성 실패*\n```" + esc("\n".join(tail)) + "```\n" + detail
    api("chat.postMessage", channel=CHANNEL, thread_ts=thread, text=text, unfurl_links=False)

print(f"[Slack] 전송 완료: {head}")
