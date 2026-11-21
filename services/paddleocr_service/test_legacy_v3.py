import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import cv2
import numpy as np

from .import_legacy_models import import_models
from .legacy_v3 import create_predictor, decode_ctc, detector_tensor, recognition_tensor


class LegacyTests(unittest.TestCase):
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
