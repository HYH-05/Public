"""
진입점 — 마스터 비밀번호 인증 후 GUI 실행.
복호화 실패 시 앱 시작을 차단한다.
실행 시 data.enc 백업을 자동 생성한다.
"""

import tkinter as tk
from tkinter import messagebox
import os
import sys
import shutil
import logging

from crypto import verify_and_derive_key, KeyFileError, AuthenticationError
from storage import Storage, DataCorruptionError
from service import PasswordService
from gui import PasswordManagerApp
from dialogs import MasterPasswordDialog
from constants import NAME_FIELD, IP_FIELD, KEY_NAME_FIELD, KEY_VALUE_FIELD, NS_PASSWORDS, NS_KEYS, NS_AWS, NS_TOTP, AWS_ACCESS_FIELD, AWS_SECRET_FIELD, TOTP_NAME_FIELD, TOTP_SECRET_FIELD

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger(__name__)


def get_base_dir():
    if getattr(sys, "frozen", False):
        return os.path.dirname(sys.executable)
    return os.path.dirname(os.path.abspath(__file__))


def _backup_data(data_file: str):
    if os.path.exists(data_file):
        bak = data_file + ".bak"
        shutil.copy2(data_file, bak)
        log.info("데이터 백업 완료: %s", bak)


def main():
    base = get_base_dir()
    keys_dir = os.path.join(base, "keys")
    data_dir = os.path.join(base, "data")
    os.makedirs(keys_dir, exist_ok=True)
    os.makedirs(data_dir, exist_ok=True)

    master_key_file = os.path.join(keys_dir, "blue_archive.json")
    data_file = os.path.join(data_dir, "data.enc")

    _backup_data(data_file)

    while True:
        dlg = MasterPasswordDialog()
        pw = dlg.result
        if pw is None:
            return
        if not pw:
            messagebox.showerror("오류", "비밀번호를 입력해야 합니다.")
            continue
        try:
            fernet = verify_and_derive_key(pw, master_key_file)
            break
        except AuthenticationError as e:
            messagebox.showerror("인증 실패", str(e))
        except KeyFileError as e:
            messagebox.showerror("키 파일 오류", str(e))
            return
        finally:
            pw = ""

    try:
        storage = Storage(data_file, fernet)
    except DataCorruptionError as e:
        messagebox.showerror("데이터 오류", str(e))
        return

    root = tk.Tk()

    def _on_save_error(msg: str):
        root.after(0, lambda: messagebox.showerror("저장 오류", msg))

    pw_svc = PasswordService(storage, NS_PASSWORDS,
                             unique_fields=[NAME_FIELD, IP_FIELD],
                             on_save_error=_on_save_error)
    key_svc = PasswordService(storage, NS_KEYS,
                              unique_fields=[KEY_NAME_FIELD, KEY_VALUE_FIELD],
                              on_save_error=_on_save_error)
    aws_svc = PasswordService(storage, NS_AWS,
                              unique_fields=[AWS_ACCESS_FIELD, AWS_SECRET_FIELD],
                              on_save_error=_on_save_error)
    totp_svc = PasswordService(storage, NS_TOTP,
                               unique_fields=[TOTP_NAME_FIELD, TOTP_SECRET_FIELD],
                               on_save_error=_on_save_error)

    app = PasswordManagerApp(root, pw_svc, key_svc, aws_svc, totp_svc, master_key_file, data_file)

    # X 버튼은 gui.py에서 처리 (트레이 최소화/종료 선택)
    # root.protocol은 gui.py __init__에서 설정됨

    root.mainloop()


if __name__ == "__main__":
    main()
