# ! 서비스 장애 발생 시 SMS/전화 알림을 보내는 모듈

import requests
import json
import time
import boto3
import config_manager
from datetime import datetime
from logger import get_logger

log = get_logger()


def _parse_phone_numbers(recipients, international=False):
  """수신자 목록에서 전화번호를 파싱합니다."""
  phone_numbers = []
  for r in recipients:
    try:
      phone = r.split('/')[-1].strip()
      if phone:
        if international:
          if phone.startswith('0'):
            phone = '+82' + phone[1:]
          elif not phone.startswith('+'):
            phone = '+82' + phone
        phone_numbers.append(phone)
    except Exception as e:
      log.error("수신자 파싱 오류 '%s': %s", r, e)
  return phone_numbers


def _send_sms(title, message_body, recipients):
  """DirectSend API를 통해 SMS를 발송합니다."""
  try:
    config = config_manager.load_config()
  except Exception as e:
    log.error("SMS 발송을 위한 설정 로드 실패: %s", e)
    return

  ds_config = config.get('directsend')
  if not ds_config:
    log.warning("DirectSend 설정이 없습니다.")
    return

  phone_numbers = _parse_phone_numbers(recipients)
  if not phone_numbers:
    log.warning("유효한 SMS 수신자가 없습니다.")
    return

  api_key = ds_config.get('api_key')
  username = ds_config.get('username')
  sender_phone = ds_config.get('sender_phone')

  if not all([api_key, username, sender_phone]):
    log.warning("DirectSend 설정이 불완전합니다.")
    return

  try:
    response = requests.post(
        "https://directsend.co.kr/index.php/api_v2/sms_change_word",
        headers={"Content-Type": "application/json"},
        data=json.dumps({
            "title": title,
            "key": api_key,
            "username": username,
            "sender": sender_phone,
            "receiver": json.dumps([{"mobile": p} for p in phone_numbers]),
            "message": message_body
        }),
        timeout=10
    )
    result = response.json()
    if str(result.get("status")) == "0":
      log.info("SMS 발송 성공: %s", ', '.join(phone_numbers))
    else:
      log.error("SMS 발송 실패: %s", result.get('msg', 'Unknown error'))
  except Exception as e:
    log.error("SMS 발송 오류: %s", e)


def send_alert(service_name, service_address, recipients):
  """서비스 장애 발생 시 SMS 알림을 전송합니다."""
  time_str = datetime.now().strftime("%H:%M:%S")
  _send_sms(
      "[경고] 서비스 장애 발생",
      f"[{time_str}] '{service_name}' 서비스 장애 발생",
      recipients
  )


def send_resolved_alert(service_name, service_address, recipients):
  """서비스 복구 시 SMS 알림을 전송합니다."""
  time_str = datetime.now().strftime("%H:%M:%S")
  _send_sms(
      "[복구] 서비스 복구됨",
      f"[{time_str}] '{service_name}' 서비스 복구됨",
      recipients
  )


