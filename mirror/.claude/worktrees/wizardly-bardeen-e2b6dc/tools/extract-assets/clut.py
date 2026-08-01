"""The standard Macintosh 8-bit system colour table.

Generated from the documented construction of the default 256-entry system
'clut' (id 8): a 6x6x6 colour cube on the levels {FF,CC,99,66,33,00} with red
the most-significant axis (index 0 is white), followed by single-channel
red/green/blue ramps, a grey ramp, and a final pure black.

The one subtlety that bites: the cube's trailing (0,0,0) is *not* left in the
cube. Apple moves that black to index 255 and starts the four primary/grey
ramps at index 215, so the cube proper is only 215 entries (0..214). Getting
this wrong shifts the whole tail up by one — the visible symptom is index 245
(the "icon white" canvas that most icons carry under their mask) landing on the
last blue (0,0,17) instead of the first grey (238,238,238), which paints the
generic-document icon (icl8 -4000) a dark page. See the belkadan.com clut #8
teardown; cross-checked against the guest's live render of -4000 on the desktop
(creator '????' -> generic doc icon), whose page reads light grey, not blue.
"""

from __future__ import annotations

_CUBE = [0xFF, 0xCC, 0x99, 0x66, 0x33, 0x00]
_RAMP = [0xEE, 0xDD, 0xBB, 0xAA, 0x88, 0x77, 0x55, 0x44, 0x22, 0x11]


def system_clut() -> list[tuple[int, int, int]]:
    table: list[tuple[int, int, int]] = []
    for r in _CUBE:
        for g in _CUBE:
            for b in _CUBE:
                table.append((r, g, b))          # 6x6x6 cube; ends on (0,0,0)
    table.pop()                                  # drop trailing black -> 0..214
    for v in _RAMP:
        table.append((v, 0, 0))                  # 215..224 red ramp
    for v in _RAMP:
        table.append((0, v, 0))                  # 225..234 green ramp
    for v in _RAMP:
        table.append((0, 0, v))                  # 235..244 blue ramp
    for v in _RAMP:
        table.append((v, v, v))                  # 245..254 grey ramp
    table.append((0, 0, 0))                      # 255 is pure black (moved here)
    assert len(table) == 256
    return table


def parse_clut_resource(body: bytes) -> dict[int, tuple[int, int, int]]:
    """Parse a 'clut' resource into {index: (r,g,b)} (8-bit per channel)."""
    import struct
    # ctSeed(4) ctFlags(2) ctSize(2) then ctSize+1 ColorSpec entries:
    # value(2) rgb(6, 16-bit each channel)
    _seed, _flags, size = struct.unpack_from(">IHH", body, 0)
    out: dict[int, tuple[int, int, int]] = {}
    off = 8
    for _ in range(size + 1):
        value, r, g, b = struct.unpack_from(">HHHH", body, off)
        off += 8
        out[value] = (r >> 8, g >> 8, b >> 8)
    return out


SYSTEM_CLUT = system_clut()
