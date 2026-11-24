# ! GUI 대화상자 모듈

import tkinter as tk
from tkinter import ttk, messagebox, simpledialog


class _CenterMixin:
  """대화상자 중앙 정렬 믹스인"""
  def _center_dialog(self):
    self.parent.update_idletasks()
    self.update_idletasks()
    x = self.parent.winfo_x() + (self.parent.winfo_width() - self.winfo_width()) // 2
    y = self.parent.winfo_y() + (self.parent.winfo_height() - self.winfo_height()) // 2
    self.geometry(f"+{x}+{y}")

  def buttonbox(self):
    """OK/Cancel 버튼을 한국어로 오버라이드"""
    box = ttk.Frame(self)
    ok_btn = ttk.Button(box, text="확인", width=10, command=self.ok, default=tk.ACTIVE)
    ok_btn.pack(side=tk.LEFT, padx=5, pady=5)
    cancel_btn = ttk.Button(box, text="취소", width=10, command=self.cancel)
    cancel_btn.pack(side=tk.LEFT, padx=5, pady=5)
    self.bind("<Return>", self.ok)
    self.bind("<Escape>", self.cancel)
    box.pack()


class ServiceDialog(_CenterMixin, simpledialog.Dialog):
  """서비스 추가/수정 대화상자"""
  def __init__(self, parent, title=None, service=None):
    self.service = service
    self._valid = False
    super().__init__(parent, title=title or ("서비스 수정" if service else "서비스 추가"))

  def body(self, master):
    ttk.Label(master, text="서비스 이름:").grid(row=0, sticky=tk.W)
    ttk.Label(master, text="IP:").grid(row=1, sticky=tk.W)
    ttk.Label(master, text="Port:").grid(row=2, sticky=tk.W)
    self.name_entry = ttk.Entry(master, width=25)
    self.ip_entry = ttk.Entry(master, width=25)
    self.port_entry = ttk.Entry(master, width=10)
    self.name_entry.grid(row=0, column=1, padx=5, pady=5)
    self.ip_entry.grid(row=1, column=1, padx=5, pady=5)
    self.port_entry.grid(row=2, column=1, padx=5, pady=5, sticky=tk.W)
    if self.service:
      self.name_entry.insert(0, self.service.get('name', ''))
      addr = self.service.get('address', '')
      if ':' in addr:
        ip, port = addr.rsplit(':', 1)
        self.ip_entry.insert(0, ip)
        self.port_entry.insert(0, port)
    self._center_dialog()
    return self.name_entry

  def validate(self):
    name = self.name_entry.get().strip()
    ip = self.ip_entry.get().strip()
    port = self.port_entry.get().strip()
    if not name or not ip or not port:
      messagebox.showwarning("입력 오류", "모든 필드를 입력해야 합니다.", parent=self)
      return False
    if not port.isdigit() or not (1 <= int(port) <= 65535):
      messagebox.showwarning("형식 오류", "Port는 1~65535 범위의 숫자여야 합니다.", parent=self)
      return False
    parts = ip.split('.')
    if len(parts) == 4:
      if not all(p.isdigit() and 0 <= int(p) <= 255 for p in parts):
        messagebox.showwarning("형식 오류", "올바른 IPv4 주소를 입력하세요.", parent=self)
        return False
    self._valid = True
    return True

  def apply(self):
    name = self.name_entry.get().strip()
    ip = self.ip_entry.get().strip()
    port = self.port_entry.get().strip()
    self.result = {"name": name, "address": f"{ip}:{port}"}


class RecipientDialog(_CenterMixin, simpledialog.Dialog):
  """수신자 추가/수정 대화상자"""
  def __init__(self, parent, title=None, recipient=None):
    self.recipient = recipient
    super().__init__(parent, title=title)

  def body(self, master):
    ttk.Label(master, text="이름:").grid(row=0, sticky=tk.W)
    ttk.Label(master, text="연락처:").grid(row=1, sticky=tk.W)
    self.name_entry = ttk.Entry(master, width=20)
    self.phone_entry = ttk.Entry(master, width=20)
    self.name_entry.grid(row=0, column=1, padx=5, pady=5)
    self.phone_entry.grid(row=1, column=1, padx=5, pady=5)
    if self.recipient and '/' in self.recipient:
      name, phone = self.recipient.split('/', 1)
      self.name_entry.insert(0, name)
      self.phone_entry.insert(0, phone)
    self._center_dialog()
    return self.name_entry

  def validate(self):
    name = self.name_entry.get().strip()
    phone = self.phone_entry.get().strip()
    if not name or not phone:
      messagebox.showwarning("입력 오류", "모든 필드를 입력해야 합니다.", parent=self)
      return False
    return True

  def apply(self):
    name = self.name_entry.get().strip()
    phone = self.phone_entry.get().strip()
    self.result = f"{name}/{phone}"


