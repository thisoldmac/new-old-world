import struct
import zlib

from .font import GLYPHS
from .profiles import PALETTES


class Raster:
    def __init__(self, width, height, depth):
        self.width, self.height, self.depth = width, height, depth
        self.palette = PALETTES[depth]
        self.pixels = [0] * (width * height)

    def set(self, x, y, color=1):
        if 0 <= x < self.width and 0 <= y < self.height:
            self.pixels[y * self.width + x] = min(color, len(self.palette) - 1)

    def fill(self, x, y, width, height, color=0):
        for py in range(max(0, y), min(self.height, y + height)):
            start = py * self.width + max(0, x)
            end = py * self.width + min(self.width, x + width)
            self.pixels[start:end] = [min(color, len(self.palette) - 1)] * max(0, end - start)

    def line(self, x1, y1, x2, y2, color=1):
        dx, sx = abs(x2 - x1), 1 if x1 < x2 else -1
        dy, sy = -abs(y2 - y1), 1 if y1 < y2 else -1
        error = dx + dy
        while True:
            self.set(x1, y1, color)
            if x1 == x2 and y1 == y2:
                return
            twice = 2 * error
            if twice >= dy:
                error += dy
                x1 += sx
            if twice <= dx:
                error += dx
                y1 += sy

    def rect(self, x, y, width, height, color=1, thickness=1):
        for offset in range(thickness):
            self.line(x + offset, y + offset, x + width - 1 - offset, y + offset, color)
            self.line(x + offset, y + height - 1 - offset, x + width - 1 - offset, y + height - 1 - offset, color)
            self.line(x + offset, y + offset, x + offset, y + height - 1 - offset, color)
            self.line(x + width - 1 - offset, y + offset, x + width - 1 - offset, y + height - 1 - offset, color)

    def dither(self, x, y, width, height, color=1):
        for py in range(y, y + height):
            for px in range(x, x + width):
                if (px + py) % 2 == 0:
                    self.set(px, py, color)

    def text(self, x, y, value, color=1, scale=1, max_width=None):
        cursor = x
        for char in str(value):
            glyph = GLYPHS.get(char, GLYPHS.get(char.upper(), GLYPHS["?"]))
            if max_width is not None and cursor + 5 * scale > x + max_width:
                break
            for row, bits in enumerate(glyph):
                for col in range(5):
                    if bits & (1 << (4 - col)):
                        self.fill(cursor + col * scale, y + row * scale, scale, scale, color)
            cursor += 6 * scale

    def text_width(self, value, scale=1):
        return max(0, len(str(value)) * 6 * scale - scale)

    def save_png(self, path):
        def chunk(kind, data):
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

        rows = []
        per_byte = 8 // self.depth
        mask = (1 << self.depth) - 1
        for y in range(self.height):
            row = bytearray()
            source = self.pixels[y * self.width:(y + 1) * self.width]
            for start in range(0, self.width, per_byte):
                packed = 0
                for offset in range(per_byte):
                    packed <<= self.depth
                    if start + offset < len(source):
                        packed |= source[start + offset] & mask
                row.append(packed)
            rows.append(b"\x00" + bytes(row))
        palette_data = b"".join(bytes(rgb) for rgb in self.palette)
        png = b"\x89PNG\r\n\x1a\n"
        png += chunk(b"IHDR", struct.pack(">IIBBBBB", self.width, self.height, self.depth, 3, 0, 0, 0))
        png += chunk(b"PLTE", palette_data)
        png += chunk(b"tEXt", b"PreviewStatus\x00measured-preview")
        png += chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
        png += chunk(b"IEND", b"")
        with open(path, "wb") as handle:
            handle.write(png)
