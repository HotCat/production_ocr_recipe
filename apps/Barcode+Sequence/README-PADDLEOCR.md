> Build and deployment paths for this source import are documented in the
> [repository README](../../README.md) and [build guide](../../docs/BUILDING.md).
> The workflow details below describe this client.

# Barcode+Sequence on Ubuntu 24.04 with shared PaddleOCR

Barcode+Sequence now calls the independent PaddleOCR ZeroMQ service. Its existing
`ObjectBehavior.hs` OCR workers continue to use `procSerialNum submit collect`;
`TextRecog.hsc` sends their images to the service. This client loads no Paddle
models and no longer needs Tesseract or Leptonica. The service must already be
running; starting Barcode+Sequence does not start another OCR server.

## Build and run

From this directory:

```sh
stack build --copy-bins --local-bin-path bin
./bin/Camera
```

`bin/Camera` is the executable compiled on this Ubuntu 24.04 system. Run the GUI
from this project directory so its shaders, images and fonts can be found. The
GUI still reads your calibration from `~/ocrconfigs/sequence` and uses the
existing camera and Modbus configuration. OCR checks below bypass GUI, camera,
calibration and PLC initialization.

Local service (default):

```sh
PADDLEOCR_ENDPOINT=tcp://127.0.0.1:5555 ./bin/Camera
```

Service on a different machine:

```sh
PADDLEOCR_ENDPOINT=tcp://192.168.0.10:5555 ./bin/Camera
```

For LAN use, configure the server's `PADDLEOCR_BIND` to its reachable interface.
The protocol has no authentication; use a trusted network. Both Barcode+Sequence and
Engraving+Sequence can use the same endpoint.

The reply timeout defaults to 120000 ms, including time queued behind other
clients. Set `PADDLEOCR_TIMEOUT_MS` to a value from 1 through 3600000 to change
it. Sending has a 5000 ms timeout. Timed-out requests are not retried and may
still finish on the server. A failed worker request is reported on stderr and
the worker remains available for the next image; an error is never submitted
as a recognized serial number.

## Select the camera

Set `SEQUENCE_OCR_CAMERA` to the camera name recognized by the SDK:

```sh
SEQUENCE_OCR_CAMERA="Hikvision" ./bin/Camera
# Or select a MindVision camera:
SEQUENCE_OCR_CAMERA="MV-SUA131GC#0" ./bin/Camera
```

The default is `Hikvision` when the variable is unset. Startup and automatic
camera reconnection both use this setting. This is independent of the
`SEQUENCE_CAMERA` variable used by Engraving+Sequence.

## Test OCR without opening the GUI

```sh
./bin/Camera --ocr-image /absolute/path/to/image.png
```

This prints the raw recognized text and exits; errors produce a nonzero exit
status. `--help` describes the command and connection settings.

The saved integration checks require Python with pyzmq, numpy and OpenCV. The
existing shared service's virtual environment already provides these:

```sh
../../services/paddleocr_service/.venv/bin/python \
  tests/test_ocr_client.py --binary bin/Camera \
  --real-endpoint tcp://127.0.0.1:5555
```

The checks exercise the compiled Haskell executable, validating multipart PNG
requests, Chinese UTF-8 replies, service errors, reply deadlines, invalid images,
and two simultaneous real client processes. Real service results on this host:
`123456 -> SERIAL 123456`, `654321 -> SERIAL 654321`.

## Haskell integration points

For existing code, keep using:

```haskell
text <- textRecog2 image
```

Or prepare the service address once and reuse it:

```haskell
ocr <- prepareOcr
text <- predictOcr image ocr
```

Both return `IO String` and raise exceptions on transport or service errors.
Images have type `Mat ('S ['D, 'D]) ('S 3) ('S Word8)`. The channel worker retains
its original signature and keeps only letters and digits in its output, as
before. `deskew` remains available without Tesseract.

A shared thread-safe ZeroMQ context owns a fresh REQ socket per request. Each
socket belongs only to its caller; sockets are never shared between workers.
The existing shared service has one REP loop and one PaddleOCR pipeline, so
requests from independent clients queue and inference runs serially. There is
no strict global FIFO ordering across independent clients.