class CallRecipientDialog(_CenterMixin, simpledialog.Dialog):
  """전화 수신자 추가/수정 대화상자 (순위 선택 포함)"""
  def __init__(self, parent, title=None, recipient=None, max_priority=1):
    self.recipient = recipient
    self.max_priority = max_priority
    self.initial_priority = None
    super().__init__(parent, title=title)

  def body(self, master):
    ttk.Label(master, text="이름:").grid(row=0, sticky=tk.W)
    ttk.Label(master, text="연락처:").grid(row=1, sticky=tk.W)
    ttk.Label(master, text="순위:").grid(row=2, sticky=tk.W)
    self.name_entry = ttk.Entry(master, width=20)
    self.phone_entry = ttk.Entry(master, width=20)
    self.name_entry.grid(row=0, column=1, padx=5, pady=5)
    self.phone_entry.grid(row=1, column=1, padx=5, pady=5)

    # 순위 선택: 기존 순위 + 새 순위(마지막+1)
    priority_values = [str(i) for i in range(1, self.max_priority + 2)]
    self.priority_combo = ttk.Combobox(master, values=priority_values, width=5, state="readonly")
    self.priority_combo.grid(row=2, column=1, padx=5, pady=5, sticky=tk.W)
    self.priority_combo.set(str(self.max_priority + 1))

    if self.recipient:
      if isinstance(self.recipient, dict):
        self.name_entry.insert(0, self.recipient.get('name', ''))
        self.phone_entry.insert(0, self.recipient.get('phone', ''))
        if self.recipient.get('priority'):
          self.priority_combo.set(str(self.recipient['priority']))
          self.initial_priority = self.recipient['priority']
      elif isinstance(self.recipient, str) and '/' in self.recipient:
        name, phone = self.recipient.split('/', 1)
        self.name_entry.insert(0, name)
        self.phone_entry.insert(0, phone)

    self._center_dialog()
    return self.name_entry

  def validate(self):
    name = self.name_entry.get().strip()
    phone = self.phone_entry.get().strip()
    if not name or not phone:
      messagebox.showwarning("입력 오류", "모든 필드를 입력해야 합니다.", parent=self)
      return False
    try:
      p = int(self.priority_combo.get())
      if p < 1:
        raise ValueError
    except ValueError:
      messagebox.showwarning("입력 오류", "순위는 1 이상의 숫자여야 합니다.", parent=self)
      return False
    return True

  def apply(self):
    name = self.name_entry.get().strip()
    phone = self.phone_entry.get().strip()
    priority = int(self.priority_combo.get())
    self.result = {
        'recipient': f"{name}/{phone}",
        'priority': priority
    }


class GroupDialog(_CenterMixin, simpledialog.Dialog):
  """그룹 추가/수정 대화상자"""
  def __init__(self, parent, title=None, group_name=None, call_alias=None):
    self.initial_name = group_name
    self.initial_alias = call_alias
    super().__init__(parent, title=title)

  def body(self, master):
    ttk.Label(master, text="그룹 이름:").grid(row=0, sticky=tk.W)
    ttk.Label(master, text="전화 별명:").grid(row=1, sticky=tk.W)
    self.name_entry = ttk.Entry(master, width=25)
    self.alias_entry = ttk.Entry(master, width=25)
    self.name_entry.grid(row=0, column=1, padx=5, pady=5)
    self.alias_entry.grid(row=1, column=1, padx=5, pady=5)
    if self.initial_name:
      self.name_entry.insert(0, self.initial_name)
    if self.initial_alias:
      self.alias_entry.insert(0, self.initial_alias)
    self._center_dialog()
    return self.name_entry

  def validate(self):
    name = self.name_entry.get().strip()
    if not name:
      messagebox.showwarning("입력 오류", "그룹 이름을 입력해야 합니다.", parent=self)
      return False
    return True

  def apply(self):
    name = self.name_entry.get().strip()
    alias = self.alias_entry.get().strip()
    self.result = {"name": name, "call_alias": alias or ""}


class InputDialog(_CenterMixin, simpledialog.Dialog):
  """단일 입력 대화상자"""
  def __init__(self, parent, title=None, prompt=None, initialvalue=None):
    self.prompt = prompt
    self.initialvalue = initialvalue
    super().__init__(parent, title=title)

  def body(self, master):
    if self.prompt:
      ttk.Label(master, text=self.prompt).pack(pady=5)
    self.entry = ttk.Entry(master)
    if self.initialvalue:
      self.entry.insert(0, self.initialvalue)
    self.entry.pack(padx=5, pady=5)
    self._center_dialog()
    return self.entry

  def apply(self):
    self.result = self.entry.get().strip() or None
