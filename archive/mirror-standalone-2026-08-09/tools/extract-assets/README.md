# extract-assets — the Platinum asset extractor

Rerunnable pull → parse → render → manifest pipeline that produces
`../assets/platinum-pack/` from a live OS 9.1 guest. Pure Python; depends only
on Pillow + numpy (both already present here). See `../ASSET-EXTRACTION.md` for
the brief and the verified transport facts.

## Run it

Bring up your own guest (never borrow another session's) with the anchor worker
on a private host port, then extract:

```bash
# from the repo root — clone-by-default, headless, anchor worker on :1400 (guest)
TIMBOTTU_QEMU=$PWD/qemu/build/qemu-system-ppc \
TIMBOTTU_IMAGE=$HOME/Lab/Assets/os91-qemu/os91-runner.qcow2 \
tools/launch --headless --instance 5          # host port 1405 -> guest :1400

cd tools/extract-assets
python3 extract.py --port 1405                 # pull live, then build the pack
tools/stop --instance 5                        # from repo root, when done
```

`--port` pulls the four source forks (read-only) into `.cache/` and then builds.
Without `--port` it rebuilds from whatever is already in `.cache/` — fast
iteration on parsing/rendering without touching the guest.

## Acceptance

```bash
python3 validate.py --port 1405   # capture guest, compare a label to a sheet
```

Default compares the Finder icon label "TBTRunner" against `fonts/geneva-10`;
verified at IoU 1.0 on 2026-07-16. `swift test` is untouched — this tree emits
data only, no MirrorKit code.

## Modules

| file               | does                                                        |
|--------------------|-------------------------------------------------------------|
| `resfork.py`       | dependency-free resource-fork reader (matches `DeRez -useDF`)|
| `fonts.py`         | FOND assoc tables, NFNT strike → sheet+metrics, sfnt → TTF   |
| `clut.py`          | the standard 8-bit system CLUT (generated, validated)       |
| `icons.py`         | icl8/ics8 composited with ICN#/ics# masks → RGBA             |
| `cursors.py`       | CURS → RGBA + hotspot                                        |
| `patterns.py`      | ppat (PixPat) and PAT tiles → RGB                            |
| `pull.py`          | live read-only rsrc-fork pull over the harness wire          |
| `render_string.py` | reference consumer: lay out a line from a sheet + metrics    |
| `extract.py`       | orchestrator + `manifest.json`                              |
| `validate.py`      | Tier-2 acceptance vs a live capture                          |

`.cache/` (raw Apple resource forks) is gitignored — it is regenerable from the
guest and is Apple's copyrighted data.
