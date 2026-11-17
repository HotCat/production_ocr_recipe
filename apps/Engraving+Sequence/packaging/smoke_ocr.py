#!/usr/bin/env python3
"""Exercise the installed OCR service over its real ZeroMQ protocol."""
import json
import multiprocessing
import os
import subprocess
import tempfile
import time

import cv2
import numpy as np
import zmq


def client(endpoint, expected, barrier, results):
    image = np.full((140, 600, 3), 255, np.uint8)
    cv2.putText(image, 'SERIAL ' + expected, (20, 90), cv2.FONT_HERSHEY_SIMPLEX,
                1.7, (0, 0, 0), 3)
    ok, png = cv2.imencode('.png', image)
    assert ok
    with zmq.Context() as context:
        with context.socket(zmq.REQ) as socket:
            socket.setsockopt(zmq.LINGER, 0)
            socket.setsockopt(zmq.RCVTIMEO, 120000)
            socket.connect(endpoint)
            barrier.wait(timeout=15)
            socket.send_multipart([b'{"op":"recognize"}', png.tobytes()])
            results.put((expected, socket.recv_string()))


def main():
    endpoint = 'tcp://127.0.0.1:15555'
    environment = dict(os.environ, PADDLEOCR_BIND=endpoint, PADDLEOCR_DEVICE='cpu')
    context = zmq.Context()
    with tempfile.TemporaryFile(mode='w+') as log:
        process = subprocess.Popen(['/opt/paddleocr-service/ocr/launch'], env=environment,
                                   stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 180
            while True:
                if process.poll() is not None:
                    raise RuntimeError('Packaged OCR service exited during startup')
                with context.socket(zmq.REQ) as socket:
                    socket.setsockopt(zmq.LINGER, 0)
                    socket.setsockopt(zmq.RCVTIMEO, 1000)
                    socket.connect(endpoint)
                    socket.send_json({'op': 'health'})
                    try:
                        health = socket.recv_json()
                        assert health['ok'], health
                        break
                    except zmq.Again:
                        if time.monotonic() > deadline:
                            raise TimeoutError('OCR model initialization exceeded 180 seconds')
            # Independent processes connect at the same instant to one REP/model.
            spawn = multiprocessing.get_context('spawn')
            barrier = spawn.Barrier(2)
            results = spawn.Queue()
            clients = [spawn.Process(target=client, args=(endpoint, text, barrier, results))
                       for text in ('123456', '654321')]
            try:
                for worker in clients:
                    worker.start()
                replies = dict(results.get(timeout=120) for _ in clients)
                for worker in clients:
                    worker.join(timeout=5)
                    assert worker.exitcode == 0, worker.exitcode
                for expected, reply in replies.items():
                    assert expected in reply, (expected, reply)
                print('Installed OCR service health:', json.dumps(health))
                print('Two concurrent process clients:', json.dumps(replies))
            finally:
                for worker in clients:
                    if worker.is_alive():
                        worker.terminate()
                    if worker.pid is not None:
                        worker.join(timeout=5)
        except Exception:
            log.seek(0)
            print(log.read())
            raise
        finally:
            process.terminate()
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            context.term()


if __name__ == '__main__':
    main()
