"""Production history/clock integration, isolated from operator data and hardware."""
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from unittest.mock import patch

from launcher.production import (APPLICATIONS, CLOCK_FLOOR_US, ClockError, ClockGuard,
                                 ProductionHistory, SCHEMA_DIRECTORY)
from launcher.processes import ProcessManager


class ProductionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.now = CLOCK_FLOOR_US + 10_000_000

    def guard(self):
        return ClockGuard(self.root, lambda: self.now)

    def seed(self, app=APPLICATIONS[0]):
        path = self.root / (app + '.sqlite3')
        with sqlite3.connect(path) as db:
            db.execute((SCHEMA_DIRECTORY / 'events.sql').read_text())
            for number in range(205):
                db.execute('''INSERT INTO production_events(app,occurred_at_us,timestamp_utc,timestamp_local,local_date,result,barcode,detected_text,preset_text)
                    VALUES(?,?,?,?,?,?,?,?,?)''',
                    (app, self.now+number, '2026-11-17T00:00:00.123456Z', '2026-11-17T08:00:00.123456+0800',
                     '2026-11-17' if number < 204 else '2026-11-16', 'NG' if number % 2 else 'OK',
                     "A'001", '客服电话：96008', '客服电话:96008'))
        return ProductionHistory(app, self.root)

    def test_first_boot_bios_reset_and_restart_rollback_are_blocked(self):
        self.now = 0
        with self.assertRaises(ClockError): self.guard().check(True)
        self.now = CLOCK_FLOOR_US+1_000_000
        self.guard().check(True)
        self.now -= 1
        with self.assertRaises(ClockError): self.guard().check(True)
        self.now += 2
        self.guard().check(True)

    def test_last_production_watermark_and_in_session_rollback(self):
        guard = self.guard()
        guard.check(True)
        self.now += 100
        guard.observe()
        self.now -= 1
        with self.assertRaises(ClockError): guard.observe()
        with sqlite3.connect(guard.path) as db:
            db.execute('UPDATE clock_state SET high_water_us=?,last_production_us=?', (self.now+1000,self.now+1000))
        with self.assertRaises(ClockError): self.guard().check()
        self.now += 1001
        self.assertEqual(self.guard().check(True)['last_production_us'], self.now-1)

    def test_corrupt_clock_and_missing_clock_row_refuse_launch(self):
        manager = ProcessManager(self.root / 'state', self.root / 'logs')
        manager.clock_status(True)
        with sqlite3.connect(manager._clock.path) as db: db.execute('DELETE FROM clock_state')
        with self.assertRaises(ClockError), patch('subprocess.Popen') as spawn:
            manager.launch('dummy', {})
        spawn.assert_not_called()
        manager._clock.path.write_bytes(b'corrupt')
        with self.assertRaises(ClockError): manager.clock_status(True)

    def test_production_clock_refuses_every_program_before_spawning(self):
        manager = ProcessManager(self.root / 'state', self.root / 'logs')
        manager.clock_status(True)
        with sqlite3.connect(manager._clock.path) as db:
            db.execute('UPDATE clock_state SET high_water_us=high_water_us+86400000000')
        with patch('subprocess.Popen') as spawn:
            for app in APPLICATIONS:
                with self.assertRaises(ClockError): manager.launch(app, {})
        spawn.assert_not_called()

    def test_concurrent_clock_checks_never_lower_the_watermark(self):
        self.guard()
        def check(number):
            try: return ClockGuard(self.root, lambda: self.now+number).check(True)
            except ClockError: return None
        with ThreadPoolExecutor(max_workers=5) as pool:
            list(pool.map(check, range(30)))
        with sqlite3.connect(self.root / 'clock.sqlite3') as db:
            self.assertEqual(db.execute('SELECT high_water_us FROM clock_state').fetchone()[0], self.now+29)

    def test_history_date_distribution_pagination_unicode_and_literal_search(self):
        history = self.seed()
        counts = history.distribution('2026-11-01','2026-11-30')
        self.assertEqual(counts['2026-11-17'], {'local_date':'2026-11-17','total':204,'ok':102,'ng':102})
        self.assertEqual(history.query('2026-11-17','2026-11-17')['total'],204)
        self.assertEqual(len(history.query('2026-11-17','2026-11-17',offset=200)['rows']),4)
        self.assertEqual(history.query('2026-11-01','2026-11-30','NG','客服')['total'],102)
        self.assertEqual(history.query('2026-11-01','2026-11-30',search="A'001")['total'],205)
        self.assertEqual(history.query('2026-11-01','2026-11-30',search="%' OR 1=1 --")['total'],0)
        with history.connect() as db:
            with self.assertRaises(sqlite3.OperationalError): db.execute('DELETE FROM production_events')

    def test_empty_history_does_not_create_an_event_database(self):
        history=ProductionHistory(APPLICATIONS[0],self.root)
        self.assertEqual(history.query('2026-11-17','2026-11-17')['total'],0)
        self.assertEqual(history.distribution('2026-11-01','2026-11-30'),{})
        self.assertFalse(history.path.exists())


