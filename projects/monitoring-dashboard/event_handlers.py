# ! GUI 이벤트 핸들러 모듈

import tkinter as tk
from tkinter import ttk, messagebox
from monitoring import ServiceMonitor
from dialogs import ServiceDialog, RecipientDialog, CallRecipientDialog, GroupDialog
from logger import get_logger

log = get_logger()


def _get_selected_group(app):
  """선택된 그룹 이름을 반환합니다."""
  selection = app.group_list.selection()
  if not selection:
    return None
  return app.group_list.item(selection[0], 'values')[1]


def on_group_select(app, event):
  """그룹 선택 시 호출"""
  group_name = _get_selected_group(app)
  if not group_name:
    app.clear_details()
    return
  app.update_service_list(group_name)
  app.update_recipient_list(group_name)
  app.update_monitoring_controls(group_name)
  app.update_interval_settings(group_name)


def add_service(app):
  group_name = _get_selected_group(app)
  if not group_name:
    messagebox.showwarning("경고", "서비스를 추가할 그룹을 먼저 선택하세요.")
    return

  dialog = ServiceDialog(app.root)
  if not dialog.result:
    return

  group_data = app.state.config['groups'][group_name]
  if any(s['address'] == dialog.result['address'] for s in group_data['services']):
    messagebox.showerror("오류", "해당 주소의 서비스가 이미 존재합니다.")
    return

  new_service = {**dialog.result, 'enabled': True, 'status': 'unknown', 'alert_sent': False}
  group_data['services'].append(new_service)
  app.state.save_config()
  app.update_service_list(group_name)
  app.rebuild_heatmap_widgets()

  if group_data.get('monitoring_on', False):
    _start_service_monitor(app, new_service, group_data, group_name)


def delete_service(app):
  group_name = _get_selected_group(app)
  selection = app.service_list.selection()
  if not group_name or not selection:
    messagebox.showwarning("경고", "삭제할 그룹과 서비스를 모두 선택하세요.")
    return

  values = app.service_list.item(selection[0])['values']
  service_address = values[2]

  if not messagebox.askyesno("확인", f"'{values[1]}' ({service_address}) 서비스를 삭제하시겠습니까?"):
    return

  if service_address in app.state.monitors:
    app.state.monitors[service_address].stop()
    del app.state.monitors[service_address]

  app.state.config['groups'][group_name]['services'] = [
      s for s in app.state.config['groups'][group_name]['services'] if s['address'] != service_address
  ]
  app.state.save_config()
  app.update_service_list(group_name)
  app.rebuild_heatmap_widgets()


def toggle_service_enabled(app, item_id):
  values = app.service_list.item(item_id, "values")
  service_address = values[2]
  group_name = _get_selected_group(app)
  group_data = app.state.config['groups'][group_name]

  service = next((s for s in group_data['services'] if s['address'] == service_address), None)
  if not service:
    return

  service['enabled'] = not service.get('enabled', True)
  app.state.save_config()

  if not service['enabled']:
    if service_address in app.state.monitors:
      app.state.monitors[service_address].stop()
      del app.state.monitors[service_address]
    app.update_service_status(service_address, "비활성화", f"서비스 '{service['name']}' 비활성화됨")
  else:
    log.info("서비스 '%s' 활성화됨", service['name'])
    if group_data.get('monitoring_on', False):
      _start_service_monitor(app, service, group_data, group_name)
    else:
      app.state.service_statuses[service_address] = "대기중"

  app.update_service_list(group_name)


def on_tree_click(app, event):
  if app.service_list.identify("region", event.x, event.y) == "heading":
    return
  item_id = app.service_list.identify_row(event.y)
  if item_id and app.service_list.identify_column(event.x) == "#1":
    toggle_service_enabled(app, item_id)


def on_group_tree_click(app, event):
  if app.group_list.identify("region", event.x, event.y) == "heading":
    return
  item_id = app.group_list.identify_row(event.y)
  if item_id and app.group_list.identify_column(event.x) == "#1":
    app.group_list.selection_set(item_id)
    toggle_group_enabled(app)


