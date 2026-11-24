> Build and deployment paths for this source import are documented in the
> [repository README](../../README.md) and [build guide](../../docs/BUILDING.md).
> The workflow details below describe this client.

# Engraving text comparison

`Engraving+Compare` recognizes an engraving region through the shared PaddleOCR
ZeroMQ service and compares it with a saved text preset. Chinese characters,
Latin letters (including case), digits and punctuation are retained. There is
no barcode decoding, sequence selection, continuity check or automatic number
increment in the inspection workflow. Repeated identical correct engravings
can pass against the same unchanged preset.

## Run

```sh
cd 'apps/Engraving+Compare'
ENGRAVING_COMPARE_CAMERA=Hikvision ./bin/Camera
```

`ENGRAVING_COMPARE_CAMERA` defaults to `Hikvision`. The existing shared OCR
service defaults to `tcp://127.0.0.1:5555`; override `PADDLEOCR_ENDPOINT` to use
another host/port. The tested service uses `PP-OCRv6_medium_rec` and recognized
both `客服电话：96008` and `客服电话：96008 ABC-01`. Any replacement service
must also use a Chinese/English capable recognition model.

The independent shared service is maintained in
`../../services/paddleocr_service`. This client does not load
PaddleOCR or Python models. Each request owns its ZeroMQ socket; the shared
service queues concurrent clients and runs inference serially. The reply timeout
includes queue time and defaults to 120 seconds. Set `PADDLEOCR_TIMEOUT_MS` to
change it (1–3600000 ms); the send timeout is 5 seconds.

## Set up an inspection

1. Open `刻字文字比对` and select a region containing all of the required
   engraving, using the existing preview window, zoom and offset controls.
2. Enter or paste the complete expected text into `预设文字`. The initial value
   is `客服电话：96008`. Mixed text such as `客服电话：96008 ABC-01` is supported.
3. Click `评估` to see the OCR text and comparison without writing a PLC result
   or changing production counters.
4. Click `检测一次`, or trigger from the PLC, to perform a production inspection.
5. Click `保存参数` to immediately save the preset with the current camera/region profile to permanent storage. The next launch automatically restores that last saved profile and its preset, even if the previous process did not exit normally.

The complete preset must be a substring of the recognized text after whitespace
is removed and `：` is converted to `:` on both sides. Line breaks and OCR spaces
therefore do not cause a rejection, and Chinese/English colon widths are
equivalent. Case, other punctuation and every Chinese character must match.
Extra text before or after the preset is accepted: for example, preset
`客服电话：96008` passes with `产品说明 客服电话:96008 ABC-01`. The preset must
appear contiguously after normalization; inserted non-whitespace characters
inside it still fail. Missing text, an empty preset, an invalid crop or an OCR
service failure produces NG. The log includes both the original preset and
original recognized text, plus the failure reason.

The camera view keeps the full image; inspection owns a separate copy of the
selected ROI. One comparison runs asynchronously at a time, so OCR queue waits
do not block the GUI. A held PLC trigger causes only one inspection and must
return inactive before the next trigger. Wait for the result before presenting
the next part. A trigger while busy is not queued. Changing the preset/profile
invalidates an in-flight result; a production inspection invalidated this way
returns NG and must be retriggered.

The result window displays the preset, raw OCR result, pending status and OK/NG.
Production counters increment once per completed production inspection. Hold
an OK/NG counter for three seconds to clear it. There is no initial serial
number to set, and passing does not modify the preset.

## Configuration and PLC

Application-specific calibration lives in `~/ocrconfigs/engraving-compare`.
Missing `fun.scm`, `my.scm` and the three profile files are seeded from `src/`
at first GUI startup. Existing files are preserved. `engraving-expected-text`
is saved as a UTF-8 Scheme string in each profile. The `startup-profile` file remembers the last saved profile. Pressing `保存参数` commits the profile immediately using a temporary file and rename; it does not wait for GUI exit. Quotes, backslashes and
newlines are escaped for the actual Scheme loader.

Runtime files use `/dev/shm/engraving-compare`, overridable through
`ENGRAVING_COMPARE_RUNTIME_DIR`, and are copied back on normal GUI exit.
Run one GUI instance per configuration/runtime directory. The default Scheme
pipeline sends the captured frame to the engraving callback `dear-rout-9` and
displays the full frame. Other inherited vision callback slots are no-ops.
The previous sequence application's configuration directories are not used.

The existing PLC protocol is retained: read register 0 for trigger value 77,
write OK register 4 value 99, or NG register 2 value 88. Defaults are host
`192.168.0.68`, port `4998`, slave `3`. Override them with
`ENGRAVING_COMPARE_MODBUS_HOST`, `ENGRAVING_COMPARE_MODBUS_PORT` and
`ENGRAVING_COMPARE_MODBUS_SLAVE` before launch.

## Build and hardware-free validation

```sh
stack build Camera --copy-bins --local-bin-path bin
./bin/Camera --help
./bin/Camera --ocr-image /path/to/engraving.png
./bin/Camera --compare-image /path/to/engraving.png '客服电话：96008'
tests/run_engraving_compare_tests.sh --real
```

The comparison command returns zero on pass and nonzero on rejection. These
CLI commands and tests do not initialize the camera, GUI or Modbus controller.
The test runner uses the shared service's Python environment by default;
override `ENGRAVING_TEST_PYTHON` if needed. Omit `--real` to run only local
comparison/profile/async tests and the mock OCR transport tests.

The resolver remains `lts-18.28` with GHC 8.10.7. Local Haskell libraries use
relative paths under `../../dependencies`. Native requirements include
this host's OpenCV 4.2, ZeroMQ/cppzmq, MindVision and Hikvision MVS SDKs, plus
husk-scheme's controller dependencies. The executable is `bin/Camera`; original
changed files are preserved in `engraving-compare-backup/`. The copied historical
packaging scripts still describe the older `engraving-sequence` application;
they are not an installer for this new client.

Validated on this Ubuntu host: compilation and native library resolution;
multilingual preset substring comparison; acceptance of surrounding text;
rejection of changed/missing/interrupted presets, case and
punctuation errors; actual Scheme preset save/load with Unicode and escapes;
background request lifecycle, bounded concurrency, held-trigger behavior and
invalidation after preset/profile edits. Real PaddleOCR checks cover Chinese
and mixed labels, rejection cases, repeated unchanged presets and two
simultaneous clients receiving their respective replies.

Physical camera calibration and the production PLC cycle require validation on
the actual equipment; the GUI was not started during these automated tests.
