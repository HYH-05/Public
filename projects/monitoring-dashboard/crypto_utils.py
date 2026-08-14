
import base64
import os
import sys
from cryptography.fernet import Fernet, InvalidToken
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC

# @ 암호화된 문자열 앞에 붙일 고정된 접두사
ENCRYPTION_PREFIX = "enc::"

# @ 키 파생(derivation)에 사용할 고정된 솔트(salt).
# @ 동일한 비밀번호로부터 항상 동일한 키를 생성하기 위해 필요합니다.
SALT = b'infratech-monitoring-salt-v1'


def derive_key(secret_key: str) -> bytes:
  """
  사용자가 제공한 문자열 비밀 키로부터 암호화에 사용할 32바이트 키를 파생시킵니다.
  """
  kdf = PBKDF2HMAC(
      algorithm=hashes.SHA256(),
      length=32,
      salt=SALT,
      iterations=480000,  # @ OWASP 권장 사항 반복 횟수
  )
  # @ 키를 URL-safe Base64로 인코딩하여 Fernet 요구사항에 맞춥니다.
  return base64.urlsafe_b64encode(kdf.derive(secret_key.encode()))


class Encryptor:
  """
  Fernet 대칭 암호화를 사용하여 문자열 데이터를 암호화하고 복호화하는 클래스.
  """

  def __init__(self, secret_key: str):
    try:
      key = derive_key(secret_key)
      self.fernet = Fernet(key)
    except Exception as e:
      print(f"오류: 암호화 키 초기화 중 심각한 오류 발생: {e}", file=sys.stderr)
      sys.exit(1)

  def encrypt(self, data: str) -> str:
    """
    주어진 문자열을 암호화하고, 암호화되었음을 나타내는 접두사를 붙여 반환합니다.
    """
    if not isinstance(data, str) or not data:
      return data

    encrypted_data = self.fernet.encrypt(data.encode('utf-8'))
    return f"{ENCRYPTION_PREFIX}{encrypted_data.decode('utf-8')}"

  def decrypt(self, data: str) -> str:
    """
    암호화된 문자열에서 접두사를 확인하고 데이터를 복호화합니다.
    접두사가 없으면 평문으로 간주하고 그대로 반환합니다.
    """
    if not isinstance(data, str) or not data.startswith(ENCRYPTION_PREFIX):
      return data  # @ 평문 데이터는 그대로 반환

    token = data[len(ENCRYPTION_PREFIX):].encode('utf-8')

    try:
      decrypted_data = self.fernet.decrypt(token)
      return decrypted_data.decode('utf-8')
    except InvalidToken:
      # @ 이 오류는 키가 다르거나 데이터가 손상되었을 때 발생합니다.
      print("오류: 데이터 복호화에 실패했습니다. MO_SECRET_KEY가 올바른지 확인하거나, 설정 파일이 손상되었을 수 있습니다.", file=sys.stderr)
      sys.exit(1)
    except Exception as e:
      print(f"오류: 예기치 못한 복호화 오류 발생: {e}", file=sys.stderr)
      sys.exit(1)
