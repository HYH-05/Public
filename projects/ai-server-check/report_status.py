#!/usr/bin/env python3
"""수집 완전성과 분석 결과를 독립적으로 관리한다."""
import json
import re
import sys
from pathlib import Path
GRADES = ('위험', '주의', '수집실패', '분석실패', '정상')
def grade(text):
    gs = re.findall(r'^\*\*종합 등급:\*\*\s*(위험|주의|정상|수집실패|분석실패)\s*$', text, re.M)
    return gs[0] if len(gs) == 1 else None

def valid_analysis(text):
    return grade(text) in ('위험', '주의', '정상') and all(x in text for x in ('## 항목별 상태', '## 조치 권고'))

def collection_state(text, meta):
    matches = re.findall(r'^### COLLECTION_ERRORS (\d+) ###$', text, re.M)
    complete = len(matches) == 1 and '### SNAPSHOT ###' in text and '### END SNAPSHOT ###' in text
    if not complete or meta.get('unreachable'): return 'failed'
    if meta.get('rc') == 0 and int(matches[0]) == 0: return 'ok'
    if meta.get('rc') == 1 and int(matches[0]) > 0: return 'partial'
    return 'failed'

def main():
    mode, arg = sys.argv[1:3]
    p = Path(arg)
    if mode == 'validate':
        sys.exit(0 if valid_analysis(p.read_text()) else 1)
    if mode == 'targets':
        hosts, active = [], False
        for line in (p/'targets.log').read_text().splitlines():
            if re.match(r'\s*hosts \(\d+\):', line): active = True
            elif active and line.strip():
                h = line.strip()
                if not re.fullmatch(r'[A-Za-z0-9_.-]+', h) or h in ('.', '..'):
                    raise ValueError('Invalid host: ' + h)
                hosts.append(h)
        hosts = sorted(set(hosts))
        if not hosts: raise ValueError('No targets')
        (p/'hosts.json').write_text(json.dumps(hosts))
        print(len(hosts))
    if mode == 'prepare':
        states = {}
        for host in json.loads((p/'hosts.json').read_text()):
            raw = p/'raw'/f'{host}.txt'
            text = raw.read_text() if raw.exists() else '(수집 결과 없음)'
            try: meta = json.loads((p/'raw'/f'{host}.status.json').read_text())
            except (OSError, ValueError): meta = {}
            state = states[host] = collection_state(text, meta)
            if state != 'ok':
                label = '[부분 수집]' if state == 'partial' else '[수집 실패]'
                raw.write_text(label + ' 원본의 조회 실패 항목과 수집 로그 확인 필요\n' + text)
        (p/'collection.json').write_text(json.dumps(states))
    if mode == 'finalize':
        hosts = json.loads((p/'hosts.json').read_text())
        states = json.loads((p/'collection.json').read_text())
        counts, rows = dict.fromkeys(GRADES, 0), []
        for host in hosts:
            f = p/'analysis'/f'{host}.md'
            report = f.read_text() if f.exists() else ''
            g = grade(report) or '분석실패'
            counts[g] += 1
            brief = re.search(r'^\*\*한줄 요약:\*\*\s*(.+)$', report, re.M)
            brief = brief.group(1).replace('|', '\\|') if brief else '상세 보고서·오류 로그 확인 필요'
            state = {'ok':'완료','partial':'부분 수집','failed':'실패'}[states[host]]
            rows.append(f'| {host} | {g} | {state} | {brief} |')
        partial = sum(v == 'partial' for v in states.values())
        summary = p/'summary.md'
        text = summary.read_text() if summary.exists() else ''
        valid = (p/'summary.ok').exists() and all(x in text for x in ('## 요약', '## 서버별 현황', '## 우선 조치 목록'))
        failed = (p/'pipeline.failed').exists() or not valid or bool(partial + counts['분석실패'] + counts['수집실패'])
        header = f'전체 {len(hosts)}대 (프로그램 집계): ' + ' / '.join(f'{k} {v}' for k,v in counts.items()) + f' | 부분 수집 {partial}대'
        table = '## 서버별 현황\n| 서버 | 등급 | 수집 상태 | 핵심 문제 |\n|---|---|---|---|\n' + '\n'.join(rows) + '\n'
        if valid:
            text = re.sub(r'## 서버별 현황.*?(?=\n## |\Z)', lambda _: table, text, flags=re.S)
        else:
            (p/'summary.failed.txt').write_text(text)
            text = '## 요약\n종합 AI 분석 실패. 서버별 결과는 아래 표 참고.\n\n' + table
        summary.write_text(header + '\n\n' + text)
        (p/'result.json').write_text(json.dumps({'failed':failed, 'summary_ok':valid, 'counts':counts, 'partial':partial, 'total':len(hosts)}, ensure_ascii=False))
        sys.exit(int(failed))
if __name__ == '__main__': main()
