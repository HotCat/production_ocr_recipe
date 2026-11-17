"""Exercise the real entry point and X11 plugin, which offscreen widget tests miss."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

from launcher.config import REPOSITORY


class DesktopStartupTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get('DISPLAY'), 'requires an X11 desktop')
    def test_real_script_initializes_x11_without_native_crash(self):
        with tempfile.TemporaryDirectory(prefix='ocr-launcher-startup-') as directory:
            root = Path(directory)
            config = root / 'config.json'
            environment = dict(os.environ, OCR_LAUNCHER_PYTHON=sys.executable,
                               QT_QPA_PLATFORM='xcb', PYTHONFAULTHANDLER='1',
                               PRODUCTION_OCR_LAUNCHER_STATE_DIR=str(root / 'state'),
                               OCR_PRODUCTION_LOG_DIR=str(root / 'production'))
            with tempfile.TemporaryFile(mode='w+') as output:
                process = subprocess.Popen(
                    [str(REPOSITORY / 'scripts/run-launcher.sh'), '--config', str(config)],
                    cwd=REPOSITORY, env=environment, stdout=output, stderr=subprocess.STDOUT,
                )
                try:
                    deadline = time.monotonic() + 10
                    lock = Path(str(config) + '.ui.lock')
                    while not lock.exists() and process.poll() is None and time.monotonic() < deadline:
                        time.sleep(.05)
                    # QApplication must initialize successfully before the UI lock is created.
                    time.sleep(.5)
                    output.seek(0)
                    details = output.read()
                    self.assertIsNone(process.poll(), details)
                    self.assertTrue(lock.exists(), details)
                    mappings = Path(f'/proc/{process.pid}/maps').read_text()
                    self.assertIn('libQt6XcbQpa', mappings)
                    self.assertNotIn('Fatal Python error', details)
                finally:
                    if process.poll() is None:
                        process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
