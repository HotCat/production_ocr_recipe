# Deployment decision and dependency audit

Target: Ubuntu 24.04 LTS, amd64, Ubuntu Desktop graphics, Hikvision USB/GigE,
Modbus TCP, CPU PaddleOCR.

| Dependency | Release delivery |
| --- | --- |
| Haskell, Yampa, Dear ImGui, husk-scheme and bindings | Compiled into `Camera`; no GHC/Stack/Cabal on target |
| Custom OpenCV 4.2 and contribution modules | Private `.so` bundle; Ubuntu's OpenCV 4.6 is a different ABI |
| Open3D 0.19, DIPlib, reconstruction/FFP, GLEW 2.1, TBB and custom transitive libraries | Private `.so` bundle, retained because husk-scheme links them |
| MindVision and ZMotion | Private link libraries; current supported camera path is Hikvision |
| Hikvision MVS | Private x86-64 userspace SDK, dynamic transport plugins, vendor notices, USB permissions |
| ZeroMQ, ZBar, GLFW, X11, GTK, audio/image/font libraries | Ubuntu APT runtime dependencies |
| glibc and C/C++ ABI runtimes | Ubuntu APT runtime dependencies; no older Conda C++ runtime override |
| OpenGL and hardware GPU driver | Ubuntu/Mesa or vendor driver on target |
| Python 3.13.5 | Relocated private interpreter and standard library |
| PaddleOCR 3.7.0, PaddlePaddle 3.3.1, PaddleX 3.7.2 and Python dependencies | Snapshot of tested CPU environment; versions recorded in package |
| Five OCR models | Included, selected by explicit local directory; no target model downloads |
| Fonts, shaders, textures, Scheme defaults | Included; missing user settings seeded on first launch |
| Modbus protocol | Included C++ header implementation; no Modbus daemon or compiler needed |

The v1.0.0 manifests contain 198 GUI native dependency records and 172 OCR records.
Records include distinct resolved origins; they are not counts of shipped files.
114 GUI and 22 OCR standard runtime package names were discovered, with overlap.
A fresh minimal Ubuntu root needs additional transitive Ubuntu packages as well.
Most are already present on a normal Ubuntu Desktop installation.

## Why Debian packages

A `.deb` integrates with APT, installs a desktop menu entry, registers the OCR
system service and USB rules, preserves settings across upgrades, and supports
normal removal. It handles this application's system integration with fewer
moving parts than a separate installer framework.

An AppImage can bundle the GUI but still needs separate installation for USB
permissions and a persistent OCR service. Snap/Flatpak introduce permissions and
sandbox integration for industrial cameras and network I/O. A Docker container
is useful for validation but adds display/GPU/USB configuration and a container
runtime to every production desktop. None provides an advantage for this fixed
Ubuntu 24.04 deployment over native binary packages.

Version 1.1.0 has independent `engraving-sequence` and `paddleocr-service`
packages, installers and archives. There is no cross-package dependency or
recommendation. Client libraries live under `/opt/engraving-sequence`; shared OCR
lives under `/opt/paddleocr-service`, independently of client installation or
removal. The installer does not overwrite system OpenCV, Python, SDKs or linker
configuration. The older v1.0.0 combined release below is retained as validation
history.

## Validation of v1.0.0

* Haskell `stack build` succeeded with portable asset/configuration paths.
* GUI native dependency and asset checks passed with `/home`, `/usr/local`, old
  `/opt` SDKs and the host linker cache hidden.
* Packaged Python imports and real model inference passed with networking disabled.
* A clean official Ubuntu 24.04.3 base filesystem received both binary packages
  and standard APT libraries. Both package statuses reached `install ok installed`.
  This rootless test used fakeroot to emulate ownership changes in standard
  Ubuntu font package maintenance scripts; no host system packages were installed.
* Installed GUI checks passed. The installed OCR service answered a real ZeroMQ
  health request and recognized `SERIAL 123456` with external networking disabled.
* The clean target had no `gcc`, `ghc`, `stack`, `pip`, or system `python3` command.
* The systemd unit passed `systemd-analyze verify` against the clean root.
* Launcher tests verified first-run seeding, preservation of operator calibration
  after changing release defaults, and rejection of duplicate instances.
* The three existing OCR transport/normalization tests passed.

This validates installation and binary runtime portability in an isolated
Ubuntu filesystem. Boot/login service startup, graphics rendering, physical
camera access, camera subnet configuration and PLC register exchange still need
acceptance on the destination desktop. It is not a full hardware VM acceptance
result. Vendor/font redistribution rights and CPU support remain those of the
included components.


## Shared service architecture in v1.1.0

The existing ZeroMQ REP topology supports multiple independent REQ clients.
One server process holds one PaddleEngine. Its socket and inference engine are
owned by one thread, which receives a request, runs inference, sends that peer's
reply, and only then receives the next request. No broker or worker pool is
needed to serialize access. ZeroMQ retains the reply route and fair-queues ready
connections. No global ordering between simultaneous independent clients is
assumed. Server high-water marks are eight messages per peer; health requests
use the same serial loop. CPU threads internal to Paddle do not constitute
concurrent inference requests.

The client owns a fresh REQ socket per call. Its reply timeout now defaults to
120 seconds, including queue waiting, and is configurable through
`PADDLEOCR_TIMEOUT_MS`. A timed-out request is not cancellation or proof of an
inference failure; it should not be retried automatically by a new client.

A TCP transport test synchronizes two independent client processes before every
submission. It checks eight correct replies, maximum one active engine call,
and one engine thread, then verifies malformed-request recovery. The packaged
smoke test uses two independent processes with different real OCR images.
The separate server package can be built with `--component ocr` without a
Camera executable or camera SDK inputs.

The v1.1.0 artifacts passed independent package isolation checks: client-only
library/assets validation and OCR-only imports and inference with no development
paths or external network. An upgrade in the disposable Ubuntu 24.04 filesystem
removed the old `engraving-sequence-ocr` package and installed `paddleocr-service`.
Removing the camera client then left the shared OCR package `install ok installed`.
With that GUI absent, two simultaneous client processes received `SERIAL 123456`
and `SERIAL 654321` from the one installed real OCR service, with external
networking disabled. Neither package depends on or recommends the other. The
new service unit passed systemd's static verification. As with v1.0.0, this is
filesystem/runtime validation, not a booted target hardware acceptance test.
