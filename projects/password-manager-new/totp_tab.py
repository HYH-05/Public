"""
TOTP(Authenticator) 탭 — 기존 TabPanel 구조를 확장하여 OTP 코드 실시간 표시.
"""

import base64
import time
import tkinter as tk
import urllib.parse
from tkinter import ttk, messagebox, simpledialog

import pyotp

from service import PasswordService, DuplicateError
from tab_panel import TabPanel, TabCallbacks, COLUMN_RATIOS_TOTP
from constants import (
    TOTP_FIELDS, TOTP_DATA_FIELDS, TOTP_DISPLAY_FIELDS,
    TOTP_SECRET_FIELD, TOTP_SECRET_IDX,
    TOTP_PREFIX_FIELD, TOTP_PREFIX_IDX,
)

# ☆ 즐겨찾기 컬럼이 display 맨 앞에 추가되므로 실제 display 인덱스는 +1
_DISPLAY_PREFIX_IDX = TOTP_PREFIX_IDX + 1
import styles


# ! ================================================================
# !  Google Authenticator migration URI 파서
# ! ================================================================
def _decode_varint(data, pos):
    result = shift = 0
    while pos < len(data):
        b = data[pos]; pos += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            break
        shift += 7
    return result, pos


def _parse_protobuf(data):
    fields = []
    pos = 0
    while pos < len(data):
        tag, pos = _decode_varint(data, pos)
        wire_type = tag & 0x07
        if wire_type == 0:
            value, pos = _decode_varint(data, pos)
        elif wire_type == 2:
            length, pos = _decode_varint(data, pos)
            value = data[pos:pos+length]; pos += length
        else:
            break
        fields.append((tag >> 3, wire_type, value))
    return fields


def parse_migration_uri(uri: str) -> list[dict]:
    """otpauth-migration URI를 파싱하여 [{name, issuer, secret}] 반환."""
    parsed = urllib.parse.urlparse(uri)
    qs = urllib.parse.parse_qs(parsed.query)
    data_b64 = urllib.parse.unquote(qs.get('data', [''])[0])
    data = base64.b64decode(data_b64)

    results = []
    for fn, wt, val in _parse_protobuf(data):
        if fn == 1 and wt == 2:
            secret = name = issuer = ""
            for pfn, pwt, pval in _parse_protobuf(val):
                if pfn == 1 and pwt == 2:
                    secret = base64.b32encode(pval).decode().rstrip('=')
                elif pfn == 2 and pwt == 2:
                    name = pval.decode('utf-8', errors='replace')
                elif pfn == 3 and pwt == 2:
                    issuer = pval.decode('utf-8', errors='replace')
            if secret:
                results.append({"name": name, "issuer": issuer, "secret": secret})
    return results


