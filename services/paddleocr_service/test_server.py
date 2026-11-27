import json
import unittest

import numpy as np

from services.paddleocr_service.server import handle_request, normalize_results


class FakeResult:
    json = {
        "res": {
            "rec_texts": ["A123", "BC45"],
            "rec_scores": [0.99, 0.95],
            "dt_polys": [np.array([[0, 0], [5, 0], [5, 2], [0, 2]])],
        }
    }


class FakeEngine:
    def recognize(self, _image, profile="legacy_en", use_angle_cls=False):
        return normalize_results([FakeResult()])


class ServiceTests(unittest.TestCase):
    def test_normalizes_paddle_result(self):
        normalized = normalize_results([FakeResult()])
        self.assertEqual(normalized["text"], "A123BC45")
        self.assertEqual(normalized["lines"][0]["score"], 0.99)
        self.assertEqual(normalized["lines"][0]["box"][0], [0, 0])

    def test_health_request(self):
        response = handle_request([b'{"op":"health"}'], FakeEngine())
        self.assertEqual(json.loads(response), {"ok": True, "service": "paddleocr"})

    def test_recognize_json_request(self):
        import cv2

        image = np.zeros((8, 8, 3), dtype=np.uint8)
        ok, encoded = cv2.imencode(".png", image)
        self.assertTrue(ok)
        response = handle_request(
            [b'{"op":"recognize_json"}', encoded.tobytes()], FakeEngine()
        )
        self.assertEqual(json.loads(response)["text"], "A123BC45")

    def test_engine_passes_thread_and_device_settings(self):
        from types import SimpleNamespace
        from unittest.mock import Mock, patch
        from services.paddleocr_service.server import PaddleEngine
        constructor = Mock()
        with patch.dict('sys.modules', {'paddleocr': SimpleNamespace(PaddleOCR=constructor)}):
            with patch.dict('os.environ', {'PADDLEOCR_MODEL_ROOT': ''}):
                with patch('services.paddleocr_service.legacy_v3.LegacyV3Engine') as legacy:
                    engine = PaddleEngine('en', 'cpu', 2)
                    image = np.zeros((8, 8, 3), np.uint8)
                    engine.recognize(image, 'legacy_en')
                    legacy.return_value.recognize.assert_called_once_with(image, use_angle_cls=False)
                    constructor.return_value.predict.assert_not_called()
                    constructor.return_value.predict.return_value = [FakeResult()]
                    self.assertEqual(engine.recognize(image, 'chinese')['text'], 'A123BC45')
        constructor.assert_called_once_with(lang='ch', device='cpu', cpu_threads=2)

    def test_profiles_are_explicit_validated_and_legacy_is_default(self):
        import cv2

        class Engine:
            def recognize(self, image, profile='legacy_en', use_angle_cls=False):
                return {'text': profile, 'lines': []}

        _, png = cv2.imencode('.png', np.zeros((8, 8, 3), np.uint8))
        for profile in ('legacy_en', 'chinese'):
            header = json.dumps({'op': 'recognize', 'profile': profile}).encode()
            self.assertEqual(handle_request([header, png.tobytes()], Engine()), profile.encode())
        self.assertEqual(handle_request([b'{"op":"recognize"}', png.tobytes()], Engine()), b'legacy_en')
        reply = handle_request([b'{"op":"recognize","profile":"typo"}', png.tobytes()], Engine())
        self.assertIn(b'Unknown OCR profile', reply)

    def test_angle_flag_is_per_request_strict_and_does_not_change_chinese(self):
        import cv2
        from unittest.mock import Mock
        engine = Mock()
        engine.recognize.return_value = {'text': 'SERIAL123', 'lines': []}
        _, png = cv2.imencode('.png', np.zeros((8, 8, 3), np.uint8))
        def request(**settings):
            return handle_request([json.dumps({'op': 'recognize', **settings}).encode(),
                                   png.tobytes()], engine)
        for enabled in (True, False, True, False):
            self.assertEqual(request(use_angle_cls=enabled), b'SERIAL123')
            self.assertIs(engine.recognize.call_args.kwargs['use_angle_cls'], enabled)
        for invalid in ('true', 1, None, []):
            engine.reset_mock()
            self.assertIn(b'JSON boolean', request(use_angle_cls=invalid))
            engine.recognize.assert_not_called()
        self.assertIn(b'only supported', request(profile='chinese', use_angle_cls=True))
        self.assertEqual(request(profile='chinese'), b'SERIAL123')

