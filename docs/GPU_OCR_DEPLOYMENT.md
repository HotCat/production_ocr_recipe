# CPU and NVIDIA GPU OCR workers

The shared service keeps its two CPU workers and adds **one serial GPU worker**
in a separate Python environment. Both model profiles are available on each
device. CPU workers retain their existing CPU-only Paddle runtime and two math
threads each. The GPU worker owns one instance of each profile; simultaneous
GPU requests queue and never overlap model calls. CPU and GPU requests can run
at the same time. The broker bounds its application queue to eight requests,
then applies ZeroMQ backpressure. Client timeouts include queue time and do not
cancel accepted inference.

## Choose a device per application

Edit `~/.config/production-ocr-launcher/config.json`. Add `ocr_dispatch` inside
each desired **program entry**, alongside `name` and `command`, outside `values`
and `environment`:

```json
"ocr_dispatch": "auto"
```

| Value | Behavior |
| --- | --- |
| `cpu` | Only CPU workers. Default for old configuration files. |
| `gpu` | Only the GPU worker. Waits during GPU startup; explicit error if unavailable. |
| `auto` | Prefer the ready GPU; use CPU if GPU is absent, starting or failed. |

Once `auto` selects a ready GPU, it waits in that GPU's serial queue even if
the GPU is busy. A failed or interrupted GPU inspection returns an error;
it is **never replayed** on CPU. New `auto` requests can use CPU after a GPU
failure. The optional GPU is not repeatedly respawned inside the broker;
restart the service after fixing its environment to re-enable it.

New defaults use `auto` for Engraving+Compare (Chinese text), and `cpu` for the
four fast English PP-OCRv3 clients. Any of the five may explicitly choose GPU.
`use_angle_cls` remains independent and supported only for the four English
clients. No launcher UI controls were added for either setting.

Restart the launcher after a code upgrade. After editing JSON, click
**重新读取配置**, then close/relaunch the affected app to apply its policy.
Already running apps keep their launch-time settings. The launcher explicitly
exports `PADDLEOCR_DISPATCH`, overriding ambient or per-program environment
values. Manual developer runs can set this environment variable directly.
The app's 运行日志 prints the requested policy beside `request_ms`; the service
journal identifies the actual worker/device and its processing duration.

## Prepare the GPU environment on a development PC

The tested combination is Python 3.13, Paddle/Paddle GPU 3.3.1 and CUDA 11.8.
Obtain the official `paddlepaddle_gpu-3.3.1-cp313-cp313-linux_x86_64.whl` from
Paddle's CUDA 11.8 distribution. One accessible official storage URL is:

```text
https://paddle-whl.bj.bcebos.com/stable/cu118/paddlepaddle-gpu/paddlepaddle_gpu-3.3.1-cp313-cp313-linux_x86_64.whl
```

From the repository root:

```sh
scripts/install-ocr-gpu-runtime.sh /path/to/paddlepaddle_gpu-3.3.1-cp313-cp313-linux_x86_64.whl
```

This verifies the wheel, creates `.venv-gpu`, installs the GPU package and its
pinned NVIDIA libraries, and executes a CUDA tensor self-test. Unchanged OCR
dependencies are shared from `.venv`; the CPU environment is not modified.
For an offline wheelhouse, pass `PIP_NO_INDEX=1 PIP_FIND_LINKS=/path/to/wheels`.
For production deployment prefer the complete portable bundle below.

GPU libraries and models are generated assets excluded from Git. Updating
source with Git alone does not install this runtime. No CUDA toolkit or
`nvcc` is needed. NVIDIA's host driver is required; driver 535.309.01 is tested
here. Use a current compatible production driver (535 or newer recommended).

## Start and inspect the service

The default `--gpu-mode auto` detects `.venv-gpu/bin/python` if present. Without
it, CPU-only installations continue working. Settings can also be supplied as
`PADDLEOCR_GPU_MODE` and `PADDLEOCR_GPU_PYTHON` in the systemd user unit.

| Service GPU mode | Behavior |
| --- | --- |
| `auto` | Optional GPU. CPU stays available on missing/failed GPU runtime. |
| `off` | Never start the GPU worker. |
| `required` | Require GPU readiness; GPU startup/failure stops the whole service. |

The default remains `--device cpu --workers 2 --cpu-threads 2`; the extra GPU
worker is separate from this base pool. Keep the base pool on CPU when using
per-request dispatch. GPU startup has a 300-second deadline. CPU readiness is
sufficient to serve requests in optional mode; required mode waits for GPU.

Validate without interrupting port 5555:

```sh
services/paddleocr_service/run.sh --bind tcp://127.0.0.1:5556 --gpu-mode required
```

