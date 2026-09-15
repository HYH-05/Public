"""
탭 패널 모듈 — 단일 탭(비밀번호 또는 키)의 시트 + 입력 패널 + 이벤트 핸들링.
App 객체에 직접 의존하지 않고 콜백을 통해 통신한다.
"""

import tkinter as tk
from tkinter import ttk, messagebox, simpledialog, filedialog
from typing import Callable

from tksheet import Sheet
from service import PasswordService, DuplicateError
from dialogs import EditDialog, PasswordGeneratorDialog
from constants import CLIPBOARD_CLEAR_SEC, SEARCH_DEBOUNCE_MS
import styles


class TabCallbacks:
    """TabPanel이 App과 통신하기 위한 콜백 인터페이스."""
    __slots__ = ("root", "set_status", "copy_to_clipboard")

    def __init__(self, root: tk.Tk,
                 set_status: Callable[[str], None],
                 copy_to_clipboard: Callable[[str, str], None]):
        self.root = root
        self.set_status = set_status
        self.copy_to_clipboard = copy_to_clipboard


# ================================================================
#  컬럼 너비 비율 설정 (탭별)
# ================================================================
# 비밀번호 탭: 즐겨찾기, 그룹, 이름, IP/도메인, OS/환경, ID/이메일, 비밀번호, 비고
COLUMN_RATIOS_PASSWORD = [0.05, 0.10, 0.15, 0.18, 0.10, 0.17, 0.12, 0.13]
# 키 관리 탭: 즐겨찾기, 그룹, 이름, 서비스/플랫폼, 키 유형, 키 값, 연결 계정/이메일, 만료일, 비고
COLUMN_RATIOS_KEY = [0.04, 0.09, 0.12, 0.12, 0.10, 0.18, 0.14, 0.09, 0.12]
# AWS IAM 키 탭: 즐겨찾기, 그룹, 연결 계정, 액세스 키, 시크릿 키, 권한, 비고
COLUMN_RATIOS_AWS = [0.05, 0.12, 0.15, 0.20, 0.20, 0.13, 0.15]
# TOTP 탭: 즐겨찾기, 그룹, 이름, 서비스/사이트, 계정, 시크릿 키, 비고, 패스워드, OTP 코드, 남은 시간
COLUMN_RATIOS_TOTP = [0.04, 0.08, 0.11, 0.11, 0.11, 0.14, 0.10, 0.10, 0.11, 0.10]


class RowData:
    __slots__ = ("display", "record_id", "group", "real_secret", "real_prefix")

    def __init__(self, display: list[str], record_id: str,
                 group: str, real_secret: str, real_prefix: str = ""):
        self.display = display
        self.record_id = record_id
        self.group = group
        self.real_secret = real_secret
        self.real_prefix = real_prefix


