"""
암호화/복호화 및 마스터 비밀번호 모듈.
- Argon2id로 마스터 비밀번호 검증
- PBKDF2HMAC(SHA-256, 600,000 iterations)으로 Fernet 키 파생
- 마스터 비밀번호 변경 (원자적 처리 + 롤백)
"""

import os
import json
import base64
import shutil
import stat
import logging

from cryptography.fernet import Fernet
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
from cryptography.hazmat.primitives import hashes
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError

log = logging.getLogger(__name__)
ph = PasswordHasher()

PBKDF2_ITERATIONS = 600_000
KEY_HASH = "password_hash"
KEY_SALT = "salt"


class KeyFileError(Exception):
    """키 파일 관련 오류."""


class AuthenticationError(Exception):
    """마스터 비밀번호 인증 실패."""


def _zero(ba: bytearray):
    """bytearray를 0으로 덮어쓴다."""
    for i in range(len(ba)):
        ba[i] = 0


def _derive_key(password: bytes, salt: bytes, iterations: int = PBKDF2_ITERATIONS) -> bytes:
    kdf = PBKDF2HMAC(algorithm=hashes.SHA256(), length=32, salt=salt, iterations=iterations)
    return base64.urlsafe_b64encode(kdf.derive(password))


def _read_key_file(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def _write_key_file(path: str, data: dict):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)


def _new_key_data(password: str, salt: bytes) -> dict:
    return {
        KEY_HASH: ph.hash(password),
        KEY_SALT: base64.b64encode(salt).decode("ascii"),
    }


def verify_and_derive_key(password: str, master_key_file: str) -> Fernet:
    """
    마스터 비밀번호를 검증하고 Fernet 객체를 반환한다.
    최초 실행 시 키 파일을 생성한다.
    비밀번호는 bytearray로 변환 후 사용 완료 시 제로화한다.

    Raises:
        KeyFileError: 키 파일 손상, 필수 필드 누락, I/O 오류
        AuthenticationError: 비밀번호 불일치
    """
    pw_ba = bytearray(password, "utf-8")
    try:
        if not os.path.exists(master_key_file):
            salt = os.urandom(64)
            _write_key_file(master_key_file, _new_key_data(password, salt))
            return Fernet(_derive_key(bytes(pw_ba), salt))

        try:
            data = _read_key_file(master_key_file)
        except json.JSONDecodeError as e:
            log.error("키 파일 JSON 파싱 실패: %s", e)
            raise KeyFileError(f"키 파일이 손상되었습니다: {e}") from e
        except OSError as e:
            log.error("키 파일 읽기 실패: %s", e)
            raise KeyFileError(f"키 파일을 읽을 수 없습니다: {e}") from e

        pw_hash = data.get(KEY_HASH)
        salt_b64 = data.get(KEY_SALT)
        if not pw_hash or not salt_b64:
            raise KeyFileError("키 파일에 필수 필드(password_hash, salt)가 없습니다.")

        try:
            ph.verify(pw_hash, password)
        except VerifyMismatchError:
            raise AuthenticationError("비밀번호가 올바르지 않습니다.")

        salt = base64.b64decode(salt_b64)
        return Fernet(_derive_key(bytes(pw_ba), salt))
    finally:
        _zero(pw_ba)


def _atomic_replace(tmp_path: str, target_path: str, backup_path: str):
    """백업 생성 → 원본 교체 헬퍼."""
    if os.path.exists(target_path):
        shutil.copy2(target_path, backup_path)
    os.replace(tmp_path, target_path)


def change_master_password(
    old_password: str, new_password: str,
    master_key_file: str, data_file: str,
) -> tuple[bool, str]:
    """
    마스터 비밀번호를 변경한다.
    원자적 처리: 임시 파일에 먼저 쓰고, 모두 성공하면 원본을 교체한다.
    실패 시 백업에서 롤백한다.
    비밀번호는 bytearray로 변환 후 사용 완료 시 제로화한다.
    """
    new_pw_ba = bytearray(new_password, "utf-8")
    try:
        try:
            old_fernet = verify_and_derive_key(old_password, master_key_file)
        except AuthenticationError:
            return False, "기존 비밀번호가 올바르지 않습니다."
        except KeyFileError as e:
            return False, str(e)

        # @ 기존 데이터 복호화
        plain_data = b""
        if os.path.exists(data_file):
            with open(data_file, "rb") as f:
                enc = f.read()
            if enc:
                try:
                    plain_data = old_fernet.decrypt(enc)
                except Exception:
                    return False, "기존 데이터 복호화에 실패했습니다."

        new_salt = os.urandom(64)
        new_fernet = Fernet(_derive_key(bytes(new_pw_ba), new_salt))

        tmp_key = master_key_file + ".tmp"
        tmp_data = data_file + ".tmp"
        backup_key = master_key_file + ".bak"
        backup_data = data_file + ".bak"
        temps = (tmp_key, tmp_data, backup_key, backup_data)

        try:
            _write_key_file(tmp_key, _new_key_data(new_password, new_salt))
            if plain_data:
                with open(tmp_data, "wb") as f:
                    f.write(new_fernet.encrypt(plain_data))
                os.chmod(tmp_data, stat.S_IRUSR | stat.S_IWUSR)

            _atomic_replace(tmp_key, master_key_file, backup_key)
            if plain_data:
                _atomic_replace(tmp_data, data_file, backup_data)

            for p in (backup_key, backup_data):
                if os.path.exists(p):
                    os.remove(p)
            return True, "마스터 비밀번호가 변경되었습니다."

        except Exception as e:
            log.error("마스터 비밀번호 변경 중 오류, 롤백 시도: %s", e)
            for bak, orig in ((backup_key, master_key_file), (backup_data, data_file)):
                if os.path.exists(bak):
                    shutil.copy2(bak, orig)
            for p in temps:
                if os.path.exists(p):
                    os.remove(p)
            return False, f"비밀번호 변경 중 오류가 발생하여 롤백되었습니다: {e}"
    finally:
        _zero(new_pw_ba)