Send a ZeroMQ REQ JSON `{"op":"status"}` to see GPU readiness, worker devices,
busy flags and queue sizes. `{"op":"health"}` retains its existing response.
Every OCR request may include `"dispatch":"cpu"`, `"gpu"` or `"auto"`; old
clients without this field use CPU. Activate a validated upgrade during a
production break with `systemctl --user restart paddleocr.service`.

Measure the same actual production region on both devices:

```sh
services/paddleocr_service/.venv/bin/python -m services.paddleocr_service.benchmark_dispatch \
  --endpoint tcp://127.0.0.1:5556 --profile chinese --image /path/to/region.png
```

The benchmark alternates CPU/GPU order, excludes warmup, and reports median,
p95, first request and recognized text for each device. Measurements include
queue, PNG decoding, inference and reply; PNG encoding occurs before timing.
Other active clients can affect these numbers. Use `--profile legacy_en` and
optionally `--use-angle-cls` to measure the English models.

## Offline portable service for RTX 3070 / 3080 / 3090

These GPUs share Ampere compute capability 8.6. This deployment uses the same
Paddle CUDA binaries and model weights, with no TensorRT engine or source
compilation for a particular card. An NVIDIA driver and sufficient free VRAM
are still required. Actual 3070/3080 hardware must be validated with production
images; the 3090 test does not certify their performance or memory headroom.

Export after validating both runtimes and preparing all models:

```sh
python3 scripts/bundle-ocr-runtime.py --output build/ocr-runtime-ubuntu24-cuda118 --archive
```

The bundle contains a relocatable Python interpreter, CPU and CUDA packages,
CUDA/cuDNN libraries, shared service source, **both model sets**, install/run
scripts and a SHA256 file manifest. It does not include the NVIDIA driver,
camera SDKs, GUI clients or launcher; these remain in their existing app
deployment. Transfer the resulting `.tar.gz` by USB to Ubuntu 24.04 x86_64.
It needs no internet, Conda installation, pip installation or compiler there.

1. Install/verify the NVIDIA driver with `nvidia-smi`.
2. Extract the entire bundle into a permanent writable directory.
3. From that directory run `./install.sh` during a production break. It probes
   CUDA, backs up the existing user unit if different, installs the new path
   and restarts `paddleocr.service` on port 5555.
4. Update the launcher/client source and binaries through the normal app
   deployment, set the per-app JSON policy, and relaunch affected apps.

The launcher and apps can remain in their original installation: the endpoint
stays `tcp://127.0.0.1:5555`. Keep the bundle at the installed path; rerun its
installer after moving it. For a smoke test before installing the unit, run
`./run-service.sh --bind tcp://127.0.0.1:5556 --gpu-mode required`.

For rollback, stop the service, restore the saved unit from
`~/.local/state/production-ocr-service/unit-backups/`, run
`systemctl --user daemon-reload`, and start the service. Set JSON dispatch to
`cpu` when rolling back to a CPU-only runtime. The source checkout's original
CPU environment remains available.

## Validation on the development PC

The implementation was built on Ubuntu 24.04 x86_64 with an i5-12600K,
RTX 3090 and NVIDIA 535.309.01. Checks completed:

- All five Haskell executables rebuilt; their compiled request, UTF-8, routing
  metadata, error and timeout checks passed.
- 25 service/legacy-model tests passed, including three-worker routing with
  injected engines, serial GPU queueing, CPU independence, optional GPU startup
  failure and GPU crash without replay.
- The full launcher suite passed: 44 tests, five optional tests skipped. This
  includes JSON-only controls and authoritative per-app environment settings.
- A portable 6.9 GiB runtime was exported (3.7 GiB archive). From a renamed
  directory with a clean environment, both Paddle packages imported their
  respective CPU/CUDA builds. Real CPU requests from all five compiled apps,
  including simultaneous clients, passed against that portable service.
  Worker memory maps showed no original Conda or source-runtime library paths.
- Real `auto` Chinese OCR succeeded on CPU when CUDA was unavailable; explicit
  `gpu` returned an error without repeating the inspection.

**Real GPU inference remains unvalidated on this boot.** Direct `libcuda`
initialization returns error 999, despite `nvidia-smi` seeing the card. The
kernel journal records suspend/resume and an NVIDIA Xid 31 MMU fault. Reloading
`nvidia_uvm` was refused because the module was in use; administrator access
is needed for driver recovery. A reboot is the next step. This does not prove
a particular root cause beyond the failing driver initialization.

After reboot, run the CUDA probe, check service `op=status` for a ready GPU
worker and run the benchmark above with production regions. GPU latency, peak
VRAM use and physical RTX 3070/3080 operation must be checked then. No measured
GPU performance or 8 GiB memory guarantee is claimed by these CPU tests.
