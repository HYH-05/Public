# ! 서비스 모니터링 모듈

import socket
import struct
import threading
from logger import get_logger

log = get_logger()


class ServiceMonitor:
  """개별 서비스를 모니터링하는 클래스"""

  def __init__(self, service, callback, app_state, normal_check_interval, max_retries):
    self.service_obj = service
    self.service = service['address']
    self.callback = callback
    self.app_state = app_state
    self.running = False
    self.thread = None
    self.stop_event = threading.Event()
    self.normal_check_interval = normal_check_interval
    self.max_retries = max_retries

  def start(self):
    """모니터링 시작"""
    self.running = True
    self.stop_event.clear()
    self.thread = threading.Thread(target=self._monitor, daemon=True)
    self.thread.start()

  def stop(self):
    """모니터링 중지"""
    self.running = False
    self.stop_event.set()

  def _save_status(self, status, alert_sent):
    """메모리 상의 config에 상태를 반영하고 저장"""
    try:
      for group in self.app_state.config['groups'].values():
        for service in group['services']:
          if service['address'] == self.service:
            service['status'] = status
            service['alert_sent'] = alert_sent
            self.app_state.save_config()
            return
    except Exception as e:
      log.error("상태 저장 실패 (%s): %s", self.service, e)

  def _check_connection(self):
    """서비스 연결 확인"""
    ip, port = self.service.rsplit(':', 1)
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
      s.settimeout(5)
      s.connect((ip, int(port)))
      s.shutdown(socket.SHUT_RDWR)

  def _monitor(self):
    """모니터링 루프"""
    retry_count = 0
    name = self.service_obj['name']

    while self.running:
      old_status = self.service_obj.get('status', '대기중')
      old_alert_sent = self.service_obj.get('alert_sent', False)

      try:
        self._check_connection()

        # 연결 성공
        retry_count = 0
        new_status = "온라인"
        new_alert_sent = False

        alert_type = 'resolved' if old_status == "오프라인" else None
        msg = f"서비스 '{name}' 복구됨" if alert_type == 'resolved' else f"서비스 '{name}' 온라인"
        self.callback(self.service, new_status, msg, alert_type)

        if old_status != new_status or old_alert_sent != new_alert_sent:
          self._save_status(new_status, new_alert_sent)
          self.service_obj['status'] = new_status
          self.service_obj['alert_sent'] = new_alert_sent

      except socket.gaierror as e:
        if not self.running:
          break
        log.error("DNS 해석 실패 '%s': %s", name, e)
        self._handle_failure(name, old_status, old_alert_sent, retry_count, e)
        retry_count = self._next_retry_count(retry_count, old_status)

      except (socket.timeout, ConnectionRefusedError, OSError) as e:
        if not self.running:
          break
        self._handle_failure(name, old_status, old_alert_sent, retry_count, e)
        retry_count = self._next_retry_count(retry_count, old_status)

      except Exception as e:
        if not self.running:
          break
        log.error("예기치 못한 모니터링 오류 '%s': %s", name, e)

      if self.stop_event.wait(self.normal_check_interval):
        break

  def _handle_failure(self, name, old_status, old_alert_sent, retry_count, error):
    """연결 실패 처리"""
    # 이미 오프라인 상태면 유지
    if old_status == "오프라인":
      self.callback(self.service, "오프라인", f"서비스 '{name}' 오프라인: {error}")
      return

    if retry_count + 1 >= self.max_retries:
      new_alert_sent = True
      alert_type = 'failure' if not old_alert_sent else None
      self.callback(self.service, "오프라인", f"서비스 '{name}' 오프라인: {error}", alert_type)

      if old_status != "오프라인" or old_alert_sent != new_alert_sent:
        self._save_status("오프라인", new_alert_sent)
        self.service_obj['status'] = "오프라인"
        self.service_obj['alert_sent'] = new_alert_sent
    else:
      status = f"연결 실패 ({retry_count + 1}/{self.max_retries})"
      self.callback(self.service, status, f"연결 재시도: '{name}' ({retry_count + 1}/{self.max_retries})")

  def _next_retry_count(self, retry_count, old_status):
    """다음 재시도 카운트 반환"""
    if old_status == "오프라인":
      return 0
    return retry_count + 1
