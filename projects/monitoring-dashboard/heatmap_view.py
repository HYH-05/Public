# ! 히트맵 뷰 모듈

import tkinter as tk
from tkinter import ttk
from logger import get_logger

log = get_logger()

# === 테마 상수 ===
_BG = "#f5f6fa"
_CARD_BG = "#ffffff"
_BORDER = "#e2e8f0"
_TEXT = "#1e293b"
_TEXT_SUB = "#64748b"
_ACCENT = "#3b82f6"

STATUS_COLORS = {
    'online': ("#22854B", "#2ECC71"),
    'offline': ("#E74C3C", "#E74C3C"),
    'checking': ("#F39C12", "#F39C12"),
    'disabled': ("#BDC3C7", "#BDC3C7"),
    'other': ("#333333", "#333333")
}

_CELL_THEME = {
    'online':   {"bg": "#dcfce7", "fg": "#166534", "bd": "#86efac", "icon": "●"},
    'offline':  {"bg": "#fee2e2", "fg": "#991b1b", "bd": "#fca5a5", "icon": "✖"},
    'checking': {"bg": "#fef9c3", "fg": "#854d0e", "bd": "#fde047", "icon": "↻"},
    'disabled': {"bg": "#f1f5f9", "fg": "#94a3b8", "bd": "#e2e8f0", "icon": "—"},
    'other':    {"bg": "#f1f5f9", "fg": "#475569", "bd": "#cbd5e1", "icon": "?"},
}

# 요약 대시보드 색상
_DASH_THEME = {
    'online':   {"bg": "#dcfce7", "fg": "#166534", "icon": "●", "label": "온라인"},
    'offline':  {"bg": "#fee2e2", "fg": "#991b1b", "icon": "✖", "label": "오프라인"},
    'checking': {"bg": "#fef9c3", "fg": "#854d0e", "icon": "↻", "label": "확인 중"},
    'disabled': {"bg": "#f1f5f9", "fg": "#94a3b8", "icon": "—", "label": "비활성"},
    'other':    {"bg": "#f1f5f9", "fg": "#475569", "icon": "?", "label": "대기"},
}

_GROUP_HEADER_NORMAL = "#e2e8f0"
_GROUP_HEADER_ALERT = "#fecaca"
_TOOLTIP_BG = "#1e293b"
_TOOLTIP_FG = "#e2e8f0"
_TOOLTIP_BORDER = "#334155"


class Tooltip:
  """모던 스타일 툴팁"""
  def __init__(self, widget, get_text):
    self.widget = widget
    self.get_text = get_text
    self.tooltip_window = None
    widget.bind("<Enter>", self.show)
    widget.bind("<Leave>", self.hide)
    widget.bind("<Destroy>", self._on_destroy)

  def show(self, event):
    self.hide(None)
    try:
      x = self.widget.winfo_rootx() + 20
      y = self.widget.winfo_rooty() + self.widget.winfo_height() + 4
    except tk.TclError:
      return
    self.tooltip_window = tw = tk.Toplevel(self.widget)
    tw.wm_overrideredirect(True)
    tw.wm_geometry(f"+{x}+{y}")
    tw.configure(bg=_TOOLTIP_BORDER)
    inner = tk.Frame(tw, bg=_TOOLTIP_BG, padx=8, pady=6)
    inner.pack(padx=1, pady=1)
    tk.Label(inner, text=self.get_text(), background=_TOOLTIP_BG,
             foreground=_TOOLTIP_FG, font=("Malgun Gothic", 8),
             justify=tk.LEFT).pack()

  def hide(self, event):
    if self.tooltip_window:
      try:
        self.tooltip_window.destroy()
      except tk.TclError:
        pass
      self.tooltip_window = None

  def _on_destroy(self, event):
    self.hide(None)


def get_status_tag(service, status):
  if not service.get('enabled', True):
    return 'disabled'
  if status == "온라인":
    return 'online'
  if status == "오프라인" or status.startswith("연결 실패"):
    return 'offline'
  if status == "확인 중...":
    return 'checking'
  return 'other'


