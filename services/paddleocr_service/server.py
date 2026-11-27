from __future__ import annotations

import argparse
import json
import logging
import multiprocessing
import os
import signal
import subprocess
import threading
import time
from collections import deque
from pathlib import Path
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    import numpy as np

import zmq


MAX_IMAGE_BYTES = 64 * 1024 * 1024
MAX_WORKERS = 2
PROFILES = ('legacy_en', 'chinese')


def _result_mapping(result: Any) -> dict[str, Any]:
    value = getattr(result, "json", result)
    if callable(value):
        value = value()
    if isinstance(value, str):
        value = json.loads(value)
    if not isinstance(value, dict):
        return {}
    nested = value.get("res")
    return nested if isinstance(nested, dict) else value


def normalize_results(results: Any) -> dict[str, Any]:
    lines: list[dict[str, Any]] = []
    for page in results or []:
        data = _result_mapping(page)
        texts = data.get("rec_texts") or []
        scores = data.get("rec_scores") or []
        polygons = data.get("rec_polys", data.get("dt_polys", [])) or []
        for index, text in enumerate(texts):
            line: dict[str, Any] = {"text": str(text)}
            if index < len(scores):
                score = scores[index]
                line["score"] = float(score.item() if hasattr(score, "item") else score)
            if index < len(polygons):
                polygon = polygons[index]
                line["box"] = polygon.tolist() if hasattr(polygon, "tolist") else polygon
            lines.append(line)
    return {"text": "".join(line["text"] for line in lines), "lines": lines}


class PaddleEngine:
    def __init__(self, lang: str, device: str | None = "cpu", cpu_threads: int = 2) -> None:
        if not device or device.lower().startswith("cpu"):
            os.environ.setdefault("PADDLE_PDX_ENABLE_MKLDNN_BYDEFAULT", "False")
        from paddleocr import PaddleOCR
        from .legacy_v3 import LegacyV3Engine

        legacy_root = Path(os.getenv('PADDLEOCR_LEGACY_MODEL_ROOT',
                                    str(Path(__file__).parent / '.cache' / 'legacy_models')))
        self.legacy = LegacyV3Engine(legacy_root, device, cpu_threads)

        # Chinese is an explicit profile; --lang must never accidentally turn
        # the preset-text application into an English-only recognizer.
        options: dict[str, Any] = {"lang": "ch", "cpu_threads": cpu_threads}
        if device:
            options["device"] = device
        # Installed packages supply the already tested models explicitly. No model
        # registry lookups or downloads are necessary on the deployment machine.
        model_root = os.getenv("PADDLEOCR_MODEL_ROOT")
        if model_root:
            for component, name in {
                "doc_orientation_classify": "PP-LCNet_x1_0_doc_ori",
                "doc_unwarping": "UVDoc",
                "text_detection": "PP-OCRv6_medium_det",
                "text_recognition": "PP-OCRv6_medium_rec",
                "textline_orientation": "PP-LCNet_x1_0_textline_ori",
            }.items():
                directory = Path(model_root) / name
                if not (directory / "inference.yml").is_file():
                    raise FileNotFoundError(f"Packaged OCR model missing: {directory}")
                options[component + "_model_name"] = name
                options[component + "_model_dir"] = str(directory)
        self.chinese = PaddleOCR(**options)
        logging.info('OCR profiles ready: legacy_en=PP-OCRv3 English, use_angle_cls=request (default false), '
                     'MKL-DNN enabled on CPU; chinese=multilingual preset text')

    def recognize(self, image: np.ndarray, profile: str = 'legacy_en',
                  use_angle_cls: bool = False) -> dict[str, Any]:
        if profile == 'legacy_en':
            return self.legacy.recognize(image, use_angle_cls=use_angle_cls)
        if profile == 'chinese':
            return normalize_results(self.chinese.predict(image))
        raise ValueError(f'Unknown OCR profile: {profile}')