def add_group(app):
  dialog = GroupDialog(app.root, title="그룹 추가")
  if not dialog.result:
    return
  group_name = dialog.result['name']
  if group_name in app.state.config['groups']:
    messagebox.showerror("오류", "이미 존재하는 그룹 이름입니다.")
    return

  app.state.config['groups'][group_name] = {
      'services': [], 'recipients': [], 'call_recipients': [],
      'monitoring_on': False, 'group_enabled': True,
      'monitoring_interval_online': 30, 'max_retries': 3,
      'call_alias': dialog.result['call_alias']
  }
  app.state.save_config()
  app.load_groups()
  app.rebuild_heatmap_widgets()
  for item_id in app.group_list.get_children():
    if app.group_list.item(item_id, 'values')[1] == group_name:
      app.group_list.selection_set(item_id)
      break
  on_group_select(app, None)


def delete_group(app):
  group_name = _get_selected_group(app)
  if not group_name:
    messagebox.showwarning("경고", "삭제할 그룹을 선택하세요.")
    return

  group_data = app.state.config['groups'][group_name]

  if group_data.get('monitoring_on', False):
    if not messagebox.askyesno("경고", f"'{group_name}' 그룹은 현재 모니터링 중입니다.\n정말 삭제하시겠습니까?", icon='warning'):
      return
  else:
    if not messagebox.askyesno("확인", f"'{group_name}' 그룹을 삭제하시겠습니까?"):
      return

  stop_group_monitoring(app, group_name)
  del app.state.config['groups'][group_name]
  app.state.save_config()
  app.load_groups()
  app.clear_details()
  app.rebuild_heatmap_widgets()


def toggle_group_enabled(app):
  """그룹 활성화/비활성화 토글"""
  group_name = _get_selected_group(app)
  if not group_name:
    messagebox.showwarning("경고", "그룹을 선택하세요.")
    return

  group_data = app.state.config['groups'][group_name]
  currently_enabled = group_data.get('group_enabled', True)

  if currently_enabled:
    # 비활성화: 모니터링 중이면 먼저 중지
    if group_data.get('monitoring_on', False):
      stop_group_monitoring(app, group_name)
    group_data['group_enabled'] = False
    log.info("그룹 '%s' 비활성화됨", group_name)
  else:
    group_data['group_enabled'] = True
    log.info("그룹 '%s' 활성화됨", group_name)

  app.state.save_config()
  app.update_group_indicator(group_name)
  app.update_monitoring_controls(group_name)
  app.update_status_summary()


# === 전화 수신자 유틸리티 (순위 그룹 기반) ===

def _get_priority_count(group_data):
  """현재 순위 그룹 수를 반환합니다."""
  cr = group_data.get('call_recipients', [])
  return len(cr)


def _find_recipient_in_groups(call_recipients, recipient_str):
  """중첩 리스트에서 수신자를 찾아 (순위 인덱스, 그룹 내 인덱스)를 반환합니다."""
  for pi, group in enumerate(call_recipients):
    for ri, r in enumerate(group):
      if r == recipient_str:
        return pi, ri
  return None, None


def _cleanup_empty_groups(call_recipients):
  """빈 순위 그룹을 제거합니다."""
  return [g for g in call_recipients if g]


# === 문자 수신자 ===

def _get_selected_recipient(list_widget):
  selection = list_widget.selection()
  if not selection:
    return None
  values = list_widget.item(selection[0], 'values')
  if len(values) == 3:
    return f"{values[1]}/{values[2]}"
  return f"{values[0]}/{values[1]}"


def _add_recipient(app, list_widget, key, title):
  group_name = _get_selected_group(app)
  if not group_name:
    messagebox.showwarning("경고", f"{title}를 추가할 그룹을 먼저 선택하세요.")
    return

  recipient = RecipientDialog(app.root, title=f"{title} 추가").result
  if not recipient:
    return

  group_data = app.state.config['groups'][group_name]
  if key not in group_data:
    group_data[key] = []
  if recipient in group_data[key]:
    messagebox.showerror("오류", f"이미 등록된 {title}입니다.")
    return

  group_data[key].append(recipient)
  app.state.save_config()
  app.update_recipient_list(group_name)


def _delete_recipient(app, list_widget, key, title):
  group_name = _get_selected_group(app)
  recipient = _get_selected_recipient(list_widget)
  if not group_name or not recipient:
    messagebox.showwarning("경고", f"삭제할 그룹과 {title}를 모두 선택하세요.")
    return

  if not messagebox.askyesno("확인", f"'{recipient}' {title}를 삭제하시겠습니까?"):
    return

  app.state.config['groups'][group_name][key].remove(recipient)
  app.state.save_config()
  app.update_recipient_list(group_name)


