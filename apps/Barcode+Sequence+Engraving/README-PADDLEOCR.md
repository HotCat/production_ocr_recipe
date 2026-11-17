> Build and deployment paths for this source import are documented in the
> [repository README](../../README.md) and [build guide](../../docs/BUILDING.md).
> The workflow details below describe this client.

# Ubuntu 24.04 migration

The application now uses the same separate PaddleOCR ZeroMQ service as
`../../services/paddleocr_service`. It no longer embeds libppocr, CPython or Tesseract.
The barcode decoder and existing barcode/engraving serial comparison remain in
this client. Existing calibration in `~/ocrconfigs/sequence2` is retained;
missing files are seeded from `src/` at first GUI startup. Do not run another
client using that same configuration directory concurrently.

## Run

Run from this project directory so the relative font and Scheme files resolve:

```sh
cd apps/Barcode+Sequence+Engraving
systemctl --user status paddleocr.service
BARCODE_ENGRAVING_CAMERA=Hikvision ./bin/Camera
```

`BARCODE_ENGRAVING_CAMERA` selects the camera; it defaults to `Hikvision`.
For the original camera use `BARCODE_ENGRAVING_CAMERA='MV-SUA131GC#0'`.
The GUI connects to the original Modbus controller at `192.168.0.68:4998`.

`PADDLEOCR_ENDPOINT` defaults to `tcp://127.0.0.1:5555` and may point to a
shared service on another machine. `PADDLEOCR_TIMEOUT_MS` sets the reply
timeout (default 120000 ms, range 1–3600000); sending times out after 5 seconds.
The reply timeout includes time queued behind other clients. Each request owns
its own REQ socket; the shared service serializes inference through its single
PaddleOCR pipeline. Images are sent as a JSON header and a PNG multipart frame;
responses are UTF-8 text. No shared image files or in-process OCR models are used.
Service/transport errors fail the current inspection and appear in the serial
log; background OCR workers report errors to stderr and keep running.
The inspection call still waits synchronously for OCR, as in the old program.

Test OCR without opening the GUI, camera or controller:

```sh
./bin/Camera --ocr-image /path/to/image.png
```

## Build

```sh
stack build Camera --copy-bins --local-bin-path bin
```

The existing resolver is `lts-18.28` (GHC 8.10.7). `stack.yaml` now points to the
shared dear-imgui, haskell-opencv and husk-scheme snapshots under
`../../dependencies`. Native dependencies use this
machine's OpenCV 4.2, ZBar, ZeroMQ/cppzmq headers, MindVision SDK, Hikvision MVS
SDK (`/opt/MVS`) and the motion/controller libraries required by husk-scheme.
This is a build for the current installed environment, not a standalone
installer for a clean machine. The OCR service and its Python/model environment
are maintained separately in `../../services/paddleocr_service`.
Historical migration backups are excluded from this repository.

## Verification

Run transport/error/timeout/UTF-8 tests plus two simultaneous real OCR clients:

```sh
../../services/paddleocr_service/.venv/bin/python tests/test_ocr_client.py --binary bin/Camera --real-endpoint tcp://127.0.0.1:5555
```

These checks exercise the compiled executable without operating machine
hardware. Live GUI camera acquisition and production Modbus behavior require
validation with the actual camera/controller.

Validated on this Ubuntu 24.04 host: Stack build, library resolution, multipart
PNG/UTF-8 response, service error, reply timeout and invalid image tests passed.
Two simultaneous processes returned `SERIAL 123456` and `SERIAL 654321` from
the real shared PaddleOCR service. The GUI and production hardware were not run.

## Optional barcode printed-text guard

Under `条码识别`, enable `校验印字与条码一致`. Select one region containing
both the bars and the nearby printed barcode text. The default is disabled;
`保存参数` saves the option in the current profile. Existing profiles without
the option keep the current setting, which defaults to off on startup.

When enabled, the entire decoded barcode must be a substring of the OCR text
after OCR whitespace is removed. Surrounding text is allowed; case and
punctuation must match. A mismatch, empty printed text or service error produces
NG and does not advance the sequence. The normal sequence and engraving checks
still have to pass before the application counts OK and advances the sequence.
When disabled, the barcode stage does not call PaddleOCR; engraving OCR remains
active. Settings and inspection outcomes appear on the existing log channels.

Barcode OCR runs asynchronously. Each completed inspection owns the production
path until engraving finishes, so later labels cannot replace its result. A
held PLC trigger does not repeatedly inspect the same label. The existing
engraving OCR call remains synchronous, as noted above.

Check a label without opening the camera/controller:

```sh
./bin/Camera --barcode-image /path/to/label.png --guard
```

Exit status is zero for accepted labels and nonzero for rejected labels. Omit
`--guard` for barcode-only decoding. Regression and real-service checks:

```sh
BARCODE_TEST_PYTHON=../../services/paddleocr_service/.venv/bin/python tests/run_barcode_guard_tests.sh --real
```

The tests cover substring matching, missing/wrong print, no/multiple barcodes,
OCR errors, per-request channel diagnostics, async inspection, trigger rearming,
engraving ownership and real ZBar/PaddleOCR labels. Pre-guard sources are saved
in `barcode-guard-backup/`.

## Serial-number bank selection

Under `序列号识别`, the `银行` combo selects `平安银行` (default, last 16
alphanumeric OCR characters) or `郑州银行` (last 12). The selected suffix is
compared with the decoded barcode as before. `保存参数` saves the bank in the
current profile as `serial-number-bank` (0 = 平安银行, 1 = 郑州银行).
