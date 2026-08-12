<!-- now-doc-provenance: generated reviewed=false -->

# Lane C — the desktop the guest actually has

**Plan:** [018 slice 5](../../plans/2026-08-06-018-feat-stable-honest-render-plan.md)
· **Date:** 2026-08-07 · **Branch:** `claude/018-lane-c`
· **Status:** acquisition side IMPLEMENTED and verified offline; the
render decision is Lane A's and is untouched here.

## The headline

The renderer tiles `ppat` 16 from the System file. That is wrong twice
over on the image we actually run:

1. **Wrong art.** System `ppat` 16 is "Mac OS Default" — the 128×128
   purple Mac face. The stage guest's desktop is the 800×600 JPEG
   **"Indigo Foam"**.
2. **Wrong operation.** It is a *picture*, drawn once at the origin.
   Tiling anything there is a claim the machine does not make.

`ppat` 16 is a **shipped default, not a setting**. Under Appearance
(8.5+) the desktop is chosen in a control panel that writes neither the
System file nor a theme file, so the System resource can sit at its
factory value forever while the screen shows something else — which is
exactly what happened here.

**Verified, not assumed.** The extracted picture was compared
pixel-for-pixel against the QMP screendump from sweep A
(`sweep-2026-08-07-a/p1/apps/simpletext-guest.ppm`), over the strip of
desktop no window covers (x 786–799, y 40–599, 2 618 samples):

    p50 delta 2   p95 delta 3   (max 194 — the window edge and cursor)

Same size (800×600), drawn 1:1 at the origin. That is the guest's
desktop, identified offline, with no VM booted.

## Where the truth lives on the guest

Two files, neither of which anything in this project was reading:

| What | Where | Contents |
|---|---|---|
| **The selection** | `System Folder/Preferences/Desktop Pictures Prefs` | `alis` 128 — the picture's name, type/creator (`JPEG`/`apcp`) and absolute path. `dkp≈` 0 — a 380-byte blob whose OSType at +12 says what kind of thing was chosen (`JPEG` here). |
| **The pattern library** | `System Folder/Control Panels/Appearance` | **44 named `ppat` resources** — "Bondi", "Azul Dark", "Bossanova Poppy", "Ripple Bondi"… ids −4010 and 20000–20440. |

The second one is why a name off a running guest could never have
resolved before: the System file holds **three** `ppat`s, and none of
them is a pattern a person can pick. The pack simply had no art to look
up.

Also present, and both empty of anything decisive on this image:
`Custom Desktop Patterns` (a resource map with no types — nobody added a
custom pattern) and `Finder Preferences` (`alis` + `fvl8`, view state,
not the desktop).

Not present at all: any `Appearance Preferences` file. The desktop
setting does **not** go through the theme-file route that
`active_theme_hint()` already reasons about.

### On a RUNNING guest (the live route, not implemented here)

Appearance Manager answers this authoritatively, and covers both the
pattern and the picture case, which the offline route only half does:

```c
Collection c = NewCollection();
GetTheme(c);                       /* CarbonLib 1.0+, Appearance 1.1+ */
/* kThemeDesktopPatternNameTag  'patn'  Str255  */
/* kThemeDesktopPatternTag      'patt'  flattened pattern */
/* kThemeDesktopPictureNameTag  'dpnm'  Str255  */
/* kThemeDesktopPictureAliasTag 'dpal'  AliasHandle */
/* kThemeDesktopPictureAlignmentTag 'dpan' UInt32 */
```

`GetTheme` is in CarbonLib 1.0 and later (Appearance.h), so it is inside
the CarbonLib 1.6 floor. Two routes are **not** available and should not
be reached for: `LMGetDeskCPat` / `LMGetDeskPattern` and `SetDeskCPat`
are all marked *CarbonLib: not available*.

## Can the scene carry it? Yes, and cheaply — but that is not the gap

The scene IR already has a `screen` object (`{"w":…,"h":…}`,
`scene_json.c`), and the delta plane restates the whole scalar head —
including `screen` — on every delta (`asyncapi.yaml`, SceneDelta), so a
field added there rides along for free and never goes stale against a
delta.

**No `asyncapi.yaml` edit is needed.** The IR document shape is not in
the contract file; it is `docs/scene-producer.md` plus `scene-deltas.md`,
and the contract states the rule outright: *"additive fields do not move
irVersion"* (the accretive rule, quoted at `windows[].ref`). So the
guest-side field would be:

```json
"screen": {"w":800,"h":600,
           "desktop":{"kind":"picture","name":"Indigo Foam"}}
```

`kind` ∈ `pattern` | `picture` | `unknown`; `name` is the Str255
Appearance hands over. ~40 bytes, once per scene.

**Bytes vs identity: send the identity.** The flattened `patt` blob for
a real pattern is 8–18 KB and a picture is a quarter of a megabyte —
per scene, on a link this project measures in hundreds of milliseconds.
An id-and-name the host resolves against its own pack is two orders of
magnitude cheaper *and* more honest, because an identity the host cannot
resolve degrades to the marked unknown, whereas bytes it cannot place
invite it to draw them somewhere plausible.

**But the wire is not what is missing.** A name is only useful if the
pack holds art under that name, and until today it did not. That is why
this lane's work is the extractor, not the guest.

## The offline route works, and is what landed

`tools/extract-assets-offline` already mounts the volume and reads
resource forks, so this cost no new machinery:

- **`extract_appearance_patterns()`** — the 44 named `ppat`s out of the
  Appearance control panel, written to `patterns/appearance/<Name>.png`,
  **keyed by name** because the name is the only identity a running
  machine can hand over (`kThemeDesktopPatternNameTag` is a Str255).
  Unnamed ones are skipped deliberately: art nothing can ask for is
  weight in the pack and a temptation to guess from.
