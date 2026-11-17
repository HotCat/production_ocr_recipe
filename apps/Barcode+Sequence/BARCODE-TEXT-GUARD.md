# Barcode and printed-text verification

Open **条码识别** and enable **校验印字与条码一致** to check the vendor's printed
text against the value actually decoded from the barcode. The existing barcode
selection must contain both the complete barcode and its corresponding printed
text. Keep the text large enough to read and exclude unrelated label text.

The guard defaults to **off**. With it off, inspection keeps the existing barcode
continuity check and does not contact PaddleOCR. With it on, a label must pass
both the printed-text substring check and the existing selected continuity
range. A printed-text mismatch, missing text, or OCR/service failure sends NG,
increments the NG count, and does **not** advance the expected sequence. Matching
text alone does not bypass the continuity check.

The complete decoded barcode must appear as a substring of the OCR text.
Extra text before or after it is allowed: barcode `123456` passes with OCR text
`Vendor X123456Y Lot 42`. OCR whitespace is ignored; case, punctuation and leading
zeros are preserved. An OCR result containing only part of the decoded barcode
still fails. No fuzzy comparison or character substitution is performed.

Use **保存参数** to save the checkbox in the selected parameter profile. Normal
shutdown copies the runtime profiles back to `~/ocrconfigs/sequence`, as before.
The three existing profiles were initialized with the guard off; previous copies
are retained as `configN.scm.before-printed-text-guard` beside those profiles.
The full camera image continues to be displayed; the recognition workers receive
the selected label image.

## Log window

`procBarcode` now returns a complete diagnostic on its corresponding `TChan
String` for every submitted evaluation/batch image, preserving barcode data and
recording the setting used for that request. It survives OCR failures and reports
the failure instead of converting error text into a serial number. Examples:

```text
[印字校验关闭] BARCODE ONLY 条码="123456"；仅解码条码；未校验印字
[印字校验开启] MATCH 条码="123456" 印字="123456"；印字中包含条码内容
[印字校验开启] NG/MISMATCH 条码="123456" 印字="654321"；印字中未找到条码内容
[印字校验开启] NG/NO TEXT 条码="123456" 印字=""；未识别到印字
[印字校验开启] NG/OCR ERROR 条码="123456" 印字=""；<service error>
```

Setting changes also appear in the barcode log. A PLC inspection logs its guard
result and then its final continuity outcome. Evaluation/batch messages are
informational and do not independently operate the PLC.

## Runtime behavior

The production PLC trigger still uses register 0 value 77; OK writes register 4
value 99 and NG writes register 2 value 88. Capture and the raw selection preview
remain responsive while a background task checks a triggered label. At most one
production inspection is in flight. Holding the same trigger/label does not
continuously repeat OCR; releasing the trigger, changing the decoded label, or
losing and reacquiring the label rearms inspection. Keep a product available for
inspection and wait for its PLC response before moving on to the next product.

The old time-based debounce was replaced by completion-event detection, so a
fast completed mismatch is not dropped behind an earlier result. A result from
an obsolete checkbox setting is discarded and the current label is inspected
again. The continuity gate also refuses an unguarded result if the guard has
since been enabled.

PaddleOCR uses the existing `PADDLEOCR_ENDPOINT` and `PADDLEOCR_TIMEOUT_MS`
settings. This program's tasks have independent REQ sockets; the shared service
still serializes all inference through one PaddleOCR pipeline. Requests are not
automatically retried following an OCR failure.

## Source/API changes

- `barcodeRecog :: Mat ... -> IO String` retains its signature and honors the
  current guard. It returns the decoded value on acceptance or `"ng"` on rejection.
- `decodeBarcode` supplies raw ZBar data for live range selection; it is not the
  production acceptance decision. Native response buffers are owned per call,
  so concurrent workers do not share a mutable C++ result string.
- `inspectBarcode` returns a `BarcodeResult` with separate verdict, decoded text,
  printed text, setting and diagnostic. `BarcodeGuard.hs` defines the comparison
  and continuity decisions. The PLC path uses these typed results rather than
  parsing human-readable diagnostic messages as barcode values.
- `procBarcode` retains its two-channel signature and snapshots the current
  setting when starting each queued request. The checkbox and profile changes
  update the shared policy atomically.

## Checks without camera or PLC

```sh
# Only decode the barcode:
./bin/Camera --barcode-image /path/to/label.png
# Require its printed text to match:
./bin/Camera --barcode-image /path/to/label.png --guard
```

These commands print the diagnostic and exit nonzero on rejection. They do not
open the GUI, initialize a camera, or connect to the PLC. `--guard` is explicit
for this command; it does not read saved GUI profile settings. It checks label
agreement only, because it has no configured production continuity state.

The regression suite checks substring comparison, continuity gating, rapid result
events, mode changes, detailed TChan messages, worker recovery, bounded background
inspection, trigger latching, actual ZBar decoding, and actual PaddleOCR output:

```sh
# Tests with a simulated OCR peer; Python needs cv2, numpy and pyzmq:
tests/run_barcode_guard_tests.sh
# Also test actual OCR using the configured service:
tests/run_barcode_guard_tests.sh --real
```

The label fixtures include a barcode decoding to `123456` with correct printed
`123456`, wrong printed `654321`, missing text, no barcode and multiple barcodes.
Real OCR accepted the matching label and rejected the vendor misprint and missing
text. The physical camera/PLC production cycle was not exercised by these tests.
