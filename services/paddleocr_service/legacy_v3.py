"""Run the original PP-OCRv3 English weights with modern Paddle Inference.

Uses the Debian C++ pipeline's BGR normalization, max-side 960 detector limit,
DB thresholds 0.3/0.6/1.5, slow score mode, 48px recognition and 127 padding.
Angle classification, document rotation and unwarping are never run here.
PaddleX supplies its maintained DB contour postprocessor; model weights and
the CTC dictionary are imported unchanged from the old installation.
"""
from __future__ import annotations

import math
from pathlib import Path

import cv2
import numpy as np


def create_predictor(directory: Path, device: str | None, cpu_threads: int):
    from paddle import inference

    model, params = directory / 'inference.pdmodel', directory / 'inference.pdiparams'
    if not model.is_file() or not params.is_file():
        raise FileNotFoundError(f'Missing PP-OCRv3 weights in {directory}; run import_legacy_models')
    config = inference.Config(str(model), str(params))
    # These are legacy ProgramDesc exports, not the modern PIR .json models.
    # Configure this predictor only; do not change global PIR flags needed by
    # the Chinese pipeline living in the same worker process.
    config.enable_new_ir(False)
    if device and device.startswith('gpu'):
        gpu = int(device.split(':', 1)[1]) if ':' in device else 0
        config.enable_use_gpu(1000, gpu)
    elif device is None or device == 'cpu':
        config.disable_gpu()
        config.set_cpu_math_library_num_threads(cpu_threads)
        config.enable_mkldnn()
        config.set_mkldnn_cache_capacity(10)
    else:
        raise ValueError('PP-OCRv3 profile supports cpu or gpu:N devices')
    config.switch_ir_optim(True)
    config.enable_memory_optim()
    config.switch_use_feed_fetch_ops(False)
    config.delete_pass('matmul_transpose_reshape_fuse_pass')
    config.disable_glog_info()
    return inference.create_predictor(config)


def run_predictor(predictor, tensor):
    handle = predictor.get_input_handle(predictor.get_input_names()[0])
    handle.reshape(tensor.shape)
    handle.copy_from_cpu(np.ascontiguousarray(tensor, dtype=np.float32))
    predictor.run()
    return predictor.get_output_handle(predictor.get_output_names()[0]).copy_to_cpu()


def detector_tensor(image):
    height, width = image.shape[:2]
    ratio = min(1.0, 960 / max(height, width))
    # Match C++ round(), which rounds positive half values away from zero.
    rh = max(32, int(math.floor(int(height * ratio) / 32 + .5)) * 32)
    rw = max(32, int(math.floor(int(width * ratio) / 32 + .5)) * 32)
    resized = cv2.resize(image, (rw, rh)).astype(np.float32) / 255
    resized = (resized - np.array([.485, .456, .406], np.float32)) / np.array(
        [.229, .224, .225], np.float32)
    return resized.transpose(2, 0, 1)[None], np.array([[height, width, rh / height, rw / width]])


def crop_text(image, box):
    points = np.asarray(box, dtype=np.float32)
    width = int(max(np.linalg.norm(points[0] - points[1]), np.linalg.norm(points[2] - points[3])))
    height = int(max(np.linalg.norm(points[0] - points[3]), np.linalg.norm(points[1] - points[2])))
    if width <= 3 or height <= 3:
        return None
    target = np.array([[0, 0], [width, 0], [width, height], [0, height]], np.float32)
    cropped = cv2.warpPerspective(image, cv2.getPerspectiveTransform(points, target),
                                  (width, height), flags=cv2.INTER_CUBIC,
                                  borderMode=cv2.BORDER_REPLICATE)
    # Geometric handling of a tall detection is part of the old crop operation,
    # not an angle-classification neural network.
    return np.rot90(cropped) if height >= width * 1.5 else cropped


def recognition_tensor(images):
    width = int(48 * max(320 / 48, *(image.shape[1] / image.shape[0] for image in images)))
    batch = []
    for image in images:
        resized_width = min(width, math.ceil(48 * image.shape[1] / image.shape[0]))
        resized = cv2.resize(image, (resized_width, 48))
        padded = cv2.copyMakeBorder(resized, 0, 0, 0, width - resized_width,
                                    cv2.BORDER_CONSTANT, value=(127, 127, 127))
        batch.append(((padded.astype(np.float32) / 255 - .5) / .5).transpose(2, 0, 1))
    return np.stack(batch)


def decode_ctc(predictions, characters):
    if predictions.shape[2] != len(characters):
        raise ValueError('PP-OCRv3 model output and English dictionary do not match')
    decoded = []
    for row in predictions:
        indices = row.argmax(axis=1)
        probabilities = row.max(axis=1)
        selected = (indices != 0) & np.concatenate(([True], indices[1:] != indices[:-1]))
        text = ''.join(characters[index] for index in indices[selected])
        decoded.append((text, float(probabilities[selected].mean()) if selected.any() else 0.0))
    return decoded


class LegacyV3Engine:
    def __init__(self, root: Path, device: str | None, cpu_threads: int):
        from paddlex.inference.models.text_detection.processors import DBPostProcess

        self.characters = ['#', *root.joinpath('en_dict.txt').read_text(encoding='utf-8').splitlines(), ' ']
        self.detector = create_predictor(root / 'ch_PP-OCRv3_det_infer', device, cpu_threads)
        self.recognizer = create_predictor(root / 'en_PP-OCRv3_rec_infer', device, cpu_threads)
        self.postprocess = DBPostProcess(thresh=.3, box_thresh=.6, unclip_ratio=1.5,
                                         score_mode='slow', use_dilation=False)

    def recognize(self, image):
        tensor, shape = detector_tensor(image)
        boxes, _ = self.postprocess([run_predictor(self.detector, tensor)], shape)
        # Read top-to-bottom, then left-to-right on a line, as the shared OCR
        # response joins all text (barcode guards may include surrounding text).
        ordered = sorted(boxes[0], key=lambda box: (box[0][1], box[0][0]))
        for index in range(1, len(ordered)):
            for previous in range(index - 1, -1, -1):
                a, b = ordered[previous], ordered[previous + 1]
                if abs(a[0][1] - b[0][1]) < 10 and a[0][0] > b[0][0]:
                    ordered[previous:previous + 2] = [b, a]
                else:
                    break
        regions = [(box, crop_text(image, box)) for box in ordered]
        regions = [(box, crop) for box, crop in regions if crop is not None]
        # Width batching matches the original recognizer's batch size of six.
        indices = sorted(range(len(regions)), key=lambda i: regions[i][1].shape[1] / regions[i][1].shape[0])
        lines = [None] * len(regions)
        for begin in range(0, len(indices), 6):
            batch = indices[begin:begin + 6]
            predictions = run_predictor(self.recognizer,
                                        recognition_tensor([regions[i][1] for i in batch]))
            for i, (text, score) in zip(batch, decode_ctc(predictions, self.characters)):
                lines[i] = {'text': text, 'score': score, 'box': np.asarray(regions[i][0]).tolist()}
        return {'text': ''.join(line['text'] for line in lines), 'lines': lines}
