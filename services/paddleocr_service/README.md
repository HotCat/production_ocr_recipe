# Shared PaddleOCR service

One process loads one PaddleOCR 3.x pipeline. Independent clients use ZeroMQ
REQ sockets connected to its REP socket; the server processes inference serially
and pairs every reply with the requesting client. At least two simultaneous
clients are supported. There is no strict FIFO order across peers. Each client
thread/process must use its own socket. Client timeouts include queue time and
do not cancel work already accepted by the server.

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

The default endpoint is `tcp://127.0.0.1:5555`. Set `PADDLEOCR_BIND` on the server
and matching `PADDLEOCR_ENDPOINT` on clients to change it. Wait for the listening
message after models load. Run only one listener per endpoint. The Haskell
client's reply deadline defaults to 120 seconds (`PADDLEOCR_TIMEOUT_MS`). After
a timeout it discards its REQ socket; accepted inference may still finish.
High-water marks are eight messages per peer, with backpressure under load.

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

Tests exercise transport, response normalization and independent concurrent
clients. They verify responses remain paired and the maximum concurrent engine
call count is one, without loading real models. Application test helpers accept
`--real` to additionally use an already running PaddleOCR endpoint.

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
