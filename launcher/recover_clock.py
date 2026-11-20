"""Explicit maintenance after correcting an incorrectly advanced OS clock.

Normal startup never invokes recovery, even when NTP reports synchronization.
History is immutable: snapshot all databases, audit the old clock state, and
start a new watermark at the independently verified current instant.
"""
from __future__ import annotations

import argparse
from contextlib import ExitStack, closing
from datetime import datetime, timezone
import fcntl
import json
from pathlib import Path
import sqlite3
import subprocess
import time
import uuid

from .processes import ProcessManager
from .production import APPLICATIONS, CLOCK_FLOOR_US, ClockError, display_time, production_directory


AUDIT_SCHEMA = '''CREATE TABLE IF NOT EXISTS clock_recoveries (
 id INTEGER PRIMARY KEY,
 recovered_at_us INTEGER NOT NULL,
 previous_high_water_us INTEGER NOT NULL,
 previous_last_production_us INTEGER,
 reason TEXT NOT NULL,
 verification TEXT NOT NULL,
 backup_directory TEXT NOT NULL
)'''


def verified_time(value: str) -> int:
    instant = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if instant.tzinfo is None:
        raise ValueError('Verified time must include a timezone, for example +08:00 or Z')
    return int(instant.timestamp() * 1_000_000)


def require_ntp() -> None:
    result = subprocess.run(['timedatectl', 'show', '--property=NTPSynchronized', '--value'],
                            capture_output=True, text=True, timeout=10, check=True)
    if result.stdout.strip() != 'yes':
        raise ClockError('Ubuntu does not report NTP synchronization; verify the time independently first')


def recover(directory: Path, verified_us: int, reason: str, verification: str, *,
            apply: bool = False, state_directory: Path | None = None, now_us=None) -> dict:
    now_us = now_us or (lambda: time.time_ns() // 1000)
    if not reason.strip() or not verification.strip():
        raise ValueError('A reason and time verification source are required')
    now = now_us()
    if now < CLOCK_FLOOR_US or abs(now - verified_us) > 60_000_000:
        raise ClockError('System time must agree with verified current time within 60 seconds')
    directory = directory.expanduser().resolve()
    path = directory / 'clock.sqlite3'
    if not path.is_file():
        raise ClockError('Existing clock.sqlite3 is required; recovery will not create missing state')
    manager = ProcessManager(state_directory, directory)
    with ExitStack() as locks:
        # Use the same process locks as the launcher, held through the repair.
        paths = {manager.paths(app)[0] for app in APPLICATIONS}
        paths.update(manager.directory.glob('*.lock'))
        for lock in sorted(paths):
            stream = locks.enter_context(lock.open('a+b'))
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise ClockError('Close all production programs before recovering time records') from exc
        # Also detect applications launched manually, without a supervisor lock.
        for process in Path('/proc').glob('[0-9]*/exe'):
            try:
                executable = str(process.readlink()).removesuffix(' (deleted)')
            except (OSError, PermissionError):
                continue
            if Path(executable).name == 'Camera':
                raise ClockError('Close the manually launched Camera program before recovery')
        writer = locks.enter_context((directory / 'writer.lock').open('a+b'))
        # Haskell uses POSIX record locks (lockf), not flock, for writer.lock.
        fcntl.lockf(writer, fcntl.LOCK_EX)
        with closing(sqlite3.connect(path, timeout=10)) as db:
            db.execute('PRAGMA synchronous=FULL')
            db.execute('BEGIN IMMEDIATE')
            try:
                row = db.execute('SELECT high_water_us,last_production_us FROM clock_state WHERE id=1').fetchone()
                if row is None:
                    raise ClockError('Missing clock state; restore a valid backup')
                previous, production = row
                now = now_us()
                if now < CLOCK_FLOOR_US or abs(now - verified_us) > 60_000_000:
                    raise ClockError('Verified time expired or system time changed; verify again')
                if max(previous, production or 0) <= now:
                    raise ClockError('No future watermark to recover; clock records have not been changed')
                report = dict(previous_high_water_us=previous, previous_last_production_us=production,
                              recovered_at_us=now, reason=reason.strip(), verification=verification.strip(),
                              event_counts={})
                databases = [path]
                for app in APPLICATIONS:
                    event_path = directory / (app + '.sqlite3')
                    if event_path.exists():
                        databases.append(event_path)
                        with closing(sqlite3.connect(event_path.as_uri() + '?mode=ro', uri=True)) as events:
                            report['event_counts'][app] = events.execute(
                                'SELECT COUNT(*),COALESCE(SUM(occurred_at_us>?),0) FROM production_events',
                                (now,)).fetchone()
                if not apply:
                    return report
                stamp = datetime.fromtimestamp(now / 1_000_000, timezone.utc).strftime('%Y%m%dT%H%M%SZ')
                backup = directory.parent / 'clock-recovery-backups' / (stamp + '-' + uuid.uuid4().hex[:8])
                backup.mkdir(parents=True, mode=0o700)
                # Back up the pre-recovery committed snapshot, including WAL data.
                # The main write transaction blocks launcher updates; writer.lock
                # blocks Haskell event writers for the entire snapshot and reset.
                for database in databases:
                    with closing(sqlite3.connect(database.as_uri() + '?mode=ro', uri=True)) as source:
                        with closing(sqlite3.connect(backup / database.name)) as target:
                            source.backup(target)
                            if target.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
                                raise ClockError('Backup integrity check failed')
                report['backup_directory'] = str(backup)
                (backup / 'recovery.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
                db.execute(AUDIT_SCHEMA)
                db.execute('''INSERT INTO clock_recoveries(recovered_at_us,previous_high_water_us,
                    previous_last_production_us,reason,verification,backup_directory) VALUES(?,?,?,?,?,?)''',
                    (now, previous, production, report['reason'], report['verification'], str(backup)))
                # Old event timestamps cannot safely be reconstructed from a
                # timezone offset: the clock may have jumped more than once.
                # Preserve them and explicitly start a new production-time era.
                db.execute('UPDATE clock_state SET high_water_us=?,last_production_us=NULL WHERE id=1', (now,))
                db.commit()
                return report
            finally:
                if db.in_transaction:
                    db.rollback()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=production_directory())
    parser.add_argument('--reason', required=True)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--verified-time', help='Independently verified current ISO timestamp including timezone')
    group.add_argument('--use-synchronized-system-time', action='store_true', help='Require Ubuntu NTP synchronization')
    parser.add_argument('--apply', action='store_true', help='Back up, audit and reset; default only previews')
    args = parser.parse_args()
    try:
        if args.use_synchronized_system_time:
            require_ntp()
            verified = time.time_ns() // 1000
            verification = 'timedatectl NTPSynchronized=yes'
        else:
            verified = verified_time(args.verified_time)
            verification = 'independently verified current time: ' + args.verified_time
        report = recover(args.directory, verified, args.reason, verification, apply=args.apply)
        print('APPLIED' if args.apply else 'PREVIEW (use --apply to back up and recover)')
        print('Previous watermark:', display_time(report['previous_high_water_us']))
        print('Previous production (original timestamp retained):', display_time(report['previous_last_production_us']))
        print('Verified current time:', display_time(report['recovered_at_us']))
        print(json.dumps(report, ensure_ascii=False, indent=2))
        print('Reopen the launcher after applying recovery. Original production event rows are unchanged.')
        return 0
    except (OSError, ValueError, sqlite3.Error, subprocess.SubprocessError) as error:
        parser.exit(1, 'Recovery refused: ' + str(error) + '\n')


if __name__ == '__main__':
    raise SystemExit(main())
