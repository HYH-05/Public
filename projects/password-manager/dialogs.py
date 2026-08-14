"""
다이얼로그 모듈 — GUI에서 분리된 Toplevel 다이얼로그 클래스들.
모든 다이얼로그에 Enter 키 바인딩 적용.
"""

import tkinter as tk
from tkinter import ttk, messagebox
import secrets
import string

from crypto import change_master_password
from constants import PASSWORD_FIELD

_BG = "#f5f6fa"


def _center(win: tk.Toplevel, parent):
    win.update_idletasks()
    w, h = win.winfo_width(), win.winfo_height()
    px = parent.winfo_x() + (parent.winfo_width() - w) // 2
    py = parent.winfo_y() + (parent.winfo_height() - h) // 2
    win.geometry(f"+{px}+{py}")


def _setup(win: tk.Toplevel, parent, title: str):
    win.title(title)
    win.configure(bg=_BG)
    win.transient(parent)
    win.grab_set()
    win.resizable(False, False)


class MasterPasswordDialog:
    """커스텀 마스터 비밀번호 입력 다이얼로그 (독립 Tk 윈도우)."""

    def __init__(self):
        self.result = None
        self.win = tk.Tk()
        self.win.title("마스터 비밀번호")
        self.win.configure(bg=_BG)
        self.win.resizable(False, False)

        main = ttk.Frame(self.win, padding=14)
        main.pack(fill="both", expand=True)

        ttk.Label(main, text="비밀번호를 입력하세요:").pack(anchor="w", pady=(0, 6))
        self.entry = ttk.Entry(main, show="*", width=35)
        self.entry.pack(fill="x", pady=(0, 4))

        btn_frame = ttk.Frame(main)
        btn_frame.pack(fill="x", pady=(8, 0))
        btn_frame.columnconfigure(0, weight=1)
        btn_frame.columnconfigure(1, weight=1)
        ttk.Button(btn_frame, text="확인", style="Accent.TButton",
                   command=self._ok).grid(row=0, column=0, sticky="ew", padx=(0, 3), ipady=2)
        ttk.Button(btn_frame, text="취소",
                   command=self._cancel).grid(row=0, column=1, sticky="ew", padx=(3, 0), ipady=2)

        self.win.bind("<Return>", lambda *_: self._ok())
        self.win.bind("<Escape>", lambda *_: self._cancel())
        self.entry.focus_set()
        self.win.protocol("WM_DELETE_WINDOW", self._cancel)

        self.win.eval('tk::PlaceWindow . center')
        self.win.mainloop()

    def _ok(self):
        self.result = self.entry.get()
        self.win.destroy()

    def _cancel(self):
        self.result = None
        self.win.destroy()


class EditDialog:
    def __init__(self, parent, data_fields: list[str],
                 old_fields: dict, on_save: callable,
                 secret_field: str = PASSWORD_FIELD,
                 group: str = "", groups: list[str] | None = None):
        self.win = tk.Toplevel(parent)
        _setup(self.win, parent, "항목 수정")

        main = ttk.Frame(self.win, padding=14)
        main.pack(fill="both", expand=True)

        # 그룹 콤보박스
        ttk.Label(main, text="그룹").grid(row=0, column=0, padx=(0, 10), pady=4, sticky="e")
        self.group_combo = ttk.Combobox(main, width=38, values=groups or [])
        self.group_combo.set(group)
        self.group_combo.grid(row=0, column=1, pady=4, sticky="ew")

        self.entries: dict[str, ttk.Entry] = {}
        for i, field in enumerate(data_fields, start=1):
            ttk.Label(main, text=field).grid(row=i, column=0, padx=(0, 10), pady=4, sticky="e")
            show = "*" if field == secret_field else ""
            frame = ttk.Frame(main)
            frame.grid(row=i, column=1, pady=4, sticky="ew")
            e = ttk.Entry(frame, width=40, show=show)
            e.insert(0, old_fields.get(field, ""))
            e.pack(side="left", fill="x", expand=True)
            self.entries[field] = e
            if field == secret_field:
                ttk.Button(
                    frame, text="표시", width=4, takefocus=False,
                    command=lambda entry=e: entry.config(
                        show="" if entry.cget("show") == "*" else "*"
                    ),
                ).pack(side="left", padx=(4, 0))

        main.columnconfigure(1, weight=1)
        row_count = len(data_fields) + 1

        def _save(*_):
            new_group = self.group_combo.get().strip()
            on_save({f: self.entries[f].get() for f in data_fields}, self.win, new_group)

        ttk.Separator(main, orient="horizontal").grid(
            row=row_count, column=0, columnspan=2, sticky="ew", pady=(8, 4))
        ttk.Button(main, text="저장", style="Accent.TButton", command=_save).grid(
            row=row_count + 1, column=0, columnspan=2, sticky="ew", ipady=2)

        self.win.bind("<Return>", _save)
        _center(self.win, parent)


