# ! 설정 파일(config.json) 관리 모듈

import json
import os
import sys
import copy
import threading
from logger import get_logger

log = get_logger()
_config_lock = threading.Lock()

# 경로 설정
if getattr(sys, 'frozen', False):
  BASE_DIR = os.path.dirname(sys.executable)
else:
  BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(BASE_DIR, 'config.json')

# 암호화 대상 키 정의
SENSITIVE_KEYS = {
    'directsend': ['username', 'api_key', 'sender_phone'],
    'aws_connect': ['access_key_id', 'secret_access_key', 'region_name', 'instance_id', 'contact_flow_id', 'source_phone_number']
}


_encryptor_cache = None

def _get_encryptor():
  """암호화 유틸리티를 반환합니다. 인스턴스를 캐싱하여 PBKDF2 키 파생을 1회만 수행합니다."""
  global _encryptor_cache
  if _encryptor_cache is not None:
    return _encryptor_cache
  secret_key = os.getenv('MO_SECRET_KEY')
  if not secret_key:
    log.critical("MO_SECRET_KEY 환경 변수가 설정되지 않았습니다.")
    sys.exit(1)
  from crypto_utils import Encryptor
  _encryptor_cache = Encryptor(secret_key)
  return _encryptor_cache


def _encrypt_section(config, section, keys, encryptor):
  """설정 섹션의 민감 정보를 암호화합니다. 변경 여부를 반환합니다."""
  if section not in config:
    return False
  updated = False
  for key in keys:
    value = config[section].get(key)
    if value and not str(value).startswith('enc::'):
      log.info("'%s.%s' 암호화 진행", section, key)
      config[section][key] = encryptor.encrypt(value)
      updated = True
  return updated


def _decrypt_section(config, section, keys, encryptor):
  """설정 섹션의 민감 정보를 복호화합니다."""
  if section not in config:
    return
  decrypted = {}
  for key, value in config[section].items():
    decrypted[key] = encryptor.decrypt(value) if key in keys else value
  config[section] = decrypted


def _migrate_call_recipients(config):
  """기존 단순 리스트 형태의 call_recipients를 중첩 리스트로 마이그레이션합니다.
  ['이름1/번호1', '이름2/번호2'] → [['이름1/번호1'], ['이름2/번호2']]
  """
  migrated = False
  for group_name, group_data in config.get('groups', {}).items():
    cr = group_data.get('call_recipients', [])
    if cr and isinstance(cr, list) and cr and not isinstance(cr[0], list):
      group_data['call_recipients'] = [[r] for r in cr]
      log.info("'%s' 그룹 call_recipients 마이그레이션 완료", group_name)
      migrated = True
  return migrated


def load_config():
  """설정 파일을 로드하고 민감 정보를 복호화합니다."""
  encryptor = _get_encryptor()

  with _config_lock:
    try:
      with open(CONFIG_FILE, 'r', encoding='utf-8') as f:
        config = json.load(f)
    except FileNotFoundError:
      log.warning("설정 파일을 찾을 수 없습니다. 기본 설정을 생성합니다.")
      config = {'health_check_port': 9163, 'groups': {}}
    except json.JSONDecodeError as e:
      log.error("설정 파일 JSON 파싱 오류: %s", e)
      config = {'health_check_port': 9163, 'groups': {}}

    config.setdefault('health_check_port', 9163)
    config_updated = False

    # call_recipients 마이그레이션
    if _migrate_call_recipients(config):
      config_updated = True

    # 각 섹션 암호화
    for section, keys in SENSITIVE_KEYS.items():
      if _encrypt_section(config, section, keys, encryptor):
        config_updated = True

    # 변경사항 저장
    if config_updated:
      try:
        with open(CONFIG_FILE, 'w', encoding='utf-8') as f:
          json.dump(config, f, indent=4, ensure_ascii=False)
        log.info("설정을 암호화하여 저장했습니다.")
      except Exception as e:
        log.critical("설정 파일 저장 실패: %s", e)
        sys.exit(1)

    # 복호화
    for section, keys in SENSITIVE_KEYS.items():
      _decrypt_section(config, section, keys, encryptor)

    return config


def save_config(config):
  """설정을 암호화하여 파일에 저장합니다."""
  from crypto_utils import ENCRYPTION_PREFIX
  encryptor = _get_encryptor()
  config_to_save = copy.deepcopy(config)

  # 각 섹션 암호화
  for section, keys in SENSITIVE_KEYS.items():
    if section in config_to_save:
      for key in keys:
        value = config_to_save[section].get(key)
        if value and not str(value).startswith(ENCRYPTION_PREFIX):
          config_to_save[section][key] = encryptor.encrypt(value)

  with _config_lock:
    try:
      with open(CONFIG_FILE, 'w', encoding='utf-8') as f:
        json.dump(config_to_save, f, indent=4, ensure_ascii=False)
    except Exception as e:
      log.error("설정 파일 저장 실패: %s", e)
