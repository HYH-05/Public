# ! GUI 위젯 생성 모듈

import tkinter as tk
from tkinter import ttk


def create_widgets(app):
  """모든 GUI 위젯을 생성합니다."""
  main_frame = ttk.Frame(app.root, padding="10")
  main_frame.pack(fill=tk.BOTH, expand=True)

  # === 상단 컨트롤 (1행: 버튼) ===
  top_frame = ttk.Frame(main_frame)
  top_frame.pack(fill=tk.X, pady=(5, 10))

  app.start_all_button = ttk.Button(top_frame, text="전체 모니터링 시작", style="Accent.TButton")
  app.start_all_button.pack(side=tk.LEFT, padx=5)
  app.stop_all_button = ttk.Button(top_frame, text="전체 모니터링 중지", style="Danger.TButton")
  app.stop_all_button.pack(side=tk.LEFT, padx=5)
  app.heatmap_button = ttk.Button(top_frame, text="전체 보기")
  app.heatmap_button.pack(side=tk.LEFT, padx=5)

  app.global_status_label = ttk.Label(top_frame, text="", font=("Malgun Gothic", 8))
  app.global_status_label.pack(side=tk.LEFT, padx=15)

  # 상단 우측: 헬스 체크
  app.save_port_button = ttk.Button(top_frame, text="저장")
  app.save_port_button.pack(side=tk.RIGHT, padx=(5, 0))
  app.health_check_port_entry = ttk.Entry(top_frame, width=6)
  app.health_check_port_entry.pack(side=tk.RIGHT)
  app.health_check_port_entry.insert(0, app.state.config.get('health_check_port', 9999))
  ttk.Label(top_frame, text="헬스 체크:").pack(side=tk.RIGHT, padx=(10, 2))

  # 상단 우측: 전화 차단
  call_time = app.state.config.get('call_time', {'start': 8, 'end': 20})
  ttk.Label(top_frame, text="시").pack(side=tk.RIGHT, padx=(0, 0))
  app.call_end_entry = ttk.Entry(top_frame, width=3)
  app.call_end_entry.pack(side=tk.RIGHT)
  app.call_end_entry.insert(0, call_time.get('end', 8))
  ttk.Label(top_frame, text="~").pack(side=tk.RIGHT, padx=2)
  app.call_start_entry = ttk.Entry(top_frame, width=3)
  app.call_start_entry.pack(side=tk.RIGHT)
  app.call_start_entry.insert(0, call_time.get('start', 20))
  ttk.Label(top_frame, text="전화 차단:").pack(side=tk.RIGHT, padx=(10, 2))

  # === 상단 컨트롤 (2행: 설정) — 상단 우측으로 이동됨 ===

  # === 메인 패널 ===
  paned = ttk.PanedWindow(main_frame, orient=tk.HORIZONTAL)
  paned.pack(fill=tk.BOTH, expand=True)

  # --- 그룹 패널 (Treeview) ---
  group_frame = ttk.LabelFrame(paned, text="그룹", padding="10")
  paned.add(group_frame, weight=1)
  btn_frame = ttk.Frame(group_frame)
  btn_frame.pack(fill=tk.X, pady=3)
  app.add_group_button = ttk.Button(btn_frame, text="추가", style="Accent.TButton")
  app.add_group_button.pack(side=tk.LEFT)
  app.delete_group_button = ttk.Button(btn_frame, text="삭제", style="Danger.TButton")
  app.delete_group_button.pack(side=tk.LEFT, padx=3)
  app.edit_group_button = ttk.Button(btn_frame, text="수정")
  app.edit_group_button.pack(side=tk.LEFT, padx=3)

  group_tree_frame = ttk.Frame(group_frame)
  group_tree_frame.pack(fill=tk.BOTH, expand=True)
  app.group_list = ttk.Treeview(group_tree_frame, columns=("enabled", "name", "alert", "status"), show="headings", selectmode="browse")
  app.group_list.heading("enabled", text="✔", anchor='center')
  app.group_list.heading("name", text="그룹 이름", anchor='center')
  app.group_list.heading("alert", text="알림", anchor='center')
  app.group_list.heading("status", text="상태", anchor='center')
  app.group_list.column("enabled", width=35, stretch=False, anchor='center')
  app.group_list.column("name", width=100, stretch=True, anchor='center')
  app.group_list.column("alert", width=40, stretch=False, anchor='center')
  app.group_list.column("status", width=45, stretch=False, anchor='center')
  app.group_list.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
  group_scroll = ttk.Scrollbar(group_tree_frame, orient="vertical", command=app.group_list.yview)
  app.group_list.configure(yscrollcommand=group_scroll.set)
  group_scroll.pack(side=tk.RIGHT, fill=tk.Y)

  # --- 서비스 패널 ---
  service_frame = ttk.LabelFrame(paned, text="서비스", padding="10")
  paned.add(service_frame, weight=3)
  svc_btn_frame = ttk.Frame(service_frame)
  svc_btn_frame.pack(fill=tk.X, pady=3)
  app.add_service_button = ttk.Button(svc_btn_frame, text="추가", style="Accent.TButton")
  app.add_service_button.pack(side=tk.LEFT)
  app.delete_service_button = ttk.Button(svc_btn_frame, text="삭제", style="Danger.TButton")
  app.delete_service_button.pack(side=tk.LEFT, padx=3)
  app.edit_service_button = ttk.Button(svc_btn_frame, text="수정")
  app.edit_service_button.pack(side=tk.LEFT, padx=3)
  app.stop_group_monitor_button = ttk.Button(svc_btn_frame, text="그룹 모니터링 중지", style="Danger.TButton")
  app.stop_group_monitor_button.pack(side=tk.RIGHT)
  app.start_group_monitor_button = ttk.Button(svc_btn_frame, text="그룹 모니터링 시작", style="Accent.TButton")
  app.start_group_monitor_button.pack(side=tk.RIGHT, padx=3)

  svc_tree_frame = ttk.Frame(service_frame)
  svc_tree_frame.pack(fill=tk.BOTH, expand=True)
  app.service_list = ttk.Treeview(svc_tree_frame, columns=("enabled", "name", "address", "status", "last_check"), show="headings")
  for col, text, width, stretch in [
      ("enabled", "✔", 35, False),
      ("name", "서비스 이름", 150, True),
      ("address", "주소 (IP:Port)", 140, True),
      ("status", "상태", 90, False),
      ("last_check", "마지막 확인", 90, False)
  ]:
    app.service_list.heading(col, text=text, anchor='center')
    app.service_list.column(col, width=width, anchor='center', stretch=stretch)
  app.service_list.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
  svc_scroll = ttk.Scrollbar(svc_tree_frame, orient="vertical", command=app.service_list.yview)
  app.service_list.configure(yscrollcommand=svc_scroll.set)
  svc_scroll.pack(side=tk.RIGHT, fill=tk.Y)

  # --- 우측 패널 (PanedWindow VERTICAL) ---
  right_paned = ttk.PanedWindow(paned, orient=tk.VERTICAL)
  paned.add(right_paned, weight=1)

  # 문자 수신자 (Treeview)
  sms_frame = ttk.LabelFrame(right_paned, text="문자 수신자", padding="5")
  right_paned.add(sms_frame, weight=1)
  sms_btn = ttk.Frame(sms_frame)
  sms_btn.pack(fill=tk.X, pady=3)
  app.add_recipient_button = ttk.Button(sms_btn, text="추가", style="Accent.TButton")
  app.add_recipient_button.pack(side=tk.LEFT)
  app.delete_recipient_button = ttk.Button(sms_btn, text="삭제", style="Danger.TButton")
  app.delete_recipient_button.pack(side=tk.LEFT, padx=5)
  app.edit_recipient_button = ttk.Button(sms_btn, text="수정")
  app.edit_recipient_button.pack(side=tk.LEFT, padx=3)
  app.recipient_list = ttk.Treeview(sms_frame, columns=("name", "phone"), show="headings", height=4)
  app.recipient_list.heading("name", text="이름", anchor='center')
  app.recipient_list.heading("phone", text="연락처", anchor='center')
  app.recipient_list.column("name", width=60, stretch=True, anchor='center')
  app.recipient_list.column("phone", width=90, stretch=True, anchor='center')
  app.recipient_list.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
  sms_scroll = ttk.Scrollbar(sms_frame, orient="vertical", command=app.recipient_list.yview)
  app.recipient_list.configure(yscrollcommand=sms_scroll.set)
  sms_scroll.pack(side=tk.RIGHT, fill=tk.Y)

  # 전화 수신자 (Treeview + ▲/▼ 버튼)
  call_frame = ttk.LabelFrame(right_paned, text="전화 수신자", padding="5")
  right_paned.add(call_frame, weight=1)
  call_btn = ttk.Frame(call_frame)
  call_btn.pack(fill=tk.X, pady=3)
  app.add_call_recipient_button = ttk.Button(call_btn, text="추가", style="Accent.TButton")
  app.add_call_recipient_button.pack(side=tk.LEFT)
  app.delete_call_recipient_button = ttk.Button(call_btn, text="삭제", style="Danger.TButton")
  app.delete_call_recipient_button.pack(side=tk.LEFT, padx=5)
  app.edit_call_recipient_button = ttk.Button(call_btn, text="수정")
  app.edit_call_recipient_button.pack(side=tk.LEFT, padx=3)
  app.move_down_button = ttk.Button(call_btn, text="▼", width=3)
  app.move_down_button.pack(side=tk.RIGHT)
  app.move_up_button = ttk.Button(call_btn, text="▲", width=3)
  app.move_up_button.pack(side=tk.RIGHT, padx=2)
  app.call_recipient_list = ttk.Treeview(call_frame, columns=("priority", "name", "phone"), show="headings", height=4)
  app.call_recipient_list.heading("priority", text="순위", anchor='center')
  app.call_recipient_list.heading("name", text="이름", anchor='center')
  app.call_recipient_list.heading("phone", text="연락처", anchor='center')
  app.call_recipient_list.column("priority", width=45, stretch=False, anchor='center')
  app.call_recipient_list.column("name", width=60, stretch=True, anchor='center')
  app.call_recipient_list.column("phone", width=90, stretch=True, anchor='center')
  app.call_recipient_list.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
  call_scroll = ttk.Scrollbar(call_frame, orient="vertical", command=app.call_recipient_list.yview)
  app.call_recipient_list.configure(yscrollcommand=call_scroll.set)
  call_scroll.pack(side=tk.RIGHT, fill=tk.Y)

  # 모니터링 설정
  settings_frame = ttk.LabelFrame(right_paned, text="모니터링 설정", padding="5")
  right_paned.add(settings_frame, weight=0)
  ttk.Label(settings_frame, text="주기 (초):").grid(row=0, column=0, sticky=tk.W, padx=5, pady=2)
  app.online_interval_entry = ttk.Entry(settings_frame, width=6)
  app.online_interval_entry.grid(row=0, column=1, sticky=tk.W, padx=5, pady=2)
  ttk.Label(settings_frame, text="최대 시도:").grid(row=0, column=2, sticky=tk.W, padx=5, pady=2)
  app.max_retries_entry = ttk.Entry(settings_frame, width=6)
  app.max_retries_entry.grid(row=0, column=3, sticky=tk.W, padx=5, pady=2)
  app.save_settings_button = ttk.Button(settings_frame, text="저장")
  app.save_settings_button.grid(row=0, column=4, padx=(10, 5), pady=2)

  # === 하단 이벤트 로그 (여러 줄) ===
  log_frame = ttk.LabelFrame(app.root, text="이벤트 로그 (장애/복구/발송 오류)", padding="3")
  log_frame.pack(side=tk.BOTTOM, fill=tk.X, padx=10, pady=(0, 5))
  app.event_log = tk.Text(log_frame, height=10, state=tk.DISABLED, wrap=tk.WORD,
                           font=("Consolas", 9), bg="#1e293b", fg="#e2e8f0",
                           relief=tk.FLAT, borderwidth=0,
                           insertbackground="#e2e8f0", selectbackground="#3b82f6")
  log_scroll = ttk.Scrollbar(log_frame, orient="vertical", command=app.event_log.yview)
  app.event_log.configure(yscrollcommand=log_scroll.set)
  app.event_log.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
  log_scroll.pack(side=tk.RIGHT, fill=tk.Y)
  app.event_log.tag_configure("failure", foreground="#E74C3C")
  app.event_log.tag_configure("resolved", foreground="#2ECC71")
  app.event_log.tag_configure("error", foreground="#F39C12")
