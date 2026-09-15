"""UI 색상 팔레트 및 ttk 스타일 설정."""

import tkinter as tk
from tkinter import ttk


# ================================================================
#  색상 팔레트
# ================================================================
BG = "#f5f6fa"
CARD_BG = "#ffffff"
ACCENT = "#3b82f6"
ACCENT_HOVER = "#2563eb"
DANGER = "#ef4444"
DANGER_HOVER = "#dc2626"
TEXT = "#1e293b"
TEXT_SUB = "#64748b"
BORDER = "#e2e8f0"
HEADER_BG = "#334155"
HEADER_FG = "#ffffff"
ROW_ALT = "#eef2f7"


def apply_style(root: tk.Tk):
    """전역 ttk 스타일을 적용한다."""
    root.configure(bg=BG)
    style = ttk.Style()
    style.theme_use("clam")

    style.configure(".", background=BG, foreground=TEXT, font=("Arial", 10))
    style.configure("TFrame", background=BG)
    style.configure("TLabel", background=BG, foreground=TEXT)
    style.configure("TPanedwindow", background=BORDER)
    style.configure("Title.TLabel", font=("Arial", 13, "bold"), foreground=TEXT)
    style.configure("Small.TLabel", font=("Arial", 9), foreground=TEXT_SUB)

    style.configure("Card.TFrame", background=CARD_BG, relief="solid", borderwidth=1)
    style.configure("CardInner.TFrame", background=CARD_BG)
    style.configure("CardInner.TLabel", background=CARD_BG, foreground=TEXT)
    style.configure("CardTitle.TLabel", background=CARD_BG, foreground=TEXT,
                    font=("Arial", 13, "bold"))
    style.configure("CardSmall.TLabel", background=CARD_BG, foreground=TEXT_SUB,
                    font=("Arial", 9))
    style.configure("CardBold.TLabel", background=CARD_BG, foreground=TEXT,
                    font=("Arial", 10, "bold"))

    style.configure("TButton", font=("Arial", 10), padding=(8, 4))
    style.map("TButton", background=[("active", "#e2e8f0"), ("!active", CARD_BG)])

    style.configure("Accent.TButton", font=("Arial", 10, "bold"),
                    foreground="white", padding=(10, 5))
    style.map("Accent.TButton",
              background=[("active", ACCENT_HOVER), ("!active", ACCENT)],
              foreground=[("active", "white"), ("!active", "white")])

    style.configure("Danger.TButton", font=("Arial", 10),
                    foreground="white", padding=(8, 4))
    style.map("Danger.TButton",
              background=[("active", DANGER_HOVER), ("!active", DANGER)],
              foreground=[("active", "white"), ("!active", "white")])

    style.configure("TCombobox", padding=3)
    style.configure("TEntry", padding=4)

    style.configure("Status.TFrame", background=CARD_BG)
    style.configure("Status.TLabel", background=CARD_BG, foreground=TEXT_SUB,
                    font=("Arial", 9))
    style.configure("StatusTimer.TLabel", background=CARD_BG, foreground=DANGER,
                    font=("Arial", 9, "bold"))

    style.configure("Card.TCheckbutton", background=CARD_BG, foreground=TEXT)
    style.configure("TNotebook", background=BG)
    style.configure("TNotebook.Tab", font=("Arial", 11, "bold"), padding=(16, 6))
