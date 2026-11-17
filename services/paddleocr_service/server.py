from __future__ import annotations

import argparse
import json
import logging
import os
import threading
from pathlib import Path
from typing import Any

import cv2
import numpy as np
import zmq


MAX_IMAGE_BYTES = 64 * 1024 * 1024


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
    def __init__(self, lang: str, device: str | None = None) -> None:
        if not device or device.lower().startswith("cpu"):
            os.environ.setdefault("PADDLE_PDX_ENABLE_MKLDNN_BYDEFAULT", "False")
        from paddleocr import PaddleOCR

        options: dict[str, Any] = {"lang": lang}
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
        self.ocr = PaddleOCR(**options)

    def recognize(self, image: np.ndarray) -> dict[str, Any]:
        return normalize_results(self.ocr.predict(image))


def handle_request(frames: list[bytes], engine: Any) -> bytes:
    try:
        if not frames:
            raise ValueError("missing request header")
        header = json.loads(frames[0].decode("utf-8"))
        operation = header.get("op")
        if operation == "health":
            return b'{"ok":true,"service":"paddleocr"}'
        if operation not in ("recognize", "recognize_json"):
            raise ValueError("unsupported operation")
        if len(frames) != 2:
            raise ValueError("recognize expects a header and one image frame")
        encoded = frames[1]
        if not encoded or len(encoded) > MAX_IMAGE_BYTES:
            raise ValueError("image frame is empty or exceeds the size limit")
        image = cv2.imdecode(np.frombuffer(encoded, dtype=np.uint8), cv2.IMREAD_COLOR)
        if image is None:
            raise ValueError("image frame is not a supported encoded image")
        result = engine.recognize(image)
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


def serve(endpoint: str, lang: str, device: str | None) -> None:
    engine = PaddleEngine(lang, device)
    context = zmq.Context.instance()
    with context.socket(zmq.REP) as socket:
        socket.setsockopt(zmq.LINGER, 0)
        socket.setsockopt(zmq.MAXMSGSIZE, MAX_IMAGE_BYTES)
        socket.setsockopt(zmq.RCVHWM, 8)
        socket.setsockopt(zmq.SNDHWM, 8)
        socket.bind(endpoint)
        logging.info("PaddleOCR service listening at %s; one model, serial inference", endpoint)
        serve_requests(socket, engine)


def main() -> None:
    parser = argparse.ArgumentParser(description="Shared PaddleOCR ZeroMQ service")
    parser.add_argument("--bind", default=os.getenv("PADDLEOCR_BIND", "tcp://127.0.0.1:5555"))
    parser.add_argument("--lang", default=os.getenv("PADDLEOCR_LANG", "en"))
    parser.add_argument("--device", default=os.getenv("PADDLEOCR_DEVICE"))
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    serve(args.bind, args.lang, args.device)


if __name__ == "__main__":
    main()
