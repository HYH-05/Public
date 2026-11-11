# ai-server-check

Ansible로 리눅스 서버 점검 데이터를 수집하고, 지난 점검 원본과 기계적으로 비교한 뒤 Claude(`claude -p`)가 서버별 분석·종합 보고서를 만들어 Slack으로 보낸다.

## 흐름

```
run.sh
 ├─ collect.yml          대상 서버에서 files/health_check.sh 실행 → reports/<시각>/raw/<호스트>.txt
 ├─ report_status.py     수집 상태 판정 (ok / partial / failed)
 ├─ compare.py           baseline/<호스트>.txt 와 비교 (디스크·포트·계정·sudoers·재부팅·SSH 실패·오류 로그 유형)
 ├─ claude -p            prompts/server.md 로 서버별 분석 (도구 비활성화)
 ├─ claude -p            prompts/summary.md 로 종합
 ├─ report_status.py     분석 검증·등급 집계, baseline 갱신
 └─ notify_slack.py      Slack 전송
```

* 지난 AI 분석 결과는 다음 분석에 넣지 않는다. 비교는 수집 데이터끼리만 한다.
* `/etc/shadow` 해시는 수집 단계에서 알고리즘 ID만 남기고 마스킹한다.

## 구성 파일

| 파일 | 설명 |
|---|---|
| `run.sh` | 전체 실행 (flock 중복 방지, 단계별 실패 기록) |
| `collect.yml` | 점검 스크립트 배포·실행·결과 회수 |
| `files/health_check.sh` | 대상 서버 점검 스크립트 (부하, 메모리, 디스크, inode, 포트, 서비스, tmp, 계정, 로그, 로그인) |
| `compare.py` | 지난 점검 대비 변화 계산 |
| `report_status.py` | 수집/분석 상태 판정, 등급 집계 |
| `notify_slack.py` | Slack 메시지·보고서 업로드 |
| `prompts/` | 서버별·종합 분석 프롬프트 |
| `tests/check_pipeline.py` | 파이프라인 검증 |

## 준비

1. `inventory.example.ini` 를 `inventory.ini` 로 복사하고 대상 호스트를 채운다.
2. Slack 설정 파일(기본 `/root/.config/ai_check/slack.env`)에 `SLACK_BOT_TOKEN`, `SLACK_CHANNEL` 을 둔다. 저장소에는 올리지 않는다.
3. `claude` CLI 로그인 후 `./run.sh` 로 실행한다.

`reports/`, `raw/`, `baseline/` 은 서버 점검 원본이 들어가므로 저장소에 올리지 않는다.
