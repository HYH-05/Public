"""
GUI 모듈 — 앱 셸 (Notebook, 메뉴, 상태바, 자동 로그아웃).
탭 패널은 tab_panel.py, 스타일은 styles.py에 위임한다.
TabPanel과는 TabCallbacks를 통해 통신한다.
"""

import tkinter as tk
from tkinter import ttk, messagebox

from service import PasswordService
from dialogs import ChangeMasterPasswordDialog
from tab_panel import TabPanel, TabCallbacks, COLUMN_RATIOS_PASSWORD, COLUMN_RATIOS_KEY, COLUMN_RATIOS_AWS
from constants import (
    FIELDS, DATA_FIELDS, DISPLAY_FIELDS, PASSWORD_FIELD, PW_IDX,
    KEY_FIELDS, KEY_DATA_FIELDS, KEY_DISPLAY_FIELDS, KEY_SECRET_FIELD, KEY_SECRET_IDX,
    AWS_FIELDS, AWS_DATA_FIELDS, AWS_DISPLAY_FIELDS, AWS_SECRET_FIELD, AWS_SECRET_IDX,
    AUTO_LOGOUT_SEC, CLIPBOARD_CLEAR_SEC,
)
from totp_tab import TotpTab
import styles


class PasswordManagerApp:
    def __init__(self, root: tk.Tk, pw_svc: PasswordService,
                 key_svc: PasswordService,
                 aws_svc: PasswordService,
                 totp_svc: PasswordService,
                 master_key_file: str, data_file: str):
        self.root = root
        self.pw_svc = pw_svc
        self.key_svc = key_svc
        self.aws_svc = aws_svc
        self.totp_svc = totp_svc
        self.master_key_file = master_key_file
        self.data_file = data_file

        self.root.title("패스워드/키 관리")
        w, h = 1520, 750
        x = (self.root.winfo_screenwidth() - w) // 2
        y = (self.root.winfo_screenheight() - h) // 2
        self.root.geometry(f"{w}x{h}+{x}+{y}")
        self.root.minsize(1100, 650)
        styles.apply_style(self.root)

        self.clipboard_timer = None
        self.inactivity_timer = None
        self.remaining_time = AUTO_LOGOUT_SEC

        self._build_ui()
        self._setup_auto_logout()

    # ================================================================
    #  콜백 (TabPanel → App 통신)
    # ================================================================
    def _set_status(self, text: str):
        self.status_label.config(text=text)

    def _copy_to_clipboard(self, value: str, field_name: str):
        self.root.clipboard_clear()
        self.root.clipboard_append(value)
        self._set_status(
            f"[{field_name}] 복사됨 — {CLIPBOARD_CLEAR_SEC}초 후 클립보드 자동 삭제")
        if self.clipboard_timer:
            self.root.after_cancel(self.clipboard_timer)
        self.clipboard_timer = self.root.after(
            CLIPBOARD_CLEAR_SEC * 1000, self._clear_clipboard)

    def _make_callbacks(self) -> TabCallbacks:
        return TabCallbacks(
            root=self.root,
            set_status=self._set_status,
            copy_to_clipboard=self._copy_to_clipboard,
        )

    # ================================================================
    #  UI 빌드
    # ================================================================
    def _build_ui(self):
        menubar = tk.Menu(self.root, bg=styles.CARD_BG, fg=styles.TEXT,
                          activebackground=styles.ACCENT, activeforeground="white",
                          font=("Arial", 10))
        file_menu = tk.Menu(menubar, tearoff=0, bg=styles.CARD_BG, fg=styles.TEXT,
                            activebackground=styles.ACCENT, activeforeground="white",
                            font=("Arial", 10))
        file_menu.add_command(label="CSV 내보내기", command=self._  export_csv)
        file_menu.add_command(label="CSV 가져오기", command=self._import_csv)
        file_menu.add_separator()
        file_menu.add_command(label="마스터 비밀번호 변경", command=self._change_master_pw)
        menubar.add_cascade(label="파일", menu=file_menu)
        self.root.config(menu=menubar)

        container = ttk.Frame(self.root)
        container.pack(fill="both", expand=True, padx=10, pady=(8, 0))

        self.notebook = ttk.Notebook(container)
        self.notebook.pack(fill="both", expand=True)

        callbacks = self._make_callbacks()

        # --- 비밀번호 탭 ---
        pw_frame = ttk.Frame(self.notebook)
        self.notebook.add(pw_frame, text=" 🔒 비밀번호 ")
        self.pw_tab = self._build_tab(
            pw_frame, self.pw_svc, callbacks,
            all_fields=FIELDS, data_fields=DATA_FIELDS,
            display_fields=DISPLAY_FIELDS, secret_field=PASSWORD_FIELD,
            secret_idx=PW_IDX, required_fields={"이름(중복 불가)", "IP/도메인(중복 불가)"},
            tab_label="항목", show_pw_generator=True,
            column_ratios=COLUMN_RATIOS_PASSWORD,
        )

        # --- 키 관리 탭 ---
        key_frame = ttk.Frame(self.notebook)
        self.notebook.add(key_frame, text=" 🔑 키 관리 ")
        self.key_tab = self._build_tab(
            key_frame, self.key_svc, callbacks,
            all_fields=KEY_FIELDS, data_fields=KEY_DATA_FIELDS,
            display_fields=KEY_DISPLAY_FIELDS, secret_field=KEY_SECRET_FIELD,
            secret_idx=KEY_SECRET_IDX, required_fields={"이름(중복 불가)", KEY_SECRET_FIELD},
            tab_label="키", show_pw_generator=False,
            column_ratios=COLUMN_RATIOS_KEY,
        )

        # --- AWS IAM 키 탭 ---
        aws_frame = ttk.Frame(self.notebook)
        self.notebook.add(aws_frame, text=" ☁ AWS IAM 키 ")
        self.aws_tab = self._build_tab(
            aws_frame, self.aws_svc, callbacks,
            all_fields=AWS_FIELDS, data_fields=AWS_DATA_FIELDS,
            display_fields=AWS_DISPLAY_FIELDS, secret_field=AWS_SECRET_FIELD,
            secret_idx=AWS_SECRET_IDX, required_fields={"액세스 키(중복 불가)", AWS_SECRET_FIELD},
            tab_label="AWS 키", show_pw_generator=False,
            column_ratios=COLUMN_RATIOS_AWS,
        )

        # --- TOTP 탭 ---
        totp_frame = ttk.Frame(self.notebook)
        self.notebook.add(totp_frame, text=" 🔐 Authenticator ")
        self.totp_tab = self._build_totp_tab(totp_frame, callbacks)

        # --- 상태바 ---
        status = ttk.Frame(self.root, style="Status.TFrame")
        status.pack(fill="x", padx=10, pady=(4, 6))
        self.timer_label = ttk.Label(status, text="", style="StatusTimer.TLabel")
        self.timer_label.pack(side="right", padx=6)
        self.status_label = ttk.Label(status, text="", style="Status.TLabel")
        self.status_label.pack(side="left", padx=6)

        # @ 상태바 생성 후 탭 시트 초기화
        self.pw_tab._populate_sheet()
        self.key_tab._populate_sheet()
        self.aws_tab._populate_sheet()
        self.totp_tab._populate_sheet()

        # @ 탭 전환 시 시트 갱신
        self.notebook.bind("<<NotebookTabChanged>>", self._on_tab_changed)

    def _build_tab(self, parent, svc, callbacks, **kwargs) -> TabPanel:
        """탭 하나를 구성하고 TabPanel을 반환한다."""
        wrapper = ttk.Frame(parent)
        wrapper.pack(fill="both", expand=True)

        toggle_bar = ttk.Frame(wrapper, style="CardInner.TFrame")
        toggle_bar.pack(fill="x", pady=(2, 0))
        toggle_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(
            toggle_bar, text="▶ 입력 패널 접기/펼치기",
            style="Card.TCheckbutton", variable=toggle_var,
        ).pack(side="right", padx=4)

        paned = ttk.PanedWindow(wrapper, orient=tk.HORIZONTAL)
        paned.pack(fill="both", expand=True)
        left_card = ttk.Frame(paned, style="Card.TFrame")
        right_card = ttk.Frame(paned, style="Card.TFrame")
        paned.add(left_card, weight=4)
        paned.add(right_card, weight=1)
        left = ttk.Frame(left_card, style="CardInner.TFrame")
        left.pack(fill="both", expand=True, padx=10, pady=8)
        right = ttk.Frame(right_card, style="CardInner.TFrame")
        right.pack(fill="both", expand=True, padx=10, pady=8)

        tab = TabPanel(left, right, callbacks, svc, **kwargs)

        toggle_var.trace_add("write", lambda *_: self._toggle_panel(
            paned, right_card, toggle_var))

        # 초기 상태 적용 (접힌 상태)
        self.root.after_idle(lambda: self._toggle_panel(paned, right_card, toggle_var))

        return tab

    def _build_totp_tab(self, parent, callbacks) -> TotpTab:
        """TOTP 탭 — 기존 탭과 동일한 레이아웃."""
        wrapper = ttk.Frame(parent)
        wrapper.pack(fill="both", expand=True)

        toggle_bar = ttk.Frame(wrapper, style="CardInner.TFrame")
        toggle_bar.pack(fill="x", pady=(2, 0))
        toggle_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(
            toggle_bar, text="▶ 입력 패널 접기/펼치기",
            style="Card.TCheckbutton", variable=toggle_var,
        ).pack(side="right", padx=4)

        paned = ttk.PanedWindow(wrapper, orient=tk.HORIZONTAL)
        paned.pack(fill="both", expand=True)
        left_card = ttk.Frame(paned, style="Card.TFrame")
        right_card = ttk.Frame(paned, style="Card.TFrame")
        paned.add(left_card, weight=4)
        paned.add(right_card, weight=1)
        left = ttk.Frame(left_card, style="CardInner.TFrame")
        left.pack(fill="both", expand=True, padx=10, pady=8)
        right = ttk.Frame(right_card, style="CardInner.TFrame")
        right.pack(fill="both", expand=True, padx=10, pady=8)

        tab = TotpTab(left, right, callbacks, self.totp_svc)

        toggle_var.trace_add("write", lambda *_: self._toggle_panel(
            paned, right_card, toggle_var))

        # 초기 상태 적용 (접힌 상태)
        self.root.after_idle(lambda: self._toggle_panel(paned, right_card, toggle_var))

        return tab

    @staticmethod
    def _toggle_panel(paned, right_card, toggle_var):
        if toggle_var.get():
            try:
                paned.add(right_card, weight=1)
            except tk.TclError:
                pass
        else:
            try:
                paned.remove(right_card)
            except tk.TclError:
                pass

    def _get_active_tab(self) -> TabPanel:
        idx = self.notebook.index(self.notebook.select())
        return (self.pw_tab, self.key_tab, self.aws_tab, self.totp_tab)[idx]

    def _on_tab_changed(self, event=None):
        """탭 전환 시 해당 탭의 시트 갱신 및 컬럼 비율 재적용."""
        tab = self._get_active_tab()
        self.root.update_idletasks()
        # 시트 데이터 다시 표시
        if tab.rows:
            tab.sheet.set_sheet_data([r.display for r in tab.rows], reset_col_positions=False)
            tab.sheet.set_all_row_heights(height=None)
        if tab.column_ratios:
            self.root.after(50, tab._apply_column_ratios)

    # ================================================================
    #  CSV (활성 탭 기준)
    # ================================================================
    def _export_csv(self):
        self._get_active_tab().export_csv()

    def _import_csv(self):
        self._get_active_tab().import_csv()

    # ================================================================
    #  클립보드
    # ================================================================
    def _clear_clipboard(self):
        self.root.clipboard_clear()
        self.root.clipboard_append("")
        self.status_label.config(text="클립보드가 삭제되었습니다.")
        self.clipboard_timer = None

    # ================================================================
    #  마스터 비밀번호 변경
    # ================================================================
    def _change_master_pw(self):
        ChangeMasterPasswordDialog(
            self.root, self.master_key_file, self.data_file,
            on_success=self.root.destroy)

    # ================================================================
    #  자동 로그아웃
    # ================================================================
    def _setup_auto_logout(self):
        self._check_idle_and_update()

    def _check_idle_and_update(self):
        """1초마다 시스템 유휴 시간 확인 및 UI 업데이트"""
        if not self.root.winfo_exists():
            return

        # 잠금 상태면 유휴 시간 무시하고 타이머 계속 감소
        if self._is_session_locked():
            self.remaining_time = max(0, self.remaining_time - 1)
        else:
            idle_sec = self._get_system_idle_sec()
            self.remaining_time = max(0, AUTO_LOGOUT_SEC - idle_sec)

        if self.remaining_time <= 0:
            self._auto_logout()
        else:
            text = self._format_remaining(self.remaining_time)
            self.timer_label.config(text=f"{text} 후 자동 로그아웃")
            self.root.after(1000, self._check_idle_and_update)

    @staticmethod
    def _get_system_idle_sec():
        """Windows 시스템 유휴 시간(초) 반환"""
        import ctypes

        class LASTINPUTINFO(ctypes.Structure):
            _fields_ = [("cbSize", ctypes.c_uint), ("dwTime", ctypes.c_uint)]

        lii = LASTINPUTINFO()
        lii.cbSize = ctypes.sizeof(LASTINPUTINFO)

        if ctypes.windll.user32.GetLastInputInfo(ctypes.byref(lii)):
            millis = ctypes.windll.kernel32.GetTickCount() - lii.dwTime
            return millis // 1000
        return 0

    @staticmethod
    def _is_session_locked():
        """Windows 세션 잠금 여부 확인"""
        import ctypes
        user32 = ctypes.windll.user32
        DESKTOP_SWITCHDESKTOP = 0x0100
        hDesktop = user32.OpenDesktopW("Default", 0, False, DESKTOP_SWITCHDESKTOP)
        if hDesktop:
            result = user32.SwitchDesktop(hDesktop)
            user32.CloseDesktop(hDesktop)
            return not result
        return True

    @staticmethod
    def _format_remaining(seconds: int) -> str:
        d, seconds = divmod(seconds, 86400)
        h, seconds = divmod(seconds, 3600)
        m, s = divmod(seconds, 60)
        parts = []
        if d:
            parts.append(f"{d}일")
        if h:
            parts.append(f"{h}시간")
        if m:
            parts.append(f"{m}분")
        parts.append(f"{s}초")
        return " ".join(parts)

    def _auto_logout(self):
        self.pw_svc.flush()
        self.key_svc.flush()
        self.aws_svc.flush()
        self.totp_svc.flush()
        self.root.withdraw()  # 메인 창 숨기기
        messagebox.showinfo("자동 로그아웃", f"{AUTO_LOGOUT_SEC}초 동안 활동이 없어 프로그램을 종료합니다.")
        self.root.destroy()
