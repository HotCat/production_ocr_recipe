from __future__ import annotations

import argparse
import json
import logging
import multiprocessing
import os
import signal
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
        logging.info('OCR profiles ready: legacy_en=PP-OCRv3 English, use_angle_cls=false, '
                     'MKL-DNN enabled on CPU; chinese=multilingual preset text')

    def recognize(self, image: np.ndarray, profile: str = 'legacy_en') -> dict[str, Any]:
        if profile == 'legacy_en':
            return self.legacy.recognize(image)
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
        if len(frames) != 2:
            raise ValueError("recognize expects a header and one image frame")
        encoded = frames[1]
        if not encoded or len(encoded) > MAX_IMAGE_BYTES:
            raise ValueError("image frame is empty or exceeds the size limit")
        image = cv2.imdecode(np.frombuffer(encoded, dtype=np.uint8), cv2.IMREAD_COLOR)
        if image is None:
            raise ValueError("image frame is not a supported encoded image")
        result = engine.recognize(image, profile=profile)
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
                    profile = json.loads(request[2]).get('profile', 'legacy_en')
                except (ValueError, AttributeError, IndexError):
                    profile = 'invalid'
                logging.info("OCR %s profile=%s completed in %.3fs", identity.decode(),
                             profile, time.monotonic() - started)
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
          engine_factory: Any = PaddleEngine, startup_timeout: float = 300) -> None:
    """Route REQ clients to at most two independent, serial model processes.

    Only read another client request when a worker is idle. Excess work stays
    in ZeroMQ's bounded queues rather than an unbounded Python task queue.
    A failed worker fails the pool so the supervisor can restart it cleanly.
    The optional stop/ready/factory arguments support hardware-free tests.
    """
    if not 1 <= workers <= MAX_WORKERS:
        raise ValueError(f"workers must be between 1 and {MAX_WORKERS}")
    if cpu_threads < 1:
        raise ValueError("cpu_threads must be positive")
    spawn = multiprocessing.get_context("spawn")
    worker_stop = spawn.Event()
    stop = stop if stop is not None else threading.Event()
    context = zmq.Context()
    processes = {}
    idle: deque[bytes] = deque()
    initialized = set()
    inflight: dict[bytes, list[bytes]] = {}
    frontend = context.socket(zmq.ROUTER)
    backend = context.socket(zmq.ROUTER)
    try:
        for socket in (frontend, backend):
            socket.setsockopt(zmq.LINGER, 0)
            socket.setsockopt(zmq.MAXMSGSIZE, MAX_IMAGE_BYTES)
            socket.setsockopt(zmq.RCVHWM, 8)
            socket.setsockopt(zmq.SNDHWM, 8)
        frontend.setsockopt(zmq.ROUTER_MANDATORY, 1)
        # Reserve the public endpoint before loading any model instances.
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

        poller = zmq.Poller()
        poller.register(backend, zmq.POLLIN)
        accepting = False
        announced = False
        deadline = time.monotonic() + startup_timeout
        while not stop.is_set():
            for identity, process in processes.items():
                if process.exitcode is not None:
                    raise RuntimeError(f"OCR {identity.decode()} exited ({process.exitcode})")
            all_ready = len(initialized) == workers
            if not all_ready and time.monotonic() >= deadline:
                raise TimeoutError("OCR workers did not initialize before the startup deadline")
            if all_ready and not announced:
                logging.info("PaddleOCR service listening at %s; %s model workers, "
                             "CPU threads per worker=%s", endpoint, workers, cpu_threads)
                announced = True
                if ready is not None:
                    ready.put(endpoint)
            can_accept = all_ready and bool(idle)
            if can_accept and not accepting:
                poller.register(frontend, zmq.POLLIN)
            elif accepting and not can_accept:
                poller.unregister(frontend)
            accepting = can_accept
            events = dict(poller.poll(100))
            if backend in events:
                message = backend.recv_multipart()
                identity, frames = message[0], message[1:]
                if identity not in processes:
                    raise RuntimeError("Unknown OCR worker")
                if frames == [b"READY"] and identity not in initialized:
                    initialized.add(identity)
                elif (len(frames) == 4 and frames[0] == b"RESULT"
                      and identity in inflight and frames[1:3] == inflight[identity]):
                    _send_reply(frontend, inflight.pop(identity), frames[3])
                else:
                    raise RuntimeError("Invalid OCR worker response")
                idle.append(identity)
            if frontend in events:
                request = frontend.recv_multipart()
                # Existing REQ clients supply [routing-id, empty, header, image].
                if len(request) < 3 or request[1] != b"":
                    logging.warning("Discarded request without a REQ routing envelope")
                    continue
                identity = idle.popleft()
                inflight[identity] = request[:2]
                backend.send_multipart([identity, *request])
    finally:
        for route in inflight.values():
            _send_reply(frontend, route, b"ERROR: OCR service is stopping; retry after restart")
        worker_stop.set()
        # Use one shared grace period, including when a worker is in inference.
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
    args = parser.parse_args()
    # argparse does not check choices for an environment-supplied default.
    if not 1 <= args.workers <= MAX_WORKERS or args.cpu_threads < 1:
        parser.error("workers must be 1 or 2, and cpu-threads must be positive")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    stop = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda _signum, _frame: stop.set())
    serve(args.bind, args.lang, args.device, args.workers, args.cpu_threads, stop=stop)


if __name__ == "__main__":
    main()
