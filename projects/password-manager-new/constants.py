"""공통 상수 모듈."""

# --- 비밀번호 탭 ---
FIELDS = ["그룹", "이름(중복 불가)", "IP/도메인(중복 불가)", "OS/환경", "ID/이메일", "비밀번호", "비고"]
DATA_FIELDS = FIELDS[1:]
DISPLAY_FIELDS = [f.replace("(중복 불가)", "").strip() for f in FIELDS]
PASSWORD_FIELD = "비밀번호"
PW_IDX = FIELDS.index(PASSWORD_FIELD)
NAME_FIELD = "이름(중복 불가)"
IP_FIELD = "IP/도메인(중복 불가)"

# --- 키 관리 탭 ---
KEY_FIELDS = ["그룹", "이름(중복 불가)", "서비스/플랫폼", "키 유형", "키 값(중복 불가)", "연결 계정/이메일", "만료일", "비고"]
KEY_DATA_FIELDS = KEY_FIELDS[1:]
KEY_DISPLAY_FIELDS = [f.replace("(중복 불가)", "").strip() for f in KEY_FIELDS]
KEY_SECRET_FIELD = "키 값(중복 불가)"
KEY_SECRET_IDX = KEY_FIELDS.index(KEY_SECRET_FIELD)
KEY_NAME_FIELD = "이름(중복 불가)"
KEY_VALUE_FIELD = "키 값(중복 불가)"

# --- AWS IAM 키 탭 ---
AWS_FIELDS = ["그룹", "연결 계정", "액세스 키(중복 불가)", "시크릿 키(중복 불가)", "권한", "비고"]
AWS_DATA_FIELDS = AWS_FIELDS[1:]
AWS_DISPLAY_FIELDS = [f.replace("(중복 불가)", "").strip() for f in AWS_FIELDS]
AWS_SECRET_FIELD = "시크릿 키(중복 불가)"
AWS_SECRET_IDX = AWS_FIELDS.index(AWS_SECRET_FIELD)
AWS_ACCESS_FIELD = "액세스 키(중복 불가)"

# --- 공통 ---
AUTO_LOGOUT_SEC = 3600
CLIPBOARD_CLEAR_SEC = 30
SEARCH_DEBOUNCE_MS = 250

# --- 네임스페이스 ---
NS_PASSWORDS = "passwords"
NS_KEYS = "keys"
NS_AWS = "aws_keys"
NS_TOTP = "totp"

# --- TOTP 탭 ---
TOTP_FIELDS = ["그룹", "이름(중복 불가)", "서비스/사이트", "계정", "시크릿 키(중복 불가)", "비고", "패스워드"]
TOTP_DATA_FIELDS = TOTP_FIELDS[1:]
TOTP_DISPLAY_FIELDS = [f.replace("(중복 불가)", "").strip() for f in TOTP_FIELDS]
TOTP_SECRET_FIELD = "시크릿 키(중복 불가)"
TOTP_SECRET_IDX = TOTP_FIELDS.index(TOTP_SECRET_FIELD)
TOTP_NAME_FIELD = "이름(중복 불가)"
TOTP_PREFIX_FIELD = "패스워드"
TOTP_PREFIX_IDX = TOTP_FIELDS.index(TOTP_PREFIX_FIELD)
