"""Isolated CUDA worker; the broker and CPU workers keep their CPU runtime."""
from __future__ import annotations

import argparse
import json
import os
import signal
import threading


def gpu_info():
    import paddle
    if not paddle.is_compiled_with_cuda():
        raise RuntimeError('GPU runtime contains a CPU-only Paddle build')
    if paddle.device.cuda.device_count() < 1:
        raise RuntimeError('No CUDA GPU is visible to Paddle')
    paddle.set_device('gpu:0')
    # Real execution validates the driver/runtime, not merely GPU enumeration.
    actual = (paddle.to_tensor([1., 2.]) + 1).numpy().tolist()
    if actual != [2., 3.]:
        raise RuntimeError('CUDA execution self-check failed')
    return {'paddle': paddle.__version__, 'cuda': paddle.version.cuda(),
            'gpu': paddle.device.cuda.get_device_name(0),
            'capability': list(paddle.device.cuda.get_device_capability(0))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--probe', action='store_true')
    parser.add_argument('--backend')
    parser.add_argument('--identity', default='gpu-worker-1')
    parser.add_argument('--cpu-threads', type=int, default=2)
    args = parser.parse_args()
    if args.cpu_threads < 1:
        parser.error('cpu-threads must be positive')
    for key in ('OMP_NUM_THREADS', 'OPENBLAS_NUM_THREADS', 'MKL_NUM_THREADS', 'NUMEXPR_NUM_THREADS'):
        os.environ[key] = str(args.cpu_threads)
    info = gpu_info()
    print('[GPU runtime] ' + json.dumps(info), flush=True)
    if args.probe:
        return
    if not args.backend:
        parser.error('--backend is required for a worker')
    from .server import PaddleEngine, _worker
    stop = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.set())
    _worker(args.backend, args.identity.encode(), 'en', 'gpu:0', args.cpu_threads, stop, PaddleEngine)


if __name__ == '__main__':
    main()
