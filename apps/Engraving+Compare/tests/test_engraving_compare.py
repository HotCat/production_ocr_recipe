#!/usr/bin/env python3
"""Exercise the compiled multilingual preset comparator without production hardware."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont
import zmq


@contextmanager
def peer(reply, delay=0):
    ready = queue.Queue()
    errors = []
    client_finished = threading.Event()
    def serve():
        try:
            with zmq.Context() as context, context.socket(zmq.REP) as socket:
                socket.setsockopt(zmq.LINGER, 1000)
                socket.setsockopt(zmq.RCVTIMEO, 10000)
                ready.put(f'tcp://127.0.0.1:{socket.bind_to_random_port("tcp://127.0.0.1")}')
                frames = socket.recv_multipart()
                assert len(frames) == 2
                assert json.loads(frames[0]) == {'op': 'recognize', 'encoding': 'png', 'profile': 'chinese', 'dispatch': 'cpu'}
                assert cv2.imdecode(np.frombuffer(frames[1], np.uint8), cv2.IMREAD_COLOR) is not None
                time.sleep(delay)
                socket.send_string(reply)
                # Keep REP/context alive until the client has consumed the reply.
                # send() alone only queues it; immediate teardown can lose it.
                client_finished.wait(timeout=10)
        except Exception as error:
            errors.append(error)
    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    try:
        yield ready.get(timeout=10)
    finally:
        client_finished.set()
        thread.join(timeout=12)
        assert not thread.is_alive(), 'mock service did not finish'
        if errors:
            raise errors[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', default='bin/Camera')
    parser.add_argument('--real-endpoint')
    args = parser.parse_args()
    binary = str(Path(args.binary).resolve())
    expected = '客服电话：96008'
    with tempfile.TemporaryDirectory(prefix='engraving-compare-') as directory:
        root = Path(directory)
        font = ImageFont.truetype('font/msyhl.ttc', 50)
        texts = {'chinese': expected, 'mixed': expected + ' ABC-01',
                 'wrong': '客服电话：96009', 'extra': expected + '额外', 'empty': ''}
        for name, text in texts.items():
            image = Image.new('RGB', (1000, 150), 'white')
            ImageDraw.Draw(image).text((35, 36), text, font=font, fill='black')
            image.save(root / (name + '.png'))

        def compare(endpoint, preset=expected, image='chinese', timeout_ms=5000):
            return subprocess.run([binary, '--compare-image', str(root / (image + '.png')), preset],
                env=dict(os.environ, PADDLEOCR_ENDPOINT=endpoint, PADDLEOCR_TIMEOUT_MS=str(timeout_ms)),
                capture_output=True, text=True, timeout=150)

        def check(result, passed, marker):
            assert (result.returncode == 0) == passed, result
            assert marker in result.stdout, result
            assert 'modbus' not in result.stdout.lower(), 'hardware must not initialize for CLI tests'

        for reply, preset, passed in [
            (expected, expected, True),
            ('客 服 电话 : 96008\n', expected, True),
            (expected + ' ABC-01', expected + ' ABC-01', True),
            (expected + ' abc-01', expected + ' ABC-01', False),
            ('96008', expected, False),
            ('客服电活：96008', expected, False),
            ('客服电话：96009', expected, False),
            ('客服电话96008', expected, False),
            (expected + '额外', expected, True),
            ('前缀' + expected, expected, True),
            ('前缀 客服 电话:96008\n后缀', expected, True),
            (expected, '前缀' + expected, False),
            ('客服电话：额外96008', expected, False),
            ('', expected, False),
            ('ERROR: inference unavailable', expected, False),
        ]:
            with peer(reply) as endpoint:
                check(compare(endpoint, preset), passed, 'OK ' if passed else 'NG ')
        print('PASS: compiled UTF-8 comparator accepts preset substrings with surrounding text and rejects missing/wrong/interrupted presets')

        with peer(expected, delay=0.25) as endpoint:
            check(compare(endpoint, timeout_ms=50), False, 'timed out waiting')
        # An empty preset must not send an OCR request or accept an empty result.
        check(compare('tcp://127.0.0.1:1', preset=' \n'), False, '未设置预设文字')
        invalid = root / 'invalid.png'
        invalid.write_bytes(b'invalid image')
        result = subprocess.run([binary, '--compare-image', str(invalid), expected],
            capture_output=True, text=True, timeout=15)
        check(result, False, 'could not encode')
        print('PASS: timeout, OCR error, invalid image and empty preset fail closed without hardware initialization')

        if args.real_endpoint:
            for image, preset, passed in [
                ('chinese', expected, True),
                ('mixed', expected + ' ABC-01', True),
                ('mixed', expected, True),
                ('wrong', expected, False),
                ('extra', expected, True),
                ('empty', expected, False),
                ('mixed', expected + ' abc-01', False),
                ('chinese', expected, True),
            ]:
                check(compare(args.real_endpoint, preset, image, timeout_ms=120000), passed, 'OK ' if passed else 'NG ')
            print('PASS: real PaddleOCR accepts surrounding text and rejects wrong text, empty image and changed case; repeated preset needs no increment')

            def concurrent(image):
                preset = texts[image]
                result = compare(args.real_endpoint, preset, image, timeout_ms=120000)
                check(result, True, 'OK ')
                return result.stdout.strip()
            with ThreadPoolExecutor(max_workers=2) as pool:
                results = list(pool.map(concurrent, ['chinese', 'mixed']))
            assert expected in results[0] and 'ABC-01' in results[1], results
            print('PASS: two simultaneous compiled clients receive their own Chinese/mixed OCR replies')


if __name__ == '__main__':
    main()
