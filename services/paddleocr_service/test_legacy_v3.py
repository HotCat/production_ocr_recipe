import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import cv2
import numpy as np

from .import_legacy_models import import_models
from .legacy_v3 import (LegacyV3Engine, classification_tensor, create_predictor,
                        decode_ctc, detector_tensor, orient_text, recognition_tensor)


class LegacyTests(unittest.TestCase):
    def test_classifier_normalization_zero_padding_and_width_limit(self):
        tensor = classification_tensor([np.full((20, 40, 3), 255, np.uint8),
                                        np.zeros((10, 100, 3), np.uint8)])
        self.assertEqual(tensor.shape, (2, 3, 48, 192))
        np.testing.assert_allclose(tensor[0, :, :, :96], 1)
        np.testing.assert_allclose(tensor[0, :, :, 96:], 0)
        np.testing.assert_allclose(tensor[1], -1)

    def test_classifier_rotates_only_confident_180_and_preserves_order_across_batches(self):
        # Distinct aspect ratios force width sorting, and seven regions require
        # two batches. Pixels distinguish rotated and untouched crops.
        images = [np.arange(12 * width * 3, dtype=np.uint8).reshape(12, width, 3)
                  for width in (70, 10, 60, 20, 50, 30, 40)]
        predictions = [np.array([[.01, .99], [.95, .05], [.2, .8],
                                 [.01, .99], [.95, .05], [.95, .05]]),
                       np.array([[.01, .99]])]
        with patch('services.paddleocr_service.legacy_v3.run_predictor', side_effect=predictions) as run:
            actual = orient_text(images, object())
        self.assertEqual(run.call_count, 2)
        for index, image in enumerate(images):
            expected = cv2.rotate(image, cv2.ROTATE_180) if index in (1, 6, 0) else image
            np.testing.assert_array_equal(actual[index], expected)

    def test_disabled_requests_skip_classifier_and_true_loads_once_per_worker(self):
        engine = LegacyV3Engine.__new__(LegacyV3Engine)
        engine.detector, engine.recognizer = object(), object()
        engine.postprocess = Mock(return_value=([[]], None))
        engine.classifier = None
        engine.device, engine.cpu_threads = 'cpu', 2
        image = np.zeros((32, 32, 3), np.uint8)
        with tempfile.TemporaryDirectory() as temporary:
            engine.classifier_directory = Path(temporary)
            with patch('services.paddleocr_service.legacy_v3.create_predictor') as create, \
                 patch('services.paddleocr_service.legacy_v3.run_predictor'), \
                 patch('services.paddleocr_service.legacy_v3.orient_text') as orient:
                self.assertEqual(engine.recognize(image, False)['text'], '')
                create.assert_not_called()
                with self.assertRaisesRegex(FileNotFoundError, 'prepare_angle_classifier'):
                    engine.recognize(image, True)
                for name in ('inference.pdmodel', 'inference.pdiparams'):
                    (engine.classifier_directory / name).touch()
                engine.recognize(image, True)
                engine.recognize(image, True)
                engine.recognize(image, False)
                create.assert_called_once_with(engine.classifier_directory, 'cpu', 2)
                orient.assert_not_called()  # No text regions, no classification inference.

    def test_ctc_repeats_blank_spaces_case_and_dictionary_mismatch(self):
        characters = ['#', 'A', 'a', '1', ' ']
        indices = [0, 1, 1, 0, 1, 4, 2, 3, 3, 0]
        predictions = np.eye(len(characters), dtype=np.float32)[indices][None]
        self.assertEqual(decode_ctc(predictions, characters), [('AA a1', 1.0)])
        self.assertEqual(decode_ctc(np.eye(5)[[0, 0]][None], characters), [('', 0.0)])
        with self.assertRaisesRegex(ValueError, 'dictionary'):
            decode_ctc(predictions, characters[:-1])

    def test_original_bgr_detector_normalization_max_side_and_rounding(self):
        image = np.zeros((1000, 2000, 3), np.uint8)
        image[:, :, 0] = 255
        tensor, shapes = detector_tensor(image)
        self.assertEqual(tensor.shape, (1, 3, 480, 960))
        np.testing.assert_allclose(shapes, [[1000, 2000, .48, .48]])
        np.testing.assert_allclose(tensor[0, :, 0, 0], [(1 - .485) / .229, -.456 / .224, -.406 / .225], rtol=1e-6)
        self.assertEqual(detector_tensor(np.zeros((48, 48, 3), np.uint8))[0].shape, (1, 3, 64, 64))

    def test_recognition_height_and_original_127_padding(self):
        tensor = recognition_tensor([np.full((20, 40, 3), 255, np.uint8)])
        self.assertEqual(tensor.shape, (1, 3, 48, 320))
        np.testing.assert_allclose(tensor[0, :, :, :96], 1)
        np.testing.assert_allclose(tensor[0, :, :, 96:], (127 / 255 - .5) / .5, atol=1e-7)

    def test_legacy_predictor_uses_mkldnn_and_local_ir_settings(self):
        from paddle import inference

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ('inference.pdmodel', 'inference.pdiparams'):
                (root / name).touch()
            config = Mock()
            with patch.object(inference, 'Config', return_value=config), patch.object(inference, 'create_predictor'):
                create_predictor(root, 'cpu', 2)
            config.enable_new_ir.assert_called_once_with(False)
            config.enable_mkldnn.assert_called_once_with()
            config.set_cpu_math_library_num_threads.assert_called_once_with(2)
            config.enable_use_gpu.assert_not_called()

    def test_import_is_verified_repeatable_and_never_overwrites_other_weights(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / 'old', root / 'new'
            for model in ('ch_PP-OCRv3_det_infer', 'en_PP-OCRv3_rec_infer'):
                (source / model).mkdir(parents=True)
                for name in ('inference.pdmodel', 'inference.pdiparams'):
                    (source / model / name).write_bytes((model + name).encode())
            dictionary = root / 'dictionary.txt'
            dictionary.write_text('A\na\n1\n')
            manifest = import_models(source, dictionary, destination)
            self.assertEqual(len(manifest), 5)
            self.assertEqual(import_models(source, dictionary, destination), manifest)
            self.assertFalse(json.loads((destination / 'manifest.json').read_text())['use_angle_cls'])
            dictionary.write_text('DIFFERENT')
            with self.assertRaisesRegex(ValueError, 'overwrite'):
                import_models(source, dictionary, destination)
            self.assertEqual((destination / 'en_dict.txt').read_text(), 'A\na\n1\n')


if __name__ == '__main__':
    unittest.main()
