# Reading the guest's assets straight off the disk image

**Date:** 2026-08-06 · **Status:** measured here, on this Mac, against
`~/Lab/Assets/os91-qemu/now-mirror-stage.qcow2`. No VM was booted and no
guest was running.

[mirror-assets.md](mirror-assets.md) carries the inherited knowledge of
WHAT the assets are and where they live in the System Folder; it names
the offline route as an "explicitly unverified alternative" that
upstream did not use. **This page verifies it**, because it is roughly
four orders of magnitude faster than the wire: the whole System file's
resource fork took 24 s over the wire at ~330 KB/s, and here the same
7,893,757 bytes are an ordinary file read.

Everything below is READ-ONLY on a COPY. The rule from
mirror-assets.md stands unchanged: these are Apple's bitmaps, the pack
stays private, and nothing is ever written into a guest System Folder.

## The four steps, and the two that are not obvious

```
qemu-img convert -f qcow2 -O raw <image>.qcow2 /private/tmp/probe.raw
```

`qemu-img` is a file converter, not the emulator — nothing boots, and
the source image is opened read-only. (A running VM's own image can be
converted too; prefer an idle one.)

**1. The Apple Partition Map.** Block 0 is `ER`, then 512-byte `PM`
entries. Take the `Apple_HFS` one: on these images it is entry 8, at
physical block 1544 → byte offset `0xc1000`.

**2. That partition is an HFS WRAPPER, and this is the step that stops
people.** Its volume signature at partition+1024 is `BD` (HFS
Standard), its name is `Untitled`, and it contains exactly three items —
`System`, `Finder`, and `Where_have_all_my_files_gone?`. That file name
is Apple's own joke and the clue: **an HFS+ volume is embedded inside**.
Modern macOS refuses the wrapper outright, because HFS Standard support
was removed after Mojave, which is why `hdiutil attach` answers "image
not recognized" and reads as a dead end.

The MDB gives the embedded volume's location:

| Field | Offset in MDB | Value here |
|---|---|---|
| `drAlBlkSiz` | 20 | 69632 |
| `drAlBlSt` | 28 | 24 |
| `drEmbedSigWord` | 124 | `H+` |
| `drEmbedExtent.startBlock` | 126 | 5 |

```
embedded = partition + drAlBlSt * 512 + startBlock * drAlBlkSiz
         = 0xc1000  + 12288          + 5 * 69632          = 0x119000
```

`H+` appears at `embedded + 1024`, confirming it.

**3. macOS mounts HFS+ happily — but not at an offset.** `hdiutil
attach -section` was tried and refused; carving the embedded volume out
to its own file works:

```
python3 - <<'PY'
src=open('/private/tmp/probe.raw','rb'); src.seek(0x119000)
import shutil; shutil.copyfileobj(src, open('/private/tmp/hfsplus.img','wb'), 1<<20)
PY
hdiutil attach -readonly -mountpoint /private/tmp/os9mnt /private/tmp/hfsplus.img
```

**4. Resource forks are then ordinary files.** macOS exposes them at
`<file>/..namedfork/rsrc`, so no MacBinary, no AppleDouble, no `DeRez`:

```python
import macresources
fork = open('/private/tmp/os9mnt/System Folder/System/..namedfork/rsrc','rb').read()
for r in macresources.parse_file(fork):
    ...   # r.type, r.id, r.name, r.data
```

Measured on the stage image: the System file's fork is **7,893,757
bytes / 2,162 resources**, and the type census matches
mirror-assets.md's wire-pulled figures closely enough to trust the
route — `ics#` 78, `ics8` 75, `ics4` 73, `ICN#` 57, `icl4` 52, `icl8`
52, `CURS` 40, `PICT` 42, plus `CDEF` 34 and 110 `DITL`s.

**`machfs` also reads the wrapper directly** (`machfs.Volume().read()`
over the partition bytes, 0.4 s) and is the right tool if mounting is
unavailable — but it lands you in the wrapper, showing three files, and
the embedded volume still has to be found. `machfs` and `macresources`
are both already installed on this Mac.

## What is there, and what is NOT

`System Folder:Appearance` holds `Desktop Pictures`, `Sound Sets` and
`Theme Files`; `Theme Files` contains **`Apple platinum`** and
`Ensemble Themes`.

That is worth opening, but do not expect chrome bitmaps in it.
mirror-assets.md's finding stands until something contradicts it:
**window frames, title bars, scroll bars and buttons are drawn
procedurally by the Appearance Manager** — there are no title-bar or
scroll-arrow images to lift, which is why the host renderer draws them
from a ported specification. The 2026-08-06 content-plane work is
consistent with that: themed controls arrive as CopyBits out of worlds
AppearanceLib composes at draw time, not as stamped art.

So the honest split for a host-side asset pack is:

- **Extractable, real bitmaps**: icons (`icl8`/`ics8` + `ICN#`/`ics#`
  masks), cursors (`CURS`), patterns (`ppat`, `PAT `), pictures
  (`PICT`), and the font strikes (`NFNT`/`sfnt`, in the Fonts folder's
  suitcases rather than the System file).
- **Not extractable, must stay drawn**: Platinum chrome, unless the
  theme file proves otherwise — in which case that is a finding and
  belongs in this file with the evidence.