def _group_stats(state, group_data):
  services = [s for s in group_data.get('services', []) if s.get('enabled', True)]
  total = len(services)
  offline = sum(1 for s in services
                if state.service_statuses.get(s['address'], '대기중') in ('오프라인',)
                or state.service_statuses.get(s['address'], '').startswith('연결 실패'))
  online = sum(1 for s in services
               if state.service_statuses.get(s['address']) == '온라인')
  return online, offline, total


def _total_stats(state):
  """전체 서비스 상태별 카운트"""
  counts = {'online': 0, 'offline': 0, 'checking': 0, 'disabled': 0, 'other': 0}
  total = 0
  for group_data in state.config.get('groups', {}).values():
    for s in group_data.get('services', []):
      status = state.service_statuses.get(s['address'], '대기중')
      tag = get_status_tag(s, status)
      counts[tag] = counts.get(tag, 0) + 1
      total += 1
  return counts, total


def _group_summary(state, group_name, group_data):
  online, offline, total = _group_stats(state, group_data)
  if total == 0:
    return f"{group_name}  (서비스 없음)"
  if offline > 0:
    return f"{group_name}    {offline}/{total} 오프라인"
  if online == total:
    return f"{group_name}    {total}/{total} 온라인"
  return f"{group_name}    {online}/{total} 온라인"


def _build_addr_map(config):
  m = {}
  for group_data in config.get('groups', {}).values():
    for s in group_data.get('services', []):
      m[s['address']] = s
  return m


def _sorted_groups(state):
  groups = list(state.config.get('groups', {}).items())
  def sort_key(item):
    _, data = item
    _, offline, _ = _group_stats(state, data)
    return (0 if offline > 0 else 1, item[0])
  return sorted(groups, key=sort_key)


