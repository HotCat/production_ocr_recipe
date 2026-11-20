# Independent Ubuntu 24.04 client and shared OCR packages

Version 1.1.0 separates the camera GUI from the reusable PaddleOCR service.
Neither package depends on or recommends the other. Each has its own .deb,
installer, checksum file and archive. Install the OCR service once; two or more
applications can share it. Target PCs need no compilers, Stack, pip, Conda, or
system Python. Models are included in the OCR package.

## Build on the development workstation

```
stack build
/usr/bin/python3 packaging/build.py --component client --version 1.1.0
/usr/bin/python3 packaging/build.py --component ocr --version 1.1.0
```

The default component is `client`. Building `ocr` does not inspect the Camera
binary or require its source build, fonts, MVS SDK, or calibration files. It
snapshots the tested OCR virtualenv, base interpreter, private libraries and
cached models. Build both with `--component all`; it still produces independent
installers and archives, without a combined installer.

Outputs:

* `dist/engraving-sequence_1.1.0_ubuntu24.04_amd64.tar`: camera client only.
* `dist/paddleocr-service_1.1.0_ubuntu24.04_amd64.tar`: shared OCR service only.
* Individual .deb files, plus release folders with `install.sh`, `SHA256SUMS`
  and documentation. Do not copy `dist/stage-*` to production machines.

The builder needs Ubuntu 24.04 amd64, `python3`, `dpkg-deb`, and `patchelf`.
Run `stack build` before building the client. Overrides include `--binary`,
`--mvs`, `--ocr-venv`, `--models`, and `--config`. The five Scheme defaults can
be taken from a selected calibration directory with `--config /path/to/config`.
Use a new version for upgrades; generated staging/release directories are
retained and will not be overwritten.

## Install the shared service once

Extract only the OCR archive on the OCR host and run its `sh install.sh`, or:

```
sudo apt install ./paddleocr-service_1.1.0_amd64.deb
```

This installs `/opt/paddleocr-service`, `/etc/paddleocr-service/settings`,
the `paddleocr-service` command, and `paddleocr-service.service`. It has no
camera application dependency. The system service starts at boot and retains
one loaded model pipeline. It runs as a systemd dynamic user, with writable
state/cache under `/var/lib/paddleocr-service` and `/var/cache/paddleocr-service`.

Two applications on the same host can use the default `tcp://127.0.0.1:5555`.
For clients on different PCs, set the OCR host's actual LAN address in
`/etc/paddleocr-service/settings`, for example:

```
PADDLEOCR_BIND=tcp://192.168.0.10:5555
PADDLEOCR_DEVICE=cpu
PADDLEOCR_LANG=en
PADDLEOCR_WORKERS=2
PADDLEOCR_CPU_THREADS=2
```

Then run `sudo systemctl restart paddleocr-service`. The bind address must exist
on that host; permit the chosen TCP port from the client PCs on the trusted LAN.
The protocol does not add authentication. Direct foreground invocation can use
`paddleocr-service --bind tcp://192.168.0.10:5555`; system settings are read by
systemd, and command-line options override the process environment.

```
systemctl status paddleocr-service
journalctl -u paddleocr-service -f
paddleocr-service --check
```

Wait for `PaddleOCR service listening ...; 2 model workers, CPU threads per worker=2` before
requesting OCR. An older source-tree user service may already own port 5555;
stop that particular old service before starting the installed replacement.
The new .deb conflicts with/replaces the old `engraving-sequence-ocr` package,
so APT removes that old package on upgrade. Other clients can continue using the
same endpoint and unchanged request/reply protocol.
The service runs at most two independent model instances; additional requests
wait for a free worker. Set `PADDLEOCR_WORKERS=1` for serial fallback. Each
worker defaults to two CPU inference threads, controlled by
`PADDLEOCR_CPU_THREADS` in the same settings file.

## Install clients separately

Extract the client archive on each camera PC and run its `sh install.sh`, or:

```
sudo apt install ./engraving-sequence_1.1.0_amd64.deb
```

This does not install or start an OCR server. Set each application's endpoint
to the shared server. For this GUI, edit `/etc/engraving-sequence/settings`, or
create `~/.config/engraving-sequence/settings`:

```
PADDLEOCR_ENDPOINT=tcp://192.168.0.10:5555
PADDLEOCR_TIMEOUT_MS=120000
SEQUENCE_CAMERA=Hikvision
SEQUENCE_MODBUS_HOST=192.168.0.68
SEQUENCE_MODBUS_PORT=4998
SEQUENCE_MODBUS_SLAVE=3
```

