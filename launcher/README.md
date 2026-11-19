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
set the clock ahead: a subsequently corrected earlier date will remain blocked
until it reaches the saved watermark. Never delete clock.sqlite3 to dismiss a
time warning. The clock and history files must be preserved across deployments.

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
