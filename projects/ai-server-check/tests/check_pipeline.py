import importlib.util, json, os, shutil, subprocess, tempfile
from pathlib import Path
src=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('status',src/'report_status.py'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
snap='### SNAPSHOT ###\ndisk / 99\n### END SNAPSHOT ###\n'
assert m.collection_state(snap+'### COLLECTION_ERRORS 1 ###',{'rc':1})=='partial'
assert m.collection_state(snap+'### COLLECTION_ERRORS 0 ###',{'rc':124})=='failed'
assert m.collection_state(snap+'### COLLECTION_ERRORS 0 ###',{'rc':0})=='ok'
for scenario in ('partial','slack_fail','early_fail'):
 with tempfile.TemporaryDirectory() as temp:
    root=Path(temp)
    for name in ('run.sh','report_status.py','compare.py'): shutil.copy(src/name,root/name)
    shutil.copytree(src/'prompts',root/'prompts')
    (root/'baseline').mkdir(); (root/'baseline/b.txt').write_text('OLD BASELINE')
    (root/'bin').mkdir(); (root/'slack.env').write_text('TEST_ONLY=1\n')
    (root/'notify_slack.py').write_text('import os,sys\nfrom pathlib import Path\nPath(sys.argv[1],"mock-notify.called").touch()\nsys.exit(1 if os.environ["SCENARIO"]=="slack_fail" else 0)\n')
    ansible='''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
if '--list-hosts' in sys.argv:
    if os.environ['SCENARIO']=='early_fail': sys.exit(2)
    print('  hosts (2):\\n    a\\n    b'); sys.exit(0)
out=Path(next(v.split('=',1)[1] for v in sys.argv if v.startswith('out_dir=')))
for host in ('a','b'):
    partial=host=='b' and os.environ['SCENARIO']=='partial'
    (out/(host+'.txt')).write_text('### SNAPSHOT ###\\ndisk / 99\\n### END SNAPSHOT ###\\n### COLLECTION_ERRORS '+str(int(partial))+' ###\\n')
    (out/(host+'.status.json')).write_text(json.dumps({'rc':int(partial)}))
'''
    (root/'bin/ansible-playbook').write_text(ansible); (root/'bin/ansible-playbook').chmod(0o700)
    claude='''#!/usr/bin/env python3
import sys
text=sys.stdin.read()
if '총괄' in ' '.join(sys.argv):
 print('## 요약\\n위험 확인\\n## 서버별 현황\\n임시 표\\n## 우선 조치 목록\\n확인 필요')
else:
 print('**종합 등급:** 위험\\n**한줄 요약:** 디스크 99% 확인 필요\\n## 항목별 상태\\n디스크 99%\\n## 조치 권고\\n확인')
'''
    (root/'bin/claude').write_text(claude); (root/'bin/claude').chmod(0o700)
    env=dict(os.environ,PATH=str(root/'bin')+':'+os.environ['PATH'],CLAUDE=str(root/'bin/claude'),SCENARIO=scenario,SLACK_ENV=str(root/'slack.env'),HOME=str(root))
    r=subprocess.run(['bash',str(root/'run.sh')],env=env,text=True,capture_output=True,timeout=30)
    out=next((root/'reports').iterdir())
    assert r.returncode==1,(scenario,r.stdout,r.stderr)
    assert (out/'exit.status').read_text().strip()=='1'
    assert (out/'mock-notify.called').exists()
    if scenario=='early_fail': assert '대상조회' in (out/'failure.txt').read_text()
    else:
        assert (root/'baseline/a.txt').read_text().startswith('### SNAPSHOT')
        result=json.loads((out/'result.json').read_text())
        if scenario=='partial':
            assert result['partial']==1 and result['counts']['위험']==2
            assert (root/'baseline/b.txt').read_text()=='OLD BASELINE'
            assert '디스크 99% 확인 필요' in (out/'summary.md').read_text()
        else: assert (root/'baseline/b.txt').read_text().startswith('### SNAPSHOT')
print('PASS: partial data analysis; per-host baseline; Slack failure isolation; early failure notification/status; summary detail')
with tempfile.TemporaryDirectory() as temp:
    a=Path(temp)/'a'; b=Path(temp)/'b'
    a.write_text('### SNAPSHOT ###\nSNAPSHOT_FIELD_FAILED sudo\n### END SNAPSHOT ###')
    b.write_text('### SNAPSHOT ###\nsudo old-rule\n### END SNAPSHOT ###')
    r=subprocess.run(['python3',str(src/'compare.py'),str(a),str(b)],capture_output=True,text=True)
    assert r.returncode==0 and '비교 불가' in r.stdout and 'sudoers 항목 제거' not in r.stdout
    s=(src/'notify_slack.py').read_text(); section=s[s.index('when = '):s.index('parent = api(')]
    ns={'TS':'20261105_120000','failed':True,'total':2,'partial':1,'count':dict.fromkeys(m.GRADES,0),'GRADES':dict.fromkeys(m.GRADES,''),'early_failure':Path(temp)/'none','esc':lambda x:x}
    ns['count']['위험']=1
    exec(section,ns)
    assert '<!here>' in ns['head'] and '위험 1' in ns['head'] and '부분 수집 1' in ns['head']
print('PASS: unknown snapshot field is not removed; danger mention survives partial failure')
