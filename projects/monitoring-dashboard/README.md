# Server Monitoring

실시간 서버/서비스 상태 모니터링 및 장애 알림 시스템

---

## 개요

Tkinter GUI를 통해 여러 서버와 서비스의 TCP 포트 상태를 실시간으로 모니터링하고, 장애 발생 시 지정된 담당자에게 SMS/전화 알림을 보내는 통합 모니터링 시스템이다.

- 서비스를 그룹별로 관리
- 전체/그룹별 모니터링 제어
- 장애 시 SMS(DirectSend API) / 전화(Amazon Connect) 알림
- 전화 수신자 순위별 동시 발신 지원
- 히트맵으로 전체 서비스 상태 시각화
- Health Check 포트로 모니터링 프로그램 자체 상태 확인

**실행 시 `MO_SECRET_KEY` 환경변수가 필요하다.** (암호화/복호화에 사용)

---

## 프로젝트 구조

```
Server-Monitoring/
├── main.py              # 메인 진입점 (Tkinter root 생성)
├── gui.py               # MonitoringApp 클래스 (GUI 레이아웃, 이벤트 바인딩)
├── gui_widgets.py       # Tkinter 위젯 생성 함수
├── app_state.py         # AppState 클래스 (공유 상태: config, monitors, statuses)
├── event_handlers.py    # GUI 이벤트 핸들러 (버튼 클릭, 목록 선택)
├── monitoring.py        # ServiceMonitor 클래스 (스레드 기반 TCP 포트 확인)
├── config_manager.py    # config.json 로드/저장, 민감정보 자동 암호화
├── alerter.py           # SMS(DirectSend), 전화(Amazon Connect) 발송
├── alert_dispatcher.py  # 알림 발송 판단 로직 (failure/resolved 구분)
├── dialogs.py           # 서비스/수신자/그룹 추가/수정 대화상자
├── heatmap_view.py      # HeatmapView 클래스 (전체 서비스 상태 시각화)
├── crypto_utils.py      # Encryptor 클래스 (Fernet + PBKDF2 암호화)
├── logger.py            # 로깅 설정 (파일/콘솔)
└── README.md
```

---

## 주요 기능

### 모니터링
- **TCP 포트 체크**: `socket.connect()`로 서비스 상태 확인
- **재시도 로직**: `max_retries` 횟수만큼 실패 시 오프라인 판정
- **그룹 기반 관리**: 서비스, SMS 수신자, 전화 수신자를 그룹으로 묶어 관리
- **모니터링 주기**: 그룹별 `monitoring_interval_online` 설정 (초 단위)

### 알림
- **SMS**: DirectSend API (`https://directsend.co.kr/index.php/api_v2/sms_change_word`)
- **전화**: Amazon Connect `start_outbound_voice_contact`
  - 순위별 중첩 리스트 구조: `[['1순위A', '1순위B'], ['2순위']]`
  - 같은 순위 내 동시 발신, 1명이라도 응답하면 성공
  - 5초 간격 폴링으로 응답 확인 (최대 90초)
  - 전체 순위 5회 반복
  - `call_time` 설정으로 시간대별 발신 차단

### Health Check
- `socketserver.TCPServer`로 외부에서 모니터링 프로그램 상태 확인 가능
- `telnet <ip> <port>` 접속 시 "MonitoringApp is running OK" 응답

### 암호화
- `crypto_utils.Encryptor`: PBKDF2(480,000 iterations) + Fernet
- `enc::` 접두사로 암호화 여부 구분
- `config_manager`에서 로드 시 자동 복호화, 저장 시 자동 암호화

### 상태 표시 색상
| 상태 | 색상 |
|------|------|
| 온라인 | `#22854B` (초록) |
| 오프라인 / 연결 실패 | `#E74C3C` (빨강) |
| 확인 중 | `#F39C12` (주황) |
| 중지됨 / 대기중 | `#333333` (검정) |
| 비활성화 | `#BDC3C7` (회색) |

---

## 실행 방법

### 요구사항
- Python 3.8+
- 패키지: `cryptography`, `boto3`, `requests`

```bash
pip install cryptography boto3 requests
```

### 실행
```bash
# 환경변수 설정
export MO_SECRET_KEY="your-secret-key"

# 실행
python main.py
```

또는 PyInstaller로 빌드된 exe 파일 실행.

---

## 설정 (config.json)

```json
{
  "health_check_port": 9163,
  "call_time": {
    "start": 0,
    "end": 8
  },
  "directsend": {
    "api_key": "enc::...",
    "username": "enc::...",
    "sender_phone": "enc::..."
  },
  "aws_connect": {
    "access_key_id": "enc::...",
    "secret_access_key": "enc::...",
    "region_name": "enc::...",
    "instance_id": "enc::...",
    "contact_flow_id": "enc::...",
    "source_phone_number": "enc::..."
  },
  "groups": {
    "그룹명": {
      "services": [
        {
          "name": "서비스명",
          "address": "IP:Port",
          "enabled": true,
          "status": "온라인",
          "alert_sent": false
        }
      ],
      "recipients": ["수신자/01012345678"],
      "call_recipients": [
        ["1순위A/01011111111", "1순위B/01022222222"],
        ["2순위/01033333333"]
      ],
      "monitoring_on": false,
      "monitoring_interval_online": 30,
      "max_retries": 3,
      "group_enabled": true,
      "call_alert_sent": false,
      "call_alias": "그룹 별명"
    }
  }
}
```

### 설정 항목

| 항목 | 설명 |
|------|------|
| `health_check_port` | 모니터링 프로그램 Health Check TCP 포트 |
| `call_time.start/end` | 전화 발신 차단 시간대 (0~23시) |
| `directsend.*` | SMS 발송용 DirectSend API 정보 (자동 암호화) |
| `aws_connect.*` | 전화 발신용 Amazon Connect 정보 (자동 암호화) |
| `groups.*.services` | 모니터링 대상 서비스 목록 |
| `groups.*.recipients` | SMS 수신자 (`이름/연락처` 형식) |
| `groups.*.call_recipients` | 전화 수신자 (순위별 중첩 리스트) |
| `groups.*.monitoring_interval_online` | 모니터링 주기 (초) |
| `groups.*.max_retries` | 오프라인 판정 전 재시도 횟수 |
| `groups.*.call_alias` | 전화 음성 메시지에 사용될 그룹 별명 |

### 자동 마이그레이션
기존 단순 리스트 형태의 `call_recipients`는 프로그램 시작 시 자동으로 중첩 리스트로 변환된다:
```
["a/번호", "b/번호"] → [["a/번호"], ["b/번호"]]
```

---

## 모니터링 흐름

```
main.py
  └─ MonitoringApp(root)
       ├─ AppState (config 로드, 상태 관리)
       ├─ create_widgets() (GUI 생성)
       ├─ autostart_monitoring() (monitoring_on=true인 그룹 자동 시작)
       └─ ServiceMonitor (스레드)
            ├─ _check_connection() → socket.connect()
            ├─ 성공 → callback("온라인")
            └─ 실패 → retry → max_retries 초과 시 callback("오프라인")
                         └─ dispatch_alert() → alerter.send_alert() / send_call_alert()
```

---

## 라이선스

Internal Use Only
