#!/usr/bin/env python3
"""Test the compiled Haskell client; run with the OCR service's Python runtime."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import json
import os
from pathlib import Path
import queue
import re
import subprocess
import tempfile
import threading
import time

import cv2
import numpy as np
import zmq


@contextmanager
def peer(reply, delay=0, profile="legacy_en", use_angle_cls=False):
    ready = queue.Queue()
    errors = []
    done = threading.Event()

    def serve():
        try:
            with zmq.Context() as context, context.socket(zmq.REP) as socket:
                # Let queued replies reach the client before this one-shot
                # mock closes. LINGER=0 can discard even a successful send.
                socket.setsockopt(zmq.LINGER, 1000)
                socket.setsockopt(zmq.RCVTIMEO, 10000)
                port = socket.bind_to_random_port('tcp://127.0.0.1')
                ready.put(f'tcp://127.0.0.1:{port}')
                frames = socket.recv_multipart()
                assert len(frames) == 2
                expected = {'op': 'recognize', 'encoding': 'png', 'profile': profile}
                if profile == 'legacy_en':
                    expected['use_angle_cls'] = use_angle_cls
                assert json.loads(frames[0]) == expected, json.loads(frames[0])
                image = cv2.imdecode(np.frombuffer(frames[1], np.uint8), cv2.IMREAD_COLOR)
                assert image is not None and image.shape == (140, 600, 3)
                time.sleep(delay)
                socket.send(reply)
                # Keep the one-shot peer connected until the client has read
                # its reply; socket.send only queues it for transmission.
                done.wait(timeout=150)
        except Exception as error:
            errors.append(error)

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    try:
        yield ready.get(timeout=10)
    finally:
        done.set()
        thread.join(timeout=12)
        assert not thread.is_alive(), 'mock service did not finish'
        if errors:
            raise errors[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', default='bin/Camera')
    parser.add_argument('--profile', choices=('legacy_en', 'chinese'), default='legacy_en')
    parser.add_argument('--real-endpoint', help='also test two processes on the real service')
    args = parser.parse_args()
    binary = str(Path(args.binary).resolve())

    with tempfile.TemporaryDirectory(prefix='sequence-ocr-test-') as directory:
        paths = {}
        for text in ('123456', '654321'):
            image = np.full((140, 600, 3), 255, np.uint8)
            cv2.putText(image, 'SERIAL ' + text, (20, 90), cv2.FONT_HERSHEY_SIMPLEX,
                        1.7, (0, 0, 0), 3)
            paths[text] = str(Path(directory) / (text + '.png'))
            assert cv2.imwrite(paths[text], image)

        def recognize(endpoint, text='123456', timeout_ms=120000, angle_cls=False):
            environment = dict(os.environ, PADDLEOCR_ENDPOINT=endpoint,
                               PADDLEOCR_TIMEOUT_MS=str(timeout_ms),
                               PADDLEOCR_USE_ANGLE_CLS='1' if angle_cls else '0')
            return subprocess.run([binary, '--ocr-image', paths[text]], env=environment,
                                  capture_output=True, text=True, timeout=150)

        def timing(result, expected, angle_cls=False):
            matches = re.findall(r'^\[PaddleOCR\] status=(\w+) request_ms=(\d+\.\d+)(?: use_angle_cls=(?:true|false|invalid))?$',
                                 result.stderr, re.MULTILINE)
            assert len(matches) == 1 and matches[0][0] == expected, result
            if args.profile == 'legacy_en':
                assert 'use_angle_cls=' + str(angle_cls).lower() in result.stderr, result
            return float(matches[0][1])

        with peer('中文 SERIAL 123456'.encode('utf-8'), delay=0.12, profile=args.profile) as endpoint:
            result = recognize(endpoint)
            assert result.returncode == 0 and result.stdout.strip() == '中文 SERIAL 123456', result
            assert timing(result, 'OK') >= 100, result
        print('PASS: multipart PNG request, UTF-8 reply and elapsed timing including service delay')

        if args.profile == 'legacy_en':
            with peer(b'SERIAL 123456', profile=args.profile, use_angle_cls=True) as endpoint:
                result = recognize(endpoint, angle_cls=True)
                assert result.returncode == 0 and result.stdout.strip() == 'SERIAL 123456', result
                timing(result, 'OK', angle_cls=True)
            print('PASS: enabled angle-classification setting reaches the service as JSON true')

        with peer(b'', profile=args.profile) as endpoint:
            result = recognize(endpoint)
            assert result.returncode == 0 and result.stdout.strip() == '', result
            timing(result, 'EMPTY')
        print('PASS: empty OCR replies retain their result and report timing')

        with peer(b'ERROR: test inference failure', profile=args.profile) as endpoint:
            result = recognize(endpoint)
            assert result.returncode != 0 and 'test inference failure' in result.stderr, result
            timing(result, 'ERROR')
        print('PASS: service errors propagate as failures')

        with peer(b'late reply', delay=0.5, profile=args.profile) as endpoint:
            result = recognize(endpoint, timeout_ms=100)
            assert result.returncode != 0 and 'timed out waiting' in result.stderr, result
            assert timing(result, 'ERROR') >= 90, result
        print('PASS: configured reply timeout')

        invalid = Path(directory) / 'invalid.png'
        invalid.write_bytes(b'not an image')
        result = subprocess.run([binary, '--ocr-image', str(invalid)],
                                capture_output=True, text=True, timeout=10)
        assert result.returncode != 0 and 'could not encode' in result.stderr, result
        timing(result, 'ERROR')
        print('PASS: invalid image fails without sending an OCR request')

        if args.real_endpoint:
            barrier = threading.Barrier(2)

            def simultaneous(text):
                barrier.wait(timeout=10)
                result = recognize(args.real_endpoint, text)
                assert result.returncode == 0 and text in result.stdout, result
                return text, result.stdout.strip()

            with ThreadPoolExecutor(max_workers=2) as pool:
                replies = dict(pool.map(simultaneous, paths))
            print('PASS: two simultaneous real Haskell clients:', json.dumps(replies))


if __name__ == '__main__':
    main()