Other clients can use the same protocol: send two frames, JSON
`{"op":"recognize","encoding":"png"}` followed by PNG bytes, and receive one
UTF-8 text frame. Errors start with `ERROR:`. A single JSON frame
`{"op":"health"}` returns `{"ok":true,"service":"paddleocr"}`. Health requests
also wait behind inference.

## Porting fixes

The Cabal file no longer lists the missing Sqlite/Utility modules or CHANGELOG.
It includes the installed native library paths and MVS runtime search path.
The unused Sound import was removed. Font paths now use local files in `font/`.
Copied stale build artifacts were cleared before compilation.

Compilation, native library resolution, and OCR integration passed. The GUI's
physical camera and PLC behavior have not been exercised as part of these OCR
checks. This executable still uses this machine's native runtime libraries;
this change does not create a separate deployment installer for Barcode+Sequence.

## Empty-frame crash regression

The display path now ignores empty/non-2D frames instead of destructuring their
shape with a partial `[h,w]` pattern. Barcode and serial crop failures retain the
source frame so the image remains available while correcting the crop settings.
Saved calibration values are preserved. The Hikvision driver reports ReverseY
failure only for a nonzero SDK status; `0` means success.

The shared `husk-scheme` renderer and Hikvision binding were updated. The binding
tracks its included C++ source/header files so subsequent driver fixes rebuild.
To rerun the focused renderer regression from this directory:

```sh
stack ghc -- -package husk-scheme -package opencv -package mtl \
  -package GLFW-b -package gl -package bytestring \
  -L/opt/MVS/lib/64 -lMvCameraControl -optl-Wl,-rpath,/opt/MVS/lib/64 \
  -outputdir /tmp/sequence-frame-check-build \
  tests/CameraFrameRegression.hs -o /tmp/sequence-frame-check
/tmp/sequence-frame-check
# With a working X/OpenGL display, also verify a real texture upload:
/tmp/sequence-frame-check --upload /absolute/path/to/image.png
```

An optional `--probe Hikvision` reads three camera frames directly, without
starting the GUI or connecting to the PLC. It needs the camera to be available
and acquisition working; acquisition errors are reported separately from the
empty-frame regression.

## Full camera image display

The active `~/ocrconfigs/sequence/fun.scm` now assigns the captured `frame` to
`finalMat`, matching Engraving+Sequence's full-frame display. Previously it
assigned the barcode callback's cropped/rotated `frame2`; an invalid crop could
also leave the display empty. Recognition callbacks still process their crops.
The source template `src/fun.scm` uses the same full-frame display rule.

The previous active script was saved as
`~/ocrconfigs/sequence/fun.scm.before-full-frame-display`. Restart Barcode+Sequence to
load the corrected saved script into its runtime directory. This is an
interpreted Scheme change; rebuilding Haskell is unnecessary.

The pipeline regression exercises the real Scheme evaluator and verifies that
full-frame shape and pixels survive even if ROI callbacks return empty images:

```sh
/tmp/sequence-frame-check --pipeline /path/to/image.png src/fun.scm
/tmp/sequence-frame-check --pipeline /path/to/image.png "$HOME/ocrconfigs/sequence/fun.scm"
```

Both scripts pass; the backed-up original script fails this regression as
expected. Live camera capture remains a separate hardware acceptance check.

## Optional barcode/printed-text guard

The **条码识别** panel now has **校验印字与条码一致**. Select one region containing
both the barcode and its printed text, enable the checkbox, and use **保存参数**
to retain it in the current profile. It defaults off. See
[BARCODE-TEXT-GUARD.md](BARCODE-TEXT-GUARD.md) for acceptance rules, log messages,
PLC behavior, camera-free label checks and regression tests.

## Project directory rename

The source directory is now `Barcode+Sequence` (formerly `Sequence`). Build and
run commands above must be executed from the renamed project directory.
`Camera.cabal` and `stack.yaml` refer to the imported shared sources under
`../../dependencies/`, without requiring the old `new3dvision` checkout.
System SDK paths such as `/opt/MVS` still refer to the installed SDK.

Existing calibration remains in `~/ocrconfigs/sequence`, runtime scripts remain
in `/dev/shm/sequence`, and the camera variable remains `SEQUENCE_OCR_CAMERA`.
These are stable runtime settings, independent of the source directory name.
Relative resources (`font/`, shaders, `src/window.png`, and audio files) are
resolved from the project directory. Historical editor backups and compiler logs are excluded from this repository.
