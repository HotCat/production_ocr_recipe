"""Check that first launch and upgrades preserve production configuration."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import fcntl


class LauncherTests(unittest.TestCase):
    def test_first_launch_upgrade_and_instance_lock(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app, home = root / 'app', root / 'home'
            (app / 'bin').mkdir(parents=True)
            (app / 'defaults').mkdir()
            home.mkdir()
            launcher = Path(__file__).parent / 'templates/launcher'
            shutil.copy2(launcher, app / 'launch')
            (app / 'launch').chmod(0o755)
            names = ('fun.scm', 'my.scm', 'config1.scm', 'config2.scm', 'config3.scm')
            for name in names:
                (app / 'defaults' / name).write_text('initial calibration')
            fake = app / 'bin/Camera'
            fake.write_text('#!/bin/sh\nset -eu\ntest -L font\ntest -L img\ntest -d "$SEQUENCE_RUNTIME_DIR"\npwd\n')
            fake.chmod(0o755)
            env = dict(os.environ, HOME=str(home), XDG_STATE_HOME=str(home / 'state'),
                       XDG_CONFIG_HOME=str(home / 'config'))
            # Avoid inheriting the workstation's XDG paths or writing to its calibration.
            process = subprocess.run([str(app / 'launch')], env=env, text=True, capture_output=True)
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertEqual(Path(process.stdout.strip()), home / 'state/engraving-sequence/work')
            calibration = home / 'ocrconfigs/sequence3/config1.scm'
            self.assertEqual(calibration.read_text(), 'initial calibration')
            calibration.write_text('operator calibration')
            (app / 'defaults/config1.scm').write_text('new release defaults')
            subprocess.run([str(app / 'launch')], env=env, check=True, capture_output=True)
            self.assertEqual(calibration.read_text(), 'operator calibration')
            lock = home / 'state/engraving-sequence/session.lock'
            with lock.open('w') as handle:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                duplicate = subprocess.run([str(app / 'launch')], env=env, text=True, capture_output=True)
                self.assertEqual(duplicate.returncode, 1)
                self.assertIn('already running', duplicate.stderr)


if __name__ == '__main__':
    unittest.main()
