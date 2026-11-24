# Shared PaddleOCR service

A ZeroMQ broker routes independent REQ clients to **two CPU worker processes**.
Each spawned worker owns both OCR profiles and runs requests serially;
up to **two requests run concurrently** across the service. Further requests
wait until a worker becomes idle. Replies return to the requesting client,
including when requests finish out of order. There is no strict FIFO order
across peers. Each client thread/process must use its own socket. Client timeouts
include queue time and do not cancel work already accepted by the server.

## Application model profiles

| Application | Request profile | Models |
| --- | --- | --- |
| Barcode+Sequence | `legacy_en` | Original Chinese PP-OCRv3 detector + English PP-OCRv3 recognizer |
| Barcode+Sequence+Barcode | `legacy_en` | Same original v3 models for both barcodes |
| Barcode+Sequence+Engraving | `legacy_en` | Same original v3 models for barcode guards and engraved serials |
| Engraving+Sequence | `legacy_en` | Same original v3 models |
| Engraving+Compare / 刻字与预设文字比对 | `chinese` | Existing PP-OCRv6 medium Chinese-capable pipeline |

The English profile uses the **unchanged weights and dictionary from the old
Debian installation**: `ch_PP-OCRv3_det_infer`, `en_PP-OCRv3_rec_infer`, and
`en_dict.txt`. It runs through Paddle Inference's legacy model reader in the
current Python environment; no Debian shared libraries, executable or mounted
old filesystem are needed. MKL-DNN is enabled for its CPU predictors. The
English path defaults to **`use_angle_cls=false`**: no angle classifier is
loaded or called until a request explicitly enables it. Document orientation
and document unwarping models are never used on the English path.
The geometric crop of a tall detected region retains the old crop behavior.

The adapter retains BGR preprocessing, detector maximum side 960, DB thresholds
0.3/0.6/1.5 with slow scoring, recognition height 48, batch size six and the old
127 padding. PaddleX supplies the maintained DB contour postprocessor; do not
assume bit-identical boxes/outputs across different runtimes. All recognized
lines are returned, preserving the shared service's barcode substring guard
semantics. Chinese profile preprocessing and acceptance rules are unchanged.

Each worker loads both profiles **once**, then selects the appropriate existing
predictors for each request. It never runs either profile concurrently inside
that worker. Two workers still allow at most two concurrent requests overall;
queued requests and profile choices retain their correct reply routes. Worker
limits apply to the whole service, not separately to each profile.

## Optional angle classification

The four English applications can enable PaddleOCR's original
`ch_ppocr_mobile_v2.0_cls_infer` classifier with `"use_angle_cls": true` in their
launcher JSON program entry (not an inspector parameter). The client sends this
boolean in every request. A worker classifies detected text crops **before**
English recognition, in batches of six, and rotates a crop 180° only if its
180° confidence exceeds 0.9. This is a 0°/180° text-line classifier, not arbitrary
page rotation or a change to sequence `Reverse`. Existing detection, cropping,
dictionary and recognition models remain the same. The Chinese application is
unchanged; `use_angle_cls=true` with `profile=chinese` is rejected.

Prepare the optional model explicitly before enabling the option:

```sh
python3 -m services.paddleocr_service.prepare_angle_classifier
```

This downloads the official ~2.1 MiB archive, checks its pinned SHA256, and
extracts only the two inference files beneath `.cache/legacy_models/`.
`--destination` accepts another legacy model root, including the location
selected by `PADDLEOCR_LEGACY_MODEL_ROOT`. For offline installation, either
copy the complete legacy model root from a prepared PC, or download the archive
on another PC and pass `--archive /path/to/ch_ppocr_mobile_v2.0_cls_infer.tar`.
Models remain outside Git. Preparation is repeatable and refuses to overwrite
different weights. Inference never downloads assets: enabling the option
without the classifier returns an explicit error, and disabled requests still work.

Each worker lazily loads one classifier predictor on its first enabled request,
then reuses it. The flag is per request and never changes a worker-global mode,
so enabled and disabled clients may run concurrently without settings leaking.
The existing worker limit and serial execution inside each worker still apply.
Rebuild all four English clients and restart the service to activate a code
upgrade. Older clients without the new request field continue with `false`.

Measure your actual production region with alternating warmed requests:

```sh
services/paddleocr_service/.venv/bin/python -m services.paddleocr_service.benchmark_angle_cls \
  --image /path/to/cropped-production-region.png --samples 30
```

Without `--image`, it generates a synthetic 600×140 `SERIAL 123456` label with
one text line. It reports first request, warmed median and p95 for each setting,
recognized text/line count, and the median difference in ms and percent.
Default six warmup requests per setting cover both service workers; increase
this if changing the worker policy. Use `--endpoint` for an isolated test service.
Timing includes ZeroMQ queue/network waits and PNG decode; the image is encoded
once before measurement. Application `request_ms` also includes PNG encoding.
First-request figures mean the first requests in that benchmark run; a service
already used by another client may have loaded/warmed its classifier earlier.
The application's 运行日志 includes `use_angle_cls=true/false` beside each timing.
Compare the same regions and load: classifier cost depends on detected line
count, crop shape, CPU and concurrent requests. First-use loading is not steady-state latency.

