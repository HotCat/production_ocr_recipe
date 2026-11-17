import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

os.environ.setdefault('QT_QPA_PLATFORM','offscreen')
from PySide6.QtCore import QDate, QCoreApplication, QEvent
from PySide6.QtWidgets import QApplication, QMessageBox

from launcher.config import ConfigStore
from launcher.history_ui import ProductionHistoryWindow
from launcher.processes import ProcessManager
from launcher.production import APPLICATIONS, ProductionHistory, SCHEMA_DIRECTORY
from launcher.ui import LauncherWindow


class HistoryUiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app=QApplication.instance() or QApplication([])

    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.history=ProductionHistory(APPLICATIONS[0],self.root)
        with sqlite3.connect(self.history.path) as db:
            db.execute((SCHEMA_DIRECTORY/'events.sql').read_text())
            for day,passed in [('2026-11-16','OK'),('2026-11-17','OK'),('2026-11-17','NG')]:
                db.execute('''INSERT INTO production_events(app,occurred_at_us,timestamp_utc,timestamp_local,local_date,result,barcode,integrity_guard,reverse)
                VALUES(?,?,?,?,?,?,?,?,?)''',(APPLICATIONS[0],123,'2026-11-17T00:00:00.123Z','2026-11-17T08:00:00.123+0800',day,passed,'条码001',1,0))

    def dispose(self, window):
        window.close()
        window.deleteLater()
        QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)
        self.app.processEvents()

    def test_calendar_counts_day_selection_filter_and_live_refresh(self):
        window=ProductionHistoryWindow(self.history,'条码 + 序列号')
        self.addCleanup(self.dispose, window)
        window.calendar.setCurrentPage(2026,11)
        self.assertEqual(window.calendar.counts['2026-11-17']['ng'],1)
        self.assertEqual(window.calendar.counts['2026-11-16']['ng'],0)
        window.choose_day(QDate(2026,11,17))
        self.assertEqual(window.table.rowCount(),2)
        window.result_filter.setCurrentText('NG');window.query()
        self.assertEqual(window.table.rowCount(),1)
        self.assertEqual(window.rows[0]['barcode'],'条码001')
        with sqlite3.connect(self.history.path) as db:
            db.execute("DELETE FROM production_events WHERE result='NG'")
        window.query()
        self.assertEqual(window.table.rowCount(),0)
        self.assertEqual(window.calendar.counts['2026-11-17']['ng'],0)
        window.calendar.setCurrentPage(2026,12)
        self.assertEqual(window.calendar.counts,{})

    def test_launcher_opens_reusable_history_and_blocks_all_launches_for_bad_clock(self):
        store=ConfigStore(self.root/'config.json');store.load()
        manager=ProcessManager(self.root/'state',self.root)
        window=LauncherWindow(store,manager)
        self.addCleanup(self.dispose, window)
        window.show_production_history()
        history_window=window.history_windows[APPLICATIONS[0]]
        window.show_production_history()
        self.assertIs(window.history_windows[APPLICATIONS[0]],history_window)
        with sqlite3.connect(manager._clock.path) as db:
            good=db.execute('SELECT high_water_us FROM clock_state').fetchone()[0]
            db.execute('UPDATE clock_state SET high_water_us=high_water_us+86400000000')
        with patch.object(window,'report_error') as warning:
            for row in window.rows.values():
                window.program_list.setCurrentItem(row)
                window.refresh_status()
                self.assertFalse(window.launch_button.isEnabled())
                self.assertTrue(window.history_button.isEnabled())
            self.app.processEvents()
            self.assertEqual(warning.call_count,1)
        with sqlite3.connect(manager._clock.path) as db:
            db.execute('UPDATE clock_state SET high_water_us=?',(good,))
        window.refresh_status()
        self.assertTrue(window.launch_button.isEnabled())
