"""
서비스 레이어 — 비즈니스 로직 (중복 검사, 배치 저장 디바운싱).
네임스페이스별로 독립적인 서비스 인스턴스를 생성한다.
GUI 의존성 없이 threading.Timer로 디바운싱을 처리한다.
"""

import logging
import threading
from typing import Callable

from storage import Storage, Record, NamespacedStore
from constants import NAME_FIELD, IP_FIELD, KEY_NAME_FIELD

log = logging.getLogger(__name__)


class DuplicateError(Exception):
    """중복 검사 실패."""


class PasswordService:
    """단일 네임스페이스에 대한 비즈니스 로직을 담당한다."""

    def __init__(self, storage: Storage, namespace: str,
                 unique_fields: list[str] | None = None,
                 on_save_error: Callable[[str], None] | None = None):
        self.storage = storage
        self.namespace = namespace
        self._store: NamespacedStore = storage.ns(namespace)
        self._save_timer: threading.Timer | None = None
        self._save_delay = 0.5
        self._lock = threading.Lock()
        self._on_save_error = on_save_error

        # @ 중복 검사 대상 필드 (필드명 → 인덱스 set)
        self._unique_fields = unique_fields or []
        self._unique_indexes: dict[str, set[str]] = {f: set() for f in self._unique_fields}
        self._rebuild_index()

    def _rebuild_index(self):
        for idx in self._unique_indexes.values():
            idx.clear()
        for records in self._store.get_all().values():
            for rec in records:
                self._index_add(rec.fields)

    def _index_add(self, fields: dict):
        for f, idx in self._unique_indexes.items():
            v = fields.get(f, "-")
            if v != "-":
                idx.add(v)

    def _index_remove(self, fields: dict):
        for f, idx in self._unique_indexes.items():
            v = fields.get(f, "-")
            if v != "-":
                idx.discard(v)

    # --- 디바운싱 저장 ---

    def _schedule_save(self):
        self.storage.mark_dirty()
        with self._lock:
            if self._save_timer:
                self._save_timer.cancel()
            self._save_timer = threading.Timer(self._save_delay, self._do_save)
            self._save_timer.daemon = True
            self._save_timer.start()

    def _do_save(self):
        with self._lock:
            self._save_timer = None
        try:
            self.storage.save()
        except Exception as e:
            log.exception("디바운싱 저장 실패")
            if self._on_save_error:
                self._on_save_error(f"데이터 저장 실패: {e}")

    def flush(self):
        with self._lock:
            if self._save_timer:
                self._save_timer.cancel()
                self._save_timer = None
        if self.storage.is_dirty:
            try:
                self.storage.save()
            except Exception as e:
                log.exception("flush 저장 실패")
                if self._on_save_error:
                    self._on_save_error(f"데이터 저장 실패: {e}")

    # --- 비즈니스 CRUD ---

    def _check_duplicate(self, fields: dict, old_fields: dict | None = None):
        for f, idx in self._unique_indexes.items():
            val = fields.get(f, "-")
            old_val = old_fields.get(f, "-") if old_fields else "-"
            if val != "-" and val != old_val and val in idx:
                raise DuplicateError(f"같은 '{f}' 값이 이미 존재합니다.")

    def add_record(self, group: str, fields: dict) -> Record:
        self._check_duplicate(fields)
        rec = Record(fields)
        self._store.add_record(group, rec)
        self._index_add(fields)
        self._schedule_save()
        return rec

    def update_fav(self, record_id: str, fav: bool):
        """즐겨찾기 상태만 업데이트."""
        result = self._store.find_record_by_id(record_id)
        if not result:
            return
        _, _, rec = result
        rec.fields["_fav"] = "1" if fav else "0"
        self._schedule_save()

    def update_record(self, record_id: str, new_fields: dict):
        result = self._store.find_record_by_id(record_id)
        if not result:
            raise ValueError("레코드를 찾을 수 없습니다.")
        _, _, old_rec = result
        self._check_duplicate(new_fields, old_fields=old_rec.fields)
        self._index_remove(old_rec.fields)
        self._store.update_record_by_id(record_id, new_fields)
        self._index_add(new_fields)
        self._schedule_save()

    def delete_record(self, record_id: str) -> tuple[str, Record] | None:
        result = self._store.delete_record_by_id(record_id)
        if result:
            group, removed = result
            self._index_remove(removed.fields)
            self._schedule_save()
            return group, removed
        return None

    def find_record(self, record_id: str):
        return self._store.find_record_by_id(record_id)

    def rename_group(self, old_name: str, new_name: str) -> tuple[bool, str]:
        if not self._store.rename_group(old_name, new_name):
            return False, "이미 존재하는 그룹 이름입니다."
        self._schedule_save()
        return True, ""

    def move_record(self, record_id: str, new_group: str):
        """레코드를 다른 그룹으로 이동한다."""
        result = self._store.find_record_by_id(record_id)
        if not result:
            raise ValueError("레코드를 찾을 수 없습니다.")
        old_group, _, rec = result
        if old_group == new_group:
            return
        self._store.delete_record_by_id(record_id)
        self._store.add_record(new_group, rec)
        self._schedule_save()

    def delete_group(self, group: str) -> list[Record]:
        removed = self._store.delete_group(group)
        for rec in removed:
            self._index_remove(rec.fields)
        self._schedule_save()
        return removed

    def export_csv(self, filepath: str, fields: list[str]):
        self._store.export_csv(filepath, fields)

    def import_csv(self, filepath: str, fields: list[str]) -> tuple[int, int]:
        rows = self._store.import_csv_rows(filepath, fields)
        added = skipped = 0
        for group, field_data in rows:
            try:
                self.add_record(group, field_data)
                added += 1
            except DuplicateError:
                skipped += 1
        return added, skipped

    def get_all(self) -> dict[str, list[Record]]:
        return self._store.get_all()

    def get_groups(self) -> list[str]:
        return self._store.get_groups()
