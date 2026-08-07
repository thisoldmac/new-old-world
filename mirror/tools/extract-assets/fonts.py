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


# -- TrueType strikes ------------------------------------------------------
#
# Charcoal, the Mac OS 8.5+ system font, ships NO bitmap strike anywhere: its
# FOND association table is a single size-0 (scalable) row, there is no NFNT
# in the suitcase or in the System file, and its sfnt carries no 'bdat'/'bloc'
# or 'EBDT'/'EBLC'. Mac OS rasterises it from the outlines at run time. So a
# strike for it has to be rasterised here too, and the honesty of the result
# turns on keeping its two halves apart:
#
#   * WIDTHS come from 'hdmx' — Apple's own device metrics, one row per ppem,
#     one unsigned byte per glyph. That is the number the Font Manager
#     advances the pen by on the machine, so it is the machine's answer and
#     not a plausible one. A rasteriser's idea of the advance is different
#     arithmetic over the same outline and is allowed to disagree; where it
#     does, hdmx wins and the disagreement is counted into `notes`.
#   * SHAPES come from FreeType (via Pillow) in monochrome. OS 9's TrueType
#     interpreter is NOT FreeType, so this half is a measured approximation
#     and the delta against the guest's own pixels is reported rather than
#     claimed away — docs/charcoal-strike.md carries the numbers.
#
# A ppem with no 'hdmx' row raises `NoDeviceMetrics` rather than falling back
# to the rasteriser's advances. A strike whose widths are a guess is worse
# than the substitution it replaces, because the substitution is at least
# written down; an absent size keeps substituting and says so.


class NoDeviceMetrics(Exception):
    """The face has no 'hdmx' row for this ppem, so its widths are unknown."""


def _sfnt_tables(ttf: bytes) -> dict:
    """{tag: (offset, length)} from the sfnt table directory."""
    num = struct.unpack_from(">H", ttf, 4)[0]
    out = {}
    for i in range(num):
        tag, _sum, off, ln = struct.unpack_from(">4sLLL", ttf, 12 + 16 * i)
        out[tag.decode("latin-1")] = (off, ln)
    return out


def _hdmx_row(ttf: bytes, tables: dict, ppem: int, n_glyphs: int):
    """The per-glyph advance widths 'hdmx' records for `ppem`, or None.

    'hdmx' (OpenType spec, "Horizontal Device Metrics"; the table predates
    OpenType and is Apple's): uint16 version, int16 numRecords, int32
    sizeDeviceRecord, then numRecords records of that many bytes each —
    uint8 pixelSize, uint8 maxWidth, uint8 widths[numGlyphs], padded.
    """
    if "hdmx" not in tables:
        return None
    off, _ = tables["hdmx"]
    _ver, n_rec, rec_size = struct.unpack_from(">HhL", ttf, off)
    for i in range(n_rec):
        base = off + 8 + i * rec_size
        size, _max = struct.unpack_from(">BB", ttf, base)
        if size == ppem:
            return list(ttf[base + 2:base + 2 + n_glyphs])
    return None


def _mac_roman_cmap(ttf: bytes, tables: dict) -> dict:
    """{byte: glyphID} from the (platform 1, encoding 0) Roman 'cmap'.

    Charcoal carries EIGHT (1,0) subtables — one per Mac script the face was
    localised for — so the platform/encoding pair alone does not identify the
    one QuickDraw uses for MacRoman text. Format 6's own `language` field
    does: 0 means language-independent, which is the Roman table. Picking the
    first (1,0) subtable instead would silently file glyphs under the wrong
    byte for some faces, and a wrong glyph is worse than a missing one.
    """
    off, _ = tables["cmap"]
    n = struct.unpack_from(">H", ttf, off + 2)[0]
    best = None
    for i in range(n):
        plat, enc, sub = struct.unpack_from(">HHL", ttf, off + 4 + 8 * i)
        if (plat, enc) != (1, 0):
            continue
        base = off + sub
        fmt = struct.unpack_from(">H", ttf, base)[0]
        if fmt == 6:
            _f, _len, lang, first, count = struct.unpack_from(">HHHHH", ttf,
                                                              base)
            ids = struct.unpack_from(">%dH" % count, ttf, base + 10)
            table = {first + j: g for j, g in enumerate(ids) if g}
        elif fmt == 0:
            _f, _len, lang = struct.unpack_from(">HHH", ttf, base)
            table = {c: g for c, g in enumerate(ttf[base + 6:base + 262]) if g}
        else:
            continue
        if lang == 0:
            return table
        best = best or table
    if best is None:
        raise ValueError("no MacRoman 'cmap' subtable in this sfnt")
    return best


