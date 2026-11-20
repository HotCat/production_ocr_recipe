# Import validation

Validated on the existing Ubuntu 24.04 amd64 development workstation on
2026-11-17. This validates relocated source builds against the separately
installed native stack and SDKs; it is not a clean-machine provisioning test.
No camera, PLC, engraving machine or GUI was started by these checks. Existing
production checkouts and their running services were preserved.

## Builds

- `scripts/build-native.sh`: built `libFFPLibrary.so` and `libreconstruct.so`
  from `dependencies/vision-native` using the included CMake files.
- `scripts/build-all.sh`: built all five independent `Camera` executables with
  Stack `lts-18.28` / GHC 8.10.7 and the imported shared Haskell sources.
- `ldd` resolved every required library for all five executables with the native
  output directories and the externally installed ZMotion directory in
  `LD_LIBRARY_PATH`. No SDK binaries or build outputs are committed.

The native environment uses OpenCV 4.2.0, Open3D 0.19.0, DIPlib, CGAL 6.0.1,
Ceres, fmt, graphics/USB libraries, Hikvision MVS, MindVision and ZMotion.
See BUILDING.md for the separate external prerequisites. Existing compiler
warnings remain in the imported native/device sources. Cabal also warns that
relative sibling includes cannot produce independent Hackage source tarballs;
the supported build unit is this repository layout.

## Behavioral checks

- Shared service: four unittest groups passed, including independent concurrent
  clients and maximum simultaneous inference count of one.
- All three barcode clients: compiled CLI tests passed with mock responses and
  the existing real PaddleOCR endpoint. Guard-off operation avoids OCR; matching
  print passes, while vendor misprints, missing text and ambiguous/missing
  barcodes fail. The guard accepts the full decoded barcode as a substring of
  OCR text after removing OCR whitespace.
- Dual-barcode Haskell and CLI suites: exact full decoded strings, independent
  print-guard settings, stale-setting rejection, continuity, separate image
  regions, service failure/recovery, bounded concurrency and trigger latching.
  A matching last-16 suffix cannot pass different complete barcodes. Real
  ZBar/PaddleOCR checks exercise misprints on either label and unequal codes.
- Engraving comparator: Haskell and compiled CLI suites passed for mixed
  Chinese/English text, whole-text comparison ignoring whitespace and treating
  `：`/`:` equally, case/punctuation/extra-text rejection, empty presets, OCR
  errors, timeouts and two real concurrent clients. Saved UTF-8 presets and
  profile selection restore through the actual Scheme loader after the RAM
  files disappear. No sequence increment is involved.
- Retained packaging launcher unittest passed for first-run configuration,
  upgrade preservation and duplicate-instance rejection. This does not claim
  that new release installers were built for all five clients.
- Git-visible source audit passed; all Python and shell files passed syntax
  checks. Relative resource links stay inside this repository. No compiled
  SDK/library binaries, private keys, databases or build caches were staged.

The mock ZeroMQ fixtures keep their final reply socket alive until the client
finishes, preventing intermittent reply loss caused by immediate socket
teardown. This affects test infrastructure only.

## Reproduce

Follow README.md and BUILDING.md to install dependencies and build. Configure
external vendor paths using `scripts/configure-local.py`; add runtime vendor
paths to `LD_LIBRARY_PATH` as needed. Create the separate service environment
or point clients at an existing compatible endpoint.

```sh
services/paddleocr_service/.venv/bin/python -m unittest services.paddleocr_service.test_server
scripts/test-app.sh 'Barcode+Sequence+Barcode' --real
scripts/test-app.sh 'Engraving+Compare' --real
python3 -m unittest discover -s apps/Engraving+Sequence/packaging -p 'test_*.py'
python3 scripts/audit-source.py
```

The real endpoint used was `tcp://127.0.0.1:5555`, served by the existing shared
PaddleOCR installation. The tested Python package inventory is preserved in
`services/paddleocr_service/requirements-tested.txt`; its virtual environment
and models are deliberately external. Camera capture, physical machine cycles,
USB permissions and target display behavior require hardware validation.

## Launcher and shared service updates, 2026-11-17

The follow-up change adds the configuration-driven PySide6 launcher, per-client
Modbus environment settings and a repository-local shared OCR runtime. See
`launcher/README.md` and `OCR_SERVICE_MIGRATION.md` for setup and interfaces.

- All 17 launcher tests pass with Ubuntu Python 3.12.3 and PySide6 6.12.0,
  including actual X11 initialization through `scripts/run-launcher.sh`.
  Ubuntu's interpreter avoids the Conda X11/XKB library conflict reproduced
  during `QApplication` initialization. The installer recreates an environment
  whose base interpreter differs from the configured system interpreter.
- Process tests cover atomic duplicate rejection across launcher processes,
  restart/reconnection, inherited locking after monitor death, independent
  applications, startup failure and abnormal exit. No production machine is
  operated by these tests.
- Inspector tests cover per-program persistence, validation, externally edited
  configuration, dynamic parameter types, configured camera choices and
  disabling launch while an instance runs. Program availability has no UI
  add/remove controls. Camera defaults include `Hikvision` and `MV-SUA131GC#0`.
- All four shared service unittest groups and the packaging launcher unittest
  pass. The migrated service passed real Chinese OCR and simultaneous clients,
  including with the old checkout hidden. A compiled Haskell client passed
  against the migrated production endpoint. Runtime models/environments remain
  ignored and are not part of this source commit.