def _edit_recipient(app, list_widget, key, title):
  group_name = _get_selected_group(app)
  old = _get_selected_recipient(list_widget)
  if not group_name or not old:
    messagebox.showwarning("경고", f"수정할 그룹과 {title}를 선택하세요.")
    return

  new = RecipientDialog(app.root, title=f"{title} 수정", recipient=old).result
  if not new or new == old:
    return

  recipients = app.state.config['groups'][group_name][key]
  if new in recipients:
    messagebox.showerror("오류", f"이미 등록된 {title}입니다.")
    return

  recipients[recipients.index(old)] = new
  app.state.save_config()
  app.update_recipient_list(group_name)


def add_recipient(app):
  _add_recipient(app, app.recipient_list, 'recipients', '문자 수신자')

def delete_recipient(app):
  _delete_recipient(app, app.recipient_list, 'recipients', '문자 수신자')

def edit_selected_recipient(app):
  _edit_recipient(app, app.recipient_list, 'recipients', '문자 수신자')


# === 전화 수신자 (순위 그룹 기반) ===

def _get_selected_call_recipient_info(app):
  """선택된 전화 수신자의 recipient 문자열을 반환합니다."""
  selection = app.call_recipient_list.selection()
  if not selection:
    return None
  values = app.call_recipient_list.item(selection[0], 'values')
  # values: (순위, 이름, 연락처)
  return f"{values[1]}/{values[2]}"


def add_call_recipient(app):
  group_name = _get_selected_group(app)
  if not group_name:
    messagebox.showwarning("경고", "전화 수신자를 추가할 그룹을 먼저 선택하세요.")
    return

  group_data = app.state.config['groups'][group_name]
  cr = group_data.get('call_recipients', [])
  max_priority = len(cr)

  dialog = CallRecipientDialog(app.root, title="전화 수신자 추가", max_priority=max_priority)
  if not dialog.result:
    return

  recipient_str = dialog.result['recipient']
  priority = dialog.result['priority']

  # 중복 확인
  for group in cr:
    if recipient_str in group:
      messagebox.showerror("오류", "이미 등록된 전화 수신자입니다.")
      return

  # 순위 그룹에 추가
  if 'call_recipients' not in group_data:
    group_data['call_recipients'] = []
  cr = group_data['call_recipients']

  # 순위 인덱스 (1-based → 0-based)
  idx = priority - 1
  if idx < len(cr):
    cr[idx].append(recipient_str)
  else:
    # 새 순위 그룹 생성
    while len(cr) < idx:
      cr.append([])
    cr.append([recipient_str])

  app.state.save_config()
  app.update_recipient_list(group_name)


def delete_call_recipient(app):
  group_name = _get_selected_group(app)
  recipient_str = _get_selected_call_recipient_info(app)
  if not group_name or not recipient_str:
    messagebox.showwarning("경고", "삭제할 그룹과 전화 수신자를 모두 선택하세요.")
    return

  if not messagebox.askyesno("확인", f"'{recipient_str}' 전화 수신자를 삭제하시겠습니까?"):
    return

  cr = app.state.config['groups'][group_name].get('call_recipients', [])
  pi, ri = _find_recipient_in_groups(cr, recipient_str)
  if pi is not None:
    cr[pi].pop(ri)
    app.state.config['groups'][group_name]['call_recipients'] = _cleanup_empty_groups(cr)
    app.state.save_config()
    app.update_recipient_list(group_name)


def edit_selected_call_recipient(app):
  group_name = _get_selected_group(app)
  old_str = _get_selected_call_recipient_info(app)
  if not group_name or not old_str:
    messagebox.showwarning("경고", "수정할 그룹과 전화 수신자를 선택하세요.")
    return

  group_data = app.state.config['groups'][group_name]
  cr = group_data.get('call_recipients', [])
  old_pi, old_ri = _find_recipient_in_groups(cr, old_str)
  if old_pi is None:
    return

  old_name, old_phone = old_str.split('/', 1)
  max_priority = len(cr)

  dialog = CallRecipientDialog(
      app.root, title="전화 수신자 수정",
      recipient={'name': old_name, 'phone': old_phone, 'priority': old_pi + 1},
      max_priority=max_priority
  )
  if not dialog.result:
    return

  new_str = dialog.result['recipient']
  new_priority = dialog.result['priority']

  # 중복 확인 (자기 자신 제외)
  if new_str != old_str:
    for group in cr:
      if new_str in group:
        messagebox.showerror("오류", "이미 등록된 전화 수신자입니다.")
        return

  # 기존 위치에서 제거
  cr[old_pi].pop(old_ri)

  # 새 순위에 추가
  new_idx = new_priority - 1
  if new_idx < len(cr):
    cr[new_idx].append(new_str)
  else:
    while len(cr) < new_idx:
      cr.append([])
    cr.append([new_str])

  group_data['call_recipients'] = _cleanup_empty_groups(cr)
  app.state.save_config()
  app.update_recipient_list(group_name)


