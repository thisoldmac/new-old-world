"""Small, dependency-free image primitives for classic 8-bit UI evidence."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
from pathlib import Path
import struct
import zlib


@dataclass(frozen=True)
class Image:
    width: int
    height: int
    rgba: bytes

    def __post_init__(self) -> None:
        if self.width <= 0 or self.height <= 0:
            raise ValueError("image dimensions must be positive")
        if len(self.rgba) != self.width * self.height * 4:
            raise ValueError("RGBA byte count does not match image dimensions")

    def pixel(self, x: int, y: int) -> tuple[int, int, int, int]:
        offset = (y * self.width + x) * 4
        return tuple(self.rgba[offset : offset + 4])  # type: ignore[return-value]


Rect = tuple[int, int, int, int]


def _bounded(rect: Rect, width: int, height: int) -> Rect:
    left, top, right, bottom = rect
    if not (0 <= left < right <= width and 0 <= top < bottom <= height):
        raise ValueError(f"rectangle {rect} is outside {width}x{height}")
    return rect


def load(path: Path) -> Image:
    data = path.read_bytes()
    if data.startswith(b"BM"):
        return _load_bmp(data)
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return _load_png(data)
    if data.startswith((b"P6", b"P3")):
        return _load_ppm(data)
    raise ValueError(f"unsupported image format: {path}")


def _load_bmp(data: bytes) -> Image:
    if len(data) < 54:
        raise ValueError("truncated BMP")
    pixel_offset = struct.unpack_from("<I", data, 10)[0]
    dib_size = struct.unpack_from("<I", data, 14)[0]
    if dib_size < 40:
        raise ValueError("unsupported BMP DIB header")
    width, signed_height = struct.unpack_from("<ii", data, 18)
    planes, depth = struct.unpack_from("<HH", data, 26)
    compression = struct.unpack_from("<I", data, 30)[0]
    if width <= 0 or signed_height == 0 or planes != 1:
        raise ValueError("invalid BMP dimensions or planes")
    if depth not in (24, 32) or compression not in (0, 3):
        raise ValueError("only uncompressed or bitfield 24-bit and 32-bit BMP are supported")
    if compression == 3 and depth != 32:
        raise ValueError("BMP bitfields are supported only at 32-bit depth")
    height = abs(signed_height)
    stride = ((width * depth + 31) // 32) * 4
    if pixel_offset + stride * height > len(data):
        raise ValueError("truncated BMP pixels")
    top_down = signed_height < 0
    rgba = bytearray(width * height * 4)
    bytes_per_pixel = depth // 8
    masks = None
    if compression == 3:
        if len(data) < 70:
            raise ValueError("truncated BMP bitfield masks")
        masks = struct.unpack_from("<IIII", data, 54)
        if not all(masks[:3]):
            raise ValueError("BMP RGB bitfield masks must be nonzero")
    for output_y in range(height):
        source_y = output_y if top_down else height - 1 - output_y
        row = pixel_offset + source_y * stride
        for x in range(width):
            source = row + x * bytes_per_pixel
            if masks is None:
                b, g, r = data[source : source + 3]
                a = 255
            else:
                value = struct.unpack_from("<I", data, source)[0]
                r, g, b = (_masked_channel(value, mask) for mask in masks[:3])
                a = _masked_channel(value, masks[3]) if masks[3] else 255
            target = (output_y * width + x) * 4
            rgba[target : target + 4] = bytes((r, g, b, a))
    return Image(width, height, bytes(rgba))


def _masked_channel(value: int, mask: int) -> int:
    shift = (mask & -mask).bit_length() - 1
    maximum = mask >> shift
    raw = (value & mask) >> shift
    return (raw * 255 + maximum // 2) // maximum


def _png_chunks(data: bytes):
    offset = 8
    while offset + 12 <= len(data):
        length = struct.unpack_from(">I", data, offset)[0]
        kind = data[offset + 4 : offset + 8]
        payload = data[offset + 8 : offset + 8 + length]
        if offset + 12 + length > len(data):
            raise ValueError("truncated PNG chunk")
        yield kind, payload
        offset += 12 + length


def _load_png(data: bytes) -> Image:
    header = None
    compressed = bytearray()
    for kind, payload in _png_chunks(data):
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", payload)
        elif kind == b"IDAT":
            compressed.extend(payload)
        elif kind == b"IEND":
            break
    if header is None:
        raise ValueError("PNG has no IHDR")
    width, height, depth, color_type, compression, filtering, interlace = header
    if depth != 8 or color_type not in (2, 6):
        raise ValueError("only 8-bit RGB and RGBA PNG are supported")
    if compression or filtering or interlace:
        raise ValueError("compressed/filter/interlaced PNG variant is unsupported")
    channels = 3 if color_type == 2 else 4
    stride = width * channels
    raw = zlib.decompress(bytes(compressed))
    if len(raw) != height * (stride + 1):
        raise ValueError("PNG scanline byte count is invalid")
    previous = bytearray(stride)
    rows: list[bytearray] = []
    offset = 0
    for _ in range(height):
        filter_kind = raw[offset]
        source = raw[offset + 1 : offset + 1 + stride]
        offset += stride + 1
        row = bytearray(stride)
        for index, value in enumerate(source):
            left = row[index - channels] if index >= channels else 0
            up = previous[index]
            upper_left = previous[index - channels] if index >= channels else 0
            if filter_kind == 0:
                prediction = 0
            elif filter_kind == 1:
                prediction = left
            elif filter_kind == 2:
                prediction = up
            elif filter_kind == 3:
                prediction = (left + up) // 2
            elif filter_kind == 4:
                prediction = _paeth(left, up, upper_left)
            else:
                raise ValueError(f"unsupported PNG filter {filter_kind}")
            row[index] = (value + prediction) & 0xFF
        rows.append(row)
        previous = row
    rgba = bytearray(width * height * 4)
    target = 0
    for row in rows:
        for x in range(width):
            source = x * channels
            rgba[target : target + 3] = row[source : source + 3]
            rgba[target + 3] = row[source + 3] if channels == 4 else 255
            target += 4
    return Image(width, height, bytes(rgba))


def _paeth(left: int, up: int, upper_left: int) -> int:
    estimate = left + up - upper_left
    choices = ((abs(estimate - left), left), (abs(estimate - up), up),
               (abs(estimate - upper_left), upper_left))
    return min(choices, key=lambda item: item[0])[1]


def _load_ppm(data: bytes) -> Image:
    tokens: list[bytes] = []
    index = 0
    while len(tokens) < 4:
        while index < len(data) and data[index] in b" \t\r\n":
            index += 1
        if index < len(data) and data[index] == ord("#"):
            while index < len(data) and data[index] not in b"\r\n":
                index += 1
            continue
        start = index
        while index < len(data) and data[index] not in b" \t\r\n":
            index += 1
        if start == index:
            raise ValueError("truncated PPM header")
        tokens.append(data[start:index])
    magic, width_token, height_token, max_token = tokens
    width, height, maximum = int(width_token), int(height_token), int(max_token)
    if width <= 0 or height <= 0 or maximum != 255:
        raise ValueError("only 8-bit PPM is supported")
    if magic == b"P6":
        while index < len(data) and data[index] in b" \t\r\n":
            index += 1
        rgb = data[index:]
    else:
        rgb_tokens = data[index:].split()
        rgb = bytes(int(token) for token in rgb_tokens)
    if len(rgb) != width * height * 3:
        raise ValueError("PPM pixel byte count is invalid")
    rgba = bytearray(width * height * 4)
    for pixel in range(width * height):
        rgba[pixel * 4 : pixel * 4 + 3] = rgb[pixel * 3 : pixel * 3 + 3]
        rgba[pixel * 4 + 3] = 255
    return Image(width, height, bytes(rgba))


def write_png(image: Image, path: Path) -> None:
    def chunk(kind: bytes, payload: bytes) -> bytes:
        body = kind + payload
        return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body))

    rows = bytearray()
    stride = image.width * 4
    for y in range(image.height):
        rows.append(0)
        rows.extend(image.rgba[y * stride : (y + 1) * stride])
    header = struct.pack(">IIBBBBB", image.width, image.height, 8, 6, 0, 0, 0)
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(bytes(rows), 9))
        + chunk(b"IEND", b"")
    )


def masked_digest(image: Image, masks: list[Rect]) -> str:
    mask_rows: dict[int, list[tuple[int, int]]] = {}
    for rect in masks:
        left, top, right, bottom = _bounded(rect, image.width, image.height)
        for y in range(top, bottom):
            mask_rows.setdefault(y, []).append((left, right))
    digest = hashlib.sha256()
    digest.update(struct.pack(">II", image.width, image.height))
    stride = image.width * 4
    for y in range(image.height):
        row = bytearray(image.rgba[y * stride : (y + 1) * stride])
        for left, right in mask_rows.get(y, []):
            row[left * 4 : right * 4] = b"\0" * ((right - left) * 4)
        digest.update(row)
    return digest.hexdigest()


def compare(actual: Image, expected: Image, regions: list[tuple[str, Rect]],
            masks: list[Rect]) -> tuple[list[dict], Image]:
    if (actual.width, actual.height) != (expected.width, expected.height):
        raise ValueError(
            f"image dimensions differ: {actual.width}x{actual.height} vs "
            f"{expected.width}x{expected.height}"
        )
    mask_pixels: set[tuple[int, int]] = set()
    for rect in masks:
        left, top, right, bottom = _bounded(rect, actual.width, actual.height)
        mask_pixels.update((x, y) for y in range(top, bottom) for x in range(left, right))
    visualization = bytearray(actual.width * actual.height * 4)
    reports: list[dict] = []
    for name, rect in regions:
        left, top, right, bottom = _bounded(rect, actual.width, actual.height)
        changed = 0
        compared = 0
        maximum = 0
        min_x = right
        min_y = bottom
        max_x = left - 1
        max_y = top - 1
        for y in range(top, bottom):
            for x in range(left, right):
                if (x, y) in mask_pixels:
                    continue
                compared += 1
                offset = (y * actual.width + x) * 4
                a = actual.rgba[offset : offset + 4]
                b = expected.rgba[offset : offset + 4]
                delta = max(abs(a[channel] - b[channel]) for channel in range(3))
                if delta:
                    changed += 1
                    maximum = max(maximum, delta)
                    min_x, min_y = min(min_x, x), min(min_y, y)
                    max_x, max_y = max(max_x, x), max(max_y, y)
                    visualization[offset : offset + 4] = bytes((255, 0, 0, 255))
        reports.append({
            "name": name,
            "rect": [left, top, right, bottom],
            "comparedPixels": compared,
            "changedPixels": changed,
            "changedRatio": changed / compared if compared else 0,
            "maxChannelDelta": maximum,
            "changeBounds": [min_x, min_y, max_x + 1, max_y + 1] if changed else None,
        })
    return reports, Image(actual.width, actual.height, bytes(visualization))


def pair(left: Image, right: Image) -> Image:
    if left.height != right.height:
        raise ValueError("pair images must have the same height")
    width = left.width + right.width
    output = bytearray(width * left.height * 4)
    for y in range(left.height):
        target = y * width * 4
        left_start = y * left.width * 4
        right_start = y * right.width * 4
        output[target : target + left.width * 4] = left.rgba[left_start : left_start + left.width * 4]
        output[target + left.width * 4 : target + width * 4] = right.rgba[
            right_start : right_start + right.width * 4
        ]
    return Image(width, left.height, bytes(output))
