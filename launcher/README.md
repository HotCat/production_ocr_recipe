# Production OCR launcher / 生产 OCR 启动器

A PySide6 launcher for Ubuntu 24.04. Operators select a program, inspect its
parameters, save them, and launch one instance. The UI contains **no program
add/remove controls**. Available programs, camera names, parameter definitions
and environment mappings are managed in JSON.

## Install and start

From the repository root, with the OCR applications already built:

```sh
scripts/install-launcher.sh
scripts/run-launcher.sh
```

The installer creates `launcher/.venv` with Ubuntu’s `/usr/bin/python3`, installs
PySide6, initializes the user
configuration if missing, and adds **生产 OCR 启动器 / Production OCR Launcher**
to the desktop application menu. It does not start the OCR clients or service.
Using the system interpreter avoids Conda X11/XKB library conflicts that can
cause a native crash during Qt startup. Re-running the installer rebuilds an
existing environment if its base interpreter differs. An explicit alternative
can be provided with `OCR_LAUNCHER_BASE_PYTHON`.
Only Python/PySide6 is needed on a deployment host; the launcher itself needs
no Haskell compiler. The clients and their native SDK dependencies must already
be installed. For offline installation, supply PySide6 wheels through your
normal pip wheel cache/index provisioning.

The default five entries use `scripts/run-app.sh`, which sets the working
directory, seeds missing Scheme profiles and loads native libraries. After
configuring non-system SDK paths with `scripts/configure-local.py`, its ignored
`runtime-libraries.local.json` also supplies those paths when launching from the
desktop. Regenerate local paths after moving a checkout. Installed releases can
use their own foreground executable/launcher instead; set `command` and `cwd`
in the configuration file accordingly.

For a double-clickable desktop shortcut, copy the installed menu entry to the
Ubuntu desktop, make it executable and mark it trusted:

```sh
launcher_desktop_dir=$(xdg-user-dir DESKTOP)
cp ~/.local/share/applications/production-ocr-launcher.desktop "$launcher_desktop_dir/"
chmod +x "$launcher_desktop_dir/production-ocr-launcher.desktop"
gio set "$launcher_desktop_dir/production-ocr-launcher.desktop" metadata::trusted true
```

## Configuration file

Default location:

```text
~/.config/production-ocr-launcher/config.json
```

`XDG_CONFIG_HOME` changes the configuration root. A new file is seeded once from
[defaults.json](defaults.json). Existing settings are preserved on upgrades.
For a separate site configuration or repository path:

```sh
scripts/run-launcher.sh --config /path/to/site.json --repo /path/to/production_ocr_recipe
scripts/run-launcher.sh --config /path/to/site.json --check-config
```

Edit the `programs` array to add/remove/reorder entries. Default `cameras`
candidates are `Hikvision`, `MV-SUA131GC#0` and `MV-GE502M-T`; each program initially selects
`Hikvision`. This selects the unique Hikvision/Hikrobot camera, ignoring MVS
entries belonging to other manufacturers such as MindVision. For multiple
Hikvision cameras, add `Hikvision:SERIAL` candidates using the exact MVS serial
numbers, reload configuration and select the desired camera in the inspector.
The list is configured, not discovered from hardware. Adding an arbitrary label
does not implement a new camera backend. See [camera selection](../docs/CAMERA_SELECTION.md).
Each program has its own `values`, so selecting another program does not overwrite its camera or Modbus address. Click **保存参数** to persist edits;
**启动程序** also saves before launching. Invalid IPv4 addresses or port ranges
block saving/launching. Changes affect the next launch.

After editing JSON, click **重新读取配置**. The launcher validates the entire
file before replacing the UI. Invalid files are preserved for correction. It
also refuses to overwrite a file that changed externally since it was loaded,
so saving inspector values cannot silently undo an edited program list.
Unsaved inspector values remain while switching selections and prompt for
save/discard when reloading or closing.

A program entry looks like:

```json
{
  "id": "Barcode+Sequence",
  "instance_key": "Barcode+Sequence",
  "name": "条码 + 序列号",
  "command": ["{repo}/scripts/run-app.sh", "Barcode+Sequence"],
  "cwd": "{repo}",
  "parameters": {
    "camera": "SEQUENCE_OCR_CAMERA",
    "modbus_host": "BARCODE_SEQUENCE_MODBUS_HOST",
    "modbus_port": "BARCODE_SEQUENCE_MODBUS_PORT"
  },
  "values": {
    "camera": "Hikvision",
    "modbus_host": "192.168.0.68",
    "modbus_port": 4998
  },
  "environment": {}
}
```