Restart the GUI after changing settings. On a shared local desktop, use
`tcp://127.0.0.1:5555` in every client instead. Other applications can reuse the
protocol in `services/paddleocr_service/README.md`; each process/thread must own
its own REQ socket. A client that still embeds PaddleOCR directly needs to be
adapted to that protocol; installing the server alone does not change it.

Launch **Engraving Sequence** from the applications menu or run
`engraving-sequence`. `engraving-sequence --check` checks native libraries and
assets without a camera. The client requires Ubuntu Desktop, OpenGL 3.3, X11 or
XWayland and the appropriate GPU driver. USB permissions and Hikvision
userspace USB/GigE SDKs are included. Reconnect USB cameras after installation;
configure the camera subnet for GigE. PCIe kernel drivers remain vendor-specific.

## Concurrent submissions, two PaddleOCR workers

Every application can submit a request independently. A ZeroMQ ROUTER broker
dispatches to two spawned workers, each owning one `PaddleEngine` and executing:

```
receive one request -> decode -> PaddleOCR.predict -> send that client's reply
```

Each worker receives its next request only after replying. At most two predict
calls are active across the service; other clients wait until a worker is free.
CPU threads used internally by Paddle are configured separately (two per worker
by default). Replies are routed to the requesting socket. Per-connection order is
preserved; no global ordering between simultaneous independent clients is
promised. Both text and JSON recognition use the same worker pool. Health
requests also wait for a free worker, and the pool starts serving only after
both models initialize. A dead worker fails the pool so systemd can restart it.

Each REQ socket permits one outstanding request. The Haskell client already
creates a socket for each call and shares only the thread-safe ZeroMQ context.
It now allows 120 seconds by default for a reply, including queue waiting time;
set `PADDLEOCR_TIMEOUT_MS` from 1 through 3600000 as appropriate for the workload.
Its send timeout remains five seconds. ZeroMQ send/receive high-water marks on
the server are eight messages per connection; they apply backpressure when
both workers are busy. There is no unlimited throughput guarantee:
size timeouts for the sum of work ahead of a request plus its own inference.
A client timeout/disconnect does not cancel work already accepted by the server;
recreate a timed-out REQ socket rather than reusing it in an invalid state.

## Data, upgrades and removal

Camera calibration remains in `~/ocrconfigs/sequence3`; missing defaults are
seeded on first launch, and existing files survive upgrades. Writable GUI files
are under `~/.local/state/engraving-sequence`. A lock prevents two instances of
this same GUI for one user from competing for its camera/calibration. Different
client applications/users can share the OCR service independently of that lock.
Modbus register behavior is unchanged: trigger 0=77, OK 4=99, NG 2=88.

Use APT for independent upgrades/removal:

```
sudo apt remove engraving-sequence
sudo apt remove paddleocr-service
```

Removing a client does not remove the shared OCR service. Removing the server
disconnects all its clients. User calibration is preserved; purge removes each
package's system configuration.

The installer refreshes APT metadata and fetches missing standard Ubuntu runtime
libraries. Native application/private libraries, Python packages and OCR models
are bundled, so no source compilation or model downloads occur on the target.
For an air-gapped installation, prepare the standard Ubuntu APT dependencies
separately. Custom OpenCV 4.2 and other husk-scheme link dependencies remain
bundled privately; GPU drivers and C/C++ ABI runtimes come from Ubuntu.

## Developer validation

```
services/paddleocr_service/.venv/bin/python -m unittest services.paddleocr_service.test_server
/usr/bin/python3 packaging/test_launcher.py
/usr/bin/python3 packaging/verify.py dist/engraving-sequence_1.1.0_amd64.deb
/usr/bin/python3 packaging/verify.py dist/paddleocr-service_1.1.0_amd64.deb --inference
```

The verifier uses bubblewrap namespaces to hide development directories and
disable external networking. `packaging/smoke_ocr.py`, run by the installed
Python interpreter, starts one service and submits distinct images from two
simultaneous client processes, checking that each receives its own OCR result.
The transport test instruments the production server loop to assert eight
requests from two processes execute with maximum one active inference call.
See `packaging/DEPENDENCIES.md` for dependency/validation details and hardware
acceptance boundaries. Available SDK/Python license metadata is preserved;
custom libraries/fonts remain subject to their redistribution terms.
