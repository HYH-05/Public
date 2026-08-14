# ! 알림 디스패치 모듈 - GUI에서 분리된 알림 발송 판단 로직

import threading
import alerter
from logger import get_logger

log = get_logger()


def _safe_send_sms(group_data, send_fn, *args):
  """발송 직전 monitoring_on을 체크하여, 꺼져 있으면 발송을 건너뜁니다."""
  if not group_data.get('monitoring_on', False):
    log.info("모니터링 종료됨, SMS 발송 스킵")
    return
  send_fn(*args)


def dispatch_alert(app, service_address, alert_type):
  """알림 유형에 따라 SMS/전화 알림을 디스패치합니다."""
  if not alert_type:
    return

  for group_name, group_data in app.state.config['groups'].items():
    service_obj = next((s for s in group_data.get('services', []) if s['address'] == service_address), None)
    if not (service_obj and group_data.get('monitoring_on', False) and service_obj.get('enabled', True)):
      continue

    # SMS 알림 (그룹당 1회)
    recipients = group_data.get('recipients', [])
    display_name = group_data.get('call_alias') or group_name
    if recipients:
      if alert_type == 'failure':
        if not group_data.get('sms_alert_sent', False):
          threading.Thread(target=_safe_send_sms, args=(group_data, alerter.send_alert, display_name, service_address, recipients), daemon=True).start()
          group_data['sms_alert_sent'] = True
          app.state.save_config()
      elif alert_type == 'resolved':
        pass  # 복구 SMS는 아래 전체 복구 시 리셋과 함께 처리

    # 전화 알림 (그룹당 1회)
    if alert_type == 'failure':
      call_recipients = group_data.get('call_recipients', [])
      if call_recipients and not group_data.get('call_alert_sent', False):
        stop_flag = lambda: not group_data.get('monitoring_on', False)
        threading.Thread(target=alerter.send_call_alert, args=(group_name, call_recipients, stop_flag), daemon=True).start()
        group_data['call_alert_sent'] = True
        app.state.save_config()
    elif alert_type == 'resolved':
      # 모든 서비스 온라인 시 call_alert_sent, sms_alert_sent 리셋
      enabled_services = [s for s in group_data.get('services', []) if s.get('enabled', True)]
      if all(app.state.service_statuses.get(s['address']) == '온라인' for s in enabled_services):
        if group_data.get('call_alert_sent', False) or group_data.get('sms_alert_sent', False):
          if group_data.get('sms_alert_sent', False) and recipients:
            threading.Thread(target=_safe_send_sms, args=(group_data, alerter.send_resolved_alert, display_name, service_address, recipients), daemon=True).start()
          group_data['call_alert_sent'] = False
          group_data['sms_alert_sent'] = False
          app.state.save_config()
          log.info("'%s' 그룹 alert 리셋", group_name)
    break