Use a stable `id` and `instance_key` when renaming an entry. Give alternate
entries for the same underlying application the **same `instance_key`** so
they share one instance lock. `command` is an argument array and runs directly,
without a shell. Commands must remain in the foreground for their whole
lifetime; a wrapper should `exec` its application rather than background it.
`{repo}` and `{parameter_key}` substitute individual argument tokens and static
`environment` values. Explicit parameter bindings take precedence over static
environment entries. Ambient display/session and SDK environment is inherited.
To launch a custom program it must understand the environment/argument mapping
you configure; the launcher cannot invent an interface for it.

## Optional English text angle classification (JSON only)

Each of the four English/serial/barcode program entries has its own boolean:

```json
"use_angle_cls": false
```

Set it to `true` alongside `id`, `values` and `environment` in the desired
`programs` entry in `~/.config/production-ocr-launcher/config.json`. It is **not**
an inspector `parameters`/`values` entry and adds no UI control. Omitted means
`false`, preserving existing configurations. Save/reload preserves the flag;
the launcher exports `PADDLEOCR_USE_ANGLE_CLS=1` or `0` for that program.
Separate entries may select different settings while sharing the same service.
`Engraving+Compare` / 刻字与预设文字比对 retains its Chinese OCR pipeline and
does not have this option. Sequence `Reverse` settings are unrelated.

