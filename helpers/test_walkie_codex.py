"""Launcher preflight must reject invalid inputs before creating Codex state."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

LAUNCHER = Path(__file__).with_name('walkie-codex')

class LauncherPreflightTests(unittest.TestCase):
    def run_rejected(self, args):
        with tempfile.TemporaryDirectory() as directory:
            called = Path(directory) / 'called'
            fake = Path(directory) / 'codex'
            fake.write_text('#!/bin/sh\ntouch "' + str(called) + '"\nexit 99\n')
            fake.chmod(0o755)
            result = subprocess.run([sys.executable, str(LAUNCHER), *args],
                                    input='', capture_output=True, text=True,
                                    env=dict(os.environ, CODEX_BIN=str(fake)), timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(called.exists(), 'Codex was invoked before preflight finished')
            return result

    def test_noninteractive_launch_creates_no_chat(self):
        result = self.run_rejected(['--cd', str(LAUNCHER.parent), '--', '-a harmless dictated dash'])
        self.assertIn('interactive terminal', result.stderr)

    def test_missing_project_creates_no_chat(self):
        result = self.run_rejected(['--cd', '/nonexistent/walkie-test-project', 'hello'])
        self.assertIn('project folder does not exist', result.stderr)

if __name__ == '__main__':
    unittest.main()