- **`desktop_state()`** — reads `Desktop Pictures Prefs`, parses the
  alias (`parse_alias()`: the fixed 150-byte header plus the
  type/length/data extras, of which only parent-name and absolute-path
  are read), resolves the file **volume-relatively** so a differently
  named volume still resolves, decodes it and writes
  `patterns/desktop-current.png`.
- **`manifest.json` gains a top-level `desktop` key** — separate from
  `patterns` on purpose: `patterns` is a library of art, `desktop` is a
  *setting*. Reading the first as the second is the entire defect.
- **`--desktop-report`** prints the answer and stops, without writing a
  pack.

It never falls back to `ppat` 16. Every failure path returns
`kind: "unresolved"` (or `"unknown"` with the OSType it actually found)
and says why, in the same voice `active_theme_hint()` already uses.

All four branches were **watched failing**, by mutation, against the
real mount: no prefs file → `unresolved`; alias path not on the volume →
`unresolved` naming the path; unrecognised file type → `unknown` naming
the type; control → `picture`.

### Run

    python3 tools/extract-assets-offline --desktop-report

on the stage image gives:

    kind    picture
    name    "Indigo Foam"   800x600  JPEG
    path    Macintosh HD:System Folder:Appearance:Desktop Pictures:
            Ensemble Pictures:Indigo Foam
    library 44 named patterns, 0 failed

### What is NOT read, and is not guessed

**The alignment** (tile / centre / scale / fill). It is
`kThemeDesktopPictureAlignmentTag` on a running machine; offline it is
somewhere in the unattributed half of `dkp≈`, next to what are plainly
live heap pointers from whichever process last wrote the blob. One
sample is not an attribution, so `"alignment": null` is recorded and
nothing pretends otherwise. This matters: the shipped pictures are
**not** all screen-sized — Ensemble Pictures are 800×600, but 3D
Graphics, Convergency and Photos are 1024×768 and 832×624.

**The pattern case of these prefs files.** Only a picture-selected image
has been seen. What `dkp≈` holds when a *pattern* is chosen is
unverified, and is reported as `kind: "unknown"` with the OSType found
rather than assumed. The live `GetTheme` route sidesteps this entirely.

## Recommendation

**Take the offline route now; keep the wire field as the later
refinement, and do not block on it.**

The offline answer is correct for any guest booted from the image it was
read from and not changed since — which is every guest in this project's
rig, because every VM clones `now-mirror-stage.qcow2`. It costs no
contract change, no guest rebuild, no bake. The live `GetTheme` field
upgrades a baked answer to a live one and can land any time after; it is
worth doing when someone changes the desktop mid-session and expects the
mirror to follow, not before.

Ordering matters and is one-directional: **the pack must hold the art
before a name off the wire is worth anything.** That half is done.

### Handoff to Lane A — what the renderer receives

Read `manifest.json` → `desktop` (already in the pack once the drop
below is installed):

```json
{"kind":"picture", "name":"Indigo Foam",
 "file":"patterns/desktop-current.png", "w":800, "h":600,
 "format":"JPEG", "alignment":null,
 "source":"System Folder/Preferences/Desktop Pictures Prefs",
 "source_sha256":"…", "confidence":"…"}
```

The ladder rule this wants to be, at rung 3 (art addressed by identity):

| `kind` | Condition | Draw |
|---|---|---|
| `picture` | `w == screen.w && h == screen.h` | the PNG **once, at the origin, unscaled** |
| `picture` | size differs | **marked unknown** — the alignment is unread, and scaling a picture the machine may be tiling is a new confident wrong answer |
| `pattern` | `patterns/appearance/<name>.png` exists | tile it |
| `pattern` | no art under that name | **marked unknown** |
| `unresolved` / `unknown` / key absent | — | **marked unknown** |

And the deletion this all exists for: **stop tiling `patterns/desktop.png`
unconditionally.** `DesktopPattern.tile` (`BitmapFont.swift:196`) and its
caller (`SceneRenderer.swift:160`) currently make the desktop a
guarantee; it must become a resolution that can fail. The
`Platinum.desktopBlue` flat fill behind it is a second guess and should
go the same way — an absent pack is the marked unknown too.

`patterns/desktop.png` is misnamed for what it is (System `ppat` 16,
"Mac OS Default"). Renaming it touches host code, so it is left alone
here; the manifest's `patterns.ppat[]` row already carries its real name
and id if Lane A wants to rename them together.

## Artifacts

Staged rather than installed, because the pack under
`~/Lab/Assets/now-mirror-assets/` is shared and this lane is meant to
touch nothing shared:

    ~/Lab/Assets/now-mirror-assets/desktop-2026-08-07/
      desktop.json                     the --desktop-report output
      patterns/desktop-current.png     Indigo Foam, 800x600
      patterns/appearance/*.png        44 named patterns
    ~/Lab/Assets/now-mirror-assets/desktop-2026-08-07.sha256   (46 rows)

To install additively into the live pack (nothing existing is
overwritten — but the `desktop` manifest key only appears on a full
extractor rerun):

    cp -R ~/Lab/Assets/now-mirror-assets/desktop-2026-08-07/patterns/ \
          ~/Lab/Assets/now-mirror-assets/pack-2026-08-06/Resources/patterns/

The clean route is to rerun `tools/extract-assets-offline` once, which
now produces all of it including the manifest key.

## Verification status

- **Tested** (offline, no VM): the extraction, the four failure
  branches by mutation, and the pixel comparison against sweep A's
  screendump.
- **Not tested:** the pattern-selected case of `Desktop Pictures Prefs`;
  the alignment field; `GetTheme` on a running guest (nothing was
  written for it).
- **Not metal-verified.** Nothing here has been near the PowerBook.
