"""플로팅 검색창 — 트레이/단축키로 호출되는 빠른 검색 UI"""

import tkinter as tk
from tkinter import ttk

try:
    import pyotp
    HAS_TOTP = True
except ImportError:
    HAS_TOTP = False


class FloatingSearchWindow:
    """플로팅 검색창 — 트레이/단축키로 호출되는 빠른 검색 UI"""

    # 탭별 컬럼 정의
    TAB_COLUMNS = {
        "password": ("⭐", "이름", "IP", "계정", "비고"),
        "key": ("⭐", "이름", "서비스/플랫폼", "연결 계정", "비고"),
        "aws": ("⭐", "그룹", "연결 계정", "액세스 키", "비고"),
        "totp": ("⭐", "이름", "서비스/사이트", "계정", "비고"),
    }
    TAB_KEYS = ["password", "key", "aws", "totp"]
    TAB_LABELS = [("🔒 비밀번호", "password"), ("🔑 키", "key"), ("☁ AWS", "aws"), ("🔐 OTP", "totp")]

    # 색상
    BG = "#1e1e2e"
    CARD_BG = "#2a2a3e"
    TEXT = "#cdd6f4"
    ACCENT = "#89b4fa"
    ROW_ODD = "#2a2a3e"
    ROW_EVEN = "#1e1e2e"

    def __init__(self, root: tk.Tk, services: dict, copy_callback):
        self.root = root
        self.services = services  # {'pw': svc, 'key': svc, 'aws': svc, 'totp': svc}
        self.copy_callback = copy_callback
        self.window = None
        self._all_records = []
        self._tab_trees = {}
        self._tab_results = {}

    def show(self):
        """검색창 표시"""
        if self.window and self.window.winfo_exists():
            self.window.lift()
            self.window.focus_force()
            self._search_entry.focus_set()
            self._search_entry.select_range(0, tk.END)
            return

        self._load_all_records()
        self._create_window()
        self._on_search()

    def _load_all_records(self):
        """모든 서비스에서 레코드 로드"""
        self._all_records = []

        # 비밀번호
        for group, records in self.services['pw'].get_all().items():
            for rec in records:
                self._all_records.append({
                    'type_name': 'password', 'group': group,
                    'name': rec.fields.get('이름(중복 불가)', ''),
                    'address': rec.fields.get('IP/도메인(중복 불가)', ''),
                    'account': rec.fields.get('ID/이메일', ''),
                    'note': rec.fields.get('비고', ''),
                    'secret': rec.fields.get('비밀번호', ''),
                    'fav': rec.fields.get('_fav', '0') == '1',
                })

        # 키
        for group, records in self.services['key'].get_all().items():
            for rec in records:
                self._all_records.append({
                    'type_name': 'key', 'group': group,
                    'name': rec.fields.get('이름(중복 불가)', ''),
                    'address': rec.fields.get('서비스/플랫폼', ''),
                    'account': rec.fields.get('연결 계정/이메일', ''),
                    'note': rec.fields.get('비고', ''),
                    'secret': rec.fields.get('키 값(중복 불가)', ''),
                    'fav': rec.fields.get('_fav', '0') == '1',
                })

        # AWS
        for group, records in self.services['aws'].get_all().items():
            for rec in records:
                self._all_records.append({
                    'type_name': 'aws', 'group': group,
                    'name': rec.fields.get('연결 계정', ''),
                    'address': '',
                    'account': '',
                    'access_key': rec.fields.get('액세스 키(중복 불가)', ''),
                    'note': rec.fields.get('비고', ''),
                    'secret': rec.fields.get('시크릿 키(중복 불가)', ''),
                    'fav': rec.fields.get('_fav', '0') == '1',
                })

        # TOTP
        for group, records in self.services['totp'].get_all().items():
            for rec in records:
                self._all_records.append({
                    'type_name': 'totp', 'group': group,
                    'name': rec.fields.get('이름(중복 불가)', ''),
                    'address': rec.fields.get('서비스/사이트', ''),
                    'account': rec.fields.get('계정', ''),
                    'note': rec.fields.get('비고', ''),
                    'secret': rec.fields.get('시크릿 키(중복 불가)', ''),
                    'password': rec.fields.get('패스워드', ''),
                    'fav': rec.fields.get('_fav', '0') == '1',
                })

        # 즐겨찾기 우선 정렬
        self._all_records.sort(key=lambda x: (not x['fav'], x['name'].lower()))

    def _create_window(self):
        """검색창 윈도우 생성"""
        win = tk.Toplevel(self.root)
        self.window = win
        win.title("🔍 검색")
        win.attributes("-topmost", True)
        win.configure(bg=self.BG)
        win.resizable(True, True)

        # 화면 중앙
        w, h = 550, 500
        x = (win.winfo_screenwidth() - w) // 2
        y = (win.winfo_screenheight() - h) // 3
        win.geometry(f"{w}x{h}+{x}+{y}")
        win.minsize(400, 300)

        self._build_search_entry(win)
        self._build_notebook(win)
        self._build_hint(win)
        self._bind_keys(win)

    def _build_search_entry(self, win):
        """검색 입력 필드"""
        frame = tk.Frame(win, bg=self.BG)
        frame.pack(fill="x", padx=10, pady=10)

        tk.Label(frame, text="🔍", bg=self.BG, fg=self.TEXT,
                 font=("Segoe UI Emoji", 14)).pack(side="left", padx=(0, 8))

        self._search_var = tk.StringVar()
        self._search_var.trace_add("write", lambda *_: self._on_search())

        self._search_entry = tk.Entry(
            frame, textvariable=self._search_var,
            font=("맑은 고딕", 12), bg=self.CARD_BG, fg=self.TEXT,
            insertbackground=self.TEXT, relief="flat", highlightthickness=0
        )
        self._search_entry.pack(fill="x", expand=True, ipady=6)
        self._search_entry.focus_set()

    def _build_notebook(self, win):
        """탭 노트북 + 트리뷰"""
        style = ttk.Style()
        style.configure("Search.TNotebook", background=self.BG)
        style.configure("Search.TNotebook.Tab", padding=[10, 5], font=("맑은 고딕", 9))
        style.configure("Search.Treeview", background=self.CARD_BG, foreground=self.TEXT,
                        fieldbackground=self.CARD_BG, rowheight=25, font=("맑은 고딕", 9))
        style.configure("Search.Treeview.Heading", background=self.BG, foreground=self.TEXT,
                        font=("맑은 고딕", 9, "bold"))
        style.map("Search.Treeview", background=[("selected", self.ACCENT)],
                  foreground=[("selected", self.BG)])

        self._notebook = ttk.Notebook(win, style="Search.TNotebook")
        self._notebook.pack(fill="both", expand=True, padx=10, pady=(0, 5))

        self._tab_trees = {}
        self._tab_results = {}

        for tab_text, tab_key in self.TAB_LABELS:
            frame = tk.Frame(self._notebook, bg=self.BG)
            self._notebook.add(frame, text=tab_text)

            cols = self.TAB_COLUMNS[tab_key]
            tree = ttk.Treeview(frame, columns=cols, show="headings", style="Search.Treeview")

            tree.tag_configure("odd", background=self.ROW_ODD)
            tree.tag_configure("even", background=self.ROW_EVEN)

            for col in cols:
                tree.heading(col, text=col, anchor="w")
                if col == "⭐":
                    tree.column(col, width=30, minwidth=30, stretch=False, anchor="center")
                elif col == "비고":
                    tree.column(col, width=150, minwidth=100, stretch=True, anchor="w")
                else:
                    tree.column(col, width=120, minwidth=80, stretch=True, anchor="w")

            tree.pack(side="left", fill="both", expand=True)

            scrollbar = ttk.Scrollbar(frame, orient="vertical", command=tree.yview)
            tree.configure(yscrollcommand=scrollbar.set)
            scrollbar.pack(side="right", fill="y")

            tree.bind("<Double-Button-1>", lambda e, k=tab_key: self._copy_from_tab(k))
            tree.bind("<Return>", lambda e, k=tab_key: self._copy_from_tab(k))

            if tab_key == "aws":
                tree.bind("<Button-3>", self._show_aws_context_menu)

            self._tab_trees[tab_key] = tree
            self._tab_results[tab_key] = []

    def _build_hint(self, win):
        """하단 안내"""
        frame = tk.Frame(win, bg=self.CARD_BG)
        frame.pack(fill="x", padx=10, pady=(0, 10))
        tk.Label(frame, text="Enter: 복사  |  Esc: 닫기  |  ↑↓: 이동  |  Ctrl+Tab: 탭 전환",
                 bg=self.CARD_BG, fg="#6c7086", font=("맑은 고딕", 8)).pack(pady=4)

    def _bind_keys(self, win):
        """키 바인딩"""
        win.bind("<Escape>", lambda e: self.close())
        win.bind("<Return>", lambda e: self._copy_from_current_tab())
        win.bind("<Up>", lambda e: self._select_prev())
        win.bind("<Down>", lambda e: self._select_next())

    def _get_current_tab_key(self):
        """현재 탭 키"""
        idx = self._notebook.index(self._notebook.select())
        return self.TAB_KEYS[idx]

    def _on_search(self):
        """검색 실행"""
        query = self._search_var.get().lower() if hasattr(self, '_search_var') else ""

        for tab_key in self.TAB_KEYS:
            results = []
            for rec in self._all_records:
                if rec['type_name'] != tab_key:
                    continue
                if query:
                    searchable = f"{rec['name']} {rec['address']} {rec['group']} {rec.get('account','')} {rec.get('note','')} {rec.get('access_key','')}".lower()
                    if query not in searchable:
                        continue
                results.append(rec)

            self._tab_results[tab_key] = results[:100]

            tree = self._tab_trees.get(tab_key)
            if tree:
                tree.delete(*tree.get_children())
                for i, rec in enumerate(self._tab_results[tab_key]):
                    fav = "⭐" if rec.get('fav') else ""
                    row_tag = "odd" if i % 2 == 0 else "even"
                    values = self._get_row_values(tab_key, rec, fav)
                    tree.insert("", tk.END, values=values, tags=(row_tag,))

                children = tree.get_children()
                if children:
                    tree.selection_set(children[0])
                    tree.focus(children[0])

    def _get_row_values(self, tab_key, rec, fav):
        """탭별 행 값 반환"""
        if tab_key == 'password':
            return (fav, rec['name'], rec['address'], rec.get('account', ''), rec.get('note', ''))
        elif tab_key == 'key':
            return (fav, rec['name'], rec['address'], rec.get('account', ''), rec.get('note', ''))
        elif tab_key == 'aws':
            return (fav, rec['group'], rec['name'], rec.get('access_key', ''), rec.get('note', ''))
        elif tab_key == 'totp':
            return (fav, rec['name'], rec['address'], rec.get('account', ''), rec.get('note', ''))
        return (fav, rec['name'], rec['address'], rec.get('account', ''), rec.get('note', ''))

    def _select_prev(self):
        """이전 항목 선택"""
        tree = self._tab_trees.get(self._get_current_tab_key())
        if not tree:
            return
        sel = tree.selection()
        if sel:
            children = tree.get_children()
            idx = children.index(sel[0])
            if idx > 0:
                tree.selection_set(children[idx - 1])
                tree.focus(children[idx - 1])
                tree.see(children[idx - 1])

    def _select_next(self):
        """다음 항목 선택"""
        tree = self._tab_trees.get(self._get_current_tab_key())
        if not tree:
            return
        sel = tree.selection()
        if sel:
            children = tree.get_children()
            idx = children.index(sel[0])
            if idx < len(children) - 1:
                tree.selection_set(children[idx + 1])
                tree.focus(children[idx + 1])
                tree.see(children[idx + 1])

    def _copy_from_current_tab(self):
        """현재 탭에서 복사"""
        self._copy_from_tab(self._get_current_tab_key())

    def _copy_from_tab(self, tab_key):
        """탭에서 선택 항목 복사"""
        tree = self._tab_trees.get(tab_key)
        results = self._tab_results.get(tab_key, [])

        if not tree or not results:
            return

        sel = tree.selection()
        if not sel:
            return

        children = tree.get_children()
        idx = children.index(sel[0])
        rec = results[idx]

        if rec['type_name'] == 'totp':
            pw = rec.get('password', '')
            otp = self._get_otp_code(rec['secret'])
            value = f"{pw}{otp}" if pw else otp
        else:
            value = rec['secret']

        self.copy_callback(value, rec['name'])

    def _show_aws_context_menu(self, event):
        """AWS 우클릭 메뉴"""
        tree = self._tab_trees.get("aws")
        if not tree:
            return

        item = tree.identify_row(event.y)
        if item:
            tree.selection_set(item)
            tree.focus(item)

        sel = tree.selection()
        if not sel:
            return

        menu = tk.Menu(self.window, tearoff=0, bg=self.CARD_BG, fg=self.TEXT,
                       activebackground=self.ACCENT, activeforeground=self.BG)
        menu.add_command(label="🔑 액세스 키 복사", command=lambda: self._copy_aws_key("access"))
        menu.add_command(label="🔐 시크릿 키 복사", command=lambda: self._copy_aws_key("secret"))
        menu.add_separator()
        menu.add_command(label="📋 둘 다 복사 (액세스:시크릿)", command=lambda: self._copy_aws_key("both"))
        menu.tk_popup(event.x_root, event.y_root)

    def _copy_aws_key(self, key_type):
        """AWS 키 복사"""
        tree = self._tab_trees.get("aws")
        results = self._tab_results.get("aws", [])

        if not tree or not results:
            return

        sel = tree.selection()
        if not sel:
            return

        children = tree.get_children()
        idx = children.index(sel[0])
        rec = results[idx]

        if key_type == "access":
            value = rec.get('access_key', '')
            name = f"{rec['name']} (액세스 키)"
        elif key_type == "secret":
            value = rec.get('secret', '')
            name = f"{rec['name']} (시크릿 키)"
        else:
            value = f"{rec.get('access_key', '')}:{rec.get('secret', '')}"
            name = f"{rec['name']} (액세스:시크릿)"

        self.copy_callback(value, name)

    @staticmethod
    def _get_otp_code(secret: str) -> str:
        """TOTP 코드 생성"""
        if not HAS_TOTP or not secret:
            return ""
        try:
            totp = pyotp.TOTP(secret.replace(" ", "").upper())
            return totp.now()
        except Exception:
            return ""

    def close(self):
        """검색창 닫기"""
        if self.window:
            self.window.destroy()
            self.window = None
