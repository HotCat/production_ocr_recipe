#!/usr/bin/env python3
"""Compiled preview-worker regression: no image dump, errors do not kill it."""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading

import cv2
import numpy as np
import zmq


@contextmanager
def peer(replies, delay=0):
    ready = queue.Queue()
    errors = []
    done = threading.Event()

    def serve():
        try:
            with zmq.Context() as context, context.socket(zmq.REP) as socket:
                socket.setsockopt(zmq.LINGER, 0)
                socket.setsockopt(zmq.RCVTIMEO, 12000)
                port = socket.bind_to_random_port('tcp://127.0.0.1')
                ready.put(f'tcp://127.0.0.1:{port}')
                for reply in replies:
                    frames = socket.recv_multipart()
                    assert json.loads(frames[0]) == {'op': 'recognize', 'encoding': 'png', 'profile': 'legacy_en'}
                    assert len(frames) == 2
                    image = cv2.imdecode(np.frombuffer(frames[1], np.uint8), cv2.IMREAD_COLOR)
                    assert image.shape == (140, 600, 3)
                    if delay:
                        import time
                        time.sleep(delay)
                    socket.send(reply)
                # Keep the last reply alive until the subprocess has read it.
                done.wait(timeout=15)
        except Exception as error:
            errors.append(error)
    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    try:
        yield ready.get(timeout=5)
    finally:
        done.set()
        thread.join(timeout=15)
        assert not thread.is_alive(), 'mock did not complete'
        if errors:
            raise errors[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--probe', required=True)
    parser.add_argument('--real-endpoint')
    args = parser.parse_args()
    probe = str(Path(args.probe).resolve())
    with tempfile.TemporaryDirectory(prefix='engraving-worker-') as directory:
        path = Path(directory) / 'label.png'
        image = np.full((140, 600, 3), 255, np.uint8)
        cv2.putText(image, 'SERIAL 123456', (20, 90), cv2.FONT_HERSHEY_SIMPLEX,
                    1.7, (0, 0, 0), 3)
        assert cv2.imwrite(str(path), image)

        def run(endpoint, count, timeout_ms=120000):
            env = dict(os.environ, PADDLEOCR_ENDPOINT=endpoint,
                       PADDLEOCR_TIMEOUT_MS=str(timeout_ms))
            result = subprocess.run([probe, str(path), str(count)], cwd=directory,
                                    env=env, capture_output=True, text=True, timeout=40)
            assert result.returncode == 0, result
            assert not (Path(directory) / '1').exists()
            assert not (Path(directory) / 'my.png').exists()
            return result.stdout.splitlines()

        with peer([b'ERROR: simulated inference failure', '中文 AB-123456'.encode(), b'',
                   b'\xff', b'SERIAL 654321']) as endpoint:
            lines = run(endpoint, 5)
            assert 'simulated inference failure' in lines[0], lines
            assert lines[1] == '中文AB123456', lines
            assert '未识别到文字' in lines[2], lines
            assert 'PaddleOCR识别失败' in lines[3], lines
            assert lines[4] == 'SERIAL654321', lines
        print('PASS: no dump directory; UTF-8, empty replies, service/encoding errors and subsequent recovery')

        with peer([b'late', b'SERIAL 123456'], delay=0.15) as endpoint:
            lines = run(endpoint, 2, timeout_ms=100)
            assert all('timed out waiting' in line for line in lines), lines
        print('PASS: timed-out requests are reported; worker continues and remains cancellable')

        if args.real_endpoint:
            lines = run(args.real_endpoint, 2)
            assert len(lines) == 2 and all('123456' in line for line in lines), lines
            print('PASS: repeated real PaddleOCR requests through the GUI preview worker:', lines)


if __name__ == '__main__':
    main()