def handle_request(frames: list[bytes], engine: Any) -> bytes:
    try:
        import cv2
        import numpy as np

        if not frames:
            raise ValueError("missing request header")
        header = json.loads(frames[0].decode("utf-8"))
        operation = header.get("op")
        if operation == "health":
            return b'{"ok":true,"service":"paddleocr"}'
        if operation not in ("recognize", "recognize_json"):
            raise ValueError("unsupported operation")
        profile = header.get('profile', 'legacy_en')
        if profile not in PROFILES:
            raise ValueError(f'Unknown OCR profile: {profile}')
        use_angle_cls = header.get('use_angle_cls', False)
        if type(use_angle_cls) is not bool:
            raise ValueError('use_angle_cls must be a JSON boolean')
        if profile == 'chinese' and use_angle_cls:
            raise ValueError('use_angle_cls is only supported by the legacy_en profile')
        if len(frames) != 2:
            raise ValueError("recognize expects a header and one image frame")
        encoded = frames[1]
        if not encoded or len(encoded) > MAX_IMAGE_BYTES:
            raise ValueError("image frame is empty or exceeds the size limit")
        image = cv2.imdecode(np.frombuffer(encoded, dtype=np.uint8), cv2.IMREAD_COLOR)
        if image is None:
            raise ValueError("image frame is not a supported encoded image")
        result = engine.recognize(image, profile=profile, use_angle_cls=use_angle_cls)
        if operation == "recognize_json":
            return json.dumps(result, ensure_ascii=False).encode("utf-8")
        return result["text"].encode("utf-8")
    except Exception as exc:
        return ("ERROR: " + str(exc)).encode("utf-8", errors="replace")


def serve_requests(socket: zmq.Socket, engine: Any,
                   stop: threading.Event | None = None) -> None:
    """Own the REP socket and engine in one thread; never overlap predict calls.

    ZeroMQ queues/fair-queues independent REQ peers and retains the reply route.
    No client socket, worker pool or additional model instance is shared here.
    The optional stop event is for embedded use and transport integration tests.
    """
    while stop is None or not stop.is_set():
        if stop is not None and not socket.poll(100):
            continue
        frames = socket.recv_multipart()
        reply = handle_request(frames, engine)
        socket.send(reply)


def _worker(backend: str, identity: bytes, lang: str, device: str | None,
            cpu_threads: int, stop: Any, engine_factory: Any) -> None:
    """A process owns both profiles and never overlaps either predict call."""
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    # Set these before importing Paddle/OpenCV/NumPy in the fresh interpreter.
    for name in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS",
                 "NUMEXPR_NUM_THREADS"):
        os.environ[name] = str(cpu_threads)
    os.environ["OMP_WAIT_POLICY"] = "PASSIVE"
    import cv2

    cv2.setNumThreads(cpu_threads)
    context = zmq.Context()
    try:
        engine = engine_factory(lang, device, cpu_threads)
        with context.socket(zmq.DEALER) as socket:
            socket.setsockopt(zmq.LINGER, 0)
            socket.setsockopt(zmq.IDENTITY, identity)
            socket.connect(backend)
            socket.send_multipart([b"READY"])
            logging.info("OCR %s ready; pid=%s, CPU threads=%s", identity.decode(),
                         os.getpid(), cpu_threads)
            while not stop.is_set():
                if not socket.poll(100):
                    continue
                request = socket.recv_multipart()
                started = time.monotonic()
                logging.debug("OCR %s request started", identity.decode())
                reply = handle_request(request[2:], engine)
                socket.send_multipart([b"RESULT", *request[:2], reply])
                try:
                    header = json.loads(request[2])
                    profile = header.get('profile', 'legacy_en')
                    angle_cls = header.get('use_angle_cls', False)
                except (ValueError, AttributeError, IndexError):
                    profile = 'invalid'
                    angle_cls = 'invalid'
                logging.info("OCR %s device=%s profile=%s use_angle_cls=%s completed in %.3fs", identity.decode(),
                             device, profile, angle_cls, time.monotonic() - started)
    finally:
        context.term()


def _send_reply(frontend: zmq.Socket, route: list[bytes], reply: bytes) -> None:
    try:
        frontend.send_multipart([*route, reply], zmq.DONTWAIT)
    except zmq.ZMQError as exc:
        if exc.errno not in (zmq.EHOSTUNREACH, zmq.EAGAIN):
            raise
        # A timed-out/disconnected client must not block the other clients.
        logging.warning("Discarded reply for a disconnected or full client")