# ! ================================================================
# !  TOTP 탭 (TabPanel 확장)
# ! ================================================================
class TotpTab(TabPanel):
    """TabPanel을 상속하여 OTP 코드 열 + 실시간 갱신 + 가져오기 기능 추가."""

    def __init__(self, parent_left: ttk.Frame, parent_right: ttk.Frame,
                 callbacks: TabCallbacks, svc: PasswordService):
        # OTP 코드/남은 시간 열을 display에 추가
        self._otp_display_fields = TOTP_DISPLAY_FIELDS + ["OTP 코드", "남은 시간"]
        self._combine_var = tk.BooleanVar(value=True)

        super().__init__(
            parent_left, parent_right, callbacks, svc,
            all_fields=TOTP_FIELDS,
            data_fields=TOTP_DATA_FIELDS,
            display_fields=self._otp_display_fields,
            secret_field=TOTP_SECRET_FIELD,
            secret_idx=TOTP_SECRET_IDX,
            required_fields={"이름(중복 불가)", TOTP_SECRET_FIELD},
            tab_label="TOTP",
            show_pw_generator=False,
            column_ratios=COLUMN_RATIOS_TOTP,
        )
        self._tick()

    def _build_left(self, parent):
        """좌측 패널 — 기존 구조 + 가져오기 버튼 + 동시복사 체크박스 추가."""
        super()._build_left(parent)

        # 그룹 버튼 바(2번째 자식)에 가져오기 버튼 추가
        grp_btn_bar = parent.winfo_children()[1]
        ttk.Button(grp_btn_bar, text="Authenticator 가져오기",
                   command=self._on_import_migration).pack(side="left", padx=(4, 0))
        ttk.Checkbutton(grp_btn_bar, text="패스워드+OTP 동시복사",
                        variable=self._combine_var).pack(side="left", padx=(8, 0))

    # ! ================================================================
    # !  시트 데이터 오버라이드 — OTP 열 추가
    # ! ================================================================
    def _populate_sheet(self, data=None):
        """기존 _populate_sheet 호출 후 OTP 열 데이터 추가."""
        super()._populate_sheet(data)
        # 패스워드 열 실제 값을 real_prefix에 저장 후 마스킹 (set_sheet_data 없이 display만 수정)
        for row in self.rows:
            real_pw = row.display[_DISPLAY_PREFIX_IDX]
            row.real_prefix = real_pw
            if not self.secret_visible and real_pw:
                row.display[_DISPLAY_PREFIX_IDX] = "●" * min(len(str(real_pw)), 12)
                self.sheet.set_cell_data(
                    self.rows.index(row), _DISPLAY_PREFIX_IDX,
                    row.display[_DISPLAY_PREFIX_IDX]
                )
        self._update_otp_columns()

    def _toggle_secrets(self):
        """시크릿 키 + 패스워드 열 동시 토글."""
        super()._toggle_secrets()
        for row in self.rows:
            row.display[_DISPLAY_PREFIX_IDX] = (
                row.real_prefix if self.secret_visible
                else "●" * min(len(str(row.real_prefix)), 12) if row.real_prefix else ""
            )
        if self.rows:
            self.sheet.set_sheet_data([r.display for r in self.rows], reset_col_positions=False)
            self.sheet.set_all_row_heights(height=None)
            self.sheet.readonly(self.sheet.span(":").expand())

    def _update_otp_columns(self):
        """각 행의 OTP 코드와 남은 시간 셀만 개별 갱신."""
        now = time.time()
        remaining = 30 - int(now % 30)
        code_col = len(TOTP_DISPLAY_FIELDS) + 1
        time_col = code_col + 1
        visible = self.secret_visible

        for i, row in enumerate(self.rows):
            while len(row.display) <= time_col:
                row.display.append("")

            secret = row.real_secret
            if secret:
                if visible:
                    try:
                        otp_code = pyotp.TOTP(secret).now()
                        prefix = row.real_prefix
                        new_code = otp_code  # 표시는 OTP만
                    except Exception:
                        new_code = "오류"
                else:
                    new_code = "••••••"
                new_time = f"{remaining}초"
            else:
                new_code = ""
                new_time = ""

            if row.display[code_col] != new_code:
                row.display[code_col] = new_code
                self.sheet.set_cell_data(i, code_col, new_code)
            if row.display[time_col] != new_time:
                row.display[time_col] = new_time
                self.sheet.set_cell_data(i, time_col, new_time)

    # ! ================================================================
    # !  셀 복사 오버라이드 — OTP 코드 열은 실제 코드 복사
    # ! ================================================================
    def _copy_selected_cell(self):
        cells = self.sheet.get_selected_cells()
        if not cells:
            return
        r, c = list(cells)[0]
        if not self.rows or r >= len(self.rows):
            return
        code_col = len(TOTP_DISPLAY_FIELDS) + 1

        # 동시복사 체크 ON 상태에서 OTP 코드 열 또는 패스워드 열이면 합쳐서 복사
        if self._combine_var.get() and c in (code_col, _DISPLAY_PREFIX_IDX):
            secret = self.rows[r].real_secret
            prefix = self.rows[r].real_prefix
            if secret:
                try:
                    otp_code = pyotp.TOTP(secret).now()
                    value = f"{prefix}{otp_code}" if prefix else otp_code
                    field_name = "패스워드+OTP 코드"
                except Exception:
                    value = prefix
                    field_name = "패스워드"
            else:
                value = prefix
                field_name = "패스워드"
            self.cb.copy_to_clipboard(value, field_name)
            return

        if c == code_col:
            secret = self.rows[r].real_secret
            if secret:
                try:
                    value = pyotp.TOTP(secret).now()
                except Exception:
                    value = ""
            else:
                value = ""
            field_name = "OTP 코드"
        elif c == self.secret_idx:
            value = self.rows[r].real_secret
            field_name = self.display_fields[c]
        elif c == _DISPLAY_PREFIX_IDX:
            value = self.rows[r].real_prefix
            field_name = self.display_fields[c]
        else:
            value = self.sheet.get_cell_data(r, c)
            field_name = self.display_fields[c]
        self.cb.copy_to_clipboard(value, field_name)

    # ! ================================================================
    # !  1초 간격 OTP 갱신
    # ! ================================================================
    def _tick(self):
        self._update_otp_columns()
        self.cb.root.after(1000, self._tick)

    # ! ================================================================
    # !  Authenticator 내보내기 데이터 가져오기
    # ! ================================================================
    def _on_import_migration(self):
        dlg = _MigrationImportDialog(self.cb.root)
        if not dlg.result:
            return

        try:
            entries = parse_migration_uri(dlg.result)
        except Exception:
            messagebox.showerror("오류", "데이터를 파싱할 수 없습니다.\notpauth-migration:// 형식인지 확인하세요.")
            return

        if not entries:
            messagebox.showinfo("결과", "가져올 항목이 없습니다.")
            return

        added = skipped = 0
        for entry in entries:
            issuer = entry["issuer"] or "기본 그룹"
            name = entry["name"]
            secret = entry["secret"]

            account = ""
            for sep in ("_", ":"):
                if sep in name:
                    account = name.split(sep, 1)[1]
                    break

            fields = {
                "이름(중복 불가)": name,
                "서비스/사이트": issuer,
                "계정": account,
                "시크릿 키(중복 불가)": secret,
                "비고": "-",
            }
            try:
                self.svc.add_record(issuer, fields)
                added += 1
            except DuplicateError:
                skipped += 1

        self._refresh()
        self.cb.set_status(f"Authenticator 가져오기: {added}건 추가, {skipped}건 중복 스킵")


# ! ================================================================
# !  가져오기 다이얼로그
# ! ================================================================
class _MigrationImportDialog(simpledialog.Dialog):
    def __init__(self, parent):
        self.result = None
        super().__init__(parent, title="Authenticator 가져오기")

    def body(self, master):
        ttk.Label(master, text="otpauth-migration:// URI를 붙여넣으세요:").pack(anchor="w", pady=(0, 4))
        self.text = tk.Text(master, width=60, height=6)
        self.text.pack(fill="both", expand=True)
        return self.text

    def apply(self):
        self.result = self.text.get("1.0", "end").strip()