# Each client process owns its socket. The production server loop is used unchanged.
def _concurrent_client(endpoint, marker, barrier, results):
    import cv2
    import zmq

    context = zmq.Context()
    try:
        with context.socket(zmq.REQ) as socket:
            socket.setsockopt(zmq.LINGER, 0)
            socket.setsockopt(zmq.RCVTIMEO, 10000)
            socket.connect(endpoint)
            ok, png = cv2.imencode('.png', np.full((8, 8, 3), marker, np.uint8))
            assert ok
            replies = []
            for _ in range(4):
                barrier.wait(timeout=10)
                socket.send_multipart([b'{"op":"recognize"}', png.tobytes()])
                replies.append(socket.recv_string())
            results.put((marker, replies))
    finally:
        context.term()


class ConcurrentServiceTests(unittest.TestCase):
    def test_two_processes_receive_their_own_replies_and_inference_is_serial(self):
        import multiprocessing
        import queue
        import threading
        import time
        import zmq
        from services.paddleocr_service.server import serve_requests

        class TrackingEngine:
            active = 0
            maximum = 0
            calls = 0
            threads = set()
            lock = threading.Lock()

            def recognize(self, image, profile="legacy_en", use_angle_cls=False):
                with self.lock:
                    self.active += 1
                    self.maximum = max(self.maximum, self.active)
                    self.calls += 1
                    self.threads.add(threading.get_ident())
                try:
                    time.sleep(0.03)  # Release the GIL so unintended parallel calls would overlap.
                    return {'text': str(int(image[0, 0, 0])), 'lines': []}
                finally:
                    with self.lock:
                        self.active -= 1

        engine = TrackingEngine()
        context = zmq.Context()
        ready = queue.Queue()
        stop = threading.Event()
        errors = []

        def server():
            try:
                with context.socket(zmq.REP) as socket:
                    socket.setsockopt(zmq.LINGER, 0)
                    port = socket.bind_to_random_port('tcp://127.0.0.1')
                    ready.put(f'tcp://127.0.0.1:{port}')
                    serve_requests(socket, engine, stop)
            except Exception as error:
                errors.append(error)

        worker = threading.Thread(target=server)
        worker.start()
        processes = []
        try:
            endpoint = ready.get(timeout=5)
            spawn = multiprocessing.get_context('spawn')
            barrier = spawn.Barrier(2)
            results = spawn.Queue()
            for marker in (31, 207):
                process = spawn.Process(target=_concurrent_client, args=(endpoint, marker, barrier, results))
                process.start()
                processes.append(process)
            responses = dict(results.get(timeout=15) for _ in processes)
            for process in processes:
                process.join(timeout=5)
                self.assertEqual(process.exitcode, 0)
            self.assertEqual(responses, {31: ['31'] * 4, 207: ['207'] * 4})
            self.assertEqual(engine.calls, 8)
            self.assertEqual(engine.maximum, 1)
            self.assertEqual(len(engine.threads), 1)
            # A malformed request must not prevent either client from using the service again.
            with context.socket(zmq.REQ) as socket:
                socket.setsockopt(zmq.LINGER, 0)
                socket.setsockopt(zmq.RCVTIMEO, 2000)
                socket.connect(endpoint)
                socket.send(b'not JSON')
                self.assertTrue(socket.recv().startswith(b'ERROR:'))
                socket.send_json({'op': 'health'})
                self.assertTrue(socket.recv_json()['ok'])
            self.assertFalse(errors)
        finally:
            for process in processes:
                if process.is_alive():
                    process.terminate()
                process.join(timeout=5)
            stop.set()
            worker.join(timeout=5)
            context.term()


