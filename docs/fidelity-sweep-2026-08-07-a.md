<!-- now-doc-provenance: generated reviewed=false -->

# Fidelity sweep A, 2026-08-07 — pricing the defects before plan 018 touches anything

**Status: SURVEY. Nothing here is a fix, and nothing was fixed while it
was taken.** This is slice 0 of
[plan 018](plans/2026-08-06-018-feat-stable-honest-render-plan.md): the A
side of an A/B whose whole value is that the tree was measured *exactly as
it stood*. A single "while I was there" repair would have voided it. No
source file in this repository was edited between the first capture and
the last.

It does not replace either 2026-08-06 sweep.
[A](fidelity-sweep-2026-08-06.md) owns the rubric and is a pre-asset-pack
baseline; [B](fidelity-sweep-2026-08-06-b.md) owns the method change
(render each capture onto the scene it was captured against) and the
current scores for six windows. Both are untouched.

## WHICH RIG THIS DESCRIBES — read before quoting a score

| | |
|---|---|
| **Renderer tree** | `claude/gworld-interior-host-render-98ddd5` at `495d10f1`; the working tree carried no source changes for the whole run |
| **Guest build** | `59dce8562ad4 2026-08-07T00:30:47Z`, asserted by `--expect-build auto` on **every** capture, and re-asserted by the host app's own `session_health` before the live phase |
| **Base image** | `~/Lab/Assets/os91-qemu/os91-runner.qcow2`, sha256 `f34f7e5df64e09ced96c7968776692bb94d9639ee32a6f51652449e1a9cda776`. `scripts/spin-up-ppc` clones it, stages **this checkout's** ext and app, cold-boots and verifies — so the resident under test is this tree's, not `now-mirror-stage.qcow2`'s. (For the record: the stage image is `c466baa9a545…`; it was not used and is not the oracle for this sweep.) |
| **Resident** | guest's own `mirror` at boot: `lifecycle active`, resident 1.0, `capabilities 127`, `sourceManifest 18d732487b03…`, `buildFingerprint 0a91ea49abcd…`. During the live phase: `requested 15, active 15`. |
| **Guest machine** | QEMU `mac99`, Mac OS 9.1, 800×600. Run dir `/private/tmp/nowvm-sw18a`, anchor **1700**, wire **5250**, qmp `/private/tmp/nowvm-sw18a/qmp.sock`. The Mac was verified empty first — no QEMU, no host app, 1700/1740/5250/5350 all free, no `nowvm-*` run dirs — so no other session's guest could have answered this listener. |
| **Host app** | built by `scripts/build-host-app` into `/private/tmp/nowhost-sw18a`, launched with `NOW_PREFS_SUFFIX=sw18a`; it was the only host on the Mac, so `tools/now-agent`'s single-per-user socket was unambiguously ours (`lsof` confirmed pid 90955 held 5250) |
| **Asset pack** | `~/Lab/Assets/now-mirror-assets/pack-2026-08-06` — unchanged from sweep B |
| **Renders drawn from** | each target's own `<label>-scene.json`, through `LiveShapedRenderTests.testRenderASweepAsTheAppWouldDrawIt` — sweep B's method, so B and this page **are** comparable |

Nothing here touched metal. Every claim below is **emulator-verified** at
best, and several are only **observed once** — said so per row.

### Artifacts

Out of git, in the `now-mirror-assets` store:
`~/Lab/Assets/now-mirror-assets/sweep-2026-08-07-a/` (63 MB, 175 files:
both passes' drains, scenes, screendumps, renders and pairs, plus the
live-phase snapshots and screendumps). Manifest:
`~/Lab/Assets/now-mirror-assets/sweep-2026-08-07-a.sha256`, itself
sha256 `80b9ea87db26520eb77a6a2140cf8ba2f1e2d431f714ace871a8ad8fabd7731f`.
Every score below traces to a file in that manifest.

## The method, and the one thing it cannot see

Three views per target, as the spec asks:

1. **Agent surface** — `tools/now-agent mirror_read --intention
   snapshot | find | metrics | lifecycle | journal` against the running
   host app.
2. **Mirror pixels** — the capture composed onto its own scene by the
   app's composition path and drawn by `RenderShot`.
3. **Guest pixels** — QMP `screendump`.

