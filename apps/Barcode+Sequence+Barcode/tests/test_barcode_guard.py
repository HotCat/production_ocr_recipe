#!/usr/bin/env python3
"""Exercise the compiled application without touching a camera or PLC."""
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

from generate_barcode_guard_labels import generate


@contextmanager
def service(reply):
    ready = queue.Queue()
    errors = []
    client_finished = threading.Event()

    def run():
        try:
            with zmq.Context() as context, context.socket(zmq.REP) as socket:
                socket.setsockopt(zmq.LINGER, 1000)
                socket.setsockopt(zmq.RCVTIMEO, 10000)
                port = socket.bind_to_random_port('tcp://127.0.0.1')
                ready.put(f'tcp://127.0.0.1:{port}')
                frames = socket.recv_multipart()
                assert len(frames) == 2
                assert json.loads(frames[0]) == {'op': 'recognize', 'encoding': 'png', 'profile': 'legacy_en', 'use_angle_cls': False}
                assert cv2.imdecode(np.frombuffer(frames[1], np.uint8), cv2.IMREAD_COLOR) is not None
                socket.send_string(reply)
                # send() queues the reply; keep the socket alive until the client consumes it.
                client_finished.wait(timeout=10)
        except Exception as error:
            errors.append(error)

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    try:
        yield ready.get(timeout=10)
    finally:
        client_finished.set()
        thread.join(timeout=12)
        assert not thread.is_alive(), 'service did not receive the label'
        if errors:
            raise errors[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', default='bin/Camera')
    parser.add_argument('--real-endpoint')
    args = parser.parse_args()
    binary = str(Path(args.binary).resolve())
    with tempfile.TemporaryDirectory(prefix='barcode-guard-') as directory:
        generate(directory)

        def inspect(name, endpoint, enabled=True):
            command = [binary, '--barcode-image', str(Path(directory) / (name + '.png'))]
            if enabled:
                command.append('--guard')
            return subprocess.run(command, text=True, capture_output=True, timeout=150,
                                  env=dict(os.environ, PADDLEOCR_ENDPOINT=endpoint, PADDLEOCR_USE_ANGLE_CLS='0'))

        # No listener exists here: guard-off, no-code and ambiguous-code cases
        # must return promptly without any OCR dependency.
        for name, enabled, expected in [('mismatch', False, True),
                                        ('no-barcode', True, False),
                                        ('multiple', True, False)]:
            result = inspect(name, 'tcp://127.0.0.1:1', enabled)
            assert (result.returncode == 0) == expected, result
        print('PASS: barcode-only mode, no barcode, and multiple barcodes')

        for reply, expected, marker in [('123456', True, 'MATCH'),
                                         ('Vendor X123456Y Lot 42', True, 'MATCH'),
                                         ('Vendor 12345 Lot 42', False, 'MISMATCH'),
                                         ('654321', False, 'MISMATCH'),
                                         ('', False, 'NO TEXT'),
                                         ('ERROR: model unavailable', False, 'OCR ERROR')]:
            with service(reply) as endpoint:
                result = inspect('match', endpoint)
                assert (result.returncode == 0) == expected, result
                assert marker in result.stdout, result
        print('PASS: real multipart transport, matching, mismatch, missing text, service error')

        if args.real_endpoint:
            for name, expected, marker in [('match', True, 'MATCH'),
                                            ('mismatch', False, 'MISMATCH'),
                                            ('no-text', False, 'NO TEXT')]:
                result = inspect(name, args.real_endpoint)
                assert (result.returncode == 0) == expected, result
                assert marker in result.stdout, result
                print(result.stdout.strip())
            print('PASS: actual ZBar and shared PaddleOCR reject vendor misprint and missing print')


if __name__ == '__main__':
    main()
