# Shared PaddleOCR service

A ZeroMQ broker routes independent REQ clients to **two CPU worker processes**.
Each spawned worker owns one PaddleOCR 3.x pipeline and runs inference serially;
up to **two requests run concurrently** across the service. Further requests
wait until a worker becomes idle. Replies return to the requesting client,
including when requests finish out of order. There is no strict FIFO order
across peers. Each client thread/process must use its own socket. Client timeouts
include queue time and do not cancel work already accepted by the server.

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
CPU inference disables the current PaddleX oneDNN default; compatible hosts can
set `PADDLE_PDX_ENABLE_MKLDNN_BYDEFAULT=True`.

CPU is the default device. `PADDLEOCR_WORKERS=2` (or `--workers 2`) is the default
and hard maximum; use `1` to fall back to serial processing. Values outside 1–2
are rejected. `PADDLEOCR_CPU_THREADS=2` (or `--cpu-threads 2`) controls Paddle's
CPU threads per worker and the OpenCV/OpenMP/BLAS thread settings. The default
uses two inference threads per worker to leave CPU capacity for the camera
applications. These settings control compute pools, not the total number of
OS helper threads. Two model copies consume more RAM than the previous single
pipeline; measure memory and latency on the production PC before deployment.
The existing models, image preprocessing and Haskell request protocol are
unchanged. No client rebuild is needed.

The default endpoint is `tcp://127.0.0.1:5555`. Set `PADDLEOCR_BIND` on the server
and matching `PADDLEOCR_ENDPOINT` on clients to change it. Wait for the listening
message after models load. Run only one listener per endpoint. The Haskell
client's reply deadline defaults to 120 seconds (`PADDLEOCR_TIMEOUT_MS`). After
a timeout it discards its REQ socket; accepted inference may still finish.
High-water marks are eight messages per peer, with backpressure under load.
The broker reads new requests only when a worker is free; it does not accumulate
an unbounded Python task queue. The listening message appears only after both
models initialize. An inference exception returns `ERROR:` and the worker
continues. If a worker process dies or initialization exceeds five minutes,
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
`{"op":"recognize","encoding":"png"}` returns recognized UTF-8 text.
`recognize_json` returns text plus line confidence/boxes. `{"op":"health"}`
uses only a metadata frame. Errors start with `ERROR:`.

```sh
services/paddleocr_service/.venv/bin/python -m unittest services.paddleocr_service.test_server
```

Tests exercise transport, response normalization and the actual spawned worker
pool without loading real models. Three concurrent clients verify that exactly
two independent pipelines run simultaneously, the third request waits, replies
remain paired even out of order, and freed workers immediately take queued work.
They also cover one-worker fallback, request errors, abandoned clients, worker
startup/crash cleanup, invalid limits and occupied endpoints. The single-worker
transport utility is tested separately. Application test helpers accept
`--real` to additionally use an already running PaddleOCR endpoint.

Two-worker validation on 2026-11-20: all 11 unit/transport tests passed. Three
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
