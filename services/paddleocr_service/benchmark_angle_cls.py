"""Compare alternating warmed requests with angle classification off/on.

Use --image with the same cropped region used by production for useful results.
No image is saved; by default a synthetic English serial-number label is used.
This measures end-to-end ZeroMQ latency including queueing on the selected service.
"""
import argparse
import json
import statistics
import time

import cv2
import numpy as np
import zmq


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--endpoint', default='tcp://127.0.0.1:5555')
    parser.add_argument('--image')
    parser.add_argument('--samples', type=int, default=30, help='Requests per setting')
    parser.add_argument('--warmup', type=int, default=6, help='Requests per setting, at least worker count')
    args = parser.parse_args()
    if args.samples < 1 or args.warmup < 1:
        parser.error('samples and warmup must be positive')
    if args.image:
        image = cv2.imread(args.image)
        if image is None:
            parser.error('Cannot read image')
    else:
        image = np.full((140, 600, 3), 255, np.uint8)
        cv2.putText(image, 'SERIAL 123456', (20, 90), cv2.FONT_HERSHEY_SIMPLEX,
                    1.7, (0, 0, 0), 3)
    ok, png = cv2.imencode('.png', image)
    if not ok:
        parser.error('Cannot encode image')
    durations = {False: [], True: []}
    first = {}
    replies = {False: set(), True: set()}
    with zmq.Context() as context, context.socket(zmq.REQ) as socket:
        socket.setsockopt(zmq.LINGER, 0)
        socket.setsockopt(zmq.RCVTIMEO, 120000)
        socket.setsockopt(zmq.SNDTIMEO, 5000)
        socket.connect(args.endpoint)
        for iteration in range(args.warmup + args.samples):
            # Alternate pair order to reduce drift bias.
            for enabled in ((False, True) if iteration % 2 == 0 else (True, False)):
                header = json.dumps({'op': 'recognize_json', 'encoding': 'png',
                                     'profile': 'legacy_en', 'use_angle_cls': enabled}).encode()
                start = time.perf_counter()
                socket.send_multipart([header, png.tobytes()])
                response = socket.recv()
                elapsed = (time.perf_counter() - start) * 1000
                if response.startswith(b'ERROR:'):
                    raise RuntimeError(response.decode())
                result = json.loads(response)
                first.setdefault(enabled, elapsed)
                if iteration >= args.warmup:
                    durations[enabled].append(elapsed)
                    replies[enabled].add((result['text'], len(result['lines'])))
    off, on = (statistics.median(durations[key]) for key in (False, True))
    print(json.dumps({
        'endpoint': args.endpoint, 'image': args.image or 'synthetic SERIAL 123456',
        'image_shape': list(image.shape), 'samples_per_setting': args.samples,
        'warmup_per_setting': args.warmup,
        'results': {str(key).lower(): {
            'first_request_ms': round(first[key], 3),
            'median_ms': round(statistics.median(values), 3),
            'p95_ms': round(float(np.percentile(values, 95)), 3),
            'recognized_text_and_line_count': sorted(replies[key]),
        } for key, values in durations.items()},
        'median_increase_ms': round(on - off, 3),
        'median_increase_percent': round(100 * (on / off - 1), 1),
    }, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
