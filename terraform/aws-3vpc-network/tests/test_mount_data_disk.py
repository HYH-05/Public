"""블록 장치·마운트 명령을 모의 명령으로 격리해 데이터 보존 분기를 검증한다."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get("PM_TEST_BASH") or shutil.which("bash")
SCRIPT = (ROOT / "scripts/mount-data-disk.sh").read_text(encoding="utf-8")
UUID = "11111111-2222-3333-4444-555555555555"
MOCK = r'''#!/bin/bash
set -eu
name=${0##*/}
printf '%s\n' "$name" >> "$PM_MOCK_STATE/calls"
case "$name" in
  realpath) printf '%s\n' "$2" ;;
  lsblk)
    if [[ "$*" == *PATH,SERIAL* ]]; then
      printf '/dev/mockdata %s\n' "${PM_MOCK_SERIAL:-vol00000000000000000}"
    elif [[ "$*" == *MOUNTPOINTS* ]]; then
      :
    elif [[ "$*" == *'-nr '* && "${PM_MOCK_PARTITIONED:-0}" == 1 ]]; then
      printf 'disk\npart\n'
    else
      echo disk
    fi ;;
  blkid)
    if [[ "$*" == *TYPE* ]]; then
      fs=$(cat "$PM_MOCK_STATE/filesystem")
      [[ "$fs" != none ]] || exit 2
      echo "$fs"
    else
      echo 11111111-2222-3333-4444-555555555555
    fi ;;
  wipefs) printf '%s' "${PM_MOCK_SIGNATURE:-}" ;;
  mkfs.xfs) echo xfs > "$PM_MOCK_STATE/filesystem" ;;
  mountpoint) [[ -e "$PM_MOCK_STATE/mounted" ]] ;;
  findmnt)
    if [[ "$*" == *'--target '* && -e "$PM_MOCK_STATE/mounted" ]]; then
      echo "${PM_MOCK_MOUNTED_UUID:-11111111-2222-3333-4444-555555555555}"
    fi ;;
  mount)
    [[ "${PM_MOCK_MOUNT_FAIL:-0}" != 1 ]] || exit 1
    touch "$PM_MOCK_STATE/mounted" ;;
  seq) printf '1\n2\n' ;;
  install|ls|systemctl|sleep) : ;;
  *) exit 99 ;;
esac
'''


@unittest.skipUnless(BASH, "Bash가 필요하다.")
class MountDataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name)
        self.bin = self.state / "bin"
        self.bin.mkdir()
        for name in ("realpath", "lsblk", "blkid", "wipefs", "mkfs.xfs", "mountpoint", "findmnt", "mount", "install", "ls", "systemctl", "sleep", "seq"):
            path = self.bin / name
            path.write_text(MOCK, encoding="utf-8", newline="\n")
            path.chmod(0o755)
        self.fstab = self.state / "fstab"
        self.fstab.write_text("# test fixture\n", encoding="utf-8")
        self.filesystem = self.state / "filesystem"
        self.filesystem.write_text("none\n", encoding="utf-8")
        self.script = self.state / "mount.sh"
        self.script.write_text(
            SCRIPT.replace("/etc/fstab", '"' + self.fstab.as_posix() + '"'),
            encoding="utf-8", newline="\n",
        )

    def run_mount(self, **extra):
        return subprocess.run(
            [BASH, "--noprofile", "--norc", "-c",
             'mock_bin=$(cd "$1" && pwd); export PATH="$mock_bin:$PATH"; shift; . "$@"',
             "pm-test", self.bin.as_posix(), self.script.as_posix(), "vol-00000000000000000", "/data"],
            env={**os.environ, "PATH": str(self.bin) + os.pathsep + str(Path(BASH).parent) + os.pathsep + os.environ["PATH"],
                 "PM_MOCK_STATE": self.state.as_posix(), **extra},
            text=True, encoding="utf-8", errors="replace", capture_output=True,
        )

    def calls(self):
        return (self.state / "calls").read_text(encoding="utf-8").splitlines()

    def test_blank_disk_formats_once_and_fstab_is_idempotent(self):
        for _ in range(2):
            result = self.run_mount()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls().count("mkfs.xfs"), 1)
        entries = self.fstab.read_text(encoding="utf-8")
        self.assertEqual(entries.count(f"UUID={UUID}"), 1)
        self.assertIn("/data xfs defaults,nofail", entries)

    def test_existing_filesystems_are_not_formatted(self):
        for filesystem in ("xfs", "ext4"):
            with self.subTest(filesystem=filesystem):
                self.filesystem.write_text(filesystem + "\n", encoding="utf-8")
                result = self.run_mount()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn("mkfs.xfs", self.calls())

    def test_partitioned_disk_is_rejected(self):
        result = self.run_mount(PM_MOCK_PARTITIONED="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("mkfs.xfs", self.calls())
        self.assertNotIn("mount", self.calls())

    def test_unknown_signature_is_not_formatted(self):
        result = self.run_mount(PM_MOCK_SIGNATURE="gpt")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("mkfs.xfs", self.calls())

    def test_wrong_volume_serial_is_not_used(self):
        result = self.run_mount(PM_MOCK_SERIAL="volfffffffffffffffff")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("mkfs.xfs", self.calls())
        self.assertNotIn("mount", self.calls())

    def test_conflicting_fstab_is_preserved(self):
        self.filesystem.write_text("xfs\n", encoding="utf-8")
        original = "UUID=other /data xfs defaults 0 0\n"
        self.fstab.write_text(original, encoding="utf-8")
        result = self.run_mount()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.fstab.read_text(encoding="utf-8"), original)
        self.assertNotIn("mkfs.xfs", self.calls())

    def test_mount_failure_is_reported(self):
        result = self.run_mount(PM_MOCK_MOUNT_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Data disk mounted:", result.stdout)
