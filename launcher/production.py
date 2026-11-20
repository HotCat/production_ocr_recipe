"""Read-only production history and a cross-application persisted clock guard."""
from __future__ import annotations

from contextlib import closing
from datetime import datetime, timezone
import os
from pathlib import Path
import sqlite3
import time

from .config import REPOSITORY

SCHEMA_DIRECTORY = REPOSITORY / 'shared/production-log'
CLOCK_FLOOR_US = int((SCHEMA_DIRECTORY / 'clock-floor-us.txt').read_text())
APPLICATIONS = ('Barcode+Sequence', 'Barcode+Sequence+Barcode', 'Barcode+Sequence+Engraving',
                'Engraving+Sequence', 'Engraving+Compare')


def production_directory() -> Path:
    override = os.environ.get('OCR_PRODUCTION_LOG_DIR')
    if override:
        return Path(override).expanduser().resolve()
    data = Path(os.environ.get('XDG_DATA_HOME', str(Path.home() / '.local/share')))
    return data / 'production-ocr/production-logs'


class ClockError(ValueError):
    pass


def display_time(microseconds: int | None) -> str:
    if microseconds is None:
        return '尚无生产记录'
    return datetime.fromtimestamp(microseconds / 1_000_000, timezone.utc).astimezone().isoformat(timespec='seconds')


class ClockGuard:
    """Block rollback; only an explicit, backed-up maintenance recovery can reset it."""
    def __init__(self, directory: Path | None = None, now_us=None):
        self.directory = (directory or production_directory()).resolve()
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.path = self.directory / 'clock.sqlite3'
        self.now_us = now_us or (lambda: time.time_ns() // 1000)
        self.last_observed = 0
        self.last_persisted = 0
        self.last_production = None
        with closing(sqlite3.connect(self.path, timeout=10)) as connection:
            connection.execute('PRAGMA synchronous=FULL')
            connection.execute('BEGIN IMMEDIATE')
            exists = connection.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='clock_state'").fetchone()
            if not exists:
                connection.execute((SCHEMA_DIRECTORY / 'clock.sql').read_text())
                connection.execute('INSERT INTO clock_state VALUES(1,?,NULL)', (CLOCK_FLOOR_US,))
            elif connection.execute('SELECT high_water_us FROM clock_state WHERE id=1').fetchone() is None:
                raise ClockError('时间记录缺失，已禁止启动。请恢复生产数据库的备份。')
            connection.commit()

    def check(self, persist: bool = False) -> dict:
        try:
            with closing(sqlite3.connect(self.path, timeout=10)) as connection:
                if persist:
                    connection.execute('PRAGMA synchronous=FULL')
                    connection.execute('BEGIN IMMEDIATE')
                row = connection.execute('SELECT high_water_us,last_production_us FROM clock_state WHERE id=1').fetchone()
                if row is None:
                    raise ClockError('时间记录缺失，已禁止启动。请恢复生产数据库的备份。')
                latest, production = row
                now = self.now_us()
                minimum = max(latest, production or 0, self.last_observed, CLOCK_FLOOR_US)
                self.last_production = production
                if now < minimum:
                    raise ClockError(f'系统日期时间异常，已禁止启动所有生产程序。\n当前时间：{display_time(now)}\n'
                                     f'已记录时间：{display_time(minimum)}\n上次生产：{display_time(production)}\n'
                                     '请检查主板电池，校准 BIOS 和 Ubuntu 日期时间后重试。\n'
                                     '若 Ubuntu/NTP 已将错误的未来时间校准回正确时间，须由维护人员执行时间记录恢复；'
                                     '请勿删除数据库或将系统时间调到未来。参见 launcher/README.md「校时后恢复」。')
                if persist:
                    connection.execute('UPDATE clock_state SET high_water_us=? WHERE id=1', (now,))
                    connection.commit()
                    self.last_persisted = now
                self.last_observed = now
                recovery = None
                if connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='clock_recoveries'").fetchone():
                    connection.row_factory = sqlite3.Row
                    row = connection.execute('SELECT * FROM clock_recoveries ORDER BY id DESC LIMIT 1').fetchone()
                    recovery = dict(row) if row else None
                return {'high_water_us': max(latest, now), 'last_production_us': production,
                        'clock_recovery': recovery}
        except sqlite3.Error as error:
            raise ClockError(f'无法读取/保存生产时间，已禁止启动：{error}') from error

    def observe(self) -> dict:
        # The database is checked every UI refresh, but fsync is limited to once
        # per minute. Production writers update it atomically on every verdict.
        return self.check(persist=(not self.last_persisted or self.now_us() - self.last_persisted >= 60_000_000))


class ProductionHistory:
    def __init__(self, app: str, directory: Path | None = None):
        if app not in APPLICATIONS:
            raise ValueError('该程序尚未配置生产记录接口')
        self.app = app
        self.path = (directory or production_directory()) / (app + '.sqlite3')

    def connect(self):
        connection = sqlite3.connect(self.path.resolve().as_uri() + '?mode=ro', uri=True, timeout=3)
        connection.row_factory = sqlite3.Row
        connection.execute('PRAGMA query_only=ON')
        return connection

    def distribution(self, start: str, end: str) -> dict:
        if not self.path.exists():
            return {}
        with closing(self.connect()) as connection:
            rows = connection.execute('''SELECT local_date,COUNT(*) AS total,
                SUM(result='OK') AS ok,SUM(result='NG') AS ng
                FROM production_events WHERE local_date BETWEEN ? AND ?
                GROUP BY local_date''', (start, end)).fetchall()
        return {r['local_date']: dict(r) for r in rows}

    def query(self, start: str, end: str, result: str = '', search: str = '', offset: int = 0, limit: int = 200) -> dict:
        if not self.path.exists():
            return {'rows': [], 'total': 0, 'ok': 0, 'ng': 0}
        if result not in ('', 'OK', 'NG') or limit < 1 or limit > 1000 or offset < 0:
            raise ValueError('无效的生产记录查询')
        clause = 'local_date BETWEEN ? AND ?'
        parameters = [start, end]
        if result:
            clause += ' AND result=?'
            parameters.append(result)
        if search:
            fields = ['barcode', 'packaging_barcode', 'serial_number', 'detected_text', 'preset_text', 'bank', 'reason']
            clause += ' AND (' + ' OR '.join('instr(' + field + ',?)>0' for field in fields) + ')'
            parameters += [search] * len(fields)
        with closing(self.connect()) as connection:
            # Keep counts and the page in one read snapshot while production appends.
            connection.execute('BEGIN')
            counts = connection.execute('SELECT COUNT(*) AS total,COALESCE(SUM(result=\'OK\'),0) AS ok,COALESCE(SUM(result=\'NG\'),0) AS ng FROM production_events WHERE ' + clause, parameters).fetchone()
            rows = connection.execute('SELECT * FROM production_events WHERE ' + clause + ' ORDER BY occurred_at_us DESC,id DESC LIMIT ? OFFSET ?', parameters + [limit, offset]).fetchall()
        return dict(counts, rows=[dict(row) for row in rows])
