"""Font extraction: FOND association tables, NFNT bitmap strikes, sfnt TTFs.

NFNT layout is from *Inside Macintosh: Text*, "Font Manager" (the FontRec /
'NFNT' record). Glyph i (char firstChar+i) occupies bit columns
locTable[i]..locTable[i+1] of a 1-bpp strike that is `rowWords*16` px wide and
`fRectHeight` rows tall. The owTable gives, per glyph, a character offset (left
side bearing, relative to kernMax) in its high byte and the advance width in its
low byte; 0xFFFF marks a glyph that is absent from the font.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass

from PIL import Image

import resfork


# -- FOND ------------------------------------------------------------------
@dataclass(frozen=True)
class FondAssoc:
    size: int    # point size (0 == scalable/sfnt entry)
    style: int   # style bits (0 plain, 1 bold, 2 italic, ...)
    font_id: int # resource id of the NFNT (or sfnt) strike


def parse_fond(body: bytes) -> tuple[str, list[FondAssoc]]:
    """Return (family_name_unused, association table). The FamRec header is a
    fixed 52 bytes before the font association table."""
    off = 52
    num = struct.unpack_from(">h", body, off)[0] + 1
    off += 2
    rows = []
    for _ in range(num):
        size, style, fid = struct.unpack_from(">hhh", body, off)
        off += 6
        rows.append(FondAssoc(size, style, fid))
    return "", rows


# -- NFNT ------------------------------------------------------------------
@dataclass
class Strike:
    first_char: int
    last_char: int
    wid_max: int
    kern_max: int
    n_descent: int
    frect_w: int
    frect_h: int
    ow_t_loc: int
    ascent: int
    descent: int
    leading: int
    row_words: int
    bitimage: bytes      # rowWords*2 bytes per row, frect_h rows
    loc_table: list[int]
    ow_table: list[int]  # raw 16-bit entries (0xFFFF == missing)


def parse_nfnt(body: bytes) -> Strike:
    (font_type, first_char, last_char, wid_max, kern_max, n_descent,
     frect_w, frect_h, ow_t_loc, ascent, descent, leading,
     row_words) = struct.unpack_from(">HHHHhhHHHHHHH", body, 0)

    n_glyphs = last_char - first_char + 2      # includes the "missing" glyph
    n_entries = n_glyphs + 1                    # loc/ow tables have one extra
    row_bytes = row_words * 2
    img_len = row_bytes * frect_h

    img_start = 26
    bitimage = body[img_start:img_start + img_len]

    loc_start = img_start + img_len
    loc_table = list(struct.unpack_from(">%dH" % n_entries, body, loc_start))

    # The owTable location is authoritatively owTLoc words after the owTLoc
    # field (which sits at byte offset 16). Fall back to right-after-locTable.
    ow_start = 16 + ow_t_loc * 2
    if not (0 < ow_start <= len(body) - n_entries * 2):
        ow_start = loc_start + n_entries * 2
    ow_table = list(struct.unpack_from(">%dH" % n_entries, body, ow_start))

    return Strike(first_char, last_char, wid_max, kern_max, n_descent,
                  frect_w, frect_h, ow_t_loc, ascent, descent, leading,
                  row_words, bitimage, loc_table, ow_table)


def _strike_pixel(strike: Strike, col: int, row: int) -> int:
    """1 if the strike bit at (col,row) is set."""
    row_bytes = strike.row_words * 2
    byte = strike.bitimage[row * row_bytes + (col >> 3)]
    return (byte >> (7 - (col & 7))) & 1


def render_strike(strike: Strike, chars: range = range(32, 256),
                  cols: int = 16, pad: int = 1):
    """Render printable glyphs into a packed sheet. Returns (PIL.Image, metrics).

    Each cell is frect_w+2*pad wide, frect_h+2*pad tall; glyph strike is copied
    verbatim (full strike height so the baseline is consistent across glyphs).
    Metrics record the glyph's pixel box in the sheet, its advance, and its left
    side bearing so the consumer can place it pen-relative.

    THE RANGE RUNS TO 256 AND THE KEYS ARE MACROMAN, and both halves of
    that were wrong until 2026-08-06. The default stopped at 127, so no
    sheet carried a single character above ASCII — and the guest's text
    is MacRoman, in which 0xC9 is an ellipsis and 0xA5 a bullet. Every
    "Save Theme…", every Scrapbook bullet and every curly apostrophe in
    the fidelity sweep drew as blank space, because the consumer
    substitutes the space glyph for a character the strike does not
    carry. That is R6, and it was never a mapping error in the renderer:
    the glyphs are in the NFNT and were never asked for.

    Keying by `chr(c)` would have been the SECOND half of the same
    defect: the consumer looks a glyph up by the character the guest's
    JSON decoded to, and `chr(0xC9)` is 'É' where MacRoman 0xC9 is '…'.
    Every high glyph would have been filed under the wrong name — a
    wrong glyph rather than a missing one, which is the worse failure.
    """
    present = [c for c in chars
              if strike.first_char <= c <= strike.last_char
              and strike.ow_table[c - strike.first_char] != 0xFFFF]
    cell_w = strike.frect_w + 2 * pad
    cell_h = strike.frect_h + 2 * pad
    rows = (len(present) + cols - 1) // cols
    sheet = Image.new("RGBA", (cols * cell_w, rows * cell_h), (0, 0, 0, 0))
    px = sheet.load()

    glyphs: dict[str, dict] = {}
    for idx, c in enumerate(present):
        gi = c - strike.first_char
        x0 = strike.loc_table[gi]
        x1 = strike.loc_table[gi + 1]
        gw = x1 - x0
        ow = strike.ow_table[gi]
        offset = (ow >> 8) & 0xFF
        advance = ow & 0xFF
        left = offset + strike.kern_max
        cx = (idx % cols) * cell_w + pad
        cy = (idx // cols) * cell_h + pad
        for row in range(strike.frect_h):
            for col in range(gw):
                if _strike_pixel(strike, x0 + col, row):
                    px[cx + col, cy + row] = (0, 0, 0, 255)
        glyphs[bytes([c]).decode("mac_roman")] = {
            "x": cx, "y": cy, "w": gw, "h": strike.frect_h,
            "advance": advance, "left": left,
        }
    metrics = {
        "ascent": strike.ascent,
        "descent": strike.descent,
        "leading": strike.leading,
        "frectHeight": strike.frect_h,
        "cellHeight": cell_h,
        "glyphs": glyphs,
    }
    return sheet, metrics


# -- sfnt ------------------------------------------------------------------
def sfnt_to_ttf(body: bytes) -> bytes:
    """An 'sfnt' resource *is* the TrueType file image. Return it verbatim."""
    return bytes(body)


if __name__ == "__main__":
    import sys
    fork = resfork.load(sys.argv[1])
    for r in fork.of_type("FOND"):
        _, assoc = parse_fond(r.data)
        print("FOND", r.id, r.name, [(a.size, a.style, a.font_id) for a in assoc])
    for r in fork.of_type("NFNT"):
        s = parse_nfnt(r.data)
        print("NFNT", r.id, "h=%d asc=%d desc=%d chars=%d-%d"
              % (s.frect_h, s.ascent, s.descent, s.first_char, s.last_char))