def move_call_recipient(app, direction):
  """전화 수신자의 순위를 변경합니다. direction: -1(순위 올림), +1(순위 내림)"""
  group_name = _get_selected_group(app)
  recipient_str = _get_selected_call_recipient_info(app)
  if not group_name or not recipient_str:
    return

  cr = app.state.config['groups'][group_name].get('call_recipients', [])
  pi, ri = _find_recipient_in_groups(cr, recipient_str)
  if pi is None:
    return

  new_pi = pi + direction
  if new_pi < 0 or new_pi >= len(cr):
    # 범위 밖이면 새 순위 그룹 생성
    if new_pi < 0:
      cr.insert(0, [recipient_str])
      cr[pi + 1].pop(ri)
    else:
      cr.append([recipient_str])
      cr[pi].pop(ri)
  else:
    # 기존 그룹에서 제거 후 대상 그룹에 추가
    cr[pi].pop(ri)
    cr[new_pi].append(recipient_str)

  app.state.config['groups'][group_name]['call_recipients'] = _cleanup_empty_groups(cr)
  app.state.save_config()
  app.update_recipient_list(group_name)


def save_group_settings(app):
  group_name = _get_selected_group(app)
  if not group_name:
    messagebox.showwarning("경고", "설정을 저장할 그룹을 선택하세요.")
    return

  try:
    interval = int(app.online_interval_entry.get())
    retries = int(app.max_retries_entry.get())
    group_data = app.state.config['groups'][group_name]
    group_data['monitoring_interval_online'] = interval
    group_data['max_retries'] = retries
    app.state.save_config()
    messagebox.showinfo("성공", f"'{group_name}' 그룹 설정이 저장되었습니다.")
  except ValueError:
    messagebox.showerror("오류", "설정 값은 숫자로 입력해야 합니다.")


def _start_service_monitor(app, service, group_data, group_name):
  addr = service['address']
  app.state.service_statuses[addr] = "확인 중..."
  if addr not in app.state.monitors or not app.state.monitors[addr].running:
    monitor = ServiceMonitor(
        service, app.update_service_status, app.state,
        normal_check_interval=group_data.get('monitoring_interval_online', 30),
        max_retries=group_data.get('max_retries', 3)
    )
    app.state.monitors[addr] = monitor
    monitor.start()


def start_group_monitoring(app, group_name, autostart=False):
  group_data = app.state.config['groups'][group_name]

  # 비활성화된 그룹은 시작 불가
  if not group_data.get('group_enabled', True):
    return

  if not autostart and group_data.get('monitoring_on', False):
    return

  group_data['monitoring_on'] = True

  for service in group_data.get('services', []):
    if service.get('enabled', True):
      _start_service_monitor(app, service, group_data, group_name)


def stop_group_monitoring(app, group_name, autostart=False):
  if group_name not in app.state.config['groups']:
    return

  group_data = app.state.config['groups'][group_name]
  if not autostart and not group_data.get('monitoring_on', False):
    return

  group_data['monitoring_on'] = False
  group_data['call_alert_sent'] = False
  group_data['sms_alert_sent'] = False

  for service in group_data.get('services', []):
    service['alert_sent'] = False
    service['status'] = '대기중'
    if service.get('enabled', True):
      addr = service.get('address')
      if addr and addr in app.state.monitors:
        app.state.monitors[addr].stop()
        del app.state.monitors[addr]
        app.update_service_status(addr, "중지됨", f"서비스 '{service['name']}' 모니터링 중지됨")


def start_selected_group_monitoring(app):
  group_name = _get_selected_group(app)
  if not group_name:
    messagebox.showwarning("경고", "그룹을 선택하세요.")
    return
  group_data = app.state.config['groups'][group_name]
  if not group_data.get('group_enabled', True):
    messagebox.showwarning("경고", "비활성화된 그룹은 모니터링을 시작할 수 없습니다.")
    return
  start_group_monitoring(app, group_name)
  app.state.save_config()
  app.update_monitoring_controls(group_name)
  app.update_service_list(group_name)
  app.update_group_indicator(group_name)
  app.update_status_summary()


