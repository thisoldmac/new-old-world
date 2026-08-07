---
title: Asset packs — Plan
type: feat
date: 2026-08-07
---

# Asset packs — Plan

An **asset pack** is the art of one machine running one system, extracted
from that machine, named, and selectable. Today the mirror draws from
whichever pack `AssetPack` happened to resolve — newest `pack-<date>`
first, one global answer for every guest. This makes the pack a
first-class object a person chooses, keyed by the machine and the OS it
came from, with **none** as an equal choice rather than a broken state.

Successor to, and dependent on,
[017 — assets from the connected guest](2026-08-06-017-feat-assets-from-the-connected-guest-plan.md),
which established the *route* (extract over the wire, per machine) but
not the *object*. This plan is the object: format, key, provenance,
selection, and the extraction a person can start and watch.

## 1. A pack is meant to be handed to someone

**Sharing is the design goal, not a risk to mitigate.** Michelle,
2026-08-07: *"the point is to make these packs easier to extract and
share without needing to put them in GH."* Everything about the format
follows from that, and it is the section that comes first because it
decides the format rather than merely constraining it.

So:

- **A pack is one portable, self-describing artefact.** Somebody hands
  you a file over a share or a forum post, you point Mirror at it, it
  works. Not a scattering of state the app reassembles, and not a
  directory whose meaning depends on where it sits.
- **It is self-contained.** No absolute paths, no reference to the
  machine that made it, nothing that resolves differently on the
  receiving Mac. Provenance *describes* the source machine; it is never
  *dereferenced*.
- **Import is as first-class as extraction.** A person handed a pack
  never ran the extractor. Their path is *choose a pack → validate →
  use it*, and it must be no more awkward than extracting their own.
- **Validation names what is wrong, specifically.** Truncated, a
  format version this build does not understand, a domain it does not
  know, a manifest that disagrees with the payload — each has its own
  reason. Never a silent partial load, never a generic failure.

**Provenance is what makes a received pack usable.** Every pack records
the machine, the OS version, when it was extracted, by which route,
which domains it contains, and the pack-format version. That is not
bookkeeping: it is how the app can say *"this pack is from OS 8.6 and you
are mirroring 9.1"* instead of rendering something subtly wrong, and it
is how anyone looking at a pack can tell what it is rather than seeing
3,000 anonymous PNGs.

**No locks.** No machine-binding, no obfuscation, no key derived from
hardware, no anti-sharing anything.

**And the constraint hands us the community case for free.** Gestalt
carries no per-unit serial number: `gestaltMachineType` is the MODEL, and
two PowerBook 1400cs answer identically. For anything that needs to tell
two Macs apart that would be a limitation. For this it is exactly right —
a pack extracted from one 1400c running 9.1 *is* the right pack for
another, so the key that identifies a pack is a key that is **meant to
collide**. Michelle's "someone in the community with all the software
ever makes a comprehensive pack" is not a feature bolted onto the keying;
it is what the keying already does. A key that could tell two units apart
would give every machine its own pack and make that impossible.

### The one rule, and it is mundane repo hygiene

A pack is a few thousand binary files extracted from a guest. It belongs
in a git source tree no more than a `.qcow2` does.

- Not committed here. `.gitignore` already carries
  `mirror/host/MirrorKit/Sources/MirrorKitUI/Resources/`; the store this
  plan introduces lives under `~/Lab/Assets/` and outside the checkout.
- Not bundled into a build. `Package.swift` declares no resources for
  `MirrorKitUI` and must not start ([asset-pack.md](../asset-pack.md)) —
  the same reason a fresh clone with no pack must still build.
- **Extraction stays read-only.** Nothing is ever written into a guest's
  System Folder; the offline route works on a converted *copy* of the
  image and the wire route only reads forks. This one is about not
  damaging someone's Macintosh, and it is unconditional.

## 2. What already exists

Read this before designing anything; most of the mechanism is built.

| Thing | Where | State |
|---|---|---|
| The offline extractor | `tools/extract-assets-offline` (1,268 lines) | works, image-only, no guest |
| The parsers | `mirror/tools/extract-assets/{resfork,icons,cursors,patterns,fonts,clut}.py` | shared by both routes on purpose |
| Pack resolution | `MirrorKitUI/AssetPack.swift` | `$NOW_MIRROR_ASSETS` → `~/Lab/Assets/now-mirror-assets/pack-*/Resources` → checkout `Resources/` → absent |
| Absent-is-loud | `AssetPack.status`, `AssetPack.bannerText`, the gates' `NOW_MIRROR_ASSETS=none` second pass | works |
| The manifest | pack `manifest.json` — `icons`, `cursors`, `patterns`, `desktop`, `pictures`, `fonts`, `appicons`, `theme_file`, `provenance` | works |
| Rung 4, the unknown | `MirrorKitUI.ProvenanceLadder`, `UnknownVisual` | works — **this is what "none" renders as** |
| Wire file pull with forks | the `file.*` family; metal-verified for browse/pull/push | works |