def render_truetype_strike(ttf: bytes, ppem: int, chars: range = range(32, 256),
                           cols: int = 16, pad: int = 1):
    """Rasterise a TrueType face at `ppem` into the sheet+metrics form
    `render_strike` produces for an NFNT. Returns (PIL.Image, metrics).

    Raises `NoDeviceMetrics` when the face has no 'hdmx' row for `ppem`.

    The vertical metrics come from 'hhea' scaled by ppem/unitsPerEm, which is
    checkable rather than assumed: at 12 ppem it yields ascent 12, descent 3,
    leading 1 for Chicago and for Geneva, and both of those faces ALSO ship a
    hand-drawn 12-point NFNT whose own header says exactly 12/3/1. Where a
    rasterised glyph reaches past that box the box grows to hold it and the
    growth is recorded, because a strike that clips its own accents is a
    defect the consumer cannot see.
    """
    import io                                   # local: only this path needs it
    from PIL import ImageDraw, ImageFont

    tables = _sfnt_tables(ttf)
    upem = struct.unpack_from(">H", ttf, tables["head"][0] + 18)[0]
    n_glyphs = struct.unpack_from(">H", ttf, tables["maxp"][0] + 4)[0]
    asc_u, desc_u, gap_u = struct.unpack_from(">hhh", ttf, tables["hhea"][0] + 4)

    widths = _hdmx_row(ttf, tables, ppem, n_glyphs)
    if widths is None:
        raise NoDeviceMetrics(
            f"no 'hdmx' row at {ppem} ppem; the machine's own advances for "
            "this size are not in the font")
    cmap = _mac_roman_cmap(ttf, tables)

    font = ImageFont.truetype(io.BytesIO(ttf), ppem,
                              layout_engine=ImageFont.Layout.BASIC)

    # One scratch canvas, big enough that no glyph at these sizes can reach
    # its edge; the pen sits at (margin, margin + 2*ppem).
    margin = 2 * ppem + 4
    pen_x, base_y = margin, margin + 2 * ppem
    side = margin * 2 + 4 * ppem

    inked: dict[int, tuple] = {}         # code -> (bitmap, left, above, below)
    for code in chars:
        gid = cmap.get(code)
        if gid is None:
            continue
        ch = bytes([code]).decode("mac_roman")
        scratch = Image.new("1", (side, side), 0)
        ImageDraw.Draw(scratch).text((pen_x, base_y), ch, font=font, fill=1,
                                     anchor="ls")
        box = scratch.getbbox()
        if box is None:                  # a real glyph with no ink, e.g. space
            inked[code] = (None, 0, 0, 0)
            continue
        x0, y0, x1, y1 = box
        inked[code] = (scratch.crop(box), x0 - pen_x, base_y - y0, y1 - base_y)

    ascent = max(round(asc_u * ppem / upem),
                 max((v[2] for v in inked.values()), default=0))
    descent = max(round(-desc_u * ppem / upem),
                  max((v[3] for v in inked.values()), default=0))
    leading = round(gap_u * ppem / upem)
    frect_h = ascent + descent

    cell_w = max((v[0].width for v in inked.values() if v[0]), default=1) + 2 * pad
    cell_h = frect_h + 2 * pad
    rows = (len(inked) + cols - 1) // cols
    sheet = Image.new("RGBA", (cols * cell_w, rows * cell_h), (0, 0, 0, 0))

    glyphs: dict[str, dict] = {}
    overhang = []
    for idx, code in enumerate(sorted(inked)):
        bitmap, left, above, _below = inked[code]
        advance = widths[cmap[code]]
        cx = (idx % cols) * cell_w + pad
        cy = (idx // cols) * cell_h + pad
        gw = bitmap.width if bitmap else 0
        if bitmap:
            tinted = Image.new("RGBA", bitmap.size, (0, 0, 0, 0))
            tinted.paste((0, 0, 0, 255), (0, 0), bitmap)
            sheet.paste(tinted, (cx, cy + ascent - above), tinted)
            if left + gw > advance:
                overhang.append(bytes([code]).decode("mac_roman"))
        glyphs[bytes([code]).decode("mac_roman")] = {
            "x": cx, "y": cy, "w": gw, "h": frect_h,
            "advance": advance, "left": left,
        }

    metrics = {
        "ascent": ascent,
        "descent": descent,
        "leading": leading,
        "frectHeight": frect_h,
        "cellHeight": cell_h,
        "glyphs": glyphs,
        # Provenance, in the file the consumer reads, because "where did this
        # width come from" is the question this strike exists to answer.
        "widthSource": "hdmx",
        "shapeSource": "freetype-mono",
        "rasterisedFrom": "sfnt",
    }
    notes = {
        "hheaBox": [round(asc_u * ppem / upem), round(-desc_u * ppem / upem)],
        "grewToFitInk": [ascent, descent] != [round(asc_u * ppem / upem),
                                              round(-desc_u * ppem / upem)],
        "inkPastAdvance": overhang,
    }
    return sheet, metrics, notes


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
