"""Compare CPU/GPU end-to-end OCR latency on the same image, without camera/PLC.

Use a cropped production region with --image for meaningful line measurements.
No inference failure is retried on another device.
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
    parser.add_argument('--image', required=True)
    parser.add_argument('--profile', choices=('legacy_en', 'chinese'), default='chinese')
    parser.add_argument('--use-angle-cls', action='store_true')
    parser.add_argument('--samples', type=int, default=20)
    parser.add_argument('--warmup', type=int, default=6)
    args = parser.parse_args()
    if args.samples < 1 or args.warmup < 2:
        parser.error('samples must be positive; warmup must be at least two (CPU pool size)')
    if args.profile == 'chinese' and args.use_angle_cls:
        parser.error('angle classification is only supported by legacy_en')
    image = cv2.imread(args.image)
    if image is None:
        parser.error('Cannot read image')
    ok, png = cv2.imencode('.png', image)
    if not ok:
        parser.error('Cannot encode image')
    encoded = png.tobytes()
    durations = {'cpu': [], 'gpu': []}
    first, replies = {}, {'cpu': set(), 'gpu': set()}
    with zmq.Context() as context, context.socket(zmq.REQ) as socket:
        socket.setsockopt(zmq.LINGER, 0)
        socket.setsockopt(zmq.RCVTIMEO, 120000)
        socket.setsockopt(zmq.SNDTIMEO, 5000)
        socket.connect(args.endpoint)
        for iteration in range(args.warmup + args.samples):
            for dispatch in (('cpu', 'gpu') if iteration % 2 == 0 else ('gpu', 'cpu')):
                header = json.dumps(dict(op='recognize_json', profile=args.profile,
                                         dispatch=dispatch, use_angle_cls=args.use_angle_cls)).encode()
                start = time.perf_counter()
                socket.send_multipart([header, encoded])
                response = socket.recv()
                elapsed = (time.perf_counter() - start) * 1000
                if response.startswith(b'ERROR:'):
                    raise RuntimeError(response.decode())
                result = json.loads(response)
                first.setdefault(dispatch, elapsed)
                if iteration >= args.warmup:
                    durations[dispatch].append(elapsed)
                    replies[dispatch].add(result['text'])
    print(json.dumps(dict(endpoint=args.endpoint, image=args.image,
        image_shape=list(image.shape), profile=args.profile, use_angle_cls=args.use_angle_cls,
        warmup_per_device=args.warmup, samples_per_device=args.samples,
        results={key: dict(first_request_ms=round(first[key], 3),
            median_ms=round(statistics.median(values), 3),
            p95_ms=round(float(np.percentile(values, 95)), 3), texts=sorted(replies[key]))
            for key, values in durations.items()}), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