Validation on 2026-11-24, Intel Core i5-8500, CPU inference, two service workers
with two Paddle threads each: the synthetic single-line label above took
**22.391 ms off / 24.920 ms on** at the median, an increase of **2.529 ms (11.3%)**.
The p95 values were 25.623 / 25.730 ms. This used 30 alternating measured
requests per setting after six warmups per setting, with builds finished and
the camera preview closed. It is a single-line latency check, not a production
guarantee. Earlier first enabled requests through compiled clients took roughly
160–210 ms including loading/warmup; each worker pays that cost independently.
All four rebuilt clients passed enabled/disabled request and runtime-log checks;
real upside-down labels were corrected only when enabled, concurrent opposite
settings retained their own results, and Chinese preset recognition still passed.
The service/legacy tests (21) and launcher config/UI tests (14) passed.

## Import the original v3 model assets

Provide a directory containing the two original model directories and the old
English character dictionary. From the repository root:

```sh
python3 -m services.paddleocr_service.import_legacy_models \
  /path/to/old/models /path/to/old/PaddleOCR/ppocr/utils/en_dict.txt
```

The importer checks all inputs before copying, refuses to replace different
existing weights, and writes SHA-256 hashes/sizes to `manifest.json`. Its default
destination is `services/paddleocr_service/.cache/legacy_models`; use
`--destination` with `PADDLEOCR_LEGACY_MODEL_ROOT` for another location. Repeating
an import of the same files is safe. Copy this cache with offline deployments,
alongside the existing Chinese models. Models remain excluded from Git.
`run.sh` checks for the required legacy assets before starting workers and
reports missing files instead of silently substituting a newer model.

**Client upgrade:** rebuild all five clients. They now send explicit profile
headers; an older client without a profile defaults to `legacy_en`, so an older
`Engraving+Compare` executable must be replaced before using the upgraded service.
The request profile, rather than the compatibility `--lang`/`PADDLEOCR_LANG`
setting, selects the language/models. Unknown profiles return an error.

## Environment setup

From the repository root:

```sh
python3 -m venv services/paddleocr_service/.venv
services/paddleocr_service/.venv/bin/python -m pip install --upgrade pip
services/paddleocr_service/.venv/bin/python -m pip install paddlepaddle
services/paddleocr_service/.venv/bin/python -m pip install -r services/paddleocr_service/requirements.txt
services/paddleocr_service/run.sh
```

`requirements-tested.txt` records the installed CPU environment used during this
import (Python 3.13.5, PaddleOCR 3.7.0, PaddlePaddle 3.3.1). To reproduce that
Python environment, install that file instead of the two dependency commands.
Ubuntu 24.04's default Python is different; use compatible wheels or provision
Python 3.13 separately. For CUDA, install the matching `paddlepaddle-gpu` wheel
instead and set `PADDLEOCR_DEVICE=gpu:0`.

Models are prepared/downloaded separately and are excluded from Git. `run.sh`
sets `PADDLE_PDX_CACHE_HOME` to the service's `.cache` directory unless supplied.
`run.sh` detects a complete local set of the five tested models under
`.cache/official_models` and passes their directories explicitly, skipping
remote model-host checks. `PADDLEOCR_MODEL_ROOT` can override this directory.
The Chinese pipeline retains its previous PaddleX oneDNN default override;
compatible hosts can set `PADDLE_PDX_ENABLE_MKLDNN_BYDEFAULT=True`. The English
v3 profile explicitly enables MKL-DNN, independently of that Chinese setting.
The legacy adapter uses the installed Paddle Inference API and PaddleX DB
postprocessor; `requirements-tested.txt` records the validated versions. Keep
that environment with offline deployments rather than substituting untested
major library versions.

CPU is the default device. `PADDLEOCR_WORKERS=2` (or `--workers 2`) is the default
and hard maximum; use `1` to fall back to serial processing. Values outside 1–2
are rejected. `PADDLEOCR_CPU_THREADS=2` (or `--cpu-threads 2`) controls Paddle's
CPU threads per worker and the OpenCV/OpenMP/BLAS thread settings. The default
uses two inference threads per worker to leave CPU capacity for the camera
applications. These settings control compute pools, not the total number of
OS helper threads. Each worker owns its own model copies; measure memory and
latency on the production PC before deployment. Both profiles share the selected thread limit.
No FPS throttle or inspection-rule change is introduced.

The default endpoint is `tcp://127.0.0.1:5555`. Set `PADDLEOCR_BIND` on the server
and matching `PADDLEOCR_ENDPOINT` on clients to change it. Wait for the listening
message after models load. Run only one listener per endpoint. The Haskell
client's reply deadline defaults to 120 seconds (`PADDLEOCR_TIMEOUT_MS`). After
a timeout it discards its REQ socket; accepted inference may still finish.
High-water marks are eight messages per peer, with backpressure under load.
The broker reads new requests only when a worker is free; it does not accumulate
an unbounded Python task queue. The listening message appears only after all
configured workers initialize both profiles. An inference exception returns
`ERROR:` and the worker continues. If a worker process dies or initialization exceeds five minutes,
the entire pool exits and systemd restarts it. In-flight requests may fail;
the service does not automatically replay production requests. Stopping the
service shuts down both children as well as the broker.

