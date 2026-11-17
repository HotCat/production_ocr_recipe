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
systemctl --user enable --now production-paddleocr.service
journalctl --user -u production-paddleocr.service -f
```

The installer writes paths for this clone and reloads systemd. It does not start
the service itself. Ensure no existing service owns the endpoint before enabling.
The unit starts at login. Use `systemctl --user disable --now
production-paddleocr.service` to stop and disable it. For system-wide deployment,
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