def send_call_alert(group_name, call_recipients, stop_flag=None):
  """Amazon Connect를 통해 그룹 장애 전화를 발신합니다.
  call_recipients는 순위별 그룹 리스트: [['이름/번호', ...], ['이름/번호', ...], ...]
  같은 순위 내 수신자에게 동시 발신하고, 1명이라도 받으면 성공 처리합니다.
  """
  try:
    config = config_manager.load_config()
  except Exception as e:
    log.error("전화 발신을 위한 설정 로드 실패: %s", e)
    return

  # 시간 체크 (설정된 시간대에는 전화 안 함)
  call_time = config.get('call_time', {'start': 8, 'end': 20})
  start, end = call_time.get('start', 8), call_time.get('end', 20)
  hour = datetime.now().hour

  if start <= end:
    blocked = start <= hour < end
  else:
    blocked = hour >= start or hour < end

  if blocked:
    log.info("전화 알림 스킵: 현재 %d시 (차단: %d시~%d시)", hour, start, end)
    return

  connect_config = config.get('aws_connect')
  if not connect_config:
    log.warning("Amazon Connect 설정이 없습니다.")
    return

  # call_recipients 호환: 기존 단순 리스트 → 중첩 리스트 변환
  priority_groups = _normalize_call_recipients(call_recipients)
  if not priority_groups:
    log.warning("유효한 전화 수신자가 없습니다.")
    return

  try:
    client = boto3.client(
        'connect',
        aws_access_key_id=connect_config.get('access_key_id'),
        aws_secret_access_key=connect_config.get('secret_access_key'),
        region_name=connect_config.get('region_name')
    )
  except Exception as e:
    log.error("Amazon Connect 클라이언트 생성 실패: %s", e)
    return

  group_data = config.get('groups', {}).get(group_name, {})
  display_name = group_data.get('call_alias') or group_name
  message = f"{display_name}에 장애가 발생했습니다."
  instance_id = connect_config.get('instance_id')

  for attempt in range(5):
    log.info("전화 발신 %d회차 시작 (그룹: %s)", attempt + 1, group_name)

    for priority_idx, priority_group in enumerate(priority_groups, 1):
      if stop_flag and stop_flag():
        log.info("전화 발신 중단됨")
        return

      phone_numbers = _parse_phone_numbers(priority_group, international=True)
      if not phone_numbers:
        continue

      log.info("[%d회차-%d순위] 동시 발신 %d명: %s", attempt + 1, priority_idx, len(phone_numbers), ', '.join(phone_numbers))

      # 같은 순위 전원에게 동시 발신
      contact_ids = {}
      for phone in phone_numbers:
        try:
          response = client.start_outbound_voice_contact(
              DestinationPhoneNumber=phone,
              ContactFlowId=connect_config.get('contact_flow_id'),
              InstanceId=instance_id,
              SourcePhoneNumber=connect_config.get('source_phone_number'),
              Attributes={'message': message}
          )
          contact_ids[phone] = response.get('ContactId')
        except Exception as e:
          log.error("%s 전화 발신 실패: %s", phone, e)

      if not contact_ids:
        log.warning("[%d회차-%d순위] 모든 발신 실패, 다음 순위로", attempt + 1, priority_idx)
        continue

      # 5초 간격 폴링으로 응답 확인 (최대 90초)
      answered = _poll_for_answer(client, instance_id, contact_ids, stop_flag, timeout=90, interval=5)

      if answered:
        log.info("[%d회차-%d순위] %s 전화 발신 성공", attempt + 1, priority_idx, answered)
        return

      log.info("[%d회차-%d순위] 응답 없음, 다음 순위로", attempt + 1, priority_idx)

  log.warning("5회 반복 후에도 모든 수신자 응답 없음 (그룹: %s)", group_name)


def _normalize_call_recipients(call_recipients):
  """call_recipients를 순위별 중첩 리스트로 정규화합니다.
  이미 중첩 리스트면 그대로, 단순 리스트면 각 항목을 개별 순위로 변환합니다.
  """
  if not call_recipients:
    return []

  # 이미 중첩 리스트인지 확인
  if call_recipients and isinstance(call_recipients[0], list):
    return [g for g in call_recipients if g]

  # 기존 단순 리스트: 각 항목을 개별 순위로 변환
  return [[r] for r in call_recipients if r]


def _poll_for_answer(client, instance_id, contact_ids, stop_flag, timeout=90, interval=5):
  """contact_ids 딕셔너리(phone→ContactId)를 폴링하여 응답 여부를 확인합니다.
  1명이라도 받으면 해당 전화번호를 반환, 타임아웃 시 None 반환.
  """
  elapsed = 0
  while elapsed < timeout:
    if stop_flag and stop_flag():
      log.info("전화 발신 중단됨")
      return None

    time.sleep(interval)
    elapsed += interval

    for phone, contact_id in contact_ids.items():
      if not contact_id:
        continue
      try:
        contact_info = client.describe_contact(InstanceId=instance_id, ContactId=contact_id)
        contact = contact_info.get('Contact', {})
        if contact.get('ConnectedToSystemTimestamp'):
          return phone
      except Exception as e:
        log.error("통화 상태 확인 실패 (%s): %s", phone, e)

  return None
