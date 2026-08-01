# Porting a straggler branch cut against the lab tree

Mirror was extracted from TimBotTu on 2026-07-29 with `git filter-repo`,
so history is preserved but **paths moved**. A branch in the lab that
still edits `prototypes/mirror/...` or `axpeek/...` needs its patch
rewritten before it applies here.

## Path map

| Lab path | Mirror path |
|---|---|
| `prototypes/mirror/MirrorKit/` | `host/MirrorKit/` |
| `prototypes/mirror/<DOC>.md` | `docs/<DOC>.md` |
| `prototypes/mirror/README.md` | `docs/PROTOTYPE-NOTES.md` |
| `prototypes/mirror/spin-up.sh`, `stop-mirror.sh`, `stage-mirror.py` | `tools/` |
| `prototypes/mirror/extract-assets/` | `tools/extract-assets/` |
| `prototypes/mirror/mirror-service-*.py` | `tests/` |
| `prototypes/mirror/assets/` | `assets/` |
| `axpeek/` | `guest/extension/` |

## Retired at extraction — do not port

The Python prototype is gone; Swift is the only implementation.

- `scene.py`, `make-fixtures.py` — the fixture generator. The captured
  corpus survives in `host/MirrorKit/Tests/MirrorKitTests/Fixtures/`;
  re-capture through the app, not through Python.
- `sources.py`, `qmp.py` — superseded by `WireClient` and `QmpClient`.
- `attic/` — the retired browser webapp.

A patch touching any of those is a patch against a design decision, not a
path. Read [MIRRORKIT-PLAN.md](MIRRORKIT-PLAN.md) before reviving it.

## Replaying a patch

```bash
git -C /path/to/timbottu format-patch --stdout main..<branch> \
  -- prototypes/mirror axpeek > /tmp/straggler.patch

sed -e 's#prototypes/mirror/MirrorKit/#host/MirrorKit/#g' \
    -e 's#\baxpeek/#guest/extension/#g' \
    /tmp/straggler.patch | git apply --3way -
```

The doc and tooling moves are one-off enough to fix by hand. Check the
result — a rename-heavy patch will need `--reject` and manual placement.

## The lab's copy is frozen, not gone

TimBotTu still contains the pre-extraction `prototypes/mirror/MirrorKit`,
frozen: its workshop host-app takes it as a local SwiftPM dependency and
its `service.mirror` managed service builds from it. **The two trees
diverge on purpose.** Do not port changes *back*, and do not treat a fix
in the lab's copy as a fix here — port the finding and write our own
patch (AGENTS.md > "TimBotTu is the lab, not a dependency").