class HeatmapView:
  """히트맵 창 관리 클래스"""

  def __init__(self, state):
    self.state = state
    self._rearrange_timer = None
    self._canvas = None
    self._canvas_window = None
    self._prev_tags = {}
    self._addr_map = {}
    self._tooltips = []
    self._collapsed = set()
    self._filter_var = None
    self._show_disabled_var = None
    self._update_scheduled = False
    self._status_filter = None     # 대시보드 상태 필터 (None=전체)
    self._group_frames = {}
    self._group_headers = {}
    self._group_badge_labels = {}
    self._group_arrow_labels = {}
    self._group_name_labels = {}
    self._group_cell_frames = {}
    # 대시보드 위젯 참조
    self._dash_frame = None
    self._dash_labels = {}         # tag → (count_label, frame)
    self._dash_total_label = None
    self._collapse_all_btn = None

  def show(self, root):
    if self.state.heatmap_window and self.state.heatmap_window.winfo_exists():
      self.state.heatmap_window.lift()
      self.rebuild()
      return

    self._prev_tags.clear()
    self._collapsed.clear()
    self._tooltips.clear()
    self._status_filter = None

    win = tk.Toplevel(root)
    self.state.heatmap_window = win
    win.title("전체 서비스 상태")
    win.geometry("1050x650")
    win.configure(bg=_BG)
    win.protocol("WM_DELETE_WINDOW", self._on_close)

    # === 상단 바 ===
    top_bar = tk.Frame(win, bg=_CARD_BG, padx=12, pady=8)
    top_bar.pack(fill=tk.X)

    tk.Label(top_bar, text="📊  전체 서비스 히트맵", font=("Malgun Gothic", 11, "bold"),
             bg=_CARD_BG, fg=_TEXT).pack(side=tk.LEFT)

    # 우측 컨트롤
    ctrl = tk.Frame(top_bar, bg=_CARD_BG)
    ctrl.pack(side=tk.RIGHT)

    self._collapse_all_btn = tk.Label(
        ctrl, text="▶ 전체 접기", font=("Malgun Gothic", 8),
        bg="#e2e8f0", fg=_TEXT_SUB, padx=8, pady=2, cursor="hand2")
    self._collapse_all_btn.pack(side=tk.RIGHT, padx=(8, 0))
    self._collapse_all_btn.bind("<Button-1>", lambda e: self._toggle_collapse_all())

    self._show_disabled_var = tk.BooleanVar(value=True)
    cb = tk.Checkbutton(ctrl, text="비활성 그룹", variable=self._show_disabled_var,
                        command=self._on_filter_change, bg=_CARD_BG, fg=_TEXT_SUB,
                        activebackground=_CARD_BG, selectcolor=_CARD_BG,
                        font=("Malgun Gothic", 8))
    cb.pack(side=tk.RIGHT, padx=(8, 0))

    self._filter_var = tk.StringVar()
    self._filter_var.trace_add("write", lambda *_: self._on_filter_change())
    search_frame = tk.Frame(ctrl, bg=_BORDER, padx=1, pady=1)
    search_frame.pack(side=tk.RIGHT)
    search_inner = tk.Frame(search_frame, bg=_CARD_BG)
    search_inner.pack()
    tk.Label(search_inner, text="🔍", bg=_CARD_BG, fg=_TEXT_SUB,
             font=("Malgun Gothic", 9)).pack(side=tk.LEFT, padx=(6, 0))
    tk.Entry(search_inner, textvariable=self._filter_var, width=18,
             font=("Malgun Gothic", 9), bg=_CARD_BG, fg=_TEXT,
             relief=tk.FLAT, insertbackground=_TEXT).pack(side=tk.LEFT, padx=(2, 6), pady=3)

    tk.Frame(win, bg=_BORDER, height=1).pack(fill=tk.X)

    # === 요약 대시보드 ===
    self._dash_frame = tk.Frame(win, bg=_CARD_BG, padx=12, pady=8)
    self._dash_frame.pack(fill=tk.X, padx=12, pady=(8, 0))
    self._build_dashboard()

    tk.Frame(win, bg=_BORDER, height=1).pack(fill=tk.X, padx=12)

    # === 스크롤 영역 ===
    self._canvas = tk.Canvas(win, bg=_BG, highlightthickness=0)
    scrollbar = ttk.Scrollbar(win, orient="vertical", command=self._canvas.yview)
    self.state.heatmap_scrollable_frame = tk.Frame(self._canvas, bg=_BG)
    self.state.heatmap_scrollable_frame.bind(
        "<Configure>", lambda e: self._canvas.configure(scrollregion=self._canvas.bbox("all")))
    self._canvas_window = self._canvas.create_window((0, 0), window=self.state.heatmap_scrollable_frame, anchor="nw")
    self._canvas.configure(yscrollcommand=scrollbar.set)
    self._canvas.bind("<Configure>", self._on_canvas_configure)
    self._canvas.pack(side="left", fill="both", expand=True)
    scrollbar.pack(side="right", fill="y")

    win.bind("<MouseWheel>", self._on_mousewheel)
    win.bind("<Button-4>", self._on_mousewheel)
    win.bind("<Button-5>", self._on_mousewheel)

    self._create_widgets()
    self._rearrange_widgets()
    self._schedule_update()

  # === 대시보드 ===

  def _build_dashboard(self):
    for widget in self._dash_frame.winfo_children():
      widget.destroy()
    self._dash_labels.clear()

    counts, total = _total_stats(self.state)

    # 전체 카운트
    total_f = tk.Frame(self._dash_frame, bg=_CARD_BG, padx=4)
    total_f.pack(side=tk.LEFT, padx=(0, 12))
    self._dash_total_label = tk.Label(
        total_f, text=f"전체  {total}", font=("Malgun Gothic", 10, "bold"),
        bg=_CARD_BG, fg=_TEXT)
    self._dash_total_label.pack()

    # 상태별 카드
    for tag in ('online', 'offline', 'checking', 'other', 'disabled'):
      dt = _DASH_THEME[tag]
      count = counts.get(tag, 0)
      is_active = self._status_filter == tag

      outer_bg = dt['bg'] if is_active else _CARD_BG
      bd_color = dt['fg'] if is_active else _BORDER

      f = tk.Frame(self._dash_frame, bg=outer_bg, padx=10, pady=4,
                   highlightbackground=bd_color, highlightthickness=1, cursor="hand2")
      f.pack(side=tk.LEFT, padx=3)

      lbl = tk.Label(f, text=f"{dt['icon']}  {dt['label']}  {count}",
                     font=("Malgun Gothic", 9, "bold" if is_active else ""),
                     bg=outer_bg, fg=dt['fg'])
      lbl.pack()

      self._dash_labels[tag] = (lbl, f)

      # 클릭 → 상태 필터 토글
      for w in (f, lbl):
        w.bind("<Button-1>", lambda e, t=tag: self._toggle_status_filter(t))

  def _update_dashboard(self):
    counts, total = _total_stats(self.state)
    if self._dash_total_label:
      try:
        self._dash_total_label.config(text=f"전체  {total}")
      except tk.TclError:
        return

    for tag, (lbl, f) in self._dash_labels.items():
      dt = _DASH_THEME[tag]
      count = counts.get(tag, 0)
      is_active = self._status_filter == tag
      outer_bg = dt['bg'] if is_active else _CARD_BG
      bd_color = dt['fg'] if is_active else _BORDER
      try:
        f.config(bg=outer_bg, highlightbackground=bd_color)
        lbl.config(text=f"{dt['icon']}  {dt['label']}  {count}",
                   bg=outer_bg,
                   font=("Malgun Gothic", 9, "bold" if is_active else ""))
      except tk.TclError:
        pass

  def _toggle_status_filter(self, tag):
    if self._status_filter == tag:
      self._status_filter = None
    else:
      self._status_filter = tag
    self._update_dashboard()
    self._rebuild_internal()

  # === 창 관리 ===

  def _on_close(self):
    self._cleanup_tooltips()
    self.state.heatmap_cells.clear()
    self.state.heatmap_group_labels.clear()
    self._prev_tags.clear()
    self._addr_map.clear()
    self._group_frames.clear()
    self._group_headers.clear()
    self._group_badge_labels.clear()
    self._group_arrow_labels.clear()
    self._group_name_labels.clear()
    self._group_cell_frames.clear()
    self._dash_labels.clear()
    if self.state.heatmap_window:
      try:
        self.state.heatmap_window.destroy()
      except tk.TclError:
        pass
    self.state.heatmap_window = None
    self.state.heatmap_scrollable_frame = None
    self._canvas = None
    self._canvas_window = None

  def _cleanup_tooltips(self):
    for tt in self._tooltips:
      tt.hide(None)
    self._tooltips.clear()

  def _on_mousewheel(self, event):
    if not self._canvas:
      return
    if event.num == 4:
      self._canvas.yview_scroll(-3, "units")
    elif event.num == 5:
      self._canvas.yview_scroll(3, "units")
    elif event.delta:
      self._canvas.yview_scroll(int(-1 * (event.delta / 120)), "units")

  def _on_canvas_configure(self, event):
    """Canvas 리사이즈 시 내부 프레임 너비를 Canvas에 맞추고 셀 재배치"""
    if not self._canvas or not self.state.heatmap_scrollable_frame:
      return
    new_width = event.width
    self._canvas.itemconfig(self._canvas_window, width=new_width)
    # 셀 재배치도 여기서 통합 처리 (디바운스)
    if self._rearrange_timer is not None:
      try:
        self.state.heatmap_window.after_cancel(self._rearrange_timer)
      except Exception:
        pass
      self._rearrange_timer = None
    try:
      self._rearrange_timer = self.state.heatmap_window.after(100, self._rearrange_widgets)
    except Exception:
      self._rearrange_timer = None

  def _on_configure(self, event=None):
    if self._rearrange_timer is not None:
      try:
        self.state.heatmap_window.after_cancel(self._rearrange_timer)
      except Exception:
        pass
      self._rearrange_timer = None
    try:
      self._rearrange_timer = self.state.heatmap_window.after(100, self._rearrange_widgets)
    except Exception:
      self._rearrange_timer = None

  def _on_filter_change(self):
    self._rebuild_internal()

  def _toggle_group(self, group_name):
    if group_name in self._collapsed:
      self._collapsed.discard(group_name)
    else:
      self._collapsed.add(group_name)
    self._rebuild_internal()

  def _toggle_collapse_all(self):
    all_groups = set(self.state.config.get('groups', {}).keys())
    if self._collapsed >= all_groups and all_groups:
      self._collapsed.clear()
      if self._collapse_all_btn:
        self._collapse_all_btn.config(text="▶ 전체 접기", bg="#e2e8f0", fg=_TEXT_SUB)
    else:
      self._collapsed = set(all_groups)
      if self._collapse_all_btn:
        self._collapse_all_btn.config(text="▼ 전체 펼치기", bg="#dbeafe", fg="#1d4ed8")
    self._rebuild_internal()

  def _rebuild_internal(self):
    if not self.state.heatmap_scrollable_frame:
      return
    try:
      if not self.state.heatmap_window.winfo_exists():
        return
    except Exception:
      return
    self._cleanup_tooltips()
    for widget in self.state.heatmap_scrollable_frame.winfo_children():
      widget.destroy()
    self._prev_tags.clear()
    self._group_frames.clear()
    self._group_headers.clear()
    self._group_badge_labels.clear()
    self._group_arrow_labels.clear()
    self._group_name_labels.clear()
    self._group_cell_frames.clear()
    self._create_widgets()
    self._rearrange_widgets()
    self._do_update()

  def _get_filtered_groups(self):
    keyword = self._filter_var.get().strip().lower() if self._filter_var else ""
    show_disabled = self._show_disabled_var.get() if self._show_disabled_var else True
    result = []
    for group_name, group_data in _sorted_groups(self.state):
      if not show_disabled and not group_data.get('group_enabled', True):
        continue
      if keyword:
        name_match = keyword in group_name.lower()
        svc_match = any(keyword in s.get('name', '').lower() or keyword in s.get('address', '').lower()
                        for s in group_data.get('services', []))
        if not name_match and not svc_match:
          continue
      result.append((group_name, group_data))
    return result

  def _service_passes_filter(self, service, group_name):
    """키워드 + 상태 필터 통과 여부"""
    keyword = self._filter_var.get().strip().lower() if self._filter_var else ""
    if keyword:
      if (keyword not in group_name.lower()
          and keyword not in service.get('name', '').lower()
          and keyword not in service.get('address', '').lower()):
        return False
    if self._status_filter:
      status = self.state.service_statuses.get(service['address'], '대기중')
      tag = get_status_tag(service, status)
      if tag != self._status_filter:
        return False
    return True

  # === 위젯 생성 ===

  def _create_widgets(self):
    self.state.heatmap_cells.clear()
    self.state.heatmap_group_labels.clear()
    self._addr_map = _build_addr_map(self.state.config)
    container = self.state.heatmap_scrollable_frame

    for group_name, group_data in self._get_filtered_groups():
      services = group_data.get('services', [])
      if not services:
        continue

      # 상태 필터 적용 시 해당 그룹에 매칭 서비스가 없으면 스킵
      visible = [s for s in services if self._service_passes_filter(s, group_name)]
      if not visible and self._status_filter:
        continue

      collapsed = group_name in self._collapsed
      _, offline, total = _group_stats(self.state, group_data)
      has_alert = offline > 0

      # 그룹 카드
      card = tk.Frame(container, bg=_CARD_BG,
                      highlightbackground=_BORDER, highlightthickness=1)
      self._group_frames[group_name] = card

      # 그룹 헤더
      header_bg = _GROUP_HEADER_ALERT if has_alert else _GROUP_HEADER_NORMAL
      header = tk.Frame(card, bg=header_bg, padx=10, pady=5, cursor="hand2")
      header.pack(fill=tk.X)
      header.bind("<Button-1>", lambda e, gn=group_name: self._toggle_group(gn))
      self._group_headers[group_name] = header

      arrow_lbl = tk.Label(header, text="▶" if collapsed else "▼",
                           font=("Malgun Gothic", 8), bg=header_bg, fg=_TEXT_SUB)
      arrow_lbl.pack(side=tk.LEFT, padx=(0, 6))
      arrow_lbl.bind("<Button-1>", lambda e, gn=group_name: self._toggle_group(gn))
      self._group_arrow_labels[group_name] = arrow_lbl

      name_lbl = tk.Label(header, text=group_name, font=("Malgun Gothic", 9, "bold"),
                          bg=header_bg, fg=_TEXT)
      name_lbl.pack(side=tk.LEFT)
      name_lbl.bind("<Button-1>", lambda e, gn=group_name: self._toggle_group(gn))
      self._group_name_labels[group_name] = name_lbl

      summary = _group_summary(self.state, group_name, group_data)
      badge_text = summary.split("    ")[-1] if "    " in summary else ""
      if badge_text:
        badge_bg = "#fecaca" if has_alert else "#dcfce7"
        badge_fg = "#991b1b" if has_alert else "#166534"
        badge = tk.Label(header, text=f" {badge_text} ", font=("Malgun Gothic", 8),
                         bg=badge_bg, fg=badge_fg, padx=6, pady=1)
        badge.pack(side=tk.LEFT, padx=(8, 0))
        badge.bind("<Button-1>", lambda e, gn=group_name: self._toggle_group(gn))
        self._group_badge_labels[group_name] = badge

      self.state.heatmap_group_labels[group_name] = header

      if collapsed:
        continue

      # 셀 컨테이너
      cell_frame = tk.Frame(card, bg=_CARD_BG, padx=4, pady=4)
      cell_frame.pack(fill=tk.X)
      self._group_cell_frames[group_name] = cell_frame

      for service in visible:
        addr = service['address']
        status = self.state.service_statuses.get(addr, "대기중")
        tag = get_status_tag(service, status)
        theme = _CELL_THEME.get(tag, _CELL_THEME['other'])

        cell = tk.Frame(cell_frame, bg=theme['bg'],
                        highlightbackground=theme['bd'], highlightthickness=1)
        lbl = tk.Label(cell, text=f"{theme['icon']} {service['name']}",
                       font=("Malgun Gothic", 7, "bold"), bg=theme['bg'], fg=theme['fg'],
                       padx=6, pady=3, anchor="center")
        lbl.pack(fill=tk.BOTH, expand=True)

        self.state.heatmap_cells[addr] = cell

        def make_tooltip_fn(svc=service, gn=group_name, a=addr):
          def fn():
            st = self.state.service_statuses.get(a, "대기중")
            last = self.state.last_check_times.get(a, "-")
            return f"[{gn}] {svc['name']}\n{a}\n상태: {st}\n마지막 확인: {last}"
          return fn

        tt = Tooltip(cell, make_tooltip_fn())
        self._tooltips.append(tt)
        for child in cell.winfo_children():
          child.bind("<Enter>", lambda e, c=cell: c.event_generate("<Enter>"))
          child.bind("<Leave>", lambda e, c=cell: c.event_generate("<Leave>"))

  # === 위젯 배치 ===

  def _rearrange_widgets(self, event=None):
    if not self.state.heatmap_scrollable_frame or not self.state.heatmap_window:
      return
    try:
      if not self.state.heatmap_window.winfo_exists():
        return
    except Exception:
      return

    # 전체 서비스 이름 중 가장 긴 텍스트 기준으로 셀 너비 계산
    import tkinter.font as tkFont
    cell_font = tkFont.Font(family="Malgun Gothic", size=7, weight="bold")
    max_text_w = 0
    for group_data in self.state.config.get('groups', {}).values():
      for service in group_data.get('services', []):
        text_w = cell_font.measure(f"● {service['name']}")
        if text_w > max_text_w:
          max_text_w = text_w
    cell_w = max(120, max_text_w + 20)  # 좌우 padx(6+6) + 여유
    canvas_w = self._canvas.winfo_width() if self._canvas else self.state.heatmap_window.winfo_width()
    content_w = max(400, canvas_w - 30)
    max_cols = max(1, content_w // cell_w)

    pack_idx = 0
    for group_name in list(self._group_frames.keys()):
      card = self._group_frames[group_name]
      card.pack(fill=tk.X, padx=12, pady=(8 if pack_idx == 0 else 4, 4))
      pack_idx += 1

      if group_name in self._collapsed:
        continue

      cell_frame = self._group_cell_frames.get(group_name)
      if not cell_frame:
        continue

      group_data = self.state.config.get('groups', {}).get(group_name)
      if not group_data:
        continue

      for c in range(max_cols):
        cell_frame.columnconfigure(c, weight=1, uniform="cell", minsize=cell_w)
      # 이전에 설정된 초과 컬럼의 weight 리셋
      for c in range(max_cols, max_cols + 50):
        cell_frame.columnconfigure(c, weight=0, uniform="", minsize=0)

      row, col = 0, 0
      for service in group_data.get('services', []):
        if not self._service_passes_filter(service, group_name):
          continue
        addr = service['address']
        if addr in self.state.heatmap_cells:
          self.state.heatmap_cells[addr].grid(row=row, column=col,
                                               padx=2, pady=2, sticky="nsew")
          col += 1
          if col >= max_cols:
            col = 0
            row += 1

  # === 주기적 갱신 ===

  def _schedule_update(self):
    try:
      if not self.state.heatmap_window or not self.state.heatmap_window.winfo_exists():
        return
      self.state.heatmap_window.after(5000, self._schedule_update)
    except (tk.TclError, RuntimeError, AttributeError):
      return
    self._do_update()

  def _do_update(self):
    try:
      if not self.state.heatmap_window or not self.state.heatmap_window.winfo_exists():
        return

      for addr, cell in self.state.heatmap_cells.items():
        status = self.state.service_statuses.get(addr, "대기중")
        service = self._addr_map.get(addr)
        if service and service.get('enabled', True):
          tag = get_status_tag(service, status)
        else:
          tag = 'disabled'

        if self._prev_tags.get(addr) == tag:
          continue
        self._prev_tags[addr] = tag

        theme = _CELL_THEME.get(tag, _CELL_THEME['other'])
        name = service['name'] if service else addr

        cell.config(bg=theme['bg'], highlightbackground=theme['bd'])
        for child in cell.winfo_children():
          if isinstance(child, tk.Label):
            child.config(bg=theme['bg'], fg=theme['fg'],
                         text=f"{theme['icon']} {name}")

      # 그룹 헤더 갱신
      for group_name in list(self.state.heatmap_group_labels.keys()):
        group_data = self.state.config.get('groups', {}).get(group_name, {})
        _, offline, _ = _group_stats(self.state, group_data)
        has_alert = offline > 0
        collapsed = group_name in self._collapsed
        header_bg = _GROUP_HEADER_ALERT if has_alert else _GROUP_HEADER_NORMAL

        header = self._group_headers.get(group_name)
        if header:
          header.config(bg=header_bg)
        arrow = self._group_arrow_labels.get(group_name)
        if arrow:
          arrow.config(bg=header_bg, text="▶" if collapsed else "▼")
        name_lbl = self._group_name_labels.get(group_name)
        if name_lbl:
          name_lbl.config(bg=header_bg)
        badge = self._group_badge_labels.get(group_name)
        if badge:
          summary = _group_summary(self.state, group_name, group_data)
          badge_text = summary.split("    ")[-1] if "    " in summary else ""
          badge.config(text=f" {badge_text} ",
                       bg="#fecaca" if has_alert else "#dcfce7",
                       fg="#991b1b" if has_alert else "#166534")

      # 대시보드 갱신
      self._update_dashboard()

    except (tk.TclError, RuntimeError) as e:
      log.debug("히트맵 업데이트 중 오류 (창 닫힘): %s", e)

  def notify_status_change(self):
    try:
      if not self.state.heatmap_window or not self.state.heatmap_window.winfo_exists():
        return
      if not self._update_scheduled:
        self._update_scheduled = True
        self.state.heatmap_window.after_idle(self._deferred_update)
    except (tk.TclError, RuntimeError):
      pass

  def _deferred_update(self):
    self._update_scheduled = False
    self._do_update()

  def rebuild(self):
    if self.state.heatmap_window and self.state.heatmap_window.winfo_exists():
      self._rebuild_internal()
