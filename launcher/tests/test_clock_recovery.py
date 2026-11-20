"""Clock recovery never runs automatically and never rewrites production events."""
from contextlib import closing
import fcntl
import os
from pathlib import Path
import sqlite3
import tempfile
import time
import unittest
from unittest.mock import patch

from launcher.processes import ProcessManager
from launcher.production import APPLICATIONS, CLOCK_FLOOR_US, ClockError, ClockGuard, SCHEMA_DIRECTORY, display_time
from launcher.recover_clock import recover, require_ntp, verified_time


class ClockRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'logs'
        self.state = Path(self.temp.name) / 'state'
        self.now = verified_time('2026-11-20T15:55:14+08:00')
        self.future = self.now + 8 * 3600_000_000
        ClockGuard(self.root, lambda: self.future).check(True)
        self.event_path = self.root / (APPLICATIONS[0] + '.sqlite3')
        with closing(sqlite3.connect(self.root / 'clock.sqlite3')) as db, db:
            db.execute('UPDATE clock_state SET last_production_us=?', (self.future,))
        with closing(sqlite3.connect(self.event_path)) as db, db:
            db.execute((SCHEMA_DIRECTORY / 'events.sql').read_text())
            db.execute('''INSERT INTO production_events(app,occurred_at_us,timestamp_utc,
                timestamp_local,local_date,result,barcode) VALUES(?,?,?,?,?,?,?)''',
                (APPLICATIONS[0], self.future, '2026-11-20T15:55:14Z',
                 '2026-11-20T23:55:14+08:00', '2026-11-20', 'OK', '保留原条码001'))
        self.original = self.event_path.read_bytes()

    def repair(self, **options):
        return recover(self.root, self.now, 'NTP corrected an incorrectly advanced RTC',
                       'independent trusted time', state_directory=self.state,
                       now_us=lambda: self.now, **options)

    def test_timezone_changes_do_not_shift_epoch_or_trigger_guard(self):
        self.assertEqual(self.now, verified_time('2026-11-20T07:55:14Z'))
        guard = ClockGuard(Path(self.temp.name) / 'timezone', lambda: self.now)
        try:
            with patch.dict(os.environ, {'TZ': 'UTC'}):
                time.tzset()
                guard.check(True)
                self.assertEqual(display_time(self.now), '2026-11-20T07:55:14+00:00')
            with patch.dict(os.environ, {'TZ': 'Asia/Shanghai'}):
                time.tzset()
                guard.check(True)
                self.assertEqual(display_time(self.now), '2026-11-20T15:55:14+08:00')
        finally:
            time.tzset()
        with self.assertRaises(ValueError):
            verified_time('2026-11-20T15:55:14')

    def test_preview_does_not_change_clock_or_create_backups(self):
        report = self.repair()
        self.assertEqual(report['event_counts'][APPLICATIONS[0]], (1, 1))
        self.assertFalse((self.root.parent / 'clock-recovery-backups').exists())
        with self.assertRaises(ClockError):
            ClockGuard(self.root, lambda: self.now).check()
        with closing(sqlite3.connect(self.root / 'clock.sqlite3')) as db:
            self.assertIsNone(db.execute("SELECT 1 FROM sqlite_master WHERE name='clock_recoveries'").fetchone())

    def test_recovery_backups_audit_history_and_future_rollback_protection(self):
        report = self.repair(apply=True)
        backup = Path(report['backup_directory'])
        with closing(sqlite3.connect(backup / 'clock.sqlite3')) as db:
            self.assertEqual(db.execute('SELECT high_water_us,last_production_us FROM clock_state').fetchone(),
                             (self.future, self.future))
        self.assertEqual(self.event_path.read_bytes(), self.original)
        with closing(sqlite3.connect(backup / self.event_path.name)) as db:
            self.assertEqual(db.execute('SELECT barcode,occurred_at_us FROM production_events').fetchone(),
                             ('保留原条码001', self.future))
        self.assertTrue((backup / 'recovery.json').is_file())
        state = ClockGuard(self.root, lambda: self.now).check(True)
        self.assertIsNone(state['last_production_us'])
        self.assertEqual(state['clock_recovery']['previous_last_production_us'], self.future)
        with self.assertRaises(ClockError):
            ClockGuard(self.root, lambda: self.now - 1).check()
        with self.assertRaises(ClockError):
            self.repair(apply=True)

    def test_unverified_or_bios_reset_time_and_running_application_are_rejected(self):
        self.now -= 120_000_000
        with self.assertRaises(ClockError):
            recover(self.root, self.now + 120_000_000, 'reason', 'source', apply=True,
                    state_directory=self.state, now_us=lambda: self.now)
        self.now = CLOCK_FLOOR_US - 1
        with self.assertRaises(ClockError):
            self.repair(apply=True)
        self.now = self.future - 8 * 3600_000_000
        manager = ProcessManager(self.state, self.root)
        with manager.paths(APPLICATIONS[0])[0].open('a+b') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaisesRegex(ClockError, 'Close all production'):
                self.repair(apply=True)
        with patch('launcher.recover_clock.subprocess.run') as run:
            run.return_value.stdout = 'no\n'
            with self.assertRaises(ClockError):
                require_ntp()
        self.assertFalse((self.root.parent / 'clock-recovery-backups').exists())

    def test_backup_failure_leaves_protection_and_audit_unchanged(self):
        with patch('launcher.recover_clock.Path.write_text', side_effect=OSError('disk full')):
            with self.assertRaises(OSError):
                self.repair(apply=True)
        with self.assertRaises(ClockError):
            ClockGuard(self.root, lambda: self.now).check()
        self.assertEqual(self.event_path.read_bytes(), self.original)
