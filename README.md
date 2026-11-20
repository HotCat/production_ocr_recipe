# Production OCR applications

Five Haskell/OpenCV production clients and their shared, locally modified source
dependencies. All camera SDKs, compiled programs/libraries, build caches, OCR
models, Python environments, production databases and old source backups are
excluded from Git.

| Application | Inspection | Camera environment variable |
| --- | --- | --- |
| `Barcode+Sequence` | Barcode continuity with optional printed-text guard | `SEQUENCE_OCR_CAMERA` |
| `Barcode+Sequence+Barcode` | Product/packaging barcodes match verbatim; independent print guards and product continuity | `DOUBLE_BARCODE_CAMERA` |
| `Barcode+Sequence+Engraving` | Barcode continuity/print guard plus engraved serial comparison | `BARCODE_ENGRAVING_CAMERA` |
| `Engraving+Sequence` | Engraved serial continuity | `SEQUENCE_CAMERA` |
| `Engraving+Compare` | Mixed Chinese/English engraving equals a saved preset; no sequence mechanism | `ENGRAVING_COMPARE_CAMERA` |

Camera defaults are `Hikvision`. This selects the unique Hikvision/Hikrobot
USB3 or GigE device by manufacturer, ignoring third-party MVS entries. To select
one of multiple Hikvision cameras, use `Hikvision:SERIAL`. See
[docs/CAMERA_SELECTION.md](docs/CAMERA_SELECTION.md). Each application keeps its
existing production workflow and calibration namespace. `Engraving+Compare` includes immediate preset
persistence and restores the last saved profile on startup. Its whole-text rule
ignores whitespace and treats `：`/`:` equally; case and other punctuation matter.

## Layout

```text
apps/                    Five independent Camera executables and their tests
assets/                  Shared fonts, textures and splash image
services/paddleocr_service/  One shared ZeroMQ/PaddleOCR service
dependencies/           Local source snapshots (no submodule checkout required)
  dear-imgui/            Haskell bindings + ImGui, ImGuizmo and ImPlot sources
  glm/                   GLM headers used by the bindings
  haskell-opencv/         Modified Haskell OpenCV binding
  husk-scheme/            Modified Scheme interpreter/device wrappers
  vision-native/         FFP/reconstruction/codec/projector source closure
  modbuspp/              Modified header-only Modbus/TCP library
scripts/                 Build, local SDK paths, launch, service setup and audit
```

The five Cabal packages are all named `Camera`, so build one application at a
time using its own Stack file. Each references the same libraries in
`dependencies/`; these are real source copies, including local modifications,
not references to the old workstation checkout.

## Build on Ubuntu 24.04 amd64

Install Stack/GHC tooling and the external native prerequisites in
[docs/BUILDING.md](docs/BUILDING.md), including the separately supplied camera and
motion SDKs. GHC 8.10.7 is selected by the pinned `lts-18.28` resolver; other
Hackage packages come from that resolver and each application's pinned extra
dependencies/lockfile.

```sh
git clone https://github.com/HotCat/production_ocr_recipe.git
cd production_ocr_recipe

# Supply external vendor paths if they are not already in the system search path.
# These generated files stay local and are ignored by Git.
python3 scripts/configure-local.py \
  --library-dir /path/to/zmotion/lib \
  --include-dir /path/to/mindvision/include

scripts/build-native.sh
scripts/build-app.sh 'Engraving+Compare'
# Or build all five clients:
scripts/build-all.sh
```

Executables are created in `apps/NAME/bin/Camera`. The native output is under
`build/native/{fpp,reconstruct}`. Both are ignored. Use
`BUILD_JOBS=1 scripts/build-native.sh` if compilation memory is limited.
CMake prefixes for externally installed packages can be supplied to
`build-native.sh`, for example `-DCMAKE_PREFIX_PATH=/opt/vision-libraries`.

The customized Husk exports 3D/projector/motion APIs and consequently still
links their native libraries. Their required source is included even though
the OCR workflows only use part of that API. See [dependencies/README.md](dependencies/README.md).

## Operator launcher

The PySide6 launcher provides a program list, a camera/Modbus parameter inspector,
status tracking and one managed instance per program. Program availability is
managed entirely through its JSON configuration; the UI has no add/remove
controls. Parameters can be extended through configuration definitions.

```sh
scripts/install-launcher.sh
scripts/run-launcher.sh
```

The user configuration is `~/.config/production-ocr-launcher/config.json`.
See [launcher/README.md](launcher/README.md) for program entries, parameter
bindings, process lifetime and desktop installation.

## Shared PaddleOCR

Use an existing compatible service by setting `PADDLEOCR_ENDPOINT`, or create a
separate Python environment from [services/paddleocr_service/README.md](services/paddleocr_service/README.md).
Models are downloaded/prepared separately and are not committed. Multiple
clients share one service; its ZeroMQ broker routes requests to two independent
CPU model workers, with at most two inferences running concurrently. Additional
requests wait for a free worker. Each worker defaults to two CPU threads;
`PADDLEOCR_WORKERS=1` selects serial fallback. A client reply timeout includes
queue time.

```sh
services/paddleocr_service/run.sh
# In another terminal, from the repository root:
scripts/run-app.sh 'Engraving+Compare'
```

`run-app.sh` seeds missing user Scheme profiles without overwriting existing
calibration, sets the working directory for assets and finds the built native
libraries. Preserve vendor library search paths in `LD_LIBRARY_PATH` if your
SDKs were installed outside the system linker search directories. On this
workstation `paddleocr.service` runs from `services/paddleocr_service` in this
repository and owns port 5555. Use that existing service; do not start a second
listener on the same endpoint. Its environment and all five models have been
migrated here, so the old application checkout is no longer required by OCR.

## Verification

```sh
python3 scripts/audit-source.py
services/paddleocr_service/.venv/bin/python -m unittest services.paddleocr_service.test_server
cd apps/Engraving+Compare
../../scripts/test-app.sh 'Engraving+Compare'
# The same helper runs the barcode suites for each barcode application.
# Add --real to exercise an already running OCR service as well.
```

The tests run without camera/PLC operations. The GUI and actual machine cycle
still require testing with the physical camera/controller. Results from this
repository import are recorded in [docs/VALIDATION.md](docs/VALIDATION.md).

The existing Debian packaging tools are retained under
`apps/Engraving+Sequence/packaging`; they build the original `engraving-sequence`
client package and a separate shared OCR package. They are not yet a generic
installer for all five client identities. Generated SDK/runtime bundles must
stay outside Git.

See [THIRD_PARTY.md](THIRD_PARTY.md) for component notices. The import preserves
the production working directories; development takes place in this new clone.

## Production records

All five clients record final OK/NG decisions in per-application SQLite databases.
The launcher inspector's **生产记录 / 日历** button opens date distribution and
query views. Shared persisted clock protection blocks production launches after
system time regresses. See [launcher/README.md](launcher/README.md#production-history-and-offline-clock-protection)
for fields, data locations, offline clock limits, backups and regression tests.
The Haskell writer and SQL schemas are in `shared/production-log/`; keep that
folder when copying or building this repository. Schemas are embedded in compiled
clients, so deployed Haskell binaries do not require their source files.