Views 2 and 3 are the same instant. View 1 is **not**: the sweep tool and
the host app both bind the wire port the guest dials, so they cannot run
together. The run was therefore three phases — capture pass 1, live
agent-surface phase, capture pass 2 — on one boot, one guest, one build.

**The limit this creates, stated before any score.** The sweep renders a
*settled capture*, twice. It cannot observe frame-to-frame recomposition
in the live app. So where a stability number below reads 3, it means *two
independent captures of that window composed to identical pixels* — not
that the live window does not flicker. Michelle's flicker complaint is
about the second thing and this instrument only measures the first. Said
again in the verdicts.

Two smaller deviations, both recorded rather than worked around:

- **Opening the Mirror is not reachable from the agent socket.** The
  window is opened by a button in the app; there is no env var, no
  preference and no agent verb for it, and `mirror_read` answers
  `now-mirror-snapshot-unavailable` until a human clicks. This run used
  macOS accessibility scripting to press it. For an agent driving NOW
  headlessly that is a hard floor.
- **Finder view switching could not be scripted from the guest side.**
  `script` (AppleScript) answers `osaErr -1753` for every form of
  `set view of window 1 to list view`, and `menuact` needs an armed act
  plane, which only the host app arms. So the three Finder views were
  switched through the Mirror in the live phase (which is the product
  path and the better test), and the sweep's three Finder capture sets
  are all **icon view**. Consequence: the list and button views have an
  agent surface and guest pixels but no host render. That is coverage
  lost, and it is a finding about the rig, not about the renderer.

## The rubric