Three of those are the load-bearing reuses. The manifest already groups
the art almost exactly the way a domain list wants to. `AssetPack`'s
resolution order is already a *policy*, so adding a selected pack is a
new rung in an existing ladder rather than a new mechanism. And rung 4
already means "nobody can account for this rectangle" — which is exactly
what an unresolved asset under **none** must render as.

## 3. The domains, grounded in what the machine holds

The measured pack (`~/Lab/Assets/now-mirror-assets/pack-2026-08-07b/Resources`,
from `now-mirror-stage.qcow2`, OS 9.1) is 1,210 files and 6.5 MB. Its
actual shape:

| Directory | Files | KB | Comes from |
|---|---|---|---|
| `appicons/` | 915 | 3,840 | 1,078 forks swept across 8 roots, 914 icons, 185 creators |
| `fonts/` | 53 | 1,072 | `System Folder/Fonts` suitcases — NFNT strikes + verbatim `sfnt` |
| `patterns/` | 53 | 964 | System `ppat`/`PAT` + 44 named Appearance patterns + the desktop picture |
| `icons/` | 137 | 548 | the System file's fork |
| `pictures/` | 42 | 240 | the System file's `PICT`s |
| `cursors/` | 41 | 164 | the System file's 40 `CURS` |

**Group by where it comes from and what it costs, not by what it is.**
That is the only grouping that lets a person make a decision — the cost
of a domain is a property of its *source*, and three of the six
directories above come out of one file read.

### The four domains

| Domain | Contents | Guest source | Cost shape |
|---|---|---|---|
| **`system`** | generic + all System icons, cursors, System patterns, pictures | **one** file: `System Folder/System`'s resource fork | one pull. 7,893,757 bytes, 2,162 resources; ~24 s at ~330 KB/s over the wire ([mirror-assets.md](../mirror-assets.md)) |
| **`fonts`** | NFNT strikes, verbatim TrueType faces | the suitcases in `System Folder/Fonts` | a handful of small file pulls; a suitcase is ~0.1 s |
| **`appearance`** | the 44 named Appearance patterns, the desktop **setting**, and the desktop picture | Appearance control panel's fork, `Preferences/Desktop Pictures Prefs`, plus the picture the alias names | three reads, then one picture whose size is not knowable until the alias is parsed |
| **`applications`** | per-application `icl8`/`ics8` | a sweep of 8 roots | **unbounded.** 1,078 forks on the stage image; on an unknown machine, unknown |

Four things that grouping decides, each of which the directory listing
does not:

- **`system` is one pull.** Splitting icons from cursors from patterns
  would present four checkboxes that cost the same 24 s together as
  separately, which is a menu that lies about its own price.
