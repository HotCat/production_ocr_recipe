#!/usr/bin/env python3
"""Read-only five-second /proc CPU sample; one occupied core equals 100%.

No debugger attachment, camera or PLC calls. The process total includes threads
that exit between samples; thread rows include only those present in both.
"""
import argparse
import json
import os
from pathlib import Path
import time


def ticks(path):
    raw = path.read_text()
    # comm may contain spaces or parentheses; fields start after its final ')'.
    fields = raw[raw.rfind(")") + 2:].split()
    return int(fields[11]) + int(fields[12])


def threads(root):
    result = {}
    for task in (root / "task").iterdir():
        try:
            result[task.name] = (ticks(task / "stat"), (task / "comm").read_text().strip())
        except (FileNotFoundError, ProcessLookupError):
            pass  # A thread can end while its /proc entries are being read.
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pid", type=int, help="running application's process ID")
    args = parser.parse_args()
    root = Path("/proc") / str(args.pid)
    hz = os.sysconf("SC_CLK_TCK")
    try:
        cwd = str((root / "cwd").resolve(strict=True))
        before = threads(root)
        total_before = ticks(root / "stat")
        start = time.monotonic()
        time.sleep(5)
        total_after = ticks(root / "stat")
        elapsed = time.monotonic() - start
        after = threads(root)
    except (FileNotFoundError, ProcessLookupError, PermissionError) as exc:
        parser.exit(1, f"Cannot sample process {args.pid}: {exc}\n")

    def percentage(delta):
        return round(100 * delta / hz / elapsed, 2)

    rows = [
        {"tid": int(tid), "name": name,
         "cpu_pct": percentage(value - before[tid][0])}
        for tid, (value, name) in after.items() if tid in before
    ]
    rows.sort(key=lambda row: -row["cpu_pct"])
    print(json.dumps({
        "pid": args.pid, "cwd": cwd, "seconds": elapsed,
        "total_cpu_pct": percentage(total_after - total_before), "threads": rows,
    }, indent=2))


if __name__ == "__main__":
    main()