## User service

```sh
scripts/install-ocr-user-service.sh
systemctl --user enable --now paddleocr.service
journalctl --user -u paddleocr.service -f
```

The installer writes paths for this clone, backs up a changed existing unit
under `~/.local/state/production-ocr-service/unit-backups`, and reloads systemd.
It does not start or restart the service itself. For an already running unit,
apply changes with `systemctl --user restart paddleocr.service`. Ensure no other
service owns the endpoint before enabling a new instance. The optional argument
`production-paddleocr.service` retains support for that alternative unit name;
run only one of the two units on a given endpoint.
The installed unit explicitly sets `PADDLEOCR_WORKERS=2` and
`PADDLEOCR_CPU_THREADS=2`. To tune them, use `systemctl --user edit
paddleocr.service` with a `[Service]` section and `Environment=...` lines,
then restart the service. CLI options override environment variables.
The unit starts at login. Use `systemctl --user disable --now
paddleocr.service` to stop and disable it. For system-wide deployment,
the separate OCR Debian package is retained in
`apps/Engraving+Sequence/packaging`; see its README.

## Protocol and tests

Requests are multipart: JSON metadata then an encoded image. For example,
`{"op":"recognize","encoding":"png","profile":"legacy_en","use_angle_cls":false}` returns recognized
UTF-8 text. Use `"profile":"chinese"` for preset Chinese text comparisons.
Omitting `profile` selects `legacy_en` for compatibility.
Omitting `use_angle_cls` selects `false`; it must be a JSON boolean, not a string or number.
`recognize_json` returns text plus line confidence/boxes. `{"op":"health"}`
uses only a metadata frame. Errors start with `ERROR:`.

```sh
services/paddleocr_service/.venv/bin/python -m unittest services.paddleocr_service.test_server services.paddleocr_service.test_legacy_v3
```

Tests exercise transport, response normalization and the actual spawned worker
pool without loading real models. Three concurrent clients verify that exactly
two independent pipelines run simultaneously, the third request waits, replies
remain paired even out of order, and freed workers immediately take queued work.
The mixed-profile tests also verify English/Chinese routing and rejection of
unknown profiles. Legacy unit tests cover CTC repeats/blanks/case/spaces, the
original normalization/padding, local legacy-IR/MKL-DNN settings and repeatable
model imports with conflict protection. They also cover one-worker fallback, request errors, abandoned clients, worker
startup/crash cleanup, invalid limits and occupied endpoints. The single-worker
transport utility is tested separately. Application test helpers accept
`--real` to additionally use an already running PaddleOCR endpoint.

Profile validation on 2026-11-21: all 17 service/legacy unit and transport tests
passed; all five clients rebuilt and passed their real-service app suites.
Checks included printed-barcode mismatches/missing text, independent guards on
both barcode regions, complete barcode-pair equality, preview-worker recovery,
and Chinese/mixed preset comparisons with wrong/extra/empty text rejection.
The active service on port 5555 was restarted with two workers and both profiles
verified again with alternating and concurrent mixed requests.

For a synthetic 600×140 `SERIAL 123456` label, a warmed English-profile request
through ZeroMQ took about 22 ms on this workstation (first request about 96 ms).
A separate 800×130 `客服电话：96008` label retained Chinese recognition and took
about 0.88–0.99 s. These use different images and models, so they are functional
and latency checks, not an equal-workload speedup or production accuracy claim.
Measure the application's existing `[PaddleOCR] ... request_ms=...` log on real
production regions to assess the resulting speed and recognition correctness.

Historical two-worker validation before the profile split, on 2026-11-20: all 11 unit/transport tests passed. Three
simultaneous real 800×100 PNG requests on this workstation returned the expected
Chinese/English text at approximately 0.98 s, 1.00 s and 1.80 s including queue
time. Worker logs confirmed two overlapping inferences and then the queued
third request. The existing compiled `Engraving+Compare --compare-image` client
also passed through the restarted service at port 5555. These synthetic timings
are a local check, not a latency guarantee under production camera/UI load.

## Workstation migration, 2026-11-17

The active, enabled `paddleocr.service` now uses this repository's service
directory, `.venv` and `.cache/official_models`. The previous application checkout
is no longer a runtime dependency. Python 3.13.5 still uses the separately
installed base interpreter under `~/anaconda3`; the camera application SDKs
remain separate installations as documented in the build guide.

The environment was copied and its entry points relocated; all 99 model files
matched their source hashes. Imports, `pip check` and four transport/concurrency
unittest groups passed. A real test service also ran with the entire old
application hidden in a private mount namespace. Chinese OCR and two concurrent
clients passed there and again on the switched production endpoint. The old
copy was retained as a backup. See [migration details](../../docs/OCR_SERVICE_MIGRATION.md).