class PasswordGeneratorDialog:
    _SPECIALS = "`~!@#$%^&*|'\";:₩\\?"

    def __init__(self, parent, on_apply: callable):
        self.win = tk.Toplevel(parent)
        _setup(self.win, parent, "비밀번호 생성")
        self._on_apply = on_apply

        main = ttk.Frame(self.win, padding=14)
        main.pack(fill="both", expand=True)

        ttk.Label(main, text="길이:").grid(row=0, column=0, padx=(0, 8), pady=4, sticky="e")
        self.length_var = tk.IntVar(value=20)
        ttk.Spinbox(main, from_=8, to=128, textvariable=self.length_var,
                     width=6).grid(row=0, column=1, pady=4, sticky="w")

        self.upper_var = tk.BooleanVar(value=True)
        self.digit_var = tk.BooleanVar(value=True)
        self.special_var = tk.BooleanVar(value=True)

        for i, (text, var) in enumerate((
            ("대문자 포함", self.upper_var),
            ("숫자 포함", self.digit_var),
            ("특수문자 포함", self.special_var),
        ), start=1):
            ttk.Checkbutton(main, text=text, variable=var).grid(
                row=i, column=0, columnspan=2, sticky="w", pady=1)

        self.result_var = tk.StringVar()
        ttk.Entry(main, textvariable=self.result_var, width=40,
                  font=("Consolas", 10)).grid(
            row=4, column=0, columnspan=2, pady=(8, 4), sticky="ew")

        ttk.Separator(main, orient="horizontal").grid(
            row=5, column=0, columnspan=2, sticky="ew", pady=4)

        btn_f = ttk.Frame(main)
        btn_f.grid(row=6, column=0, columnspan=2, sticky="ew")
        btn_f.columnconfigure(0, weight=1)
        btn_f.columnconfigure(1, weight=1)
        ttk.Button(btn_f, text="생성", command=self._generate).grid(
            row=0, column=0, sticky="ew", padx=(0, 3), ipady=1)
        ttk.Button(btn_f, text="적용", style="Accent.TButton",
                   command=self._apply).grid(
            row=0, column=1, sticky="ew", padx=(3, 0), ipady=1)

        main.columnconfigure(1, weight=1)
        self.win.bind("<Return>", lambda *_: self._apply())
        self._generate()
        _center(self.win, parent)

    def _generate(self):
        length = self.length_var.get()
        required = [secrets.choice(string.ascii_lowercase)]
        pool = string.ascii_lowercase
        for flag, chars in (
            (self.upper_var, string.ascii_uppercase),
            (self.digit_var, string.digits),
            (self.special_var, self._SPECIALS),
        ):
            if flag.get():
                required.append(secrets.choice(chars))
                pool += chars
        remaining = [secrets.choice(pool) for _ in range(max(0, length - len(required)))]
        pw_list = required + remaining
        secrets.SystemRandom().shuffle(pw_list)
        self.result_var.set("".join(pw_list))

    def _apply(self):
        pw = self.result_var.get()
        if pw:
            self._on_apply(pw)
        self.win.destroy()


class ChangeMasterPasswordDialog:
    def __init__(self, parent, master_key_file: str,
                 data_file: str, on_success: callable):
        self.win = tk.Toplevel(parent)
        _setup(self.win, parent, "마스터 비밀번호 변경")

        main = ttk.Frame(self.win, padding=14)
        main.pack(fill="both", expand=True)

        labels = ["현재 비밀번호:", "새 비밀번호:", "새 비밀번호 확인:"]
        self.entries = []
        for i, lbl in enumerate(labels):
            ttk.Label(main, text=lbl).grid(row=i, column=0, padx=(0, 10), pady=5, sticky="e")
            e = ttk.Entry(main, show="*", width=30)
            e.grid(row=i, column=1, pady=5, sticky="ew")
            self.entries.append(e)

        main.columnconfigure(1, weight=1)

        def _do_change(*_):
            old_pw, new_pw, confirm = (e.get() for e in self.entries)
            try:
                if not old_pw or not new_pw:
                    messagebox.showerror("오류", "모든 필드를 입력하세요.")
                    return
                if new_pw != confirm:
                    messagebox.showerror("오류", "새 비밀번호가 일치하지 않습니다.")
                    return
                ok, msg = change_master_password(old_pw, new_pw, master_key_file, data_file)
                if ok:
                    messagebox.showinfo("완료", msg + "\n프로그램을 재시작하세요.")
                    self.win.destroy()
                    on_success()
                else:
                    messagebox.showerror("오류", msg)
            finally:
                old_pw = new_pw = confirm = ""

        ttk.Separator(main, orient="horizontal").grid(
            row=3, column=0, columnspan=2, sticky="ew", pady=(8, 4))
        ttk.Button(main, text="변경", style="Accent.TButton",
                   command=_do_change).grid(
            row=4, column=0, columnspan=2, sticky="ew", ipady=2)

        self.win.bind("<Return>", _do_change)
        _center(self.win, parent)