def serve(endpoint: str, lang: str, device: str | None = "cpu", workers: int = 2,
          cpu_threads: int = 2, *, stop: Any = None, ready: Any = None,
          engine_factory: Any = PaddleEngine, startup_timeout: float = 300,
          gpu_python: str | None = None, gpu_mode: str = "auto",
          gpu_factory: Any = None) -> None:
    """Two CPU workers plus an optional isolated, serial GPU worker.

    Requests select cpu/gpu/auto. Auto prefers a ready GPU and otherwise CPU;
    once selected, busy workers queue requests rather than switching devices.
    A bounded queue prevents unlimited decoded-image/request accumulation.
    GPU loss fails its active/queued requests, leaves CPU workers available,
    and never silently replays a production inspection.
    """
    if not 1 <= workers <= MAX_WORKERS:
        raise ValueError(f"workers must be between 1 and {MAX_WORKERS}")
    if cpu_threads < 1:
        raise ValueError("cpu_threads must be positive")
    if gpu_mode not in ("off", "auto", "required"):
        raise ValueError("gpu_mode must be off, auto or required")
    if gpu_mode == "required" and not (gpu_python or gpu_factory):
        raise ValueError("GPU runtime is required but not configured")
    spawn = multiprocessing.get_context("spawn")
    worker_stop = spawn.Event()
    stop = stop if stop is not None else threading.Event()
    context = zmq.Context()
    processes = {}
    devices = {}
    idle: deque[bytes] = deque()
    initialized = set()
    inflight: dict[bytes, list[bytes]] = {}
    pending = {"cpu": deque(), "gpu": deque()}
    gpu_process = None
    gpu_id = b"gpu-worker-1"
    gpu_state = "disabled"
    frontend = context.socket(zmq.ROUTER)
    backend = context.socket(zmq.ROUTER)
    try:
        for socket in (frontend, backend):
            socket.setsockopt(zmq.LINGER, 0)
            socket.setsockopt(zmq.MAXMSGSIZE, MAX_IMAGE_BYTES)
            socket.setsockopt(zmq.RCVHWM, 8)
            socket.setsockopt(zmq.SNDHWM, 8)
        frontend.setsockopt(zmq.ROUTER_MANDATORY, 1)
        frontend.bind(endpoint)
        endpoint = frontend.getsockopt_string(zmq.LAST_ENDPOINT)
        backend.bind("tcp://127.0.0.1:*")
        backend_endpoint = backend.getsockopt_string(zmq.LAST_ENDPOINT)
        for index in range(workers):
            identity = f"worker-{index + 1}".encode()
            process = spawn.Process(
                target=_worker, name=identity.decode(), daemon=True,
                args=(backend_endpoint, identity, lang, device, cpu_threads,
                      worker_stop, engine_factory))
            process.start()
            processes[identity] = process
            devices[identity] = "gpu" if device and device.startswith("gpu") else "cpu"
        if gpu_mode != "off" and (gpu_python or gpu_factory):
            gpu_state = "starting"
            devices[gpu_id] = "gpu"
            if gpu_factory is not None:  # Injectable spawn path for routing tests.
                process = spawn.Process(target=_worker, name=gpu_id.decode(), daemon=True,
                    args=(backend_endpoint, gpu_id, lang, "gpu:0", cpu_threads,
                          worker_stop, gpu_factory))
                process.start()
                processes[gpu_id] = process
            else:
                try:
                    gpu_process = subprocess.Popen([
                        gpu_python, "-u", "-m", "services.paddleocr_service.gpu_worker",
                        "--backend", backend_endpoint, "--identity", gpu_id.decode(),
                        "--cpu-threads", str(cpu_threads)],
                        cwd=Path(__file__).resolve().parents[2])
                except OSError as failure:
                    gpu_state = "unavailable"
                    if gpu_mode == "required":
                        raise RuntimeError("Cannot start required GPU runtime") from failure
                    logging.error("Cannot start optional GPU runtime: %s", failure)
        elif gpu_mode != "off":
            gpu_state = "unavailable"

        def lose_gpu(reason):
            nonlocal gpu_state
            gpu_state = "unavailable"
            logging.error("GPU worker unavailable: %s; CPU workers remain available", reason)
            initialized.discard(gpu_id)
            while gpu_id in idle:
                idle.remove(gpu_id)
            if gpu_id in inflight:
                _send_reply(frontend, inflight.pop(gpu_id),
                            b"ERROR: GPU worker stopped during inference; request was not replayed")
            while pending["gpu"]:
                request = pending["gpu"].popleft()
                _send_reply(frontend, request[:2], b"ERROR: GPU worker unavailable")
            if gpu_mode == "required":
                raise RuntimeError("Required GPU worker unavailable: " + reason)

        poller = zmq.Poller()
        poller.register(backend, zmq.POLLIN)
        accepting = False
        announced = False
        deadline = time.monotonic() + startup_timeout
        while not stop.is_set():
            for identity, process in processes.items():
                if process.exitcode is not None:
                    if identity == gpu_id:
                        if gpu_state not in ("unavailable", "disabled"):
                            lose_gpu(f"exited ({process.exitcode})")
                    else:
                        raise RuntimeError(f"OCR {identity.decode()} exited ({process.exitcode})")
            if gpu_process is not None and gpu_process.poll() is not None and gpu_state != "unavailable":
                lose_gpu(f"exited ({gpu_process.returncode})")
            cpu_ready = all(identity in initialized for identity in processes if identity != gpu_id)
            if time.monotonic() >= deadline:
                if not cpu_ready:
                    raise TimeoutError("OCR workers did not initialize before the startup deadline")
                if gpu_state == "starting":
                    lose_gpu("startup deadline exceeded")
                    if gpu_process is not None:
                        gpu_process.terminate()
                    elif gpu_id in processes and processes[gpu_id].is_alive():
                        processes[gpu_id].terminate()
            if cpu_ready and not announced and (gpu_mode != "required" or gpu_state == "ready"):
                logging.info("PaddleOCR service listening at %s; %s base workers, GPU=%s; "
                             "CPU threads per worker=%s", endpoint, workers, gpu_state, cpu_threads)
                announced = True
                if ready is not None:
                    ready.put(endpoint)
            # A bounded pool queue allows a CPU request to pass a busy GPU and
            # vice versa. Each worker still executes exactly one request at a time.
            can_accept = announced and sum(map(len, pending.values())) < 8
            if can_accept and not accepting:
                poller.register(frontend, zmq.POLLIN)
            elif accepting and not can_accept:
                poller.unregister(frontend)
            accepting = can_accept
            events = dict(poller.poll(100))
            if backend in events:
                message = backend.recv_multipart()
                identity, frames = message[0], message[1:]
                if identity not in devices:
                    raise RuntimeError("Unknown OCR worker")
                if identity == gpu_id and gpu_state == "unavailable":
                    continue
                if frames == [b"READY"] and identity not in initialized:
                    initialized.add(identity)
                    if identity == gpu_id:
                        gpu_state = "ready"
                        logging.info("GPU worker ready; dispatch=gpu/auto is available")
                elif (len(frames) == 4 and frames[0] == b"RESULT"
                      and identity in inflight and frames[1:3] == inflight[identity]):
                    _send_reply(frontend, inflight.pop(identity), frames[3])
                else:
                    raise RuntimeError("Invalid OCR worker response")
                idle.append(identity)
            if frontend in events:
                request = frontend.recv_multipart()
                if len(request) < 3 or request[1] != b"":
                    logging.warning("Discarded request without a REQ routing envelope")
                    continue
                try:
                    header = json.loads(request[2])
                    if not isinstance(header, dict):
                        raise ValueError("Request header must be a JSON object")
                    operation = header.get("op")
                    if operation == "health":
                        _send_reply(frontend, request[:2], b'{"ok":true,"service":"paddleocr"}')
                        continue
                    if operation == "status":
                        status = {"ok": True, "service": "paddleocr", "gpu": gpu_state,
                                  "workers": [{"id": ident.decode(), "device": devices[ident],
                                               "busy": ident in inflight}
                                              for ident in sorted(initialized)],
                                  "queued": {key: len(value) for key, value in pending.items()}}
                        _send_reply(frontend, request[:2], json.dumps(status).encode())
                        continue
                    dispatch = header.get("dispatch", "cpu")
                    if dispatch not in ("cpu", "gpu", "auto"):
                        raise ValueError("dispatch must be cpu, gpu or auto")
                    selected = "gpu" if dispatch == "auto" and gpu_state == "ready" else dispatch
                    if selected == "auto":
                        selected = "cpu"
                    available = any(value == selected and (ident != gpu_id or gpu_state == "ready")
                                    for ident, value in devices.items())
                    if selected == "gpu" and not available and gpu_state != "starting":
                        raise ValueError("GPU worker unavailable; choose cpu or auto")
                    if selected == "cpu" and not available:
                        raise ValueError("CPU worker unavailable")
                    pending[selected].append(request)
                except (ValueError, TypeError, AttributeError) as failure:
                    _send_reply(frontend, request[:2], ("ERROR: " + str(failure)).encode())
            for identity in list(idle):
                queue = pending[devices[identity]]
                if queue:
                    request = queue.popleft()
                    idle.remove(identity)
                    inflight[identity] = request[:2]
                    logging.debug("Dispatch request to %s device=%s", identity.decode(), devices[identity])
                    backend.send_multipart([identity, *request])
    finally:
        for queue in pending.values():
            for request in queue:
                _send_reply(frontend, request[:2], b"ERROR: OCR service is stopping; retry after restart")
        for route in inflight.values():
            _send_reply(frontend, route, b"ERROR: OCR service is stopping; retry after restart")
        worker_stop.set()
        if gpu_process is not None and gpu_process.poll() is None:
            gpu_process.terminate()
        deadline = time.monotonic() + 5
        for process in processes.values():
            process.join(timeout=max(0, deadline - time.monotonic()))
        for process in processes.values():
            if process.is_alive():
                process.terminate()
        for process in processes.values():
            process.join(timeout=2)
            if process.is_alive():
                process.kill()
                process.join(timeout=2)
            process.close()
        if gpu_process is not None:
            try:
                gpu_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                gpu_process.kill()
                gpu_process.wait(timeout=2)
        frontend.close()
        backend.close()
        context.term()


