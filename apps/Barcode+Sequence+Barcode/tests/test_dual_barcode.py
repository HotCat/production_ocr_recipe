#!/usr/bin/env python3
"""Check the compiled dual-label CLI without opening hardware or GUI."""
import argparse
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
import zmq
from generate_barcode_guard_labels import generate, label

@contextmanager
def service(replies, delay=0):
    ready = queue.Queue()
    errors = []
    client_finished = threading.Event()
    def run():
        try:
            with zmq.Context() as context, context.socket(zmq.REP) as socket:
                socket.setsockopt(zmq.LINGER, 1000)
                socket.setsockopt(zmq.RCVTIMEO, 10000)
                ready.put(f"tcp://127.0.0.1:{socket.bind_to_random_port('tcp://127.0.0.1')}")
                for reply in replies:
                    frames = socket.recv_multipart()
                    assert len(frames) == 2
                    assert json.loads(frames[0]) == {'op':'recognize','encoding':'png','profile':'legacy_en','use_angle_cls':False}
                    time.sleep(delay)
                    socket.send_string(reply)
                # Keep the final queued reply alive until the client has consumed it.
                client_finished.wait(timeout=10)
        except Exception as error:
            errors.append(error)
    thread = threading.Thread(target=run,daemon=True)
    thread.start()
    try:
        yield ready.get(timeout=10)
    finally:
        client_finished.set()
        thread.join(timeout=12)
        assert not thread.is_alive(), 'mock service did not finish'
        if errors: raise errors[0]

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',default='bin/Camera')
    parser.add_argument('--real-endpoint')
    args=parser.parse_args()
    binary=str(Path(args.binary).resolve())
    with tempfile.TemporaryDirectory(prefix='dual-barcode-') as directory:
        root=generate(directory)
        for name,decoded,printed in [('other','654321','654321'),
                                    ('sixteen','1234567890123456','1234567890123456'),
                                    ('prefixed','991234567890123456','991234567890123456')]:
            assert cv2.imwrite(str(root/(name+'.png')),label(decoded,printed))
        def inspect(endpoint, product='match', packaging='match', flags=(), timeout_ms='120000'):
            return subprocess.run([binary,'--barcode-pair',str(root/(product+'.png')),str(root/(packaging+'.png')),*flags],
                env=dict(os.environ,PADDLEOCR_ENDPOINT=endpoint,PADDLEOCR_TIMEOUT_MS=timeout_ms,PADDLEOCR_USE_ANGLE_CLS='0'),
                text=True,capture_output=True,timeout=150)
        def check(result, passed, marker):
            assert (result.returncode==0)==passed and marker in result.stdout, result
        for replies,passed,marker in [(['Vendor X123456Y Lot 42','123 456'],True,'PAIR OK'),
                                      (['654321','123456'],False,'产品条码'),
                                      (['123456','654321'],False,'包装条码'),
                                      (['123456',''],False,'NO TEXT'),
                                      (['ERROR: model unavailable','123456'],False,'OCR ERROR'),
                                      (['123456','ERROR: model unavailable'],False,'OCR ERROR')]:
            with service(replies) as endpoint: check(inspect(endpoint),passed,marker)
        print('PASS: independent product/packaging guards; substring, missing text and OCR failure')
        with service(['123456']) as endpoint:
            check(inspect(endpoint,product='mismatch',flags=['--no-product-guard']),True,'PAIR OK')
        with service(['123456']) as endpoint:
            check(inspect(endpoint,packaging='mismatch',flags=['--no-packaging-guard']),True,'PAIR OK')
        check(inspect('tcp://127.0.0.1:1',product='mismatch',packaging='mismatch',
              flags=['--no-product-guard','--no-packaging-guard']),True,'PAIR OK')
        with service(['123456','654321']) as endpoint:
            check(inspect(endpoint,packaging='other'),False,'内容不完全一致')
        with service(['1234567890123456','991234567890123456']) as endpoint:
            check(inspect(endpoint,product='sixteen',packaging='prefixed'),False,'内容不完全一致')
        for product,packaging,replies in [('no-barcode','match',['123456']),('match','multiple',['123456'])]:
            with service(replies) as endpoint: check(inspect(endpoint,product,packaging),False,'NO UNIQUE BARCODE')
        with service(['123456','123456'],delay=0.3) as endpoint:
            check(inspect(endpoint),True,'PAIR OK')
        with service(['late','late'],delay=0.2) as endpoint:
            check(inspect(endpoint,timeout_ms='50'),False,'OCR ERROR')
        print('PASS: independent disabling, exact full-code comparison, missing/ambiguous codes, slow inference and timeout')
        if args.real_endpoint:
            for product,packaging,passed,marker in [('match','match',True,'PAIR OK'),
              ('mismatch','match',False,'产品条码'),('match','mismatch',False,'包装条码'),
              ('match','no-text',False,'NO TEXT'),('no-text','match',False,'NO TEXT'),
              ('match','other',False,'内容不完全一致')]:
                check(inspect(args.real_endpoint,product,packaging),passed,marker)
            print('PASS: actual ZBar/PaddleOCR accepts matching pair and rejects misprints on either label, missing print and different barcodes')

if __name__=='__main__': main()