Five axes from [sweep A](fidelity-sweep-2026-08-06.md) — TEXT /
PLACEMENT / CONTROLS / REGIONS / CHROME — plus plan 018's two new ones.
(Plan 018's spec names the five as "STRUCTURE / TEXT / CONTROLS / ART /
CHROME"; the rubric it points at has no such axes. The rubric wins; the
plan's line is wrong and should be corrected when 018 is next edited.)

- **STABILITY (0–3)** — open/act/close twice; do the two renders agree?
  Measured as an exact pixel diff of the target window's **content**
  rectangle between pass 1 and pass 2 (`pngdiff.py` in the artifact
  store). 3 = zero pixels differ.
- **DRIVABILITY (0–3)** — can the agent surface address what the pixels
  show? 3 = every visible control enumerable **and** carrying a usable
  ref and rect.

## The table

| # | Target | T | P | C | R | Ch | **STAB** | **DRIVE** |
|---|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| 1 | Date & Time | 3 | 3 | 2 | 3 | 3 | **void** | 2 |
| 2 | Memory | 3 | 3 | 1 | 2 | 3 | **3** | 1 |
| 3 | Appearance (tabs) | 2 | 3 | 1 | 1 | 2 | **3** | 0 |
| 4 | Energy Saver (tabs) | 2 | 3 | 1 | 2 | 2 | **3** | 1 |
| 5 | General Controls | 3 | 3 | 1 | 3 | 3 | **3** | 1 |
| 6 | Monitors | 0 | 2 | 2 | 0 | 3 | **3** | 1 |
| 7 | Mouse | 3 | 3 | 0 | 1 | 3 | **3** | 0 |
| 8 | Finder — icon view | 0 | 2 | 1 | 0 | 3 | **3** | 1 |
| 9 | Finder — list view | – | – | – | – | – | – | **0** |
| 10 | Finder — button view | – | – | – | – | – | – | **0** |
| 11 | Finder desktop | – | – | – | – | – | – | **0** |
| 12 | Sherlock 2 | 2 | 3 | 1 | 2 | 3 | **3** | 1 |
| 13 | SimpleText + document | 3 | 3 | 2 | 3 | 2 | **3** | 1 |
| 14 | NOW's own Workshop | 3 | 3 | 2 | 3 | 3 | **3** | 2 |
| 15 | Internet Explorer — TLS modal | 3 | 3 | 2 | 2 | 3 | **1** | 2 |
| 16 | Mail — modal from the desktop | 1 | 3 | – | – | – | – | **2** |

`–` is *not measured*, never *zero*: rows 9–11 have no host render (see
the deviation above), row 16 was only ever seen live, and row 1's
stability comparison is void because the machine was in a different state
in pass 2 (below).

Every score was judged from `<label>-pair.png` — the guest's own
screendump left, the host's render right, same moment.

**Where a row is comparable to sweep B it agrees**: Memory 3/3/1/2/3 in
both; NOW's window 3/3/2/3/3 in both; General Controls 3/3/1/3/3 in both;
Appearance's two missing tab labels reproduce for the third time on a
third VM. That agreement is worth as much as any new number — it says the
instrument is repeatable.

## STABILITY, measured rather than felt — and it is the surprise

Content-rectangle pixel diff, pass 1 vs pass 2, two independent
open/act/close cycles minutes apart:

| Target | pixels differing | of | verdict |
|---|--:|--:|---|
| Memory | **0** | 111,232 | identical |
| Appearance | **0** | 152,192 | identical |
| Energy Saver | **0** | 85,500 | identical |
| General Controls | **0** | 157,296 | identical |
| Monitors | **0** | 123,750 | identical |
| Mouse | **0** | 39,168 | identical |
| Sherlock 2 | **0** | 228,340 | identical |
| SimpleText | **0** | 343,785 | identical |
| NOW's own window | 187 | 382,285 | one row of its own live status text |
| Finder (icon) | 571 | 95,344 | the scroll-bar thumb column only |
| Finder (button-view capture) | 1,776 | 95,344 | content region; see below |
| Internet Explorer | 7,030 | 54,912 | **12.8%** — a real disagreement |
| Date & Time | 79,554 | 130,676 | **void**: different window state |

Two of those need saying plainly.

- **Date & Time is void, not unstable.** The panel's own "Set Time Zone"
  dialog was left open by pass 1 and was front in pass 2, so the two
  renders are of two different machines. That dialog stayed open for the
  entire rest of the run — the sweep's `--quit-after` does not close a
  modal a panel opened — and it shows in every `POST-RUN HEALTH` line
  from that point on. A rig defect worth fixing before sweep B.
- **Internet Explorer is genuinely unstable, and cheaply diagnosed.** The
  machine's dialog says `Error 1 of 3` in pass 2; the host renders
  `Error 1 of 2` — a **stale string** from the earlier capture. And the
  default-button ring lands on a different button in the two passes: the
  machine draws it on *Next* both times, the host drew it on *OK* in pass
  1 and on *Next* in pass 2. Same window, same dialog, two answers.

So: **on this instrument, the composed still frame is overwhelmingly
stable.** Eight of nine control-panel and application targets are pixel-
identical across two passes. That does not refute the flicker complaint —
see verdict 1 — but it does say the instability is not in composing a
settled capture, which is worth knowing before slice 1 rewrites the
epoch model.

## DRIVABILITY — a window can render beautifully and be undrivable

Measured from the live `mirror_read snapshot`, per window: how many items
the surface publishes, how many carry a ref (addressable at all), how
many carry a usable rect, and how many titles are real strings.

| Window | items | with ref | pointer titles | note |
|---|--:|--:|--:|---|
| Date & Time | 41 | 41 | **6** | drivable, but six labels are 68K addresses |
| Set Time Zone | 19 | 18 | **5** | same |
| Sherlock | 24 | 24 | 0 | 20 of 24 have **no title** — addressable, unnameable |
| Error (IE TLS) | 11 | 6 | 0 | the best-behaved modal in the sweep |
| Mail's modal | 13 | 13 | **2** | see verdict 3 |
| Macintosh HD (icon) | 13 | 3 | 0 | only the scroll bars have refs |
| Macintosh HD (list) | 23 | 13 | 0 | **the ten rows have no ref** |
| Macintosh HD (button) | 14 | 4 | 0 | same |
| Desktop | 19 | **0** | 0 | 19 icons, none addressable, all rects degenerate |
| Microsoft Internet Explorer | 2 | 2 | 0 | a browser window with two elements |
| New Old World | 64 of 68 | 9 | 0 | truncated at the budget, and it says so |

Two findings the table understates:

- **Appearance publishes nothing.** Its window arrives in the scene with
  `controls = 0` and `dialogItems = 0` — six tabs, a theme picker, a
  scroll bar and a button, and not one of them is enumerable. That is
  the only DRIVE 0 caused by silence rather than by missing refs, and it
  is why the tab-edge complaint cannot be worked around by an agent.

  **EXPLAINED 2026-08-07 (lane D).** Not unreadable: its control chain is
  **73 controls** long and the per-window walk bound is 48, so the whole
  plane is correctly dropped rather than shipped as a prefix. The silence
  was the reporting — `controls: []` reads identically for a dropped
  plane and an empty window, and the only note was scene-wide and named
  no window. Windows now carry a walk verdict and `meta.errors` names
  them. Appearance is still undrivable, and what is left is a sizing
  decision with a measured cost (docs/open-issues.md).
- **Desktop items carry screen coordinates and zero size.** Every one of
  the 19 is a point (`l == r`, `t == b`) at a screen position, while
  every other surface's rects are content-local. Two conventions in one
  snapshot, and the degenerate one cannot be hit-tested.

## PERF — recorded, not gated

From the live metrics lane (`mirror_read --intention metrics`), steady
state with ten windows and 182 elements:

| | |
|---|---|
| full walk, real | **1,860–1,962 ms** total (request 913–1,022, decode 920–954) |
| full walk, cached | **35–39 ms** total |
| idle between cycles | 756–808 ms |
| lane depth | **0** throughout; no growth, no drain stall observed |

Cycles alternate real/cached, so a change on the machine takes up to
about **2.8 s** to reach the snapshot. Acts, from the same lane:

| act | dispatch | total | outcome |
|---|--:|--:|---|
| menu `as List` (1st) | 1,507 ms | 1,507 ms | dispatched |
| menu `as List` (2nd) | 89 ms | 89 ms | dispatched |
| menu `as Buttons` (1st) | 3,556 ms | 3,556 ms | dispatched |
| menu `as Buttons` (2nd) | 109 ms | 109 ms | dispatched |
| `open "Mail"` | 2,553 ms | **18,007 ms** | **timedOut** — but it worked |
| dialog item 2 (dismiss) | 7,655 ms | 7,655 ms | dispatched |

The first act after a period of quiet costs 1.5–3.5 s and a following one
costs under 110 ms — consistent with the alternating walk above rather
than with the act itself being slow. Capture-side, `qdtrace` drains were
17 to 6,303 records per target and the two passes agree to within a
percent on every target (4,550 = 4,550, 2,888 = 2,888, 2,139 vs 2,140),
which is its own small stability result.

## Michelle's six complaints, by name

### 1. Hatching flickers; Finder content draws over/under/absent — **CONFIRMED (absent), NOT REPRODUCED (flicker), and the instrument is the reason**

*Absent* is confirmed hard and is the worst single result in this sweep.
The Finder's `Macintosh HD` window renders as **one full-window "Bitmap
unavailable" hatch** — no icons, no file names, not even the
"10 items, 3.21 GB available" header — in every capture, both passes,
while the machine draws ten items perfectly. The hatch also spills across
the desktop backdrop below the window. `p1/pairs/finder-icon/finder-pair.png`.
The scene *has* the rows (13 items with rects reach the host), so this is
the ladder losing a rectangle, not the guest going quiet.

*Flicker* was not reproduced — and I want to be precise about how weak
that is. Two independent captures of eight different windows composed to
**identical pixels**, and three independent captures of the Finder inside
one pass likewise. But this instrument renders a settled capture; it
never draws two consecutive live frames, so it cannot see the thing
Michelle saw. What the live phase does show is the two clocks the plan
names: `sceneGeneration` went 1 → 7 while `contentGeneration` went 2 → 7,
never in step, and **`baseComplete` was `false` in every single snapshot
taken across ten minutes** — 22 entities at scene-gen 1, still `false` at
scene-gen 7. A frame is being assembled from a base the host never calls
complete. That is the mechanism to chase; it is not proof of flicker.

Attempts: 2 capture passes × 15 targets, plus ~12 live snapshots.

### 2. View switching slow and brittle; list drawn once then hatched; cannot select list items; new view over old — **SPLIT: one part confirmed exactly, one refuted, two not reproduced**

- **Cannot select items in list view: CONFIRMED, with the mechanism.**
  After switching to list view through the Mirror, the surface publishes
  23 items. The 13 controls (four column headers, the scroll bars) all
  carry refs. The **ten file rows carry no ref at all** — and their rects
  are still the *icon view* grid (`l` ∈ {1, 129, 257}, `t` ∈ {42, 106,
  170, 234}) with zero width and height, on a machine that is visibly
  drawing a list. Nothing can hit-test that. Two attempts, same result.
  Evidence: `agent/snap-list.json` beside `agent/live-list.png`.
- **Slow: measured, and it is the walk not the act.** `as List` took
  1,507 ms the first time and 89 ms the second; the snapshot behind it
  refreshes on a ~1.9 s real cycle.
- **`as Buttons` never produced button view.** Menu 259 item 2 dispatched
  cleanly twice and the machine stayed in icon view both times, while
  item 3 (`as List`) worked on the first try. Two attempts. Unexplained —
  index mapping or a Finder refusal; not chased.

  **CORRECTED 2026-08-07 (lane D of plan 018).** Chased on a private
  clone with the build pinned: `as Buttons` **works**, and did here too.
  All three View items switch the window, the checkmark moves with each,
  and the pixels agree — `as Buttons` is `enabled` in the walk, so
  neither index mapping nor a Finder refusal. What this sweep actually
  met is that the act plane **could not tell**: every menu act carried
  `kNowActPostNone`, which the settlement store skips when observing
  scenes, so a menu act could never leave `dispatched-but-unconfirmed`
  no matter what it did. The reading above is exactly what an honest
  observer gets from a plane that reports the same word for "it worked"
  and "it did nothing" — which is the finding, and it is now fixed:
  a press on a marked menu settles against the mark landing on the item
  pressed. The silent success this sweep was right to name is real and
  lives one door over — a press on a DISABLED item (`File > Print` with
  an empty selection) returned `ok: true` and did nothing, and now
  refuses with a reason.
- **"List rendered once then a hatched overlay" and "new view drawn on
  top of old": NOT REPRODUCED**, and cannot be by this rig — the Finder's
  list and button views have no host render at all here (the deviation
  above). This is the single biggest coverage hole in sweep A and sweep B
  must close it by driving the views through the app.

### 3. Mail double-clicked from the desktop → broken modal, not dismissible through Mirror — **"broken" CONFIRMED with a named mechanism; "not dismissible" REFUTED**

Opening `Mail` from the desktop raises the Internet-setup alert *"Is your
computer set up for Internet access?"* with **Yes / No / Set Up Now**
(`agent/live-mail.png`). It is captured, not missing: a window with 13
items, every one carrying a ref. What is broken is what it says:

- The window has **no title**, so the act's own postcondition
  (`windowNamedPresent`) never matches and `open "Mail"` reports
  **timedOut after 18 s having succeeded**. A false negative on the wire.
- Its two message paragraphs arrive as **pointer bytes**
  (`'\x1dµ\x13å\x1dµ\x17Ä'`), so the sentence a person must read to answer
  the question never reaches the host at all.
- The three buttons are reported **twice with different titles**: the
  control walk says `Yes` / `No` / `Set Up Now` (correct), the dialog-item
  walk says `OK` / `Cancel` / `Don't Save` (wrong) — same refs, same
  rects, contradictory names. A confident wrong answer, which is exactly
  the class rule 1 forbids.

**It dismissed on the first attempt** through
`mirror_drive --gesture dialogItem --entityID <window> --itemIndex 2`,
7.6 s, verified by screendump (`agent/live-mail2.png`). No manual VM
override was needed and none was used. Michelle's authorisation to
override at the SDL window went unspent. One attempt, one success — I did
not try to reproduce the old failure, so the honest statement is "this
build dismissed it once", not "the defect is gone".

### 4. Tabs (Appearance, Energy Saver) missing their edges — **CONFIRMED, both panels, both passes**

Neither panel draws a tab: the labels sit on flat grey with no tab
outline, no selected-tab join, no panel edge. Appearance additionally
loses **"Themes" and "Appearance"** entirely while Fonts / Desktop /
Sound / Options draw — the third independent reproduction of R-B3, now on
a third VM and a fourth guest build, so it is neither an asset-pack nor a
placeholder effect. Energy Saver's labels are present but clipped
("Notificatio", "Advanced Setting"). Appearance's theme swatches are two
blank white rectangles where the machine draws full previews, which is
what takes its REGIONS to 1.

### 5. Some scrollbars render the blank-page icon instead of arrows — **the symptom is real and everywhere; the location is not scroll bars**

In fifteen windows I did not find a page icon inside a scroll bar. Scroll
arrows are **absent or blank**, which is a different (and quieter) defect.
The blank-page icon appears where **icon-sized art** belongs, four times:

- Mouse's three mouse-tracking pictures → three page icons
  (`p1/pairs/panels/mouse-pair.png`);
- Sherlock 2's nine channel buttons → nine page icons;
- the IE TLS alert's stop sign → a page icon;
- Set Time Zone's caution triangle → a page icon.

So complaint #5 is really the size-based blit classification the plan
already condemns (#6 in its own table), and slice 2's rung 3 —
"addressed **by identity**, never by size or shape guessing" — is aimed
at exactly the right thing. Michelle's description just points at the
wrong control.

### 6. Unknown-creator / open-with modal renders nothing at all — **NOT REPRODUCED; I could not force one**

I did not manage to raise an unknown-creator dialog on this machine, so
the specific claim is untested. What the run does show is that a modal
raised from the desktop (verdict 3) **does** enter the scene, with 13
items and refs, and does render. That weakens the "a whole window class
never arrives" hypothesis a little and strengthens "it arrives with
unreadable contents", but only for the class I could force. Slice 3's
diagnosis should start by finding a reliable way to raise the
unknown-creator alert — a document with a garbage creator dropped on the
volume would do it — because until one exists this row cannot be scored
either way.

## What this sweep could NOT measure, and why

- **The live app's own pixels.** Every "Mirror pixels" view here is a
  render of a capture. I never photographed the running Mirror window.
  That is the gap that keeps verdict 1 open, and closing it needs either
  a screen capture of the app or an agent-side frame export.
- **Finder list and button views' renders** — the rig deviation above.
- **The desktop as a rendered picture.** Same limit sweep B named: no
  sweep scene carries `desktopItems`, so no sweep render can draw them.
  The live surface *does* publish 19 desktop icons, which is progress on
  the capture side and no help on the render side.
- **Whether any of this behaves on metal.** Nothing here touched the
  PowerBook.
- **Date & Time's stability**, voided by the leftover modal.

## Callouts the rubric has no row for

- **Pointer titles are not a Memory problem, they are everywhere.** Sweep
  B found them in Memory (21). This run finds them in **every control
  panel swept**: Date & Time 6, General Controls 7, Monitors 13, Mouse 12,
  Memory 21, Energy Saver 1, Set Time Zone 5, Mail's modal 2. And in the
  **menu bar** — the application-switcher menu's own title is
  `'\x01\x1f@"Ï'`. Slice 4 is priced accordingly: this is not a
  one-window fix.
- **Out-of-port rects likewise**: Memory 18, Energy Saver 2 (`l = 16584`,
  `l = 16504` — the same `16xxx` family sweep B named).
- **A great many controls have no title at all**: Mouse 37 of 38,
  Sherlock 20 of 24, Monitors 13 of 18, Memory 26 of 44. An untitled,
  unkinded control is addressable and unnameable, which is drivable in
  theory and useless in practice.
- **NOW's own sidebar icons are absent** in this run's render, where
  sweep B reported them drawing "as icon stubs at their true positions".
  Same asset pack. Not chased — flagged as a possible regression between
  `cea30543` and `495d10f1`, and cheap for sweep B to settle.
- **Monitors remains the pure capture-side hole.** 17 records total, none
  on its own window port, twice — exactly as sweep A described in July.
  Its interior renders as hatch with three pointer-byte strings.
- **The help "?" button renders as a small empty plate** in Date & Time,
  Appearance, Energy Saver, General Controls and Monitors — five for five.
- **The sweep's own hygiene**: `--quit-after` does not close a modal a
  control panel opened. One dialog contaminated every later health check
  and voided one stability row. Fix before sweep B.

## What I would tell slice 1

The plan's premise is that instability is the top problem. On this
evidence the composed still frame is *already* stable, and the three
things actually costing the most are, in order:

1. **The Finder's interior is a full-window hatch** — the single largest
   visible failure in the sweep, and it is a ladder/join problem on data
   the host already has.
2. **Nothing inside a Finder window can be selected** — no refs, and
   rects from the wrong view.
3. **Pointer titles in every panel**, which corrupt both the render and
   every measurement taken over it.

None of those is an epoch-coherence problem. Slice 1 may still be right —
`baseComplete` never reaching `true` is a real and unexplained signal —
but the sweep does not support ordering it ahead of slices 2 and 4.
That is the A side's job: to say so before the work starts.
