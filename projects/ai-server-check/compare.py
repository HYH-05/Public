#!/usr/bin/env python3
# ! 이번 점검 원본과 지난 점검 원본(baseline)을 비교해 변화와 지난 데이터를 마크다운으로 출력한다.
# @ 사용법: compare.py <이번 원본: reports/<시각>/raw/<호스트>.txt> <지난 원본: baseline/<호스트>.txt>
# * 지난 회차는 원본 데이터만 쓴다. 지난 AI 분석 결과는 읽지 않는다.
# * 경과 일수는 두 파일의 수정 시각으로 계산한다. (run.sh가 baseline을 cp -p로 저장)
import re
import sys
from datetime import datetime
from pathlib import Path

LOG_SHOW = 10  # @ 오류 로그 유형 변화를 항목별로 최대 몇 개까지 보여줄지


def read(path):
    try:
        return path.read_text(errors="replace")
    except OSError:
        return None


def snapshot(text):
    """SNAPSHOT 블록을 {키: {값,...}} 으로 읽는다. 없으면 None."""
    if not text or "### SNAPSHOT ###" not in text or "### END SNAPSHOT ###" not in text:
        return None
    block = text.split("### SNAPSHOT ###", 1)[1].split("### END SNAPSHOT ###", 1)[0]
    snap = {}
    for line in block.splitlines():
        key, _, val = line.strip().partition(" ")
        if key:
            snap.setdefault(key, set()).add(val.strip())
    return snap


def section(text, marker):
    """marker가 들어간 줄 다음부터 빈 줄 전까지를 돌려준다."""
    out, on = [], False
    for line in text.splitlines():
        if on:
            if not line.strip():
                break
            out.append(line.rstrip())
        elif marker in line:
            on = True
    return out


def log_kinds(text):
    """시스템 오류 로그 요약(uniq -c 결과)을 {유형: 건수} 로 읽는다."""
    kinds = {}
    for line in section(text, "시스템 오류 이상 로그 요약"):
        m = re.match(r"\s*(\d+)\s+(.+)", line)
        if m:
            kinds[m.group(2).strip()] = int(m.group(1))
    return kinds


def disk(snap):
    """{"/mount 71"} → {"/mount": 71}"""
    out = {}
    for v in snap.get("disk", ()):
        mount, _, pct = v.rpartition(" ")
        if pct.isdigit():
            out[mount] = int(pct)
    return out


def one(snap, key):
    vals = snap.get(key)
    return min(vals) if vals else None


cur_path, base_path = Path(sys.argv[1]), Path(sys.argv[2])
cur_text, base_text = read(cur_path), read(base_path)
cur, base = snapshot(cur_text), snapshot(base_text)

print("## 지난 점검 대비 변화 (스크립트 계산)")
if cur is None:
    print("- 이번 점검에 비교용 데이터 없음 (수집 실패)")
    sys.exit(0)
if base is None:
    print("- 비교할 지난 기록 없음 (이번 점검이 기준선)")
    sys.exit(0)

base_time = datetime.fromtimestamp(base_path.stat().st_mtime)
days = (cur_path.stat().st_mtime - base_path.stat().st_mtime) / 86400
print(f"- 비교 기준: {base_time:%Y-%m-%d %H:%M} 점검 ({days:.0f}일 전)")

changes = []
invalid = cur.get("SNAPSHOT_FIELD_FAILED", set()) | base.get("SNAPSHOT_FIELD_FAILED", set())
for key in invalid:
    cur.pop(key, None)
    base.pop(key, None)
    changes.append(f"- {key}: 이번 또는 지난 수집 실패로 비교 불가")

cd, bd = disk(cur), disk(base)
for m in sorted(cd.keys() | bd.keys()):
    if m in cd and m in bd:
        if cd[m] != bd[m]:
            changes.append(f"- 디스크 {m}: {bd[m]}% → {cd[m]}% ({cd[m] - bd[m]:+d}%p)")
    elif m in cd:
        changes.append(f"- 디스크 {m}: 새로 보임 ({cd[m]}%)")
    else:
        changes.append(f"- 디스크 {m}: 이번에 안 보임 (지난번 {bd[m]}%)")

for key, label in (("port", "리스닝 포트"), ("user", "계정(UID 1000 이상)"), ("sudo", "sudoers 항목")):
    c, b = cur.get(key, set()), base.get(key, set())
    changes += [f"- {label} 추가: `{x}`" for x in sorted(c - b)]
    changes += [f"- {label} 제거: `{x}`" for x in sorted(b - c)]

cb, bb = one(cur, "boot"), one(base, "boot")
if cb and bb and cb != bb:
    changes.append(f"- 재부팅 발생: 부팅 시각 {bb} → {cb}")

cs, bs = one(cur, "sshfail"), one(base, "sshfail")
if cs is not None and bs is not None and cs != bs:
    changes.append(f"- SSH 로그인 실패 건수(각 점검 기간 기준): {bs} → {cs}")

# @ 오류 로그 유형: 이번에 처음 나온 것 / 사라진 것 / 두 번 다 있는데 건수가 바뀐 것
ck, bk = log_kinds(cur_text), log_kinds(base_text)
new = sorted(ck.keys() - bk.keys(), key=lambda k: -ck[k])
gone = sorted(bk.keys() - ck.keys(), key=lambda k: -bk[k])
moved = sorted((k for k in ck.keys() & bk.keys() if ck[k] != bk[k]), key=lambda k: -abs(ck[k] - bk[k]))
for label, keys, fmt in (
    ("새 오류 로그 유형", new, lambda k: f"({ck[k]}건) `{k}`"),
    ("이번 상위 로그에서 미관측 (해소 여부 미확인)", gone, lambda k: f"(지난번 {bk[k]}건) `{k}`"),
    ("오류 로그 건수 변화", moved, lambda k: f"{bk[k]} → {ck[k]}건 `{k}`"),
):
    changes += [f"- {label}: {fmt(k)}" for k in keys[:LOG_SHOW]]
    if len(keys) > LOG_SHOW:
        changes.append(f"- {label}: 그 외 {len(keys) - LOG_SHOW}종")

print("\n".join(changes) if changes else "- 변화 없음")

# ! --- 지난 점검 원본 데이터 (판단 근거가 아닌 비교 참고용) ---
print()
print(f"## 지난 점검 데이터 (참고용, {base_time:%Y-%m-%d %H:%M} 점검 원본)")
for title, marker in (
    ("일별 1분 부하", "일별 1분 부하"),
    ("일별 메모리 사용률", "일별 메모리 사용률"),
    ("시스템 오류 로그 요약", "시스템 오류 이상 로그 요약"),
):
    print(f"[{title}]")
    print("\n".join(section(base_text, marker)) or "(기록 없음)")
print("[SNAPSHOT]")
print(base_text.split("### SNAPSHOT ###", 1)[1].split("### END SNAPSHOT ###", 1)[0].strip())
