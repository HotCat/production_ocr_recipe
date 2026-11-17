"""Generate Code 39 label fixtures without adding a packaging dependency."""
from pathlib import Path
import cv2
import numpy as np

DIGITS = [0x034, 0x121, 0x061, 0x160, 0x031,
          0x130, 0x070, 0x025, 0x124, 0x064]


def label(decoded, printed):
    bars = []
    for char in '*' + decoded + '*':
        mask = 0x094 if char == '*' else DIGITS[int(char)]
        for index in range(9):
            bars.extend([0 if index % 2 == 0 else 255] *
                        (6 if mask & (1 << (8 - index)) else 2))
        bars.extend([255] * 2)
    width = max(len(bars) + 80, 540)
    image = np.full((210, width, 3), 255, np.uint8)
    left = (width - len(bars)) // 2
    image[20:135, left:left + len(bars)] = np.array(bars)[None, :, None]
    if printed:
        (text_width, _), _ = cv2.getTextSize(printed, cv2.FONT_HERSHEY_SIMPLEX, 1.6, 2)
        cv2.putText(image, printed, ((width - text_width) // 2, 190),
                    cv2.FONT_HERSHEY_SIMPLEX, 1.6, (0, 0, 0), 2)
    return image


def generate(directory):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    images = {
        'match': label('123456', '123456'),
        'mismatch': label('123456', '654321'),
        'no-text': label('123456', ''),
        'no-barcode': np.full((210, 540, 3), 255, np.uint8),
        'multiple': np.concatenate([label('123456', '123456'), label('654321', '654321')], axis=0),
    }
    for name, image in images.items():
        assert cv2.imwrite(str(directory / (name + '.png')), image)
    return directory


if __name__ == '__main__':
    import sys
    print(generate(sys.argv[1]))