# Picklable fake pipeline: these tests exercise the production spawn/broker path.
class PoolEngine:
    def __init__(self, state, lang, device, cpu_threads):
        import os
        self.state = state
        self.pid = os.getpid()
        state['events'].put(('ready', self.pid, lang, device, cpu_threads))
        if state.get('fail_init'):
            raise RuntimeError('test initialization failure')

    def recognize(self, image, profile="legacy_en", use_angle_cls=False):
        import os
        marker = int(image[0, 0, 0])
        with self.state['lock']:
            self.state['active'].value += 1
            self.state['maximum'].value = max(self.state['maximum'].value,
                                              self.state['active'].value)
        self.state['events'].put(('start', marker, self.pid, profile, use_angle_cls))
        try:
            if marker == 250:
                os._exit(23)
            if marker == 249:
                raise RuntimeError('test inference failure')
            gate = self.state.get('gates', {}).get(marker)
            if gate is not None and not gate.wait(10):
                raise TimeoutError('test gate was not released')
            return {'text': ('chinese:' if profile == 'chinese' else '') + str(marker), 'lines': []}
        finally:
            with self.state['lock']:
                self.state['active'].value -= 1


def pool_request(endpoint, marker=None, operation='recognize', profile='legacy_en', use_angle_cls=False,
                 dispatch='cpu'):
    import cv2
    import zmq
    context = zmq.Context()
    try:
        with context.socket(zmq.REQ) as socket:
            socket.setsockopt(zmq.LINGER, 0)
            socket.setsockopt(zmq.RCVTIMEO, 10000)
            socket.connect(endpoint)
            frames = [json.dumps({'op': operation, 'profile': profile,
                                  'use_angle_cls': use_angle_cls, 'dispatch': dispatch}).encode()]
            if marker is not None:
                ok, png = cv2.imencode('.png', np.full((8, 8, 3), marker, np.uint8))
                assert ok
                frames.append(png.tobytes())
            socket.send_multipart(frames)
            return socket.recv_string()
    finally:
        context.term()


