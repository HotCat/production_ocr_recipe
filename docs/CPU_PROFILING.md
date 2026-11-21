# Client CPU investigation

The high CPU measured on 2026-11-21 came primarily from OpenCV's native worker
pool. Restricting GHC to two capabilities alone had not fixed it. All five GUI
clients now call `OpenCV.setNumThreads 1` before camera/worker initialization.
They keep the GHC default `-N2`. There is no added frame-rate limit, camera delay
or change to production trigger polling, OCR acceptance rules or image pixels.

## Live barcode result

The running `Barcode+Sequence` client was closed gracefully and restarted with
the same saved camera/inspection configuration and production mode, after the
operator authorized the interruption. Measurements use Linux's convention that
one fully occupied logical core is 100%.

| Five-second sample | Before | After |
| --- | ---: | ---: |
| Total application CPU | 470.63% | 107.59% |
| Main thread | 79.18% | 98.99% |
| OpenCV configured threads | 16 | 1 |
| GHC capabilities | 2 | 2 |

Total CPU fell approximately **77%**. A later independent `/proc` sample was
90.59%; subsequent frame reports were around 82–92% CPU at 60 FPS. Before the
change, the fifteen newest native workers accounted for 378.65% CPU;
GHC worker/ticker threads together
accounted for only 2.8%. OpenCV's installed build reports the `pthreads` parallel
backend, so changing TBB settings would not control this pool.

After the change, two in-app five-second reports showed 33.3 and 47.0 FPS,
89.5% and 108.5% process CPU. Script/image processing averaged 19.5 and 18.6 ms
per frame, including barcode callbacks of 17.8 ms. Image upload averaged
1.9 and 1.7 ms, and FRP callback bindings 0.026 ms. GC used 0.104/4.486 and
0.088/5.447 CPU seconds (about 2.3% and 1.6% of process CPU).

These are short camera-preview samples under the current configuration, not a
full production throughput/PLC acceptance test. Frame rates are observations,
not targets or guarantees. `Engraving+Sequence` has the same native limit and
was rebuilt, but was not substituted for the running barcode client for a live
measurement. Its CPU use after the change still needs measurement against the
reported 700% baseline in its normal production configuration.

## Why the tutorial is cheaper

`CoordinateSystems` renders static textures. The production programs also
capture frames, convert colors, flip/crop images, upload camera textures and
interpret the Scheme processing script each frame. The engraving configuration
includes serial and motion callbacks, while the measured barcode configuration
executes the barcode callback. Those IO callbacks perform image processing even
though Yampa schedules them. Their native work must be distinguished from the
cost of evaluating the FRP network itself.

Two hardware-free probes support this distinction:

| Probe | Result |
| --- | --- |
| Engraving+Sequence idle FRP, 100,000 steps | 0.025767 ms CPU/step; equivalent to 0.155% CPU at 60 FPS |
| Barcode+Sequence idle FRP, 100,000 steps | 0.019845 ms CPU/step; equivalent to 0.119% CPU at 60 FPS |
| OpenCV synthetic pipeline at 30 FPS, default 16 threads | 73.77% CPU |
| Same pipeline, one thread | 6.59% CPU |
| Same pipeline, two threads | 9.66% CPU |

The FRP probe uses each application's actual `parseKeyInput >>> combineAll`
network and forces its returned action closures, but **does not execute IO
callbacks**. It uses idle controls and cannot characterize every event or the
camera, PLC and OCR work within those closures. Allocation/GC counters are also
reported; 100,000 unpaced steps are much more work than 60 steps in one second.

The native probe uses a synthetic 1280×1024 image and representative color
conversion, flip and crop operations. Output hashes matched across all three
thread settings. This establishes the pool overhead on this machine, not an
end-to-end application speedup. Results vary with hardware and scheduling.

## Repeatable diagnostics

Run these from the repository root. The first three commands do not initialize
a GUI, camera, PLC or production database:

```sh
scripts/test-rts-capabilities.sh
scripts/profile-frp-cpu.sh
scripts/profile-opencv-cpu.sh
```

The FRP probe compiles with Stack and uses locally configured SDK/library paths.
The native probe needs a C++ compiler and this installation's `opencv`
pkg-config package. To sample an already running application's threads:

```sh
python3 scripts/sample-app-cpu.py PID
```

This reads `/proc` for five seconds and does not attach a debugger. Restricted
`perf`/ptrace access on the production host was left unchanged.

After closing a client's existing instance, an operator can start a diagnostic
GUI run with its normal camera and PLC connections:

```sh
OCR_CPU_PROFILE=1 scripts/run-app.sh 'Engraving+Sequence'
```

Alternatively set `OCR_CPU_PROFILE` to `"1"` in that program's launcher
`environment` and launch normally to capture reports in the launcher's runtime
log. Remove the setting when finished. Reports contain FPS, whole-process CPU,
GC CPU seconds and average **wall time** per phase with call counts. Waits can
be included in wall time, so phase time is not a native CPU stack profile.
`script+vision` includes the named image callbacks; do not add those nested
times together. Some FRP evaluation can be deferred until a callback is forced.
With profiling disabled, wrappers execute their actions without reading clocks
or updating timing counters.

Runtime settings:

| Variable | Default | Accepted values |
| --- | --- | --- |
| `OCR_RTS_CAPABILITIES` (launch script) | `2` | `1`, `2` |
| `OCR_OPENCV_THREADS` (client startup) | `1` | integers `1` through `16`, or `auto` |
| `OCR_CPU_PROFILE` | disabled | `1` enables reporting |

`auto` is intended for a controlled baseline comparison; it can restore the high
CPU use. The launch script supplies `GHCRTS=-N2` (or `-N1`) and adds `-T` when
profiling, overriding inherited RTS settings. Launching the binary directly
still gets its compiled `-N2` default, but explicit RTS arguments can override
that. GHC capabilities do not limit native pools or the separate PaddleOCR
service. A headless `--runtime-info` prints actual GHC/OpenCV settings and exits
without opening production hardware.