First provision the optional classifier as described in
[the service guide](../services/paddleocr_service/README.md#optional-angle-classification).
For this code upgrade, rebuild the four English clients, restart the OCR
service during a production break, and restart the launcher to load the updated
Python code. For subsequent JSON-only edits, click **重新读取配置**, then close
and relaunch the affected OCR program; a running process retains its setting.

The launcher's **运行日志** identifies the active setting on every timed request:

```text
[PaddleOCR] status=OK request_ms=30.906 use_angle_cls=true
```

Compare warmed requests on the same production regions. The first enabled
request on each service worker includes one-time classifier loading/warmup.
The service also includes a repeatable latency comparison command; see its guide.

## Add a parameter without editing Python

Add a definition in the top-level `parameters` object, then bind it in each
applicable program's `parameters`. For example:

```json
"ocr_endpoint": {
  "label": "OCR 服务地址",
  "type": "string",
  "default": "tcp://127.0.0.1:5555"
}
```

In a program entry, add `"ocr_endpoint": "PADDLEOCR_ENDPOINT"` to its parameter
mapping and optionally set `"ocr_endpoint"` in its `values`. After reload a new
text field appears and the saved value is passed to the existing OCR client.

Supported types are `string`, `choice`, `integer` and `boolean`. A choice uses
`choices: ["A", "B"]` or `choices_from: "cameras"`; integers can define
`minimum`/`maximum`; strings can use `format: "ipv4"` and `required: false`.
Booleans are passed as `1`/`0`. An empty environment binding is allowed when the
value is supplied through a `{parameter_key}` command argument instead.
Applications must actually support a parameter before it can affect behavior.

## Existing client mappings

| Program | Camera environment | Modbus environment prefix |
| --- | --- | --- |
| Barcode+Sequence | SEQUENCE_OCR_CAMERA | BARCODE_SEQUENCE |
| Barcode+Sequence+Barcode | DOUBLE_BARCODE_CAMERA | DOUBLE_BARCODE |
| Barcode+Sequence+Engraving | BARCODE_ENGRAVING_CAMERA | BARCODE_ENGRAVING |
| Engraving+Sequence | SEQUENCE_CAMERA | SEQUENCE |
| Engraving+Compare | ENGRAVING_COMPARE_CAMERA | ENGRAVING_COMPARE |

Modbus variables are `<PREFIX>_MODBUS_HOST`, `_MODBUS_PORT` and optionally
`_MODBUS_SLAVE`. The defaults remain `192.168.0.68`, `4998`, slave `3`.
The three barcode clients now honor these variables; the engraving clients
already did. Existing Scheme inspection/calibration settings remain separate.

## Process lifetime and logs

Each launched program has a Linux `flock` held by a detached supervisor and
inherited by the application. A second launch is rejected atomically, including
simultaneous requests from separate launcher processes. Closing/reopening the
launcher does not stop the application or lose its lock. Even if the monitor
is killed, an application that retains the inherited descriptor keeps its
lock until it exits. Normal exit, startup failure and crashes release the
lock and allow relaunch; stale PID records alone never block a program.

The UI refreshes state automatically and disables launch/parameter editing
while that program runs. It shows startup errors, exit codes and the last 64 KiB
of stdout/stderr in **运行日志**. Logs rotate at 2 MiB with two backups. State and
logs live under `~/.local/state/production-ocr-launcher` (`XDG_STATE_HOME` is
honored). `PRODUCTION_OCR_LAUNCHER_STATE_DIR` provides an isolated state root for
tests. Use the same state root across production launchers to share locks.
One UI is allowed per configuration file, with Qt's stale-aware UI lock.

This tracks applications started through this launcher. Independently started
processes that do not participate in its locks are not adopted. Close any such
instance before switching to the launcher. The launcher does not start a new
PaddleOCR server per client; clients continue to share the configured service.

## Validation

```sh
QT_QPA_PLATFORM=offscreen launcher/.venv/bin/python -m unittest discover -s launcher/tests -v
scripts/run-launcher.sh --check-config
# Development host: compile the three client modules and check a loopback Modbus peer.
scripts/test-launcher-modbus.sh
```

The tests cover configuration isolation/persistence, externally edited program
lists, extensible forms, IPv4 validation, duplicate races, launcher restarts,
monitor failure, abnormal exit, relaunch and UI enable/disable behavior. Test
workers are harmless Python processes; no camera or production PLC is used.
The Python/Qt tests pass with PySide6 6.12.0 and Ubuntu Python 3.12.3.
A desktop startup regression test runs the actual shell wrapper and X11 plugin,
covering the native initialization path that offscreen tests miss. The three modified Haskell
clients were rebuilt, and their real Haskell/C++ Modbus modules reached an
ephemeral loopback peer using configured IP/port/slave settings. The Chinese UI was rendered
and visually checked at 1140×760.

## Production history and offline clock protection

Select a program and click **生产记录 / 日历** in its inspector. This opens a
separate, reusable history window without interrupting inspection. The calendar
shows each day's production count: green means all OK; red means at least one NG.
Click a date or select a date range, optionally filter OK/NG or search a barcode,
serial, detected/preset text, bank, or failure reason. Results have 200-row pages;
double-click a row for all fields and complete text. Click 查询 / 刷新 for new
records while the production app is running. History remains accessible when the
clock guard blocks launches.

The five apps each write their own SQLite database. The default directory is:

```
~/.local/share/production-ocr/production-logs/
  Barcode+Sequence.sqlite3
  Barcode+Sequence+Barcode.sqlite3
  Barcode+Sequence+Engraving.sqlite3
  Engraving+Sequence.sqlite3
  Engraving+Compare.sqlite3
  clock.sqlite3
```

`XDG_DATA_HOME` changes the data root; `OCR_PRODUCTION_LOG_DIR` overrides the whole
directory. Set it for the launcher process (not independently per program): the
launcher passes its resolved directory to every child. Directly started clients
use the same defaults. Use one Unix operator account / one common directory for
a workstation's production applications. Databases are outside the source tree,
not committed to Git, and never automatically deleted.

Only final production OK/NG decisions are inserted, immediately **before** the
corresponding counter/PLC output. Preview/evaluation OCR attempts are excluded.
No verdict is recorded where the existing workflow makes no decision (for
example, a missing sequence marker). If a database write or time check fails,
the app stops with an error rather than issuing an unrecorded PLC result. See
运行日志 for that error. A row records the software's decision; it does not prove
that the PLC received it, and an unexpected crash after commit may leave a row
without a completed PLC signal.

| Application | Recorded data in addition to OK/NG and timestamps |
| --- | --- |
| Barcode+Sequence | Full decoded barcode, integrity guard, Reverse |
| Barcode+Sequence+Barcode | Both full decoded barcodes, independent integrity guards, the single product Reverse control |
| Barcode+Sequence+Engraving | Full decoded barcode, serial and full OCR text, integrity guard, Reverse, bank name/index/serial length |
| Engraving+Sequence | Numeric recognized serial, full OCR text, Reverse |
| Engraving+Compare | Actual inspection preset and full detected text; no sequence requirement |

Packaging has **no** separate Reverse control. Settings changes that invalidate
pending engraving comparison results produce NG with the original preset and
recognized text retained. Bank choices and their serial lengths share
`apps/Barcode+Sequence+Engraving/src/BankRecipes.hs`; adding a bank there updates
the combo and the name logged. Applicable settings are booleans; unrelated fields
are SQL NULL or empty text. Each row includes UTC epoch microseconds, full UTC
and local timestamps with fractional seconds, local timezone offset and local
calendar date. The date distribution uses the local date saved at production,
even if the workstation timezone later changes.

The launcher displays the last production time and persists a shared time
watermark. Startup, each actual launch, periodic launcher checks, and every
production verdict check the clock. The last production time commits atomically
with its event. If system time is earlier than recorded production/observed time,
a warning explains the problem and all launch buttons are disabled. Correct the
BIOS/Ubuntu date and time and inspect/replace the motherboard battery; the
launcher automatically enables launches after time is valid. There is no Ignore
button. Corrupt, inaccessible or incomplete clock state also blocks launching.

The initial minimum date is 2026-11-17 00:00 UTC, so a fresh installation with a
BIOS default date is rejected even before its first production run. With no
network or trusted hardware clock this detects regression, **not** the absolute
correct date, forward jumps, or deliberate deletion/restoration of state. Do not
set the clock ahead: a subsequently corrected earlier date requires the audited
maintenance recovery below. Never delete clock.sqlite3 to dismiss a time warning.
The clock and history files must be preserved across deployments.

### 校时后恢复 / Recovery after correcting an advanced clock

All guard comparisons use UTC epoch microseconds. Displaying `+08:00` changes
only presentation; switching between UTC and Asia/Shanghai does not change the
stored instant. If the actual OS clock was ahead (for example, BIOS/RTC local
time interpreted as UTC), then corrected backward by NTP, the old future
watermark will correctly block launches even though the current time is valid.
`journalctl -u systemd-timesyncd` can distinguish this case from a display issue.

First check the real date against a trusted source and fix Ubuntu/BIOS time.
Ubuntu normally uses a UTC hardware clock: `timedatectl` should report the
intended local timezone and `RTC in local TZ: no`. Keep the BIOS RTC convention
consistent with Ubuntu; do not set UTC RTC to local wall time. Do not advance
the OS clock simply to satisfy an incorrect saved watermark.

Close all five production applications and the launcher. From the repository
root, preview recovery using Ubuntu's synchronized network clock:

```sh
launcher/.venv/bin/python -m launcher.recover_clock \
  --use-synchronized-system-time \
  --reason 'NTP corrected an incorrectly advanced BIOS/RTC clock'
```

After reviewing the previous/current times, run the same command with `--apply`.
This option requires `timedatectl` to report `NTPSynchronized=yes`; recovery is
never called automatically by normal startup or merely because NTP is enabled.
For an offline installation, verify the date independently and replace
`--use-synchronized-system-time` with `--verified-time '2026-11-20T16:00:00+08:00'`
using the **actual current time**, not that example. The supplied time must
include a timezone and agree with the OS within 60 seconds. Time before the
minimum supported date, missing/corrupt state, active apps, or backup failure
refuse recovery. `--directory PATH` selects a nondefault production-log root.

Recovery holds the application/writer locks, backs up all existing production
databases using SQLite's backup API, and saves `recovery.json` under
`~/.local/share/production-ocr/clock-recovery-backups/` (beside the selected log
directory). In `clock.sqlite3`, `clock_recoveries` records the old watermark,
old last-production time, verified current instant, reason, verification source
and backup path. The new watermark is current time; last production resets to
“校时后尚无生产记录” until the next verdict. The original last-production value
remains in the audit and backup. Every original event and timestamp stays
unchanged: a fixed eight-hour subtraction cannot reconstruct timestamps after
multiple system clock jumps. The launcher shows a notice that history before
recovery may have inaccurate times. Calendar searches still use saved dates.

Reopen the launcher after recovery to clear its old in-memory time watermark
and load the updated notice. All future clock-regression checks stay enabled,
including the checks in the five compiled Haskell apps; no app rebuild is needed.

For a consistent backup, close **all five apps and the launcher**, then copy the
whole production-logs directory (including clock.sqlite3) to backup storage.
When taking live backups, use SQLite's backup API per file, retaining a clock
backup at least as new as all backed-up events; do not copy open database files
individually. Keep sufficient free space and back up this directory regularly.

Development checks (all use temporary log data and no camera/PLC):

```sh
scripts/test-production-logs.sh
launcher/.venv/bin/python -m unittest discover -s launcher/tests -v
```

## Offline Modbus debug trigger

In `~/.config/production-ocr-launcher/config.json`, add/edit the **top-level**
boolean (alongside `schema_version`, not inside a program's `values`):

```json
"debug_mode": true
```

The default is `false`; old configuration files without the key also default to
production mode. Save the file, click **重新读取配置** in the launcher (or restart
it), and close/relaunch the OCR clients. Running clients keep their launch-time
mode. The inspector identifies debug mode, with no operator switch for it.

In all five clients, debug mode shows **触发modbus** beside **保存参数**. One
accepted click submits one normal inspection of the current camera regions.
Real camera capture, PaddleOCR when applicable, print guards, sequence checks,
counters, and SQLite logging still run. It bypasses real Modbus initialization,
reads and OK/NG writes entirely, so no PLC connection is required. A second
click during an active cycle is rejected with a console message; after completion
the same label may be inspected again. Invalid regions/missing codes produce NG
rather than silently waiting for a successful decode. The four sequence clients
require an initial sequence value/region; if missing, the console explains what
to set before triggering. The comparator uses its normal preset-text matching.

Debug events are retained in each client's normal SQLite database with
`debug_mode=1`; launcher production history shows a **调试模式** column. Existing
records migrate to `debug_mode=0` without losing data. Debug inspections advance
counters and sequence numbers according to their results, and the production
clock checks remain active. Restore the appropriate starting number after tests.
Set `debug_mode` back to `false`, reload the launcher, and restart the clients to
hide the button and resume PLC operation. Debug history is not deleted.

The launcher always passes `OCR_DEBUG_MODE=1` or `0` explicitly, overriding any
inherited or per-program value. Direct developer runs bypass launcher JSON;
use `OCR_DEBUG_MODE=1 scripts/run-app.sh 'Barcode+Sequence'` explicitly for debug
(default when unset is production). No other developer flag enables it.

Hardware-free regression checks:

```sh
scripts/test-debug-modbus.sh
scripts/test-production-logs.sh
launcher/.venv/bin/python -m unittest discover -s launcher/tests -v
```


### Client CPU capabilities

Per-app CPU/GPU selection is JSON-only: add `"ocr_dispatch": "cpu"`, `"gpu"`
or `"auto"` beside a program's `name` (outside `values`). Missing fields use
CPU; new defaults use `auto` for Engraving+Compare and CPU for the four English
apps. After upgrading, restart the launcher; after JSON edits, reload its
configuration and relaunch the affected app. `auto` prefers a ready GPU and
uses CPU when GPU is unavailable. A failed GPU request is never replayed.
See [GPU dispatch and offline deployment](../docs/GPU_OCR_DEPLOYMENT.md).

Every PaddleOCR request now prints one timing entry to **运行日志**, without
enabling CPU profiling:

```text
[PaddleOCR] status=OK request_ms=123.456 use_angle_cls=false dispatch=cpu
```

`request_ms` is elapsed wall time in milliseconds for the complete client
request: image encoding, service queue/network waits, inference and reply
decoding. It is not an isolated measurement of the model's inference time.
Statuses are `OK`, `EMPTY`, `ERROR` (including timeouts) and `CANCELLED`.
Errors still follow the application's existing NG/error handling. Timing goes
to stderr, which the launcher captures alongside normal console output, while
headless OCR command stdout continues to contain only the recognized text.
`dispatch` is the requested policy; the service journal shows the actual device.
The Chinese app omits `use_angle_cls` because that option applies to English.

The five Haskell clients use two GHC RTS capabilities by default. The launcher
starts them through `scripts/run-app.sh`, which explicitly sets `GHCRTS=-N2` and
therefore ignores an inherited unlimited `GHCRTS` value. For a lower-power
machine, set `OCR_RTS_CAPABILITIES=1` before launching; values other than `1` or
`2` are rejected. This cap applies to Haskell scheduling and garbage collection.
All five clients separately default OpenCV to one native thread before opening
the camera. `OCR_OPENCV_THREADS=1..16` overrides that setting; `auto` restores
OpenCV's machine-dependent default for diagnosis.

To investigate a client, add `"OCR_CPU_PROFILE": "1"` to its `environment` in
the launcher configuration before its next launch. Five-second reports appear
in its runtime log; remove the setting after diagnosis. This does not change
camera settings, inspection rules or trigger polling. See
[CPU profiling](../docs/CPU_PROFILING.md) for live results and timing limitations.
