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
    def recognize(self, _image):
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

            def recognize(self, image):
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


if __name__ == "__main__":
    unittest.main()