- The three barcode clients rebuilt with configurable Modbus host/port/slave
  settings. Their actual Haskell/C++ modules passed loopback checks using
  `scripts/test-launcher-modbus.sh`, without accessing a camera or real PLC.
- The dual-barcode client rebuilt again after removing the Canny header and
  controls from its parameter panel. Existing processing/configuration support
  was retained; this change removes the operator-facing panel.
- Source audit, Python/shell syntax checks and Git whitespace checks passed.
  Local runtime paths, virtual environments, model weights, generated binaries
  and user settings are excluded from the source commit.

The desktop shortcut is a user installation artifact. Its reproducible setup
commands are documented in `launcher/README.md`; its absolute workstation path
is not committed as a portable desktop entry.

## Mixed-vendor Hikvision selection, 2026-11-19

- `scripts/test-camera-selection.sh` passed 21 hardware-free constructor tests.
  The actual Hikvision Camera.cpp runs against fake MVS entry points using the
  installed SDK headers and OpenCV. MindVision GigE before Hikvision USB3 and the
  reverse ordering both select the correct Hikvision descriptor. Other-vendor,
  missing, ambiguous, duplicate-serial and enumeration-error cases never create
  a camera handle. USB vendor identity, Hikvision GigE, explicit serial selectors,
  null entries and unterminated SDK fields are covered.
- `scripts/build-all.sh` rebuilt and copied all five application binaries.
  Every binary contains the new selection diagnostics, and `ldd` resolves all
  native dependencies with each application's configured runtime library paths.
- The Scheme initialization error now retains the underlying camera diagnostic.
  The selection policy header is a tracked compile dependency of the shared
  Haskell binding. The executable-name ignore rule no longer hides the camera
  wrapper source directory; object files and shared libraries remain ignored.
- Source audit, shell syntax and Git whitespace checks pass. Tests did not open
  cameras, acquire images, launch production GUI clients, or operate a PLC.

Physical acceptance with both cameras connected remains necessary. Follow
[CAMERA_SELECTION.md](CAMERA_SELECTION.md): retain the `Hikvision` setting and
confirm the selected USB3 serial in 运行日志, then check the live image after
restarting the application. No application camera/profile configuration was
changed by this fix.

## Offline Modbus debug trigger (2026-11-19)

- Rebuilt all five clients with the shared `ProductionDebug` module and
  config-only `debug_mode` flag. Default/user configuration remains false.
- Compiled actual Barcode Haskell/C++ modules for all five apps and tested
  against ephemeral loopback listeners. Debug initialization, trigger reads,
  and OK/NG outputs open no socket. Production mode still reads register 0
  (77 triggers), writes OK register 4=99 and NG register 2=88, and respects
  configured host/port/slave. Concurrent debug clicks latch one pulse; busy
  requests are rejected, scheduler verdicts run once, and OK/NG both rearm.
- Barcode queue tests cover repeated identical labels across separate debug
  requests, a single completion, busy pair rejection, both ROI failures, normal
  guard/sequence decisions, and asynchronous error recovery.
- SQLite integration tests cover lossless migration of existing rows to
  debug_mode=0, new debug OK/NG rows marked 1, one row per final debug verdict,
  production restart marking new rows 0, concurrent writers, transaction failure
  rollback, and the existing production clock guard. Haskell writer setup is
  serialized using an automatically released advisory file lock to avoid
  schema/attached-database deadlocks.
- Launcher tests verify strict JSON booleans, legacy default-off behavior,
  authoritative child environment, reload/save persistence, inspector indicator,
  and history display for both legacy and debug events.
- Existing barcode/dual-barcode and engraving comparator Haskell/CLI regression
  suites passed with synthetic images and mock OCR responses. No real camera,
  PLC connection or production event database was used by these checks. Live
  camera/production-line GUI testing remains an operator check.

## Engraving+Sequence OCR preview recovery (2026-11-20)

The `刻字顺号` evaluation thread previously called `renderImage "my.png"`,
which writes through Husk to `1/my.png`. A missing `1/` directory threw before
ZeroMQ could send a request, permanently stopping that preview worker. The
client now encodes PNG only in memory and reports per-request service/UTF-8
errors to its console channel while continuing to accept evaluation requests.
Cancellation still stops the worker. Empty OCR responses produce a visible
message. The direct start-number OCR path also handles service errors, and
production OCR failures are sent to the console as well as the production log.

Build with `scripts/build-app.sh 'Engraving+Sequence'`. Close and reopen a running
instance after installing the new binary; a thread already stopped in an older
process cannot recover by reconnecting the service. The app also supports
`Camera --ocr-image IMAGE` for diagnostics without GUI, camera, PLC or database
initialization, using the same configured PaddleOCR endpoint and timeout.

```sh
scripts/test-app.sh 'Engraving+Sequence' --real
```

Run after building. The compiled probe exercises the same `procSerialNum`
worker as the GUI from a temporary directory without `1/`. Tests cover multiple
responses after inference failure, malformed UTF-8 and empty recognition;
request timeouts, cancellation and repeated real service inference. Compiled
CLI tests also check the multipart PNG protocol, UTF-8 replies, failures and
simultaneous real clients. Test fixtures do not capture cameras or write to
production history.