@unittest.skipUnless(os.environ.get('PRODUCTION_LOG_PROBE'), 'run scripts/test-production-logs.sh for compiled Haskell integration')
class HaskellWriterTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory();self.addCleanup(self.temporary.cleanup)
        self.root=Path(self.temporary.name)
        self.environment=dict(os.environ,OCR_PRODUCTION_LOG_DIR=str(self.root),OCR_DEBUG_MODE="0")
        self.probe=os.environ['PRODUCTION_LOG_PROBE']

    def run_probe(self, app, *args):
        return subprocess.run([self.probe,app,*args],env=self.environment,capture_output=True,text=True)

    def test_five_app_writes_lossless_text_timestamps_and_shared_clock(self):
        for app in APPLICATIONS:
            result=self.run_probe(app)
            self.assertEqual(result.returncode,0,result.stderr)
            history=ProductionHistory(app,self.root)
            with history.connect() as db:
                rows=db.execute('SELECT * FROM production_events ORDER BY id').fetchall()
                self.assertEqual(len(rows),2)
                self.assertEqual([row['result'] for row in rows],['OK','NG'])
                for row in rows:
                    self.assertEqual(row['barcode'],"ABC'\\包装\n001\0END")
                    self.assertEqual(row['detected_text'],'客服电话：96008 ABC\n第二行')
                    self.assertEqual(row['bank'],'未来银行')
                    self.assertEqual(row['reverse'],0)
                    self.assertEqual(row['integrity_guard'],1)
                    stamp=datetime.fromisoformat(row['timestamp_utc'].replace('Z','+00:00'))
                    self.assertLess(abs(stamp.timestamp()*1_000_000-row['occurred_at_us']),2)
                    self.assertEqual(datetime.fromisoformat(row['timestamp_local']).date().isoformat(),row['local_date'])
            state=ClockGuard(self.root).check()
            self.assertEqual(state['last_production_us'],rows[-1]['occurred_at_us'])

    def test_debug_rows_marked_and_existing_database_migrates_losslessly(self):
        app = APPLICATIONS[0]
        # Simulate a database from the previous release (no debug_mode column).
        old_schema = (SCHEMA_DIRECTORY / 'events.sql').read_text().replace(
            ' debug_mode INTEGER NOT NULL DEFAULT 0 CHECK(debug_mode IN (0,1)),\n', '')
        self.assertNotIn('debug_mode', old_schema)
        with sqlite3.connect(self.root / (app + '.sqlite3')) as db:
            db.execute(old_schema)
            db.execute("INSERT INTO production_events(app,occurred_at_us,timestamp_utc,timestamp_local,local_date,result,barcode) VALUES(?,1,'old','old','2026-11-17','OK','原条码')", (app,))
        self.environment['OCR_DEBUG_MODE'] = '1'
        result = self.run_probe(app, 'debug-cycles')
        self.assertEqual(result.returncode, 0, result.stderr)
        with ProductionHistory(app,self.root).connect() as db:
            rows = db.execute('SELECT result,barcode,debug_mode FROM production_events ORDER BY id').fetchall()
            self.assertEqual([tuple(row) for row in rows], [('OK','原条码',0),('OK','SAME001',1),('NG','SAME001',1)])
        # A production restart must mark only its new records as production.
        self.environment['OCR_DEBUG_MODE'] = '0'
        self.assertEqual(self.run_probe(app).returncode, 0)
        with ProductionHistory(app,self.root).connect() as db:
            self.assertEqual([row[0] for row in db.execute('SELECT debug_mode FROM production_events ORDER BY id')], [0,1,1,0,0])

    def test_failed_event_rolls_back_clock_and_future_clock_refuses_haskell(self):
        app=APPLICATIONS[0]
        self.assertEqual(self.run_probe(app,'init').returncode,0)
        with sqlite3.connect(self.root/'clock.sqlite3') as db:
            db.execute('UPDATE clock_state SET high_water_us=?',(CLOCK_FLOOR_US,))
        with sqlite3.connect(self.root/(app+'.sqlite3')) as db:
            db.execute("CREATE TRIGGER reject_event BEFORE INSERT ON production_events BEGIN SELECT RAISE(ABORT,'disk failure simulation'); END")
        # Probe normally initializes first. Use an insert-only mode to test its transaction.
        failure=self.run_probe(app,'insert-only')
        self.assertNotEqual(failure.returncode,0)
        with sqlite3.connect(self.root/'clock.sqlite3') as db:
            self.assertEqual(db.execute('SELECT high_water_us,last_production_us FROM clock_state').fetchone(),(CLOCK_FLOOR_US,None))
            db.execute('UPDATE clock_state SET high_water_us=9999999999999999')
        failure=self.run_probe(app,'init')
        self.assertNotEqual(failure.returncode,0)
        self.assertIn('系统时间',failure.stderr)

    def test_concurrent_haskell_writers_and_reader(self):
        app=APPLICATIONS[0]
        self.assertEqual(self.run_probe(app,'init').returncode,0)
        with ThreadPoolExecutor(max_workers=5) as pool:
            results=list(pool.map(lambda _:self.run_probe(app),range(12)))
        self.assertTrue(all(result.returncode==0 for result in results),[r.stderr for r in results])
        history=ProductionHistory(app,self.root)
        self.assertEqual(history.query('2000-01-01','9999-12-31')['total'],24)
        with history.connect() as db:
            latest=db.execute('SELECT MAX(occurred_at_us) FROM production_events').fetchone()[0]
        self.assertEqual(ClockGuard(self.root).check()['last_production_us'],latest)

    def test_haskell_resumes_after_audited_clock_recovery(self):
        import time
        from launcher.recover_clock import recover
        app = APPLICATIONS[0]
        self.assertEqual(self.run_probe(app).returncode, 0)
        future = time.time_ns() // 1000 + 8 * 3600_000_000
        with sqlite3.connect(self.root / 'clock.sqlite3') as db:
            db.execute('UPDATE clock_state SET high_water_us=?,last_production_us=?', (future, future))
        self.assertNotEqual(self.run_probe(app, 'init').returncode, 0)
        recover(self.root, time.time_ns() // 1000, 'test NTP correction', 'test clock',
                apply=True, state_directory=self.root / 'state')
        for app in APPLICATIONS:
            result = self.run_probe(app)
            self.assertEqual(result.returncode, 0, result.stderr)
        state = ClockGuard(self.root).check()
        self.assertIsNotNone(state['last_production_us'])
        self.assertEqual(state['clock_recovery']['previous_high_water_us'], future)