class WorkerPoolTests(unittest.TestCase):
    def setUp(self):
        import multiprocessing
        import queue
        import threading
        self.spawn = multiprocessing.get_context('spawn')
        self.state = {'lock': self.spawn.Lock(), 'active': self.spawn.Value('i', 0),
                      'maximum': self.spawn.Value('i', 0), 'events': self.spawn.Queue()}
        self.ready = queue.Queue()
        self.stop = threading.Event()
        self.errors = []
        self.thread = None
        self.pids = []

    def start_pool(self, workers=2, **options):
        import functools
        import threading
        from services.paddleocr_service.server import serve

        def run():
            try:
                serve('tcp://127.0.0.1:*', 'en', 'cpu', workers, 2,
                      stop=self.stop, ready=self.ready,
                      engine_factory=functools.partial(PoolEngine, self.state), **options)
            except Exception as exc:
                self.errors.append(exc)
        self.thread = threading.Thread(target=run)
        self.thread.start()
        endpoint = self.ready.get(timeout=10)
        expected = workers + (1 if options.get('gpu_factory') else 0)
        for _ in range(expected):
            event = self.state['events'].get(timeout=5)
            self.assertEqual(event[0], 'ready')
            self.assertIn(event[2:], [('en', 'cpu', 2), ('en', 'gpu:0', 2)])
            if event[3] == 'gpu:0':
                self.gpu_pid = event[1]
            self.pids.append(event[1])
        self.assertEqual(len(set(self.pids)), expected)
        return endpoint

    def start_mixed_pool(self):
        import functools
        endpoint = self.start_pool(gpu_factory=functools.partial(PoolEngine, self.state))
        import time
        deadline = time.monotonic() + 5
        while json.loads(pool_request(endpoint, operation='status'))['gpu'] != 'ready':
            self.assertLess(time.monotonic(), deadline)
            time.sleep(.01)
        return endpoint

    def test_cpu_gpu_and_auto_routing_is_serial_per_worker_and_independent(self):
        import concurrent.futures
        import queue
        self.state['gates'] = {marker: self.spawn.Event() for marker in (31, 97)}
        endpoint = self.start_mixed_pool()
        with concurrent.futures.ThreadPoolExecutor(3) as clients:
            gpu = clients.submit(pool_request, endpoint, 31, dispatch='gpu')
            event = self.state['events'].get(timeout=5)
            self.assertEqual(event[2], self.gpu_pid)
            automatic = clients.submit(pool_request, endpoint, 97, dispatch='auto')
            # A busy ready GPU queues auto work; idle CPU workers do not steal it.
            with self.assertRaises(queue.Empty):
                self.state['events'].get(timeout=.15)
            self.assertEqual(pool_request(endpoint, 207, dispatch='cpu'), '207')
            event = self.state['events'].get(timeout=5)
            self.assertNotEqual(event[2], self.gpu_pid)
            self.state['gates'][31].set()
            self.assertEqual(gpu.result(timeout=5), '31')
            event = self.state['events'].get(timeout=5)
            self.assertEqual(event[1:3], (97, self.gpu_pid))
            self.state['gates'][97].set()
            self.assertEqual(automatic.result(timeout=5), '97')
        self.assertFalse(self.errors)

    def test_missing_gpu_is_explicit_and_auto_falls_back_to_cpu(self):
        endpoint = self.start_pool()
        self.assertIn('GPU worker unavailable', pool_request(endpoint, 31, dispatch='gpu'))
        self.assertEqual(pool_request(endpoint, 31, dispatch='auto'), '31')
        self.assertIn('dispatch must', pool_request(endpoint, 31, dispatch='cuda'))
        status = json.loads(pool_request(endpoint, operation='status'))
        self.assertEqual(status['gpu'], 'unavailable')
        self.assertEqual(len(status['workers']), 2)
        self.assertFalse(self.errors)

    def test_invalid_optional_gpu_interpreter_keeps_cpu_service_available(self):
        endpoint = self.start_pool(gpu_python='/nonexistent/production-ocr-gpu/python')
        self.assertEqual(pool_request(endpoint, 31, dispatch='auto'), '31')
        self.assertIn('GPU worker unavailable', pool_request(endpoint, 97, dispatch='gpu'))
        self.assertEqual(json.loads(pool_request(endpoint, operation='status'))['gpu'], 'unavailable')
        self.assertFalse(self.errors)

    def test_gpu_crash_does_not_replay_or_stop_cpu_workers(self):
        endpoint = self.start_mixed_pool()
        self.assertIn('request was not replayed', pool_request(endpoint, 250, dispatch='gpu'))
        self.assertEqual(pool_request(endpoint, 31, dispatch='auto'), '31')
        self.assertEqual(pool_request(endpoint, 97, dispatch='cpu'), '97')
        self.assertIn('GPU worker unavailable', pool_request(endpoint, 31, dispatch='gpu'))
        self.assertEqual(json.loads(pool_request(endpoint, operation='status'))['gpu'], 'unavailable')
        self.assertFalse(self.errors)

    def tearDown(self):
        import os
        self.stop.set()
        for gate in self.state.get('gates', {}).values():
            gate.set()
        if self.thread is not None:
            self.thread.join(timeout=12)
            self.assertFalse(self.thread.is_alive(), 'pool did not shut down')
        for pid in self.pids:
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
        self.state['events'].close()
        self.state['events'].join_thread()

    def test_three_clients_two_workers_out_of_order_and_queued_third(self):
        import concurrent.futures
        import queue
        self.state['gates'] = {marker: self.spawn.Event() for marker in (31, 97, 207)}
        endpoint = self.start_pool()
        with concurrent.futures.ThreadPoolExecutor(3) as clients:
            pending = {marker: clients.submit(pool_request, endpoint, marker, 'recognize',
                                              'chinese' if marker == 97 else 'legacy_en', marker == 31)
                       for marker in (31, 97, 207)}
            try:
                first = self.state['events'].get(timeout=5)
                second = self.state['events'].get(timeout=5)
                self.assertEqual(first[0], 'start')
                self.assertEqual(second[0], 'start')
                for event in (first, second):
                    self.assertIs(event[4], event[1] == 31)
                self.assertNotEqual(first[2], second[2])
                with self.assertRaises(queue.Empty):
                    self.state['events'].get(timeout=0.2)
                # Finish the second request first. The queued third request must
                # use its newly idle worker while the first remains in flight.
                self.state['gates'][second[1]].set()
                expected = lambda marker: ('chinese:' if marker == 97 else '') + str(marker)
                self.assertEqual(pending[second[1]].result(timeout=5), expected(second[1]))
                third = self.state['events'].get(timeout=5)
                self.assertEqual(third[0], 'start')
                self.assertIs(third[4], third[1] == 31)
                self.assertEqual(third[2], second[2])
                self.assertFalse(pending[first[1]].done())
                self.state['gates'][third[1]].set()
                self.assertEqual(pending[third[1]].result(timeout=5), expected(third[1]))
                self.state['gates'][first[1]].set()
                self.assertEqual(pending[first[1]].result(timeout=5), expected(first[1]))
            finally:
                for gate in self.state['gates'].values():
                    gate.set()
        self.assertEqual(self.state['maximum'].value, 2)
        self.assertFalse(self.errors)

    def test_single_worker_and_error_recovery(self):
        endpoint = self.start_pool(workers=1)
        self.assertIn('test inference failure', pool_request(endpoint, 249))
        self.assertTrue(pool_request(endpoint, operation='unsupported').startswith('ERROR:'))
        self.assertTrue(pool_request(endpoint, operation='recognize').startswith('ERROR:'))
        self.assertEqual(pool_request(endpoint, 31), '31')
        self.assertEqual(json.loads(pool_request(endpoint, 97, 'recognize_json')),
                         {'text': '97', 'lines': []})
        self.assertEqual(json.loads(pool_request(endpoint, operation='health')),
                         {'ok': True, 'service': 'paddleocr'})
        self.assertEqual(self.state['maximum'].value, 1)
        self.assertFalse(self.errors)

    def test_abandoned_client_does_not_block_others(self):
        import cv2
        import zmq
        self.state['gates'] = {31: self.spawn.Event()}
        endpoint = self.start_pool()
        with zmq.Context() as context:
            with context.socket(zmq.REQ) as client:
                client.setsockopt(zmq.LINGER, 0)
                client.connect(endpoint)
                _, png = cv2.imencode('.png', np.full((8, 8, 3), 31, np.uint8))
                client.send_multipart([b'{"op":"recognize"}', png.tobytes()])
                self.assertEqual(self.state['events'].get(timeout=5)[1], 31)
            self.assertEqual(pool_request(endpoint, 207), '207')
            self.state['gates'][31].set()
            self.assertTrue(json.loads(pool_request(endpoint, operation='health'))['ok'])
        self.assertFalse(self.errors)

    def test_worker_crash_fails_pool_and_cleans_children(self):
        endpoint = self.start_pool()
        self.assertTrue(pool_request(endpoint, 250).startswith('ERROR: OCR service is stopping'))
        self.thread.join(timeout=10)
        self.assertFalse(self.thread.is_alive())
        self.assertEqual(len(self.errors), 1)
        self.assertIn('exited (23)', str(self.errors[0]))

    def test_initialization_failure_cleans_children(self):
        import functools
        import threading
        from services.paddleocr_service.server import serve
        self.state['fail_init'] = True

        def run():
            try:
                serve('tcp://127.0.0.1:*', 'en', stop=self.stop,
                      engine_factory=functools.partial(PoolEngine, self.state))
            except Exception as exc:
                self.errors.append(exc)
        self.thread = threading.Thread(target=run)
        self.thread.start()
        for _ in range(2):
            self.pids.append(self.state['events'].get(timeout=10)[1])
        self.thread.join(timeout=10)
        self.assertFalse(self.thread.is_alive())
        self.assertEqual(len(self.errors), 1)
        self.assertIn('exited (1)', str(self.errors[0]))

    def test_invalid_limits_and_bind_conflict_do_not_start_workers(self):
        import zmq
        from services.paddleocr_service.server import serve
        for options in ({'workers': 0}, {'workers': 3}, {'cpu_threads': 0}):
            with self.assertRaises(ValueError):
                serve('tcp://127.0.0.1:*', 'en', **options)
        with zmq.Context() as context, context.socket(zmq.REP) as existing:
            existing.bind('tcp://127.0.0.1:*')
            with self.assertRaises(zmq.ZMQError):
                serve(existing.getsockopt_string(zmq.LAST_ENDPOINT), 'en')


if __name__ == "__main__":
    unittest.main()