class TabPanel:
    """하나의 탭에 대한 좌측 시트 + 우측 입력 패널."""

    def __init__(self, parent_left: ttk.Frame, parent_right: ttk.Frame,
                 callbacks: TabCallbacks, svc: PasswordService,
                 all_fields: list[str], data_fields: list[str],
                 display_fields: list[str], secret_field: str,
                 secret_idx: int, required_fields: set[str],
                 tab_label: str, show_pw_generator: bool = False,
                 column_ratios: list[float] | None = None):
        self.cb = callbacks
        self.svc = svc
        self.all_fields = all_fields
        self.data_fields = data_fields
        # 즐겨찾기 컬럼을 맨 앞에 추가
        self.display_fields = ["즐겨찾기"] + display_fields
        self.secret_field = secret_field
        self.secret_idx = secret_idx + 1  # ☆ 컬럼 때문에 +1
        self.required_fields = required_fields
        self.tab_label = tab_label
        self.show_pw_generator = show_pw_generator
        self.column_ratios = column_ratios

        self.rows: list[RowData] = []
        self.delete_stack: list[tuple[str, dict, str]] = []
        self._group_label_map: dict[str, str] = {"전체": "전체"}
        self._search_after_id = None
        self._resize_after_id = None
        self.secret_visible = False
        self.sort_asc = True
        self.sort_col = None

        self._search_field_map = dict(zip(
            ["전체 필드"] + display_fields, ["전체 필드"] + all_fields))

        self._build_left(parent_left)
        self._build_right(parent_right)
        self._update_group_combos()

    # ================================================================
    #  좌측 패널 (시트)
    # ================================================================
    def _build_left(self, parent):
        top = ttk.Frame(parent, style="CardInner.TFrame")
        top.pack(fill="x", pady=(0, 6))

        ttk.Label(top, text="그룹:", style="CardTitle.TLabel").pack(side="left", padx=(0, 4))
        self.group_filter = ttk.Combobox(top, width=18, state="readonly")
        self.group_filter.pack(side="left", padx=(0, 10))
        self.group_filter.bind("<<ComboboxSelected>>", lambda e: self._reset_sort_and_populate())

        ttk.Label(top, text="검색:", style="CardInner.TLabel").pack(side="left", padx=(10, 4))
        self.search_field_filter = ttk.Combobox(
            top, width=14, state="readonly",
            values=["전체 필드"] + self.display_fields)
        self.search_field_filter.set("전체 필드")
        self.search_field_filter.pack(side="left", padx=(0, 4))
        self.search_field_filter.bind("<<ComboboxSelected>>", lambda e: self._populate_sheet())

        self.search_var = tk.StringVar()
        self.search_var.trace_add("write", lambda *_: self._schedule_search())
        ttk.Entry(top, textvariable=self.search_var, width=25).pack(
            side="left", fill="x", expand=True, padx=(0, 4))
        ttk.Button(top, text="X", width=2, takefocus=False,
                   command=lambda: self.search_var.set("")).pack(side="left")

        grp_btn = ttk.Frame(parent, style="CardInner.TFrame")
        grp_btn.pack(fill="x", pady=(0, 6))
        ttk.Button(grp_btn, text="그룹 이름 변경",
                   command=self._rename_group).pack(side="left", padx=(0, 4))
        ttk.Button(grp_btn, text="그룹 삭제", style="Danger.TButton",
                   command=self._delete_group).pack(side="left", padx=(0, 4))

        sheet_frame = tk.Frame(parent, bg=styles.BORDER)
        sheet_frame.pack(fill="both", expand=True)
        sheet_frame.grid_rowconfigure(0, weight=1)
        sheet_frame.grid_columnconfigure(0, weight=1)

        self.sheet = Sheet(
            sheet_frame, headers=self.display_fields, show_row_index=False,
            table_wrap="", header_wrap="",
            font=("Arial", 10, "normal"),
            header_font=("Arial", 10, "bold"),
            header_bg=styles.HEADER_BG, header_fg=styles.HEADER_FG,
            header_grid_fg=styles.HEADER_BG, top_left_bg=styles.HEADER_BG,
            align="center", header_align="center",
            default_row_height="1", default_header_height="1",
            table_bg=styles.CARD_BG, table_fg=styles.TEXT,
            table_grid_fg="#cbd5e1", alternate_color=styles.ROW_ALT,
            horizontal_grid_to_end_of_window=False,
            vertical_grid_to_end_of_window=False,
            empty_horizontal=0, empty_vertical=0,
        )
        self.sheet.grid(row=0, column=0, sticky="nsew")
        self._sheet_frame = sheet_frame

        # 컬럼 비율 기반 리사이즈 바인딩
        if self.column_ratios:
            sheet_frame.bind("<Configure>", self._on_sheet_resize)
            sheet_frame.bind("<Map>", self._on_sheet_map)

        self.empty_overlay = tk.Label(
            sheet_frame, text="저장된 항목이 없습니다.",
            bg=styles.CARD_BG, fg=styles.TEXT_SUB,
            font=("Arial", 12), anchor="center",
        )

        self.sheet.enable_bindings(
            "single_select", "drag_select", "row_select", "column_select",
            "column_width_resize", "double_click_column_resize",
            "row_height_resize", "double_click_row_resize",
            "copy", "arrowkeys",
        )
        self.sheet.bind("<Double-Button-1>", lambda e: self._copy_selected_cell())
        self.sheet.bind("<ButtonRelease-1>", self._on_button_release)

        btn = ttk.Frame(parent, style="CardInner.TFrame")
        btn.pack(fill="x", pady=(6, 0))
        ttk.Button(btn, text="선택 수정",
                   command=self._edit_selected).pack(side="left", padx=(0, 4))
        ttk.Button(btn, text="선택 삭제", style="Danger.TButton",
                   command=self._delete_selected).pack(side="left", padx=(0, 4))
        ttk.Button(btn, text="삭제 취소",
                   command=self._undo_delete).pack(side="left", padx=(0, 4))
        ttk.Label(btn, text="( 셀 더블클릭 시 복사 )", style="CardSmall.TLabel").pack(
            side="left", padx=(8, 0))

        self.secret_toggle_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(btn, text=f"{self.secret_field} 표시",
                        style="Card.TCheckbutton",
                        variable=self.secret_toggle_var,
                        command=self._toggle_secrets).pack(side="right", padx=(4, 0))

    # ================================================================
    #  우측 패널 (입력 폼)
    # ================================================================
    def _build_right(self, parent):
        ttk.Label(parent, text=f"새 {self.tab_label} 추가",
                  style="CardTitle.TLabel").pack(pady=(0, 8))
        ttk.Separator(parent, orient="horizontal").pack(fill="x", pady=(0, 8))

        ttk.Label(parent, text="그룹", style="CardInner.TLabel").pack(anchor="w")
        self.group_combo = ttk.Combobox(parent, width=30)
        self.group_combo.pack(fill="x", pady=(0, 8))

        self.entries: dict[str, ttk.Entry] = {}
        for field in self.data_fields:
            lbl_frame = ttk.Frame(parent, style="CardInner.TFrame")
            lbl_frame.pack(anchor="w", pady=(2, 0))
            if field in self.required_fields:
                tk.Label(lbl_frame, text="*", fg=styles.DANGER,
                         bg=styles.CARD_BG,
                         font=("Arial", 10, "bold")).pack(side="left", padx=(0, 2))
            ttk.Label(lbl_frame, text=field, style="CardBold.TLabel").pack(side="left")

            frame = ttk.Frame(parent, style="CardInner.TFrame")
            frame.pack(fill="x", pady=(0, 4))
            show = "*" if field == self.secret_field else ""
            entry = ttk.Entry(frame, show=show)
            entry.pack(side="left", fill="x", expand=True)
            self.entries[field] = entry

            if field == self.secret_field:
                self.secret_show_btn = ttk.Button(
                    frame, text="표시", width=4, takefocus=False,
                    command=self._toggle_entry_show)
                self.secret_show_btn.pack(side="left", padx=(4, 0))
                if self.show_pw_generator:
                    ttk.Button(frame, text="생성", width=4, takefocus=False,
                               command=self._generate_password).pack(side="left", padx=(4, 0))

        ttk.Label(parent, text='* 필수값(중복 불가) / "-" 입력 시 비우기 및 중복 허용',
                  style="CardSmall.TLabel").pack(pady=(4, 8))
        ttk.Separator(parent, orient="horizontal").pack(fill="x", pady=(0, 8))

        ttk.Button(parent, text="저장", style="Accent.TButton",
                   command=self._save_entry).pack(fill="x", ipady=2)

    # ================================================================
    #  검색 디바운싱
    # ================================================================
    def _schedule_search(self):
        if self._search_after_id:
            self.cb.root.after_cancel(self._search_after_id)
        self._search_after_id = self.cb.root.after(SEARCH_DEBOUNCE_MS, self._do_search)

    def _do_search(self):
        self._search_after_id = None
        self._populate_sheet()

    # ================================================================
    #  시트 데이터
    # ================================================================
    def _update_group_combos(self, data: dict | None = None):
        if data is None:
            data = self.svc.get_all()
        groups = list(data.keys())

        self._group_label_map = {"전체": "전체"}
        group_labels = ["전체"]
        for g in groups:
            label = f"{g} ({len(data.get(g, []))})"
            group_labels.append(label)
            self._group_label_map[label] = g

        self.group_filter["values"] = group_labels
        if not self.group_filter.get() or self.group_filter.get() not in group_labels:
            self.group_filter.set("전체")

        self.group_combo["values"] = groups
        if groups and not self.group_combo.get():
            self.group_combo.current(0)

    def _populate_sheet(self, data: dict | None = None):
        self.rows.clear()
        if data is None:
            data = self.svc.get_all()
        selected_group = self._group_label_map.get(self.group_filter.get(), "전체")
        query = self.search_var.get().lower().strip()
        search_field = self._search_field_map.get(self.search_field_filter.get(), "전체 필드")
        keywords = query.split() if query else []

        for group_name, records in data.items():
            if selected_group != "전체" and group_name != selected_group:
                continue
            for rec in records:
                if keywords and not self._match(group_name, rec, search_field, keywords):
                    continue
                fav = rec.get("_fav", "") == "1"
                fav_star = "★" if fav else "☆"
                values = [fav_star, group_name] + [rec.get(f, "") for f in self.data_fields]
                real_secret = values[self.secret_idx]
                if not self.secret_visible:
                    values[self.secret_idx] = "●" * min(len(str(real_secret)), 12)
                self.rows.append(RowData(values, rec.id, group_name, real_secret))

        if self.rows:
            # 즐겨찾기 상단 정렬 (★ 먼저)
            self.rows.sort(key=lambda r: (0 if r.display[0] == "★" else 1))
            self.sheet.set_sheet_data([r.display for r in self.rows], reset_col_positions=False)
            self._apply_fav_colors()
            self.empty_overlay.place_forget()
        else:
            self.sheet.set_sheet_data([], reset_col_positions=False)
            self.empty_overlay.place(relx=0.5, rely=0.45, anchor="center")

        self.sheet.set_all_row_heights(height=None)
        self.sheet.readonly(self.sheet.span(":").expand())
        self.cb.set_status(f"총 {len(self.rows)}개 항목")

    def _reset_sort_and_populate(self):
        """정렬 상태 초기화 후 시트 갱신."""
        if self.sort_col is not None:
            self.sort_col = None
            self.sort_asc = True
            self.sheet.headers(self.display_fields)
        self._populate_sheet()

    def _refresh(self):
        data = self.svc.get_all()
        self._update_group_combos(data)
        self._populate_sheet(data)

    def _match(self, group: str, rec, search_field: str, keywords: list[str]) -> bool:
        if search_field == "전체 필드":
            haystack = (group + " " + " ".join(
                str(rec.get(f, "")) for f in self.data_fields)).lower()
        elif search_field == "그룹":
            haystack = group.lower()
        else:
            haystack = str(rec.get(search_field, "")).lower()
        return all(kw in haystack for kw in keywords)

    def _apply_fav_colors(self):
        pass

    def _on_sheet_resize(self, event=None):
        """창 크기 변경 시 컬럼 너비를 비율에 맞게 조정."""
        if not self.column_ratios:
            return
        # 디바운싱: 연속 리사이즈 이벤트에서 마지막 것만 처리
        if self._resize_after_id:
            self.cb.root.after_cancel(self._resize_after_id)
        self._resize_after_id = self.cb.root.after(50, self._apply_column_ratios)

    def _on_sheet_map(self, event=None):
        """시트가 화면에 표시될 때 컬럼 비율 적용."""
        if self.column_ratios:
            self.cb.root.after(50, self._apply_column_ratios)

    def _apply_column_ratios(self, retry_count=0):
        """실제 컬럼 너비 비율 적용."""
        self._resize_after_id = None
        if not self.column_ratios:
            return
        total_width = self._sheet_frame.winfo_width()
        if total_width <= 1:
            # 아직 위젯이 그려지지 않음 - 최대 10회 재시도
            if retry_count < 10:
                self.cb.root.after(100, lambda: self._apply_column_ratios(retry_count + 1))
            return
        # 스크롤바 여백 고려
        total_width -= 4
        min_width = 40
        for col, ratio in enumerate(self.column_ratios):
            if col < len(self.display_fields):
                width = max(int(total_width * ratio), min_width)
                self.sheet.column_width(column=col, width=width)

    def _on_button_release(self, event):
        """헤더 단일 클릭 시 정렬, 테이블 col=0 클릭 시 즐겨찾기 토글."""
        region = self.sheet.identify_region(event)
        if region == "header":
            col = self.sheet.identify_column(event, allow_end=False)
            if col is not None:
                # 컬럼 경계선 근처(5px 이내)면 리사이즈로 간주하여 정렬 무시
                try:
                    col_right = sum(self.sheet.column_width(c) for c in range(col + 1))
                    col_left = col_right - self.sheet.column_width(col)
                    x = event.x + self.sheet.xview()[0] * self.sheet.winfo_width()
                    if abs(x - col_right) <= 5 or abs(x - col_left) <= 5:
                        return
                except Exception:
                    pass
                class _FakeEvent:
                    def __init__(self, c):
                        self.column = c
                        self.selection_boxes = []
                self._on_column_header_click(_FakeEvent(col))
        elif region == "table":
            r = self.sheet.identify_row(event, allow_end=False)
            c = self.sheet.identify_column(event, allow_end=False)
            if r is not None and c == 0 and self.rows and r < len(self.rows):
                row = self.rows[r]
                is_fav = row.display[0] == "★"
                self.svc.update_fav(row.record_id, not is_fav)
                # 정렬 상태 + 헤더 아이콘 초기화
                if self.sort_col is not None:
                    self.sort_col = None
                    self.sort_asc = True
                    self.sheet.headers(self.display_fields)
                self._refresh()

    def _toggle_secrets(self):
        self.secret_visible = self.secret_toggle_var.get()
        for row in self.rows:
            row.display[self.secret_idx] = (
                row.real_secret if self.secret_visible
                else "●" * min(len(str(row.real_secret)), 12)
            )
        if self.rows:
            self.sheet.set_sheet_data([r.display for r in self.rows], reset_col_positions=False)
            self.sheet.set_all_row_heights(height=None)
            self.sheet.readonly(self.sheet.span(":").expand())

    # ================================================================
    #  항목 저장
    # ================================================================
    def _save_entry(self):
        group = self.group_combo.get().strip()
        if not group:
            messagebox.showerror("오류", "그룹을 선택하거나 입력하세요.")
            return
        fields = {f: self.entries[f].get() for f in self.data_fields}
        for rf in self.required_fields:
            if not fields.get(rf):
                messagebox.showerror("오류", "필수 입력 항목을 모두 채워주세요.")
                return
        try:
            self.svc.add_record(group, fields)
        except DuplicateError as e:
            messagebox.showerror("중복 오류", str(e))
            return
        for e in self.entries.values():
            e.delete(0, tk.END)
        self._refresh()
        self.group_combo.set(group)

    # ================================================================
    #  선택 항목 수정/삭제
    # ================================================================
    def _get_selected_row_data(self) -> RowData | None:
        idx = None
        selected = self.sheet.get_selected_rows()
        if selected:
            idx = list(selected)[0]
        else:
            cells = self.sheet.get_selected_cells()
            if cells:
                idx = list(cells)[0][0]
        if idx is None or not self.rows or idx >= len(self.rows):
            messagebox.showwarning("선택 없음", "항목을 선택하세요.")
            return None
        return self.rows[idx]

    def _delete_selected(self):
        row = self._get_selected_row_data()
        if not row:
            return
        name = row.display[1]
        if not messagebox.askyesno("삭제 확인", f"'{name}' 항목을 삭제하시겠습니까?"):
            return
        result = self.svc.delete_record(row.record_id)
        if result:
            group, removed = result
            self.delete_stack.append((group, dict(removed.fields), removed.id))
        self._refresh()
        self.cb.set_status(f"'{name}' 삭제됨 — [삭제 취소] 버튼으로 복구 가능")

    def _undo_delete(self):
        if not self.delete_stack:
            messagebox.showinfo("실행취소", "복구할 삭제 내역이 없습니다.")
            return
        group, fields, _ = self.delete_stack.pop()
        try:
            self.svc.add_record(group, fields)
        except DuplicateError as e:
            messagebox.showerror("복구 실패", str(e))
            return
        self._refresh()
        name_field = self.data_fields[0]
        self.cb.set_status(f"'{fields.get(name_field, '')}' 복구 완료")

    def _edit_selected(self):
        row = self._get_selected_row_data()
        if not row:
            return
        result = self.svc.find_record(row.record_id)
        if not result:
            return
        old_group, _, rec = result

        def on_save(new_fields: dict, win: tk.Toplevel, new_group: str):
            try:
                self.svc.update_record(row.record_id, new_fields)
                if new_group and new_group != old_group:
                    self.svc.move_record(row.record_id, new_group)
            except (DuplicateError, ValueError) as e:
                messagebox.showerror("오류", str(e))
                return
            win.destroy()
            self._refresh()

        EditDialog(self.cb.root, self.data_fields, rec.fields, on_save,
                   secret_field=self.secret_field,
                   group=old_group, groups=self.svc.get_groups())

    # ================================================================
    #  셀 복사 + 클립보드 자동 삭제
    # ================================================================
    def _copy_selected_cell(self):
        cells = self.sheet.get_selected_cells()
        if not cells:
            return
        r, c = list(cells)[0]
        if not self.rows or r >= len(self.rows):
            return
        value = (self.rows[r].real_secret if c == self.secret_idx
                 else self.sheet.get_cell_data(r, c))
        field_name = self.display_fields[c]
        self.cb.copy_to_clipboard(value, field_name)

    # ================================================================
    #  그룹 관리
    # ================================================================
    def _rename_group(self):
        current = self._group_label_map.get(self.group_filter.get(), "전체")
        if current == "전체":
            messagebox.showwarning("선택 오류", "이름을 변경할 그룹을 선택하세요.")
            return
        new_name = simpledialog.askstring("그룹 이름 변경", "새 그룹 이름:", initialvalue=current)
        if not new_name or new_name == current:
            return
        ok, msg = self.svc.rename_group(current, new_name)
        if not ok:
            messagebox.showerror("오류", msg)
            return
        data = self.svc.get_all()
        self._update_group_combos(data)
        cnt = len(data.get(new_name, []))
        self.group_filter.set(f"{new_name} ({cnt})")
        self._populate_sheet(data)

    def _delete_group(self):
        current = self._group_label_map.get(self.group_filter.get(), "전체")
        if current == "전체":
            messagebox.showwarning("선택 오류", "삭제할 그룹을 선택하세요.")
            return
        cnt = len(self.svc.get_all().get(current, []))
        if not messagebox.askyesno("그룹 삭제",
                                   f"'{current}' 그룹 ({cnt}개 항목)을 삭제하시겠습니까?",
                                   icon="warning"):
            return
        self.svc.delete_group(current)
        self._refresh()
        self.group_filter.set("전체")

    # ================================================================
    #  비밀번호 생성 / 입력 토글
    # ================================================================
    def _generate_password(self):
        PasswordGeneratorDialog(self.cb.root, lambda pw: (
            self.entries[self.secret_field].delete(0, tk.END),
            self.entries[self.secret_field].insert(0, pw),
        ))

    def _toggle_entry_show(self):
        entry = self.entries[self.secret_field]
        current = entry.cget("show")
        entry.config(show="" if current == "*" else "*")
        self.secret_show_btn.config(text="숨김" if current == "*" else "표시")

    # ================================================================
    #  CSV
    # ================================================================
    def export_csv(self):
        if not messagebox.askyesno("CSV 내보내기 경고",
                                   f"{self.secret_field}이(가) 평문으로 저장됩니다.\n계속하시겠습니까?",
                                   icon="warning"):
            return
        path = filedialog.asksaveasfilename(
            defaultextension=".csv", filetypes=[("CSV", "*.csv")], title="CSV 내보내기")
        if path:
            self.svc.export_csv(path, self.data_fields)
            self.cb.set_status(f"내보내기 완료: {path}")

    def import_csv(self):
        path = filedialog.askopenfilename(
            filetypes=[("CSV", "*.csv")], title="CSV 가져오기")
        if not path:
            return
        added, skipped = self.svc.import_csv(path, self.data_fields)
        self._refresh()
        self.cb.set_status(f"가져오기 완료: {added}개 추가, {skipped}개 중복 건너뜀")

    # ================================================================
    #  정렬
    # ================================================================
    def _on_column_header_click(self, event):
        col = None
        if hasattr(event, "column") and event.column is not None:
            col = event.column
        elif hasattr(event, "selection_boxes") and event.selection_boxes:
            for box in event.selection_boxes:
                col = box[1]
                break

        self.cb.root.after_idle(self.sheet.deselect)

        if col is None or col == 0 or not self.rows:
            return

        if self.sort_col == col:
            if self.sort_asc:
                self.sort_asc = False
            else:
                self.sort_col = None
                self.sort_asc = True
                self.sheet.headers(self.display_fields)
                self._populate_sheet()
                return
        else:
            self.sort_col = col
            self.sort_asc = True

        self.rows.sort(
            key=lambda r: (r.real_secret if col == self.secret_idx
                           else str(r.display[col])).lower(),
            reverse=not self.sort_asc,
        )

        arrow = " ▲" if self.sort_asc else " ▼"
        self.sheet.headers([
            f + (arrow if i == col else "")
            for i, f in enumerate(self.display_fields)
        ])
        self.sheet.set_sheet_data([r.display for r in self.rows], reset_col_positions=False)
        self.sheet.set_all_row_heights(height=None)
        self.sheet.readonly(self.sheet.span(":").expand())
