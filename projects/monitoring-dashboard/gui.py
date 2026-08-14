# ! 통합 모니터링 시스템 메인 GUI 모듈

import tkinter as tk
import socketserver
import threading
from datetime import datetime
from tkinter import ttk, messagebox, TclError

from app_state import AppState
from heatmap_view import HeatmapView, STATUS_COLORS, get_status_tag
from alert_dispatcher import dispatch_alert
from gui_widgets import create_widgets
import event_handlers as handlers
from logger import get_logger

log = get_logger()

_MAX_EVENT_LOG_LINES = 50


class MonitoringApp:
  """메인 애플리케이션 클래스"""

  def __init__(self, root):
    self.root = root
    self.state = AppState()
    self.health_check_server = None
    self.heatmap = HeatmapView(self.state)
    self._item_id_map = {}
    self._group_item_map = {}
    self._original_title = "통합 모니터링 시스템"
    self._alert_title = False

    root.title(self._original_title)
    root.geometry("1400x800")
    root.minsize(900, 600)

    self._apply_theme(root)
    create_widgets(self)
    self._setup_log_handler()
    self._bind_events()
    self._reset_config_on_startup()
    self.load_groups()

    root.after(100, self.autostart_monitoring)
    root.protocol("WM_DELETE_WINDOW", self.on_closing)
    self._start_health_check_server()

  def _apply_theme(self, root):
    BG = "#f5f6fa"
    CARD_BG = "#ffffff"
    ACCENT = "#3b82f6"
    ACCENT_HOVER = "#2563eb"
    DANGER = "#ef4444"
    DANGER_HOVER = "#dc2626"
    TEXT = "#1e293b"
    TEXT_SUB = "#64748b"
    BORDER = "#e2e8f0"
    HEADER_BG = "#e2e8f0"
    HEADER_FG = "#334155"
    ROW_ALT = "#f8fafc"

    root.configure(bg=BG)
    style = ttk.Style(root)
    style.theme_use("clam")

    style.configure(".", background=BG, foreground=TEXT, font=("Malgun Gothic", 9))
    style.configure("TFrame", background=BG)
    style.configure("TLabel", background=BG, foreground=TEXT)
    style.configure("TPanedwindow", background=BORDER)

    style.configure("TButton", font=("Malgun Gothic", 9), padding=(8, 4),
                    bordercolor="#cbd5e1", borderwidth=1, relief="solid")
    style.map("TButton", background=[("active", "#e2e8f0"), ("!active", CARD_BG)])

    style.configure("Accent.TButton", font=("Malgun Gothic", 9),
                    foreground="#1d4ed8", padding=(8, 4))
    style.map("Accent.TButton",
              background=[("active", "#bfdbfe"), ("!active", "#dbeafe")],
              foreground=[("active", "#1d4ed8"), ("!active", "#1d4ed8")])

    style.configure("Danger.TButton", font=("Malgun Gothic", 9),
                    foreground="#b91c1c", padding=(8, 4))
    style.map("Danger.TButton",
              background=[("active", "#fecaca"), ("!active", "#fee2e2")],
              foreground=[("active", "#b91c1c"), ("!active", "#b91c1c")])

    style.configure("TEntry", padding=4, fieldbackground=CARD_BG)
    style.configure("TLabelframe", background=BG, foreground=TEXT,
                    bordercolor="#cbd5e1", borderwidth=1, relief="solid")
    style.configure("TLabelframe.Label", background=BG, foreground=TEXT,
                    font=("Malgun Gothic", 9, "bold"))

    style.configure("Treeview",
                    background=CARD_BG, foreground=TEXT, fieldbackground=CARD_BG,
                    rowheight=26, font=("Malgun Gothic", 9),
                    bordercolor="#cbd5e1", borderwidth=1, relief="solid")
    style.configure("Treeview.Heading",
                    background=HEADER_BG, foreground=HEADER_FG,
                    font=("Malgun Gothic", 9, "bold"), bordercolor="#cbd5e1",
                    borderwidth=1, relief="solid")
    style.map("Treeview.Heading",
              background=[("active", "#cbd5e1"), ("!active", HEADER_BG)])
    style.map("Treeview",
              background=[("selected", ACCENT)],
              foreground=[("selected", "white")])

    # 스크롤바 스타일
    style.configure("Vertical.TScrollbar",
                    width=10, gripcount=0,
                    background="#94a3b8", troughcolor=BORDER,
                    bordercolor=BORDER, arrowcolor=TEXT_SUB, arrowsize=10)
    style.map("Vertical.TScrollbar",
              background=[("active", "#64748b"), ("!active", "#94a3b8")])

    self._theme = {
        'LOG_BG': "#1e293b", 'LOG_FG': "#e2e8f0",
        'ROW_ALT': ROW_ALT, 'CARD_BG': CARD_BG,
    }

  def _reset_config_on_startup(self):
    changed = False
    for group_data in self.state.config.get('groups', {}).values():
      if group_data.get('monitoring_on'):
        group_data['monitoring_on'] = False
        changed = True
      if group_data.get('call_alert_sent'):
        group_data['call_alert_sent'] = False
        changed = True
      if group_data.get('sms_alert_sent'):
        group_data['sms_alert_sent'] = False
        changed = True
      group_data.setdefault('group_enabled', True)
      for service in group_data.get('services', []):
        if service.get('status') != '대기중':
          service['status'] = '대기중'
          changed = True
        if service.get('alert_sent'):
          service['alert_sent'] = False
          changed = True
    if changed:
      log.info("모니터링 상태를 초기화했습니다.")
      self.state.save_config()

  def _bind_events(self):
    self.group_list.bind("<<TreeviewSelect>>", lambda e: handlers.on_group_select(self, e))
    self.group_list.bind("<Button-1>", lambda e: handlers.on_group_tree_click(self, e))
    self.service_list.bind("<Button-1>", lambda e: handlers.on_tree_click(self, e))

    # 수정 버튼
    self.edit_group_button.config(command=lambda: handlers.edit_selected_group(self))
    self.edit_service_button.config(command=lambda: handlers.edit_selected_service(self))
    self.edit_recipient_button.config(command=lambda: handlers.edit_selected_recipient(self))
    self.edit_call_recipient_button.config(command=lambda: handlers.edit_selected_call_recipient(self))

    self.add_service_button.config(command=lambda: handlers.add_service(self))
    self.delete_service_button.config(command=lambda: handlers.delete_service(self))
    self.add_group_button.config(command=lambda: handlers.add_group(self))
    self.delete_group_button.config(command=lambda: handlers.delete_group(self))
    self.add_recipient_button.config(command=lambda: handlers.add_recipient(self))
    self.delete_recipient_button.config(command=lambda: handlers.delete_recipient(self))
    self.add_call_recipient_button.config(command=lambda: handlers.add_call_recipient(self))
    self.delete_call_recipient_button.config(command=lambda: handlers.delete_call_recipient(self))
    self.move_up_button.config(command=lambda: handlers.move_call_recipient(self, -1))
    self.move_down_button.config(command=lambda: handlers.move_call_recipient(self, 1))
    self.start_all_button.config(command=lambda: handlers.start_all_monitoring(self))
    self.stop_all_button.config(command=lambda: handlers.stop_all_monitoring(self))
    self.start_group_monitor_button.config(command=lambda: handlers.start_selected_group_monitoring(self))
    self.stop_group_monitor_button.config(command=lambda: handlers.stop_selected_group_monitoring(self))
    self.save_settings_button.config(command=lambda: handlers.save_group_settings(self))
    self.heatmap_button.config(command=lambda: self.heatmap.show(self.root))
    self.save_port_button.config(command=self.save_health_check_port)

  # === 이벤트 로그 ===

  def _setup_log_handler(self):
    """logging의 WARNING 이상 메시지를 GUI 이벤트 로그에 표시"""
    import logging
    app = self

    class GUILogHandler(logging.Handler):
      def emit(self, record):
        if record.levelno >= logging.WARNING:
          try:
            tag = "error" if record.levelno >= logging.ERROR else "failure"
            app.root.after(0, app._append_event_log, record.getMessage(), tag)
          except Exception:
            pass

    handler = GUILogHandler()
    handler.setLevel(logging.WARNING)
    log.addHandler(handler)

  def _append_event_log(self, text, tag=None):
    """이벤트 로그에 항목 추가 (장애/에러만)"""
    try:
      self.event_log.config(state=tk.NORMAL)
      timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
      line = f"[{timestamp}] {text}\n"
      self.event_log.insert(tk.END, line, tag or "")
      # 최대 줄 수 제한
      line_count = int(self.event_log.index('end-1c').split('.')[0])
      if line_count > _MAX_EVENT_LOG_LINES:
        self.event_log.delete("1.0", f"{line_count - _MAX_EVENT_LOG_LINES}.0")
      self.event_log.see(tk.END)
      self.event_log.config(state=tk.DISABLED)
    except TclError:
      pass

  # === 서비스 목록 ===

  def update_service_list(self, group_name):
    self.service_list.delete(*self.service_list.get_children())
    self._item_id_map.clear()
    services = self.state.config['groups'].get(group_name, {}).get('services', [])

    for tag, (fg, _) in STATUS_COLORS.items():
      self.service_list.tag_configure(tag, foreground=fg)
    self.service_list.tag_configure("oddrow", background="#f8fafc")

    for i, service in enumerate(services):
      addr = service['address']
      status = self.state.service_statuses.get(addr, "대기중")
      if not service.get('enabled', True):
        status = "비활성화"
      tag = get_status_tag(service, status)
      tags = (tag, "oddrow") if i % 2 else (tag,)
      check_sym = "✔" if service.get('enabled', True) else "✘"
      last_check = self.state.last_check_times.get(addr, "-")
      item_id = self.service_list.insert("", tk.END,
          values=(check_sym, service['name'], addr, status, last_check), tags=tags)
      self._item_id_map[addr] = item_id

  # === 수신자 목록 ===

  def update_recipient_list(self, group_name):
    group_data = self.state.config['groups'].get(group_name, {})
    self.recipient_list.delete(*self.recipient_list.get_children())
    for r in group_data.get('recipients', []):
      if '/' in r:
        name, phone = r.split('/', 1)
        self.recipient_list.insert("", tk.END, values=(name, phone))

    self.call_recipient_list.delete(*self.call_recipient_list.get_children())
    call_recipients = group_data.get('call_recipients', [])
    for priority_idx, priority_group in enumerate(call_recipients, 1):
      if isinstance(priority_group, list):
        for r in priority_group:
          if '/' in r:
            name, phone = r.split('/', 1)
            self.call_recipient_list.insert("", tk.END, values=(priority_idx, name, phone))
      elif isinstance(priority_group, str) and '/' in priority_group:
        # 하위 호환: 단순 문자열
        name, phone = priority_group.split('/', 1)
        self.call_recipient_list.insert("", tk.END, values=(priority_idx, name, phone))

  # === 그룹 목록 ===

  def load_groups(self):
    self.group_list.delete(*self.group_list.get_children())
    self._group_item_map.clear()
    for name, data in self.state.config.get('groups', {}).items():
      enabled = data.get('group_enabled', True)
      check_sym = "✔" if enabled else "✘"
      if not enabled:
        indicator = "—"
      elif data.get('monitoring_on', False):
        indicator = "●"
      else:
        indicator = "○"
      alert_sym = self._get_alert_symbol(data)
      item_id = self.group_list.insert("", tk.END, values=(check_sym, name, alert_sym, indicator))
      self._group_item_map[name] = item_id
    self.group_list.tag_configure("mon_on", foreground="#22854B")
    self.group_list.tag_configure("mon_off", foreground="#333333")
    self.group_list.tag_configure("mon_alert", foreground="#E74C3C")
    self.group_list.tag_configure("disabled", foreground="#BDC3C7")
    self._update_all_group_indicators()

  def _get_alert_symbol(self, group_data):
    """그룹의 알림 발송 상태 심볼 반환"""
    if not group_data.get('monitoring_on', False):
      return ""
    has_sms = any(s.get('alert_sent', False) for s in group_data.get('services', []))
    has_call = group_data.get('call_alert_sent', False)
    if has_call and has_sms:
      return "📞✉"
    if has_call:
      return "📞"
    if has_sms:
      return "✉"
    return ""

  def update_group_indicator(self, group_name):
    item_id = self._group_item_map.get(group_name)
    if not item_id:
      return
    try:
      group_data = self.state.config['groups'][group_name]
      enabled = group_data.get('group_enabled', True)
      check_sym = "✔" if enabled else "✘"
      if not enabled:
        indicator, tag = "—", "disabled"
      elif group_data.get('monitoring_on', False):
        has_offline = any(
            self.state.service_statuses.get(s['address'], '') in ('오프라인',)
            or self.state.service_statuses.get(s['address'], '').startswith('연결 실패')
            for s in group_data.get('services', []) if s.get('enabled', True)
        )
        if has_offline:
          indicator, tag = "▲", "mon_alert"
        else:
          indicator, tag = "●", "mon_on"
      else:
        indicator, tag = "○", "mon_off"
      alert_sym = self._get_alert_symbol(group_data)
      self.group_list.item(item_id, values=(check_sym, group_name, alert_sym, indicator), tags=(tag,))
    except (TclError, KeyError):
      pass

  def _update_all_group_indicators(self):
    for group_name in self.state.config.get('groups', {}):
      self.update_group_indicator(group_name)

  # === 모니터링 컨트롤 ===

  def update_monitoring_controls(self, group_name):
    if group_name and group_name in self.state.config['groups']:
      group_data = self.state.config['groups'][group_name]
      group_enabled = group_data.get('group_enabled', True)
      state = tk.NORMAL if group_enabled else tk.DISABLED
    else:
      state = tk.DISABLED

    for widget in [self.start_group_monitor_button, self.stop_group_monitor_button,
                   self.online_interval_entry, self.max_retries_entry, self.save_settings_button]:
      widget.config(state=state)

  def update_interval_settings(self, group_name):
    group_data = self.state.config['groups'].get(group_name, {})
    self.online_interval_entry.delete(0, tk.END)
    self.online_interval_entry.insert(0, group_data.get('monitoring_interval_online', 30))
    self.max_retries_entry.delete(0, tk.END)
    self.max_retries_entry.insert(0, group_data.get('max_retries', 3))

  def clear_details(self):
    self.service_list.delete(*self.service_list.get_children())
    self._item_id_map.clear()
    self.recipient_list.delete(*self.recipient_list.get_children())
    self.call_recipient_list.delete(*self.call_recipient_list.get_children())
    self.online_interval_entry.delete(0, tk.END)
    self.max_retries_entry.delete(0, tk.END)
    self.update_monitoring_controls(None)

  # === 상태 요약 ===

  def update_status_summary(self):
    groups = self.state.config.get('groups', {})
    enabled_groups = {n: d for n, d in groups.items() if d.get('group_enabled', True)}
    total_groups = len(enabled_groups)
    active_groups = sum(1 for d in enabled_groups.values() if d.get('monitoring_on', False))
    offline = sum(1 for d in enabled_groups.values() for s in d.get('services', [])
                  if s.get('enabled', True) and (self.state.service_statuses.get(s['address']) == '오프라인'
                  or self.state.service_statuses.get(s['address'], '').startswith('연결 실패')))

    summary = f"{active_groups}/{total_groups} 그룹 모니터링 중"
    if offline > 0:
      summary += f"  |  {offline}개 서비스 오프라인"
    self.global_status_label.config(text=summary)

    if offline > 0:
      if not self._alert_title:
        self.root.title(f"[!] {self._original_title}")
        self._alert_title = True
    else:
      if self._alert_title:
        self.root.title(self._original_title)
        self._alert_title = False

  # === 자동 시작 ===

  def autostart_monitoring(self):
    autostart = [n for n, d in self.state.config.get('groups', {}).items()
                 if d.get('monitoring_on', False) and d.get('group_enabled', True)]
    for name in autostart:
      handlers.start_group_monitoring(self, name, autostart=True)

    if autostart:
      for item_id in self.group_list.get_children():
        if self.group_list.item(item_id, 'values')[1] == autostart[0]:
          self.group_list.selection_set(item_id)
          handlers.on_group_select(self, None)
          break
    elif self.group_list.get_children():
      first = self.group_list.get_children()[0]
      self.group_list.selection_set(first)
      handlers.on_group_select(self, None)

    self.update_status_summary()

  # === 상태 업데이트 ===

  def update_service_status(self, service_address, status, message, alert_type=None):
    self.root.after(0, self._update_gui, service_address, status, message, alert_type)

  def _update_gui(self, service_address, status, message, alert_type):
    self.state.service_statuses[service_address] = status
    if status in ("온라인", "오프라인") or status.startswith("연결 실패"):
      self.state.last_check_times[service_address] = datetime.now().strftime("%H:%M:%S")

    # 로그: 장애/복구만 기록
    is_error = status in ("오프라인",)
    is_resolved = alert_type == 'resolved'

    if is_error or is_resolved:
      log.info(message)

    item_id = self._item_id_map.get(service_address)
    if item_id:
      try:
        values = self.service_list.item(item_id)['values']
        if values:
          service_config = next((s for g in self.state.config['groups'].values() for s in g['services'] if s['address'] == service_address), {})
          tag = get_status_tag(service_config, status)
          check_sym = values[0]
          name = values[1]
          last_check = self.state.last_check_times.get(service_address, "-")
          self.service_list.item(item_id, values=(check_sym, name, service_address, status, last_check), tags=(tag,))
      except (IndexError, TclError) as e:
        log.debug("서비스 목록 업데이트 오류: %s", e)

    # 이벤트 로그 + 경고: 장애/복구만
    if status == "오프라인" and alert_type == 'failure':
      try:
        self.root.bell()
      except TclError:
        pass
      svc_name = next((s['name'] for g in self.state.config['groups'].values() for s in g['services'] if s['address'] == service_address), service_address)
      self._append_event_log(f"[장애] {svc_name} ({service_address}) - {message}", "failure")
    elif status == "온라인" and alert_type == 'resolved':
      svc_name = next((s['name'] for g in self.state.config['groups'].values() for s in g['services'] if s['address'] == service_address), service_address)
      self._append_event_log(f"[복구] {svc_name} ({service_address}) 온라인 복구", "resolved")

    self.update_status_summary()
    self._update_all_group_indicators()
    self.heatmap.notify_status_change()
    dispatch_alert(self, service_address, alert_type)

  # === 히트맵 위임 ===

  def show_heatmap_status(self):
    self.heatmap.show(self.root)

  def rebuild_heatmap_widgets(self):
    self.heatmap.rebuild()

  # === 종료 ===

  def on_closing(self):
    if not messagebox.askyesno("종료", "프로그램을 종료하시겠습니까?"):
      return

    if self.state.heatmap_window and self.state.heatmap_window.winfo_exists():
      self.state.heatmap_window.destroy()

    if self.health_check_server:
      log.info("헬스 체크 서버 종료")
      try:
        self.health_check_server.shutdown()
        self.health_check_server.server_close()
      except Exception as e:
        log.error("헬스 체크 서버 종료 오류: %s", e)

    self.state.clear_all_states()
    self.root.destroy()

  # === 헬스 체크 서버 ===

  def _start_health_check_server(self):
    try:
      port = int(self.state.config.get('health_check_port', 9999))
    except (ValueError, TypeError):
      port = 9999

    class Handler(socketserver.BaseRequestHandler):
      def handle(self):
        self.request.sendall(b"MonitoringApp is running OK\n")

    def run():
      if self.health_check_server:
        try:
          self.health_check_server.shutdown()
          self.health_check_server.server_close()
        except Exception as e:
          log.error("기존 헬스 체크 서버 종료 오류: %s", e)

      try:
        self.health_check_server = socketserver.ThreadingTCPServer(("0.0.0.0", port), Handler)
        log.info("헬스 체크 서버 시작: 포트 %d", port)
        self.health_check_server.serve_forever()
      except Exception as e:
        log.error("헬스 체크 서버 시작 실패 (포트: %d): %s", port, e)
        self.root.after(0, lambda: messagebox.showerror("서버 오류", f"헬스 체크 서버 시작 실패 (포트: {port})\n{e}"))

    threading.Thread(target=run, daemon=True).start()

  def save_health_check_port(self):
    try:
      new_port = int(self.health_check_port_entry.get())
      if not (1 <= new_port <= 65535):
        raise ValueError("포트 범위 오류")

      start = int(self.call_start_entry.get())
      end = int(self.call_end_entry.get())
      if not (0 <= start <= 23 and 0 <= end <= 23):
        raise ValueError("시간은 0~23 사이여야 합니다")

      self.state.config['call_time'] = {'start': start, 'end': end}

      current = int(self.state.config.get('health_check_port', 9999))
      port_changed = new_port != current

      if port_changed:
        self.state.config['health_check_port'] = new_port

      self.state.save_config()

      if port_changed:
        messagebox.showinfo("저장 완료", f"설정이 저장되었습니다. 헬스 체크 포트: {new_port}")
        self._start_health_check_server()
      else:
        messagebox.showinfo("저장 완료", "설정이 저장되었습니다.")
    except ValueError as e:
      messagebox.showerror("입력 오류", f"유효한 값을 입력하세요.\n{e}")
