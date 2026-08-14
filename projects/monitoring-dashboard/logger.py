# ! 로깅 모듈

import logging
import os
import sys
from logging.handlers import TimedRotatingFileHandler

if getattr(sys, 'frozen', False):
  BASE_DIR = os.path.dirname(sys.executable)
else:
  BASE_DIR = os.path.dirname(os.path.abspath(__file__))

LOG_DIR = os.path.join(BASE_DIR, 'log')
os.makedirs(LOG_DIR, exist_ok=True)
LOG_FILE = os.path.join(LOG_DIR, 'monitoring.log')

_logger = logging.getLogger('monitoring')
_logger.setLevel(logging.DEBUG)

_formatter = logging.Formatter('[%(asctime)s] %(levelname)s - %(message)s', datefmt='%Y-%m-%d %H:%M:%S')

_file_handler = TimedRotatingFileHandler(LOG_FILE, when='midnight', backupCount=7, encoding='utf-8')
_file_handler.suffix = '%Y%m%d'
_file_handler.setLevel(logging.DEBUG)
_file_handler.setFormatter(_formatter)

_console_handler = logging.StreamHandler(sys.stdout)
_console_handler.setLevel(logging.INFO)
_console_handler.setFormatter(_formatter)

_logger.addHandler(_file_handler)
_logger.addHandler(_console_handler)


def get_logger():
  return _logger