- **The desktop is a SETTING, not a pattern.** The manifest already keeps
  `desktop` separate from `patterns` for exactly this reason, and reading
  the first as the second was a measured defect (`ppat` 16 is a shipped
  default; the stage guest's actual desktop is an 800×600 JPEG). It
  belongs in `appearance` beside the control panel it is chosen in, not
  in `system` beside the resources it is not.
- **`applications` is the only unbounded one**, and it is where the
  progressive design of plan 017 lives: extract it lazily, driven by the
  roster's creators, or extract it all with a sweep the person opted into
  knowing it is the expensive one.
- **The accent ramps are not a domain**, and that is an open question —
  see §8.

## 4. Size estimation, and where it must say `unknown`

An estimate shown before a long operation must be honest about being an
estimate. The vocabulary is load-bearing and already in use in this
project: **`empty` means we looked and there are none; `unknown` means we
could not establish it.** A wrong number is worse than an absent one.

What is cheap to establish *before* extracting, per domain:

| Domain | Estimate from | Honesty |
|---|---|---|
| `system` | the fork's byte length, which `file.list` already carries as `rsrcBytes` — one listing, no pull | **an exact source size**, not an estimate. Present it as bytes-to-transfer with an elapsed estimate derived from the measured ~330 KB/s, and label the *time* as the estimate it is |
| `fonts` | the suitcase file sizes, likewise from one listing | exact source size; pack output is smaller (sheets are packed PNGs) |
| `appearance` | the Appearance control panel's fork size; the desktop picture's size only **after** the alias is read | partial. The picture is `unknown` until the prefs file is pulled — which is itself a small read, so the modal may resolve it as a first step |
| `applications` | **nothing cheap.** Establishing it means walking 8 roots and reading a `BNDL` out of every fork | `unknown`, always, until a scan is run. Offer "scan first" as an explicit, cancellable step that turns `unknown` into a number — never guess from another machine's 3.8 MB |

The last row is the one that matters. The stage image's 3.8 MB is
*this* image's number and predicts nothing about a PowerBook with a
different set of applications. Showing it as an estimate for an unknown
machine would be the exact defect this project keeps paying for: a
plausible number nobody can attribute.

## 5. Keying, per machine and per OS

The key must work identically for a QEMU `mac99` guest and for the
PowerBook 1400c, and it must be derivable from a *connected* guest.

### 5.1 What the guest can actually report — and the hole in it

Established from the guests' own source, not invented. **The answer is
that neither existing surface can key this today**, and that is the
finding this section exists to record.

**`hello` cannot do it. Both fields are lies of convenience.**

| Field | PPC | 68K |
|---|---|---|
| `os` | the hardcoded literal `"9"` (`now-guest-ppc/src/core/wire.c:735`) — never read from Gestalt | the compile-time constant `"7.1"` (`now-guest-68k/src/core/hello.c`) |
| `name` | the System file's *Sharing* name, resource `-16413` — user-editable | the compile-time constant `"now-68k"` — the **product**, not the Mac |

`GuestIdentity.swift` already says outright that `hello.name` is "a label
now, shown to humans, never compared". A key built on either is a key
built on a constant.

**`census identity` has the facts and delivers them as prose.**
`census.request{probe:"identity"}` returns `[name, raw, meaning]` string
triples — there is no typed field anywhere in `census.report` — and the
two guests spell the same fact differently:

- the OS row is `Mac OS` on PPC and `System` on 68K;
- `Model`'s raw column is the model *name* on PPC and the decimal
  `gestaltMachineType` on 68K, with the meaning columns correspondingly
  swapped.

`selectors` does carry machine-readable `MachineType` and
`SystemVersion` — and **68K refuses that probe outright** (32 KB of
selector names in a 384 KB partition), so it cannot be the universal
route.

Two more facts that bound the design:

- **Gestalt has no serial number.** `gestaltMachineType` is the *model*;
  two PowerBook 1400cs answer identically. `GuestRegistry.swift` says
  "do not go looking again." **This is fine for us** — a pack *should*
  be shared between two machines of the same model and system, which is
  §1's whole point. We need a model-and-OS key, not a unique id, so the
  unbuilt "guest-minted id in `hello`" open issue is **not** a blocker
  for this plan.
- **Not one census probe has ever run against a Macintosh** as an
  integrated page — `open-issues.md:9015`, and `contract-coverage.md`
  says the same for the 68K half. The mechanism is metal-proven in
  `spikes/census-metal` on the 1400c (System 9.1.0, CarbonLib 1.6.0);
  the *report* is not. Anything keyed off it inherits that status.

### 5.1.1 The contract change this needs

The key is **(machine model, system version)**. Parsing it out of
localised display strings whose labels differ per guest is precisely the
`two-halves-never-met-in-a-test` defect class, so it is not the route.
**The contract changes first**, and the smallest honest change is:

- `hello` gains an optional typed `machine` object — `{ modelId,
  modelName }` from `gestaltMachineType` and the model-name lookup both
  guests already have (`machine_model()` on PPC, `k_machines[]` on 68K);
- `hello.os` starts carrying `gestaltSystemVersion` rather than a
  literal, with the field's description saying what it now is. On 68K
  that is `gest_or(gestaltSystemVersion, 0)` — the value its `System`
  identity row already reads.

Both guests already compute every one of those values for the `identity`
probe. This adds no capability; it moves facts from prose into fields.

**It is a contract change touching both guests and `hello` is the first
frame of every session, so it wants Michelle's sign-off before S1
starts** — see Open questions. The fallback if it is refused is to parse
`census identity` with a per-guest label map, which works and which this
plan considers the worse answer for a reason it can name.

### 5.1.2 The key is derived, never asserted

Whatever the source, the key is computed in **one** place on the host,
from typed fields, and written into the pack manifest at extraction. A
received pack's key is read from its manifest and never recomputed from
its contents — that is what makes a pack from a machine nobody here has
seen comparable to the guest in front of you.

### 5.2 The key is a default, not a constraint

Two OS 9.1 installs on the same model, with different applications and
different themes, produce genuinely different packs and share a key.
That is not a collision to be engineered away:

- the **key** decides which pack is *suggested* when a guest connects;
- **selection is explicit and per-Mirror-instance**, which is what
  Michelle asked for — "select an asset pack to use on any mirror
  instance";
- so several packs may share a key, are listed together, and the newest
  is the default. A person who wants the other one picks it.

This also makes the supported portability case fall out for free: a pack
copied from another machine lands in the store, matches by key, and is
suggested — because it *is* the right pack.

### 5.3 The store, and the artefact

Two shapes, and the distinction is the whole of §1:

**The artefact — what you hand someone.** One file:

    Mac OS 9.1 (Power Macintosh G4).nowpack

A zip container, because it is one file every Mac can already make and
open, it holds a directory tree unchanged, and a truncated one is
detectably truncated. `manifest.json` at the root, the domain
directories beside it, exactly the layout the extractor already writes.
Nothing inside references the machine that made it.

**The store — where the app keeps them.**

    ~/Lab/Assets/now-mirror-assets/packs/<slug>/
        manifest.json
        icons/ cursors/ patterns/ fonts/ pictures/ appicons/

Expanded, because the renderer reads individual files lazily and mounting
a zip to draw one cursor is a cost with no payer. `<slug>` is
human-readable and derived from the key; the authoritative key lives in
`manifest.json` so nothing has to parse a filename. Import expands into
the store; export zips back out. The existing `pack-<date>` directories
keep resolving unchanged, as unkeyed legacy packs.

**`manifest.json` gains a provenance block** — additive, so an old pack
still reads:

```json
"packFormat": 1,
"provenanceOf": {
  "machine": { "id": "...", "name": "..." },
  "os": { "version": "...", "name": "..." },
  "route": "wire | offline",
  "extracted": "2026-08-07",
  "domains": ["system", "fonts", "appearance", "applications"],
  "producer": "NOW <version>"
}
```

`domains` is the field that makes a partial pack honest: a pack with
`system` and no `fonts` says so, and the modal shows three domains
present and one absent rather than implying a complete pack that draws
the wrong text. The existing top-level `provenance` array (per-asset
source rows) stays as it is; this is the pack-level block it never had.

### 5.4 What has to change in `AssetPack` — and it is not small

`AssetPack.status` is `static let`: **resolved once and immutable for the
process lifetime**. So are the caches below it —
`IconAtlas.cache`, `BitmapFont.cache`, and `DesktopPattern.manifest`
(all `static`, none invalidated). Selecting a pack from a modal and
seeing the mirror change therefore needs a mutable seam and a cache
flush, or pack selection means "next launch", which is not what a modal
implies.

That is a real refactor of a type currently designed to answer one
question once, and it belongs in S4 rather than being discovered in S6.
The `.absent(searched:)` case and `bannerText` are kept exactly as they
are — they are already the honest-absence machinery that **none** needs.

## 6. What this format must be able to become

Not a slice. Four constraints on the format, written down now because
each is cheap today and a one-way door once a pack exists in the wild.

Michelle, 2026-08-07:

> i think the packs should be modifiable. like, i want to be able to (in
> a future slice) go in and add applications installed on the guest as
> targets for asset extraction. So, if I install a new browser and want
> its assets, i can just add them to an existing pack. then someone in
> the community with all the software ever can make a comprehensive
> asset pack that covers most all needs.
>
> we dont need to build all that out just yet, but i do want to keep
> that kind of scaling and modularity in mind for our design

**We are not building this now.** We are making sure it can be built
without a format break.

### 6.1 Provenance is per entry, not per pack

The moment a pack accumulates — a second extraction session, a newly
installed application, a merge with somebody else's pack — a single
pack-level "extracted from machine X, OS Y, on date Z" header becomes a
lie about most of its contents.

**This is the one place the design is already most of the way there.**
The extractor writes a per-asset `provenance` array today — 1,239 rows
in the measured pack:

```json
{ "asset": "appicons/1wcs__sdev-16.png",
  "type": "ics8", "id": 128,
  "source": "System Folder/Control Strip Modules/AirPort Control Strip" }
```

It carries the resource type, the resource id, and the file it came out
of. What it is missing is **which machine, which OS, and which extraction
session** — so the change is three fields on a row that already exists,
not a new structure:

```json
{ "asset": "...", "type": "ics8", "id": 128,
  "source": "System Folder/.../AirPort Control Strip",
  "machine": "<machine key>", "os": "9.1", "session": "<extraction id>" }
```

`provenanceOf` from §5.3 stays, and its meaning narrows honestly: it
describes **the pack** — who assembled it, when, in what format version —
and stops claiming to describe its contents. A pack whose entries all
share one machine can still say so in one line; it derives that from the
entries rather than asserting it over them.

This also gives the renderer something true to say: *this glyph came
from this machine's System file; that icon came from a browser somebody
else extracted.* Which is the provenance discipline the render already
runs on ([render-composition.md](../render-composition.md)).

### 6.2 Packs merge, so entries need stable identity

Two packs covering the same application must combine without collision
and without silent overwrite.

**Identity of an entry:** `(source file, resource type, resource id, OS
version)`. The first three are already in every provenance row; the
fourth is what 6.1 adds. Note it is *not* the asset's path in the pack —
`appicons/<creator>__<type>.png` collides for two different applications
sharing a creator, and has already folded two entries together once on a
case-insensitive volume (`ddsk__dimg` vs `ddsk__dImg`, recorded in
[asset-pack.md](../asset-pack.md)).

**A merge that hits the same identity twice REFUSES and names the
conflict.** That is the first behaviour, deliberately, and it is a
legitimate answer rather than a placeholder: a silent overwrite is the
defect class this project keeps paying for, and "prefer newer" needs a
policy nobody has yet had a reason to choose. Keeping both is possible
later — the format allows it, since identity is a tuple and not a path —
and would be a decision with an argument behind it.

### 6.3 A domain is a target, not a fixed category

Michelle's example is adding a newly-installed browser. So "the System
file" and "an arbitrary application on the guest" must be the **same
kind of thing** in the format: a *source you point the extractor at*.

**Consequence for S1, and it reverses this plan's first draft: the
domains are DATA, not a closed contract enum.** A domain record carries
its name, its guest paths, the resource types it wants, and how (or
whether) it can estimate itself. The four in §3 are the built-in
records; a fifth added later is a new record, not a format version bump.

The contract still declares the *shape* of a domain record and the names
of the built-in four — a guest inventing a name the host has never heard
of is still the defect AGENTS.md warns about. What it must not declare is
that those four are all there will ever be.

### 6.4 A partially-understood pack still loads

A community pack will eventually carry a domain or an asset kind this
build has never heard of. That build **loads what it understands and
says what it skipped and why** — it does not refuse the whole pack and
it does not silently drop anything.

This is the same rule as everywhere else here: **`unknown` is a fact
about us, and must be legible as one.** It is also why §7's refusal
table has "unknown domain" as an *import-with-a-note*, not a rejection —
that row was written to this constraint before it was stated.

The one thing that still refuses outright is a `packFormat` newer than
the build understands, because that is a claim about the container
itself rather than about one entry inside it.

## 7. Slices

Command-first, per [command-parity.md](../command-parity.md): every
capability is proven as a console x-command before any UI exists, with
one implementation behind both faces. **The modal is last.**

| # | Slice | Ends when |
|---|---|---|
| **S0** | **The `hello` typed-identity change** (§5.1.1), if Michelle signs it off. Contract first, then both guests. Everything downstream keys off it. | both guests report a real `gestaltSystemVersion` and a typed `machine`, and the host derives one key from them |
| **S1** | **The domain RECORD shape and the manifest schema.** Contract first: `packFormat`, the pack-level `provenanceOf`, the per-entry provenance fields (§6.1), and the shape of a domain record — **as data, with the built-in four named, not as a closed enum** (§6.3). No behaviour. | the contract declares the record shape; a native test pins the manifest schema and the merge-identity tuple |
| **S2** | **`assets` — the enumerate/estimate verb.** A guest verb that reports, per domain, whether it is present and what it would cost, answering `unknown` where it cannot establish a size. Both faces. | `assets` is typeable at the guest console and from the host console, and `CommandParityTests` is green |
| **S3** | **Extraction of one domain over the wire.** `system` first — it is one fork pull and the largest single win. Swift resource-fork reader, cross-checked byte-for-byte against the Python route (017's Q1/Q2 and its stop condition apply unchanged). | the same System fork extracted both ways produces identical bytes |
| **S4** | **Pack format, keying, provenance, selection.** The store, the `packFormat`/`provenanceOf` block, `AssetPack` gaining a mutable selected-pack seam above the date-ordered scan plus the cache flush §5.4 requires, and **none** as an explicit selection distinct from absent-by-accident. | a pack can be selected and deselected live; with **none**, unresolved art renders as rung 4 and says so |
| **S5** | **Import, export, validation.** `.nowpack` in and out, with a named reason for every way a pack can be wrong. Command-first: this is a host-side capability, so its first face is the agent/MCP surface and the modal comes later. | a pack extracted on one Mac is imported and used on another; a truncated pack is refused by name |
| **S6** | **The remaining domains** — `fonts`, `appearance`, then `applications` with its scan-first estimate. | each domain extracts over the wire and agrees with the offline route |
| **S7** | **The modal.** `Asset Packs…` in the Mirror module with the current pack named beside it; the pack list, import, the domain list with estimates, multi-step progress. | a person can pick a pack, import one, run an extraction, and watch it honestly |

S5 is placed before the remaining domains deliberately. Import is what
makes the whole thing worth having for anyone who did not build it, and
a format is cheapest to get right while only one domain exists to put in
it. S1–S3 are the arc's technical risk; S7 is the part Michelle asked
for and is worth nothing without them.

### What S2 actually costs, so nobody rediscovers it

Adding `assets` to the PowerPC guest is **five edits, and only one of
them is compiler-checked**:

1. the contract's `x-commands` entry, with an `x-line` stating the
   argument grammar once, where both halves read it;
2. a `d_assets[]` detail block in `now-guest-ppc/src/commands/cmd_help.c`;
3. a `kNowCommandDocs[]` row **with `wire=1`** — omit the row and the
   verb works on the wire and is invisible to `help` and to the guest's
   own console; set `wire=0` and `help` refuses a verb the dispatch
   serves;
4. the handler, building `output: {"assets": [[label, value], …]}`;
5. a literal `strcmp(name, "assets")` row in `now_command_run` — literal
   because that string is what `contract-coverage.md` greps to derive
   what the guest serves.

Two traps, both already paid for by other verbs:

- **`kNowCommandResultCap` is 3072 bytes and it is a hard wall.** A
  four-domain report fits; a per-application listing does not, and
  anything larger needs its own console path (as `wirestat` has) or it
  silently says `command failed` at the keyboard while answering the
  host correctly — the bug that hid `putstat` from its own machine.
- **An arg key must not shadow an envelope key** (`type`, `id`, `name`,
  `args`, `line`). The classic guest scans a frame flat, first
  occurrence wins; `launch` shipped that bug to metal with an arg named
  `name`.

`docs/contract-coverage.md` must be updated in the same commit, and
**re-derived with its own commands, never hand-edited** — the running
values today are 44 declared / 41 PPC / 13 68K, while the comments
embedded in its own derivation block still say 43 / 40. Nothing gates
that file, which is exactly why it has to be re-run rather than
remembered.

Any new native test goes into `scripts/test-native`'s manifest or the
run fails naming it.

## 8. The UI, when it is reached

A button reading `Asset Packs…` with the **current pack named beside
it** — its label, its machine, its OS — or `none (minimal assets)`. The
name beside the button is not decoration: it is the smallest possible
version of the provenance rule, on screen at all times.

It goes in `MirrorControlView`'s `header` HStack beside `Refresh` — the
page has no toolbar, and `header` is where its other verbs already live.
The modal is a `.sheet`, following `FilesModuleView`'s idiom (*"a
question, not a failure, so it is a sheet on the window rather than an
alert"*), and honours that file's macOS 13 floor: no
`ContentUnavailableView`, use a local empty-state helper as
`CensusModuleView` does.

The modal:

- **lists packs** with machine, OS, date, domains present, and size, and
  whether the key matches the connected guest. A mismatch is *marked*
  — "this pack is from OS 8.6, you are mirroring 9.1" — not hidden and
  not forbidden;
- **offers none** as a peer of the packs, described as what it is —
  minimal assets, unresolved art drawn as unknown — not as "off";
- **imports** a `.nowpack` and **exports** the selected one, with import
  no more steps than extraction;
- **lists the four domains** with their estimates, `unknown` where
  §4 says `unknown`, and a scan-first affordance for `applications`;
- **runs the extraction with honest multi-step progress.**

### What a refused import says

Each has its own sentence, and none of them is "could not open pack":

| Reason | What it means |
|---|---|
| not a pack | no `manifest.json` at the root — the same test `AssetPack.isPack` already uses |
| truncated | the container will not read to its end, or a file the manifest names is missing |
| format too new | `packFormat` exceeds what this build understands. Name both numbers |
| unknown domain | the manifest lists a domain this build has no reader for. The pack still imports; that domain is marked unusable and the others work |
| manifest disagrees with payload | counts or names in the manifest do not match what is on disk. A partial extraction that was zipped anyway |

**Never a silent partial load.** A pack that imports with three of four
domains says which one it lost and why, in the list, permanently — not
in a toast that disappears.

### Progress that does not lie

Four states, four appearances, and they are not shades of one spinner:

| State | Shown as |
|---|---|
| not started | named, dimmed, with its estimate |
| running, with a known total | determinate — bytes of bytes, because a fork pull knows its length |
| running, total unknown | indeterminate **and labelled** with what it is doing and what it has done so far (forks scanned, icons found). Never a percentage |
| done | the actual number, which replaces the estimate |
| failed | named, with the guest's own words, and the rest of the run's disposition stated |

A spinner that keeps moving while nothing happens is the UI version of
the defect this whole arc exists to kill. An indeterminate step must
carry a *counter that moves*, or it must say it is waiting.

## 9. Open questions

Named rather than decided.

0. ~~The `hello` typed-identity contract change.~~ **DECIDED 2026-08-07:
   take it. Typed fields in `hello`, not the census-label map — and it is
   built (§12).** The reasoning, recorded here rather than left in the
   conversation that produced it: the fallback is disqualified by this
   project's own worst defect class. A per-guest label map is a third
   place that must agree with two others, maintained by hand, with
   nothing failing the build when a guest changes its wording — while the
   two guests already spell the same fact differently (`Mac OS` against
   `System`; `Model`'s raw column a name on one and a decimal on the
   other). And the change adds **no capability**: both guests already
   compute every value for the `identity` probe, so it moves facts from
   prose into fields. `hello.os` carrying `gestaltSystemVersion` instead
   of a hardcoded `"9"` / `"7.1"` is strictly more true than what shipped.
   `hello.name` stays what it is — a human label, never compared — and
   was deliberately not promoted into the key while the file was open.
1. **The accent ramps.** `tools/extract-assets-offline` writes them as
   *generated Swift source* (`PlatinumAccentRamps.swift`), deliberately —
   168 integers the renderer needs at static-init, with no bundle lookup
   that could fail silently. But that makes them a property of the
   **build**, not of the pack, so a per-machine pack cannot carry a
   machine's own ramps. Either they move into the pack as data (and gain
   the failure mode they were designed to avoid), or the plan states
   plainly that accent ramps are always the build's and not the selected
   machine's. **This is a real trade-off and it is Michelle's call.**
2. ~~Whether "none" means no art at all, or the built-in minimal set.~~
   **DECIDED 2026-08-07: "None" is PROCEDURAL AND HONEST-UNKNOWN, not a
   smaller pack.** Michelle's words were "none with the default minimal
   assets we were using before making that full extraction", and the
   reading that matches what exists is the right one: `AssetPack` returns
   nil everywhere, the renderer draws its procedural fallbacks, and
   anything it cannot account for is rung 4 / `UnknownVisual`. **No
   starter pack is to be built.** Shipped extracted art is precisely what
   §1 rules out, and a built-in "minimal" set of Apple bitmaps would be
   that with a smaller file count. A later slice must not try.
3. **Whether extraction is offered against the PowerBook at all.** A
   1,078-fork sweep over MacTCP on a 68K machine is a different
   proposition from the same sweep on an emulated G4, and the 180c
   wedges silently under load. The domains make this answerable per
   domain rather than as one yes/no.
4. **`applications` is 68K's cliff, not just its slow lane.** On the
   PowerBook that domain is a sweep of eight roots over MacTCP on a
   machine that wedges silently under load, and NOW-68K refuses the
   `selectors` probe already for want of 32 KB in a 384 KB partition.
   Whether the 68K guest serves `assets` at all, or serves it for
   `system` and `fonts` only, is a
   [contract-coverage](../contract-coverage.md) decision to be declared
   rather than a gap to be left.

## 10. Stop conditions

- **017's stop condition is inherited unchanged.** If the Swift and
  Python extractions ever disagree about a single icon's bytes, stop and
  resolve *that* before adding a resource type.
- **If a domain cannot state its cost honestly, it does not ship a
  number.** It ships `unknown`, or the domain waits.
- **If the key cannot be derived from what a connected guest already
  reports**, stop and say so rather than adding a capability to the guest
  to invent one — that is a design change, not an implementation detail.
  As of this writing it **cannot**, which is why S0 exists and why
  question 0 blocks it.
- **If the first pack format would ship with a single provenance header
  or a closed domain enum, stop.** Both are one-way doors (§6), and
  neither is expensive to avoid before a pack exists in anyone else's
  hands.

## 11. Verification status of everything above

Per AGENTS.md — *verification is a status, not an adjective*.

| Claim | Status |
|---|---|
| The measured pack shape in §3 (1,210 files, 6.5 MB, the six directories) | **Tested** — read off `~/Lab/Assets/now-mirror-assets/pack-2026-08-07b/Resources` on this Mac |
| The wire route's ~24 s / ~330 KB/s for the System fork | **Metal-verified upstream**, quoted from [mirror-assets.md](../mirror-assets.md); not re-measured here |
| `hello.os` and `hello.name` cannot key a machine | **Tested** — read out of both guests' source (`wire.c:735`, `now-guest-68k/src/core/hello.c`) |
| `census identity` carries the facts as untyped display strings with per-guest label drift | **Tested** — read out of `census_probes.c` and `census68.c` |
| The census report has never run against a Macintosh | **Recorded** in `open-issues.md:9015` and `contract-coverage.md`; inherited, not re-checked |
| `AssetPack.status` is `static let` and the downstream caches are never invalidated | **Tested** — read out of `AssetPack.swift`, `IconAtlas.swift`, `BitmapFont.swift` |
| Everything in §6 through §9 | **Design.** Nothing below §5 has been built or run. |

Nothing in this plan has been implemented. No claim here is
metal-verified by this lane.

## 12. S0, as built (2026-08-07)

Status: **Builds** (both guests + ext + three rig instruments) and
**Tested** (`scripts/test-native` 138; host suites green).
**Not metal-verified** — no Macintosh has sent one of these frames.

What landed, against §5.1.1:

- `hello` gained an optional typed `machine {id, model}`; `hello.os` now
  carries `gestaltSystemVersion`. Additive, **no revision bump** (the
  `agent.access` precedent). `additionalProperties: false` on `Hello`
  means the field had to be declared before either guest could send it,
  which is the contract-first rule enforcing itself.
- **Both guests send it, in the same shape, from one decode.** No
  direction where one half sends what the other has never heard of.
- `NOW68K_HELLO_OS` was **deleted rather than updated**. It was `"7.1"` —
  a property of the build sent as a property of the machine.

### What the work found that the plan had not

**Both guests already decoded `gestaltSystemVersion`, differently, in two
places neither of which was on the wire.** `commands.c` read the major as
BCD and dropped a zero bug-fix (`"9.1"`); `census68.c` read the same byte
as plain decimal and always printed three (`"7.1.0"`). Both correct for
every System either guest has ever run on. A key built by comparing them
would still have failed to match a pack to its own machine — the least
debuggable shape a defect takes.

So the decode is **one shared header**, `contract/guest_identity.h`,
compiled by both guests and by the host `cc` for its native test. The
`census68.c` copy now delegates to it, which incidentally corrects two
things: a BCD ten reads as ten, and a Gestalt that answered 0 renders
`unknown` rather than claiming System 0.0.0.

**`hello.os` had a twin, and it was a live break rather than a tidiness
item.** `peek.c` published the resident endpoint's OS as the literal
`"9"`, beside a comment stating that if `send_hello()`'s matching literal
ever became computed, this must read the same source. The resident's own
hello fills its `os` from that field, and the host associates a resident
channel with its application by **fingerprinting name and OS together**.
An application saying `9.1.0` beside a resident still saying `9` is two
different machines to that fingerprint — the channel would have gone on
connecting and silently vouched for nobody. Both are now published off
the same call, at the same instant, once per successful connect.

### The key

`AssetPackKey` (`now-host/Sources/Host/GuestIdentity.swift`) derives it in
one place from typed fields only. The machine id leads and the model name
follows — a name is localised and can fall back to a Sharing name a
person edits, while the number is the same on every System.

`isComplete` is the guard that matters. **A guest built before today
sends no `machine` and a compiled-in `os`, so nothing may auto-select a
pack from it.** Selection stays manual and the UI must say why; dressing
one machine in another's art is what §1's provenance rules exist to
prevent.

### One test was found to be a fake

`testTheHumanLabelNeverReachesTheKey` first used a `hello` **with** a
machine — where a `?? hello.name` fallback can never engage — so it
asserted nothing and passed against the exact mutation it was written
for. It now uses the no-machine case, which is the redeploy case that
would actually bite. Recorded because it is the shape: **a test of a
fallback must reach the state where the fallback runs.**

### Residue, named rather than left

- `census_probes.c` keeps its own `machine_model` that skips the `'STR '`
  step, so the census page and `hello` can name the same Mac
  differently. Only `hello` is the key, so it does not corrupt one — but
  it is two implementations of "which machine is this".
- `scripts/test-all` reports that **the commit gates are not armed in
  this clone** (`tools/hooks-doctor --fix`). Green means the tests pass,
  not that anything would refuse a bad commit here.
