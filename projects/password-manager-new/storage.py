"""
데이터 저장/로드 모듈.
- 2-네임스페이스 구조: {"passwords": {...}, "keys": {...}}
- 고유 ID 기반 레코드 모델 + ID 인덱스(O(1) 조회)
- 그룹별 딕셔너리 구조로 암호화 저장
- 복호화 실패 시 예외 전파 (데이터 덮어쓰기 방지)
- 원자적 파일 쓰기 (임시 파일 → os.replace)
- CSV 내보내기/가져오기
- 기존 단일 구조 자동 마이그레이션
"""

import os
import json
import csv
import stat
import uuid
import logging

from cryptography.fernet import Fernet, InvalidToken
from constants import NS_PASSWORDS, NS_KEYS, NS_AWS, NS_TOTP

log = logging.getLogger(__name__)

DEFAULT_GROUP = "기본 그룹"
NAMESPACES = (NS_PASSWORDS, NS_KEYS, NS_AWS, NS_TOTP)


class DataCorruptionError(Exception):
    """암호화 데이터 복호화 실패."""


class Record:
    """고유 ID를 가진 단일 레코드."""

    __slots__ = ("id", "fields")

    def __init__(self, fields: dict, record_id: str | None = None):
        self.id = record_id or uuid.uuid4().hex[:12]
        self.fields = fields

    def to_dict(self) -> dict:
        return {"_id": self.id, **self.fields}

    @classmethod
    def from_dict(cls, d: dict) -> "Record":
        rid = d.pop("_id", None)
        return cls(d, record_id=rid)

    def get(self, key: str, default: str = "") -> str:
        return self.fields.get(key, default)


class NamespacedStore:
    """단일 네임스페이스(passwords 또는 keys)의 그룹별 레코드 저장소."""

    def __init__(self):
        self._data: dict[str, list[Record]] = {DEFAULT_GROUP: []}
        self._id_index: dict[str, tuple[str, Record]] = {}

    def load(self, raw: dict):
        self._data = {
            group: [Record.from_dict(r) for r in records if isinstance(r, dict)]
            for group, records in raw.items()
        }
        if not self._data:
            self._data = {DEFAULT_GROUP: []}
        self._rebuild_id_index()

    def _rebuild_id_index(self):
        self._id_index = {
            rec.id: (group, rec)
            for group, records in self._data.items()
            for rec in records
        }

    def serialize(self) -> dict:
        return {
            group: [rec.to_dict() for rec in records]
            for group, records in self._data.items()
        }

    def get_all(self) -> dict[str, list[Record]]:
        return self._data

    def get_groups(self) -> list[str]:
        return list(self._data.keys())

    def find_record_by_id(self, record_id: str) -> tuple[str, int, Record] | None:
        entry = self._id_index.get(record_id)
        if not entry:
            return None
        group, rec = entry
        records = self._data.get(group, [])
        try:
            idx = records.index(rec)
        except ValueError:
            return None
        return group, idx, rec

    def add_record(self, group: str, record: Record):
        self._data.setdefault(group, []).append(record)
        self._id_index[record.id] = (group, record)

    def update_record_by_id(self, record_id: str, new_fields: dict) -> bool:
        entry = self._id_index.get(record_id)
        if not entry:
            return False
        entry[1].fields = new_fields
        return True

    def delete_record_by_id(self, record_id: str) -> tuple[str, Record] | None:
        entry = self._id_index.pop(record_id, None)
        if not entry:
            return None
        group, rec = entry
        records = self._data.get(group, [])
        records.remove(rec)
        if not records:
            del self._data[group]
        return group, rec

    def rename_group(self, old_name: str, new_name: str) -> bool:
        if new_name in self._data:
            return False
        self._data[new_name] = self._data.pop(old_name)
        for rec in self._data[new_name]:
            self._id_index[rec.id] = (new_name, rec)
        return True

    def delete_group(self, group: str) -> list[Record]:
        removed = self._data.pop(group, [])
        for rec in removed:
            self._id_index.pop(rec.id, None)
        return removed

    def export_csv(self, filepath: str, fields: list[str]):
        with open(filepath, "w", newline="", encoding="utf-8-sig") as f:
            writer = csv.writer(f)
            writer.writerow(["그룹"] + fields)
            for group, records in self._data.items():
                for rec in records:
                    writer.writerow([group] + [rec.get(fd, "") for fd in fields])

    def import_csv_rows(self, filepath: str, fields: list[str]) -> list[tuple[str, dict]]:
        rows = []
        with open(filepath, "r", encoding="utf-8-sig") as f:
            for row in csv.DictReader(f):
                group = row.get("그룹", DEFAULT_GROUP) or DEFAULT_GROUP
                rows.append((group, {fd: row.get(fd, "-") or "-" for fd in fields}))
        return rows


class Storage:
    """파일 I/O 전담. 2-네임스페이스 구조를 관리한다."""

    def __init__(self, data_file: str, fernet: Fernet):
        self.data_file = data_file
        self.fernet = fernet
        self._stores: dict[str, NamespacedStore] = {
            ns: NamespacedStore() for ns in NAMESPACES
        }
        self._dirty = False
        self.reload()

    def reload(self):
        raw = self._load_from_disk()
        for ns in NAMESPACES:
            self._stores[ns].load(raw.get(ns, {}))
        self._dirty = False

    def _load_from_disk(self) -> dict[str, dict]:
        if not os.path.exists(self.data_file):
            return {}
        with open(self.data_file, "rb") as f:
            enc = f.read()
        if not enc:
            return {}

        try:
            dec = self.fernet.decrypt(enc)
        except InvalidToken as e:
            log.error("데이터 파일 복호화 실패: %s", e)
            raise DataCorruptionError(
                "데이터 파일을 복호화할 수 없습니다. 키가 일치하지 않거나 파일이 손상되었습니다."
            ) from e

        raw = json.loads(dec)

        # @ 기존 단일 구조 마이그레이션: 최상위에 네임스페이스 키가 없으면 passwords로 감싼다
        if isinstance(raw, list):
            return {NS_PASSWORDS: {DEFAULT_GROUP: raw}}
        if isinstance(raw, dict) and NS_PASSWORDS not in raw and NS_KEYS not in raw:
            return {NS_PASSWORDS: raw}
        return raw

    def save(self):
        serializable = {
            ns: store.serialize() for ns, store in self._stores.items()
        }
        enc = self.fernet.encrypt(json.dumps(serializable).encode())
        tmp = self.data_file + ".tmp"
        with open(tmp, "wb") as f:
            f.write(enc)
        os.chmod(tmp, stat.S_IRUSR | stat.S_IWUSR)
        os.replace(tmp, self.data_file)
        self._dirty = False

    def mark_dirty(self):
        self._dirty = True

    @property
    def is_dirty(self) -> bool:
        return self._dirty

    def ns(self, namespace: str) -> NamespacedStore:
        """네임스페이스별 저장소를 반환한다."""
        return self._stores[namespace]
