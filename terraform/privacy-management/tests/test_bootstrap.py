"""서버 명령은 실행하지 않고 Bash 설정과 Vim 매핑을 실제 인터프리터로 검증한다."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = (ROOT / "templates/linux-bootstrap.sh.tftpl").read_text(encoding="utf-8")


def executable(name):
    explicit = os.environ.get(f"PM_TEST_{name.upper()}")
    return explicit or shutil.which(name)


def render(environment):
    return (
        TEMPLATE.replace("${deployment_environment}", environment)
        .replace("${server_hostname}", f"pm-{environment}-test")
        .replace("${data_volume_id}", "vol-00000000000000000")
        .replace("${data_mount_path}", "/data")
        .replace("${protect_mysql}", "true")
        .replace("${mount_script}", (ROOT / "scripts/mount-data-disk.sh").read_text(encoding="utf-8"))
        .replace("$${", "${")
    )


def heredoc(script, marker):
    return re.search(r"<<'" + marker + r"'\n(.*?)\n" + marker, script, re.S).group(1) + "\n"


class BootstrapTests(unittest.TestCase):
    @unittest.skipUnless(executable("bash"), "Bash가 필요하다.")
    def test_bash_syntax(self):
        for environment in ("live", "qa"):
            result = subprocess.run(
                [executable("bash"), "-n"], input=render(environment), text=True,
                encoding="utf-8", capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipUnless(executable("bash"), "Bash가 필요하다.")
    def test_interactive_aliases_and_environment_colours(self):
        for environment, colour in (("live", "31"), ("qa", "33")):
            with tempfile.TemporaryDirectory() as directory:
                profile = Path(directory) / "profile.sh"
                profile.write_text(heredoc(render(environment), "PM_SHELL"), encoding="utf-8")
                result = subprocess.run(
                    [executable("bash"), "--noprofile", "--norc", "-ic",
                     'source "$1"; alias ll; alias vi; printf "%s\\n" "$PS1"',
                     "pm-test", profile.as_posix()],
                    text=True, encoding="utf-8", errors="replace", capture_output=True,
                    env={**os.environ, "TERM": "xterm"},
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("alias ll='ls -al'", result.stdout)
                self.assertIn("alias vi='vim'", result.stdout)
                self.assertIn(r"\e[" + colour + "m", result.stdout)
                self.assertIn(r"\u@\h", result.stdout)

    @unittest.skipUnless(executable("vim"), "Vim이 필요하다.")
    def test_vim_configuration_and_safe_comment_removal(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "vimrc"
            config.write_text(heredoc(render("qa"), "PM_VIMRC"), encoding="utf-8")
            assertions = Path(directory) / "assertions.vim"
            assertions.write_text(
                r'''call assert_equal(2, &shiftwidth)
call assert_equal(500, &history)
call assert_true(&autoindent)
call assert_true(&smartindent)
call assert_true(&hlsearch)
call setline(1, ['#comment', 'plain text', '  #indented', 'last line'])
execute "normal gg\<F2>"
call assert_equal('comment', getline(1))
execute "normal 2G\<F2>"
call assert_equal('plain text', getline(2))
execute "normal 3G\<F2>"
call assert_equal('  indented', getline(3))
execute "normal 2G\<F1>"
call assert_equal('#plain text', getline(2))
execute "normal 2GVj\<F2>"
call assert_equal(['plain text', '  indented'], getline(2, 3))
if len(v:errors)
  cquit
endif
qa!
''', encoding="utf-8",
            )
            result = subprocess.run(
                [executable("vim"), "-Nu", config.as_posix(), "-i", "NONE", "-n", "-es",
                 "-S", assertions.as_posix()],
                text=True, encoding="utf-8", errors="replace", capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
