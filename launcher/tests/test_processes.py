import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from launcher.processes import AlreadyRunning, ProcessManager


def wait_for(predicate, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.025)
    raise AssertionError('Timed out waiting for test process')


class ProcessTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.production_env = patch.dict(os.environ, OCR_PRODUCTION_LOG_DIR=str(self.root / 'production'))
        self.production_env.start()
        self.addCleanup(self.production_env.stop)
        self.manager = ProcessManager(self.root / 'state')
        self.script = self.root / 'worker.py'
        self.script.write_text('''import json, os, sys, time
from pathlib import Path
print(json.dumps({'camera': os.environ.get('TEST_CAMERA'), 'host': os.environ.get('TEST_HOST'), 'argv': sys.argv[2:], 'cwd': os.getcwd()}), flush=True)
while not Path(sys.argv[1]).exists():
    time.sleep(.02)
raise SystemExit(int(os.environ.get('TEST_EXIT', '0')))
''')
        self.keys = []

    def tearDown(self):
        for key in self.keys:
            (self.root / (key + '.stop')).touch()
        for key in self.keys:
            wait_for(lambda: not self.manager.status(key)['running'])
        for child in self.manager.children:
            child.wait(timeout=5)
        self.temporary.cleanup()

    def spec(self, key, **environment):
        self.keys.append(key)
        return {'name': key, 'cwd': str(self.root), 'command': [sys.executable, '-u', str(self.script), str(self.root / (key + '.stop')), 'a; b $(literal)'],
                'environment': dict(TEST_CAMERA='Hikvision 2', TEST_HOST='10.2.3.4', **environment)}

    def running(self, key):
        state = self.manager.status(key)
        return state if state['running'] and state.get('pid') else None

    def test_duplicate_lock_reconnect_exit_and_relaunch(self):
        spec = self.spec('one')
        self.manager.launch('one', spec)
        first = wait_for(lambda: self.running('one'))
        reconnected = ProcessManager(self.manager.directory)
        self.assertTrue(reconnected.status('one')['running'])
        with self.assertRaises(AlreadyRunning):
            reconnected.launch('one', spec)
        wait_for(lambda: 'Hikvision 2' in reconnected.log_tail('one'))
        log = reconnected.log_tail('one')
        self.assertIn('10.2.3.4', log)
        self.assertIn('a; b $(literal)', log)
        self.assertIn(str(self.root), log)
        (self.root / 'one.stop').touch()
        wait_for(lambda: not self.manager.status('one')['running'])
        self.assertEqual(self.manager.status('one')['exit_code'], 0)
        (self.root / 'one.stop').unlink()
        reconnected.launch('one', spec)
        second = wait_for(lambda: self.running('one'))
        self.assertNotEqual(first['pid'], second['pid'])

    def test_different_programs_run_independently_and_abnormal_exit_is_reported(self):
        self.manager.launch('one', self.spec('one'))
        self.manager.launch('two', self.spec('two', TEST_EXIT='7'))
        wait_for(lambda: self.running('one'))
        wait_for(lambda: self.running('two'))
        (self.root / 'two.stop').touch()
        wait_for(lambda: not self.manager.status('two')['running'])
        self.assertTrue(self.manager.status('one')['running'])
        self.assertEqual(self.manager.status('two')['exit_code'], 7)

    def test_console_timing_and_utf8_are_not_split_at_pipe_read_boundaries(self):
        self.script.write_text('''import os, time
payload = '识别完成\\n[PaddleOCR] status=OK request_ms=123.456\\n尾行'.encode('utf-8')
for byte in payload:
    os.write(2, bytes([byte]))
    time.sleep(.002)
''')
        self.manager.launch('timing', self.spec('timing'))
        wait_for(lambda: self.manager.status('timing').get('state') == 'exited')
        log = self.manager.log_tail('timing')
        self.assertIn('识别完成\n[PaddleOCR] status=OK request_ms=123.456\n尾行', log)
        self.assertNotIn('\ufffd', log)
        self.assertIn('=== 程序结束，退出码 0 ===', log)

    def test_application_inherits_lock_if_supervisor_is_killed(self):
        spec = self.spec('inherited')
        self.manager.launch('inherited', spec)
        state = wait_for(lambda: self.running('inherited'))
        os.kill(state['supervisor_pid'], signal.SIGKILL)
        wait_for(lambda: self.manager.children[0].poll() is not None)
        # The worker still owns the kernel lock; a stale supervisor PID cannot allow a duplicate.
        self.assertTrue(self.manager.status('inherited')['running'])
        with self.assertRaises(AlreadyRunning):
            ProcessManager(self.manager.directory).launch('inherited', spec)
        (self.root / 'inherited.stop').touch()
        wait_for(lambda: not self.manager.status('inherited')['running'])

    def test_launcher_process_exit_does_not_release_application_lock(self):
        spec = self.spec('detached')
        code = 'import json,sys; from pathlib import Path; from launcher.processes import ProcessManager; ProcessManager(Path(sys.argv[1])).launch("detached",json.loads(sys.argv[2]))'
        subprocess.run([sys.executable, '-c', code, str(self.manager.directory), json.dumps(spec)], check=True)
        state = wait_for(lambda: self.running('detached'))
        self.assertTrue(self.manager.status('detached')['running'])
        with self.assertRaises(AlreadyRunning):
            self.manager.launch('detached', spec)

    def test_simultaneous_requests_from_separate_launchers_have_one_winner(self):
        spec = self.spec('racing')
        gate = self.root / 'gate'
        code = '''import json,sys,time
from pathlib import Path
from launcher.processes import ProcessManager, AlreadyRunning
while not Path(sys.argv[3]).exists(): time.sleep(.01)
try:
 ProcessManager(Path(sys.argv[1])).launch('racing',json.loads(sys.argv[2]))
 print('launched')
except AlreadyRunning:
 print('blocked')
'''
        processes = [subprocess.Popen([sys.executable, '-c', code, str(self.manager.directory), json.dumps(spec), str(gate)], stdout=subprocess.PIPE, text=True) for _ in range(2)]
        gate.touch()
        outputs = sorted(p.communicate(timeout=10)[0].strip() for p in processes)
        self.assertEqual(outputs, ['blocked', 'launched'])
        wait_for(lambda: self.running('racing'))

    def test_missing_executable_and_failed_exec_allow_another_attempt(self):
        spec = self.spec('missing')
        spec['command'][0] = str(self.root / 'not-there')
        with self.assertRaises(ValueError):
            self.manager.launch('missing', spec)
        self.assertFalse(self.manager.status('missing')['running'])
        executable = self.root / 'invalid-executable'
        executable.write_text('invalid executable format')
        executable.chmod(0o755)
        spec['command'] = [str(executable)]
        self.manager.launch('missing', spec)
        wait_for(lambda: not self.manager.status('missing')['running'])
        self.assertEqual(self.manager.status('missing')['state'], 'failed')
        self.assertIn('Exec format', self.manager.status('missing')['message'])


if __name__ == '__main__':
    unittest.main()