def main() -> None:
    parser = argparse.ArgumentParser(description="Shared PaddleOCR ZeroMQ service")
    parser.add_argument("--bind", default=os.getenv("PADDLEOCR_BIND", "tcp://127.0.0.1:5555"))
    parser.add_argument("--lang", default=os.getenv("PADDLEOCR_LANG", "en"),
                        help='Compatibility option; request profile selects English v3 or Chinese')
    parser.add_argument("--device", default=os.getenv("PADDLEOCR_DEVICE", "cpu"))
    parser.add_argument("--workers", type=int, choices=range(1, MAX_WORKERS + 1),
                        default=os.getenv("PADDLEOCR_WORKERS", "2"))
    parser.add_argument("--cpu-threads", type=int,
                        default=os.getenv("PADDLEOCR_CPU_THREADS", "2"))
    default_gpu = Path(__file__).parent / '.venv-gpu' / 'bin' / 'python'
    parser.add_argument("--gpu-python", default=os.getenv("PADDLEOCR_GPU_PYTHON",
                        str(default_gpu) if default_gpu.exists() else None))
    parser.add_argument("--gpu-mode", choices=("off", "auto", "required"),
                        default=os.getenv("PADDLEOCR_GPU_MODE", "auto"))
    args = parser.parse_args()
    # argparse does not check choices for an environment-supplied default.
    if not 1 <= args.workers <= MAX_WORKERS or args.cpu_threads < 1:
        parser.error("workers must be 1 or 2, and cpu-threads must be positive")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    stop = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda _signum, _frame: stop.set())
    serve(args.bind, args.lang, args.device, args.workers, args.cpu_threads, stop=stop,
          gpu_python=args.gpu_python, gpu_mode=args.gpu_mode)


if __name__ == "__main__":
    main()
