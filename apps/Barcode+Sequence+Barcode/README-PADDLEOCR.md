> Build and deployment paths for this source import are documented in the
> [repository README](../../README.md) and [build guide](../../docs/BUILDING.md).
> The workflow details below describe this client.

# Dual-barcode inspection on Ubuntu 24.04

This application checks a product barcode and a packaging barcode. The two
complete decoded strings must match exactly, including case, punctuation,
prefixes and spaces. No last-16-character extraction or alphanumeric filtering
is applied to this comparison. The existing product sequence continuity check
is still required before production OK is counted and the expected number is
advanced.

Each label also has an independent PaddleOCR printed-text guard. The application
uses the shared ZeroMQ service from `../../services/paddleocr_service`; it does not embed
PaddleOCR, CPython or Tesseract.

## Run

Run from this project directory so the fonts, shaders and Scheme resources resolve:

```sh
cd 'apps/Barcode+Sequence+Barcode'
systemctl --user status paddleocr.service
DOUBLE_BARCODE_CAMERA=Hikvision ./bin/Camera
```

`DOUBLE_BARCODE_CAMERA` selects the camera and defaults to `Hikvision`. For the
original MindVision camera, set `DOUBLE_BARCODE_CAMERA='MV-SUA131GC#0'`.
The GUI connects to the existing Modbus controller at `192.168.0.68:4998`.

Configuration belongs to `~/ocrconfigs/doublebarcode`. Missing `fun.scm`,
`my.scm` and `config1.scm` through `config3.scm` are copied from `src/` on GUI
startup. Existing files and calibration are preserved. Runtime copies use
`/dev/shm/doublebarcode` and are copied back on normal exit. Do not run multiple
GUI instances sharing these directories.

The supplied `src/fun.scm` captures one full frame and calls the packaging
callback `dear-rout-9` before the product callback `dear-rout-7`. If retaining a
custom `fun.scm`, keep this order and pass the same frame to both callbacks.
The packaging ROI is consumed once; a missing or invalid packaging ROI rejects
the inspection. Each background inspection owns its two cropped images.

## Printed-text controls

Select two separate regions, each containing its barcode and nearby printed
text. The controls are:

- `条码识别` → `校验产品印字与条码一致`
- `条码识别(包装)` → `校验包装印字与条码一致`

Both guards default to enabled. `保存参数` stores them independently in the
current profile as `barcode-printed-text-guard` and
`packaging-printed-text-guard`. Profiles without these keys retain the current
settings; a fresh process starts with both enabled.

For each enabled guard, the entire decoded barcode must occur as a substring
of that region's OCR text after removing OCR whitespace. Extra surrounding
text is allowed; case and punctuation are preserved. This OCR normalization
never changes the two decoded strings used for the cross-barcode comparison.
Missing/wrong print, an OCR error, or no unique barcode rejects the inspection.
Disabling a guard skips OCR for that region, while decoding and the exact
cross-barcode comparison remain required.

`评估` checks an individual region and logs its decoded value, printed text,
guard setting and outcome. Production logs identify product and packaging
results separately. Only a complete pair passing both configured guards, exact
barcode equality and sequence continuity counts OK. A rejected pair produces
NG without advancing the sequence. No OK is counted until an expected sequence
has been configured.

A complete pair runs asynchronously with at most one production inspection in
flight. There is no old half-second inspection deadline: a request may wait
behind another OCR client. A held PLC trigger does not repeatedly inspect the
same decoded product. The production line must wait for the PLC result before
presenting the next pair. Existing PLC registers remain: trigger register 0
value 77, OK register 4 value 99, NG register 2 value 88.

## Shared OCR service

The service is maintained separately at
`../../services/paddleocr_service`. `PADDLEOCR_ENDPOINT` defaults
to `tcp://127.0.0.1:5555` and can point to another shared host.
`PADDLEOCR_TIMEOUT_MS` sets the per-request reply timeout (default 120000 ms,
range 1–3600000); the send timeout is 5 seconds. Queue time is included in the
reply timeout. A pair can make two consecutive OCR requests when both guards
are enabled.

Each call owns a fresh ZeroMQ REQ socket and sends a JSON header plus a PNG
multipart frame. Responses are UTF-8 text. The shared service accepts multiple
clients and processes inference serially through one PaddleOCR pipeline.
Transport/service errors reject the current inspection; subsequent inspections
can recover. No shared image files or in-process OCR model are used.

## Build

```sh
stack build Camera --copy-bins --local-bin-path bin
```

The resolver is `lts-18.28` (GHC 8.10.7). `stack.yaml` references local
`dear-imgui`, `haskell-opencv` and `husk-scheme` sources relative to this project,
under `../../dependencies`. Native dependencies include this host's
OpenCV 4.2, ZBar, ZeroMQ/cppzmq, MindVision SDK, Hikvision MVS SDK (`/opt/MVS`),
and the motion/controller libraries used by husk-scheme. `Camera.cabal` uses
relative native project paths and an MVS runtime path of `/opt/MVS/lib/64`.

The built executable is `bin/Camera`. This migration builds for the installed
Ubuntu 24.04 environment; deployment to a clean machine still requires the
native runtime libraries and camera SDKs. The OCR service environment and
models remain a separate installation. Historical migration backups are excluded from this repository.

## Hardware-free checks

These commands do not open the GUI, camera or Modbus controller:

```sh
./bin/Camera --help
./bin/Camera --ocr-image /path/to/text.png
./bin/Camera --barcode-image /path/to/label.png --guard
./bin/Camera --barcode-pair /path/to/product.png /path/to/packaging.png
./bin/Camera --barcode-pair /path/to/product.png /path/to/packaging.png --no-product-guard
./bin/Camera --barcode-pair /path/to/product.png /path/to/packaging.png --no-packaging-guard
```

The pair command defaults to both guards enabled. Both disabling flags may be
combined. It returns zero only when the pair's guards and exact barcode match
pass; it does not apply the GUI's configured sequence continuity check. The
single-label command defaults to barcode-only unless `--guard` is supplied.
Rejected checks return a nonzero exit status.

Run regression checks and actual ZBar/PaddleOCR label tests:

```sh
BARCODE_TEST_PYTHON=../../services/paddleocr_service/.venv/bin/python tests/run_barcode_guard_tests.sh --real
../../services/paddleocr_service/.venv/bin/python tests/test_ocr_client.py --binary bin/Camera --real-endpoint tcp://127.0.0.1:5555
```

Validated on this host: application compilation, runtime library resolution,
exact full-code comparison (including the old suffix-16 regression), independent
guards, missing/multiple codes, misprints and absent text on either label,
service failures/timeouts, sequence decisions, asynchronous inspection and
trigger rearming. Real shared PaddleOCR tests accepted a matching pair and
rejected wrong print on either side and independently valid different barcodes.
UTF-8 and multipart transport tests passed, as did two simultaneous compiled
Haskell clients returning their own expected OCR results.

The physical camera, GUI calibration and production PLC cycle have not been run
during this migration and require validation on the actual production equipment.