def stop_selected_group_monitoring(app):
  group_name = _get_selected_group(app)
  if not group_name:
    messagebox.showwarning("경고", "그룹을 선택하세요.")
    return
  stop_group_monitoring(app, group_name)
  app.state.save_config()
  app.update_monitoring_controls(group_name)
  app.update_service_list(group_name)
  app.update_group_indicator(group_name)
  app.update_status_summary()


def start_all_monitoring(app):
  """전체 모니터링 시작 (일괄 처리 후 한 번만 GUI 갱신)"""
  if not messagebox.askyesno("확인", "전체 모니터링을 시작하시겠습니까?"):
    return
  selected_name = _get_selected_group(app)

  for group_name in app.state.config['groups']:
    start_group_monitoring(app, group_name)

  # 일괄 저장 + GUI 갱신 (1회)
  app.state.save_config()
  app.load_groups()
  if selected_name and selected_name in app._group_item_map:
    app.group_list.selection_set(app._group_item_map[selected_name])
    on_group_select(app, None)
  app.update_status_summary()


def stop_all_monitoring(app):
  """전체 모니터링 중지 (일괄 처리 후 한 번만 GUI 갱신)"""
  if not messagebox.askyesno("확인", "전체 모니터링을 종료하시겠습니까?"):
    return
  selected_name = _get_selected_group(app)

  for group_name in app.state.config['groups']:
    stop_group_monitoring(app, group_name, autostart=True)

  # stop_group_monitoring이 처리하지 못한 잔여 상태 정리
  app.state.clear_all_states()

  # 일괄 저장 + GUI 갱신 (1회)
  app.state.save_config()
  app.load_groups()
  if selected_name and selected_name in app._group_item_map:
    app.group_list.selection_set(app._group_item_map[selected_name])
    on_group_select(app, None)
  app.update_status_summary()


def edit_selected_group(app):
  group_name = _get_selected_group(app)
  if not group_name:
    messagebox.showwarning("경고", "수정할 그룹을 선택하세요.")
    return

  group_data = app.state.config['groups'][group_name]
  dialog = GroupDialog(
      app.root, title="그룹 수정",
      group_name=group_name,
      call_alias=group_data.get('call_alias', '')
  )
  if not dialog.result:
    return

  new_name = dialog.result['name']
  if new_name != group_name and new_name in app.state.config['groups']:
    messagebox.showerror("오류", "이미 존재하는 그룹 이름입니다.")
    return

  group_data['call_alias'] = dialog.result['call_alias']

  if new_name != group_name:
    app.state.config['groups'][new_name] = app.state.config['groups'].pop(group_name)
  app.state.save_config()
  app.load_groups()
  for item_id in app.group_list.get_children():
    if app.group_list.item(item_id, 'values')[1] == new_name:
      app.group_list.selection_set(item_id)
      on_group_select(app, None)
      break
  app.rebuild_heatmap_widgets()


def edit_selected_service(app):
  group_name = _get_selected_group(app)
  selection = app.service_list.selection()
  if not group_name or not selection:
    messagebox.showwarning("경고", "수정할 그룹과 서비스를 선택하세요.")
    return

  old_address = app.service_list.item(selection[0], 'values')[2]
  service_obj = next((s for s in app.state.config['groups'][group_name]['services'] if s['address'] == old_address), None)
  if not service_obj:
    return

  dialog = ServiceDialog(app.root, service=service_obj)
  if not dialog.result:
    return

  new_address = dialog.result['address']
  if new_address != old_address and any(s['address'] == new_address for s in app.state.config['groups'][group_name]['services']):
    messagebox.showerror("오류", "해당 주소의 서비스가 이미 존재합니다.")
    return

  if old_address in app.state.monitors:
    app.state.monitors[old_address].stop()
    del app.state.monitors[old_address]
  if old_address in app.state.service_statuses:
    del app.state.service_statuses[old_address]

  service_obj['name'] = dialog.result['name']
  service_obj['address'] = new_address
  app.state.save_config()

  group_data = app.state.config['groups'][group_name]
  if group_data.get('monitoring_on', False) and service_obj.get('enabled', True):
    _start_service_monitor(app, service_obj, group_data, group_name)

  app.update_service_list(group_name)
  app.rebuild_heatmap_widgets()
