# The content join: what the guest emits, what the host decodes, what joins

Lane `audit/content-join`, 2026-08-01. Acceptance row 1 of the upstream
audit — *"it didn't even draw window content."*

**Nothing in this document has run on a Macintosh.** Neither has the plane it
describes: `qdtrace.h`'s own header says so, and upstream's `verb_qdtrace`
shipped a count-only M0 that never exercised a ring. Everything below is read
off source and verified by a host `swift build` plus unit tests. Where a
number appears it cites the file that defines it.

## 1. What the guest emits

`now-guest-ppc/src/content/qdtrace_json.c`, `drain_sink()`. Every record is a
JSON object inside `output.qdtrace.ops[]`.

Always present, on every record (`qdtrace_json.c:271`):

| key | shape | source |
|---|---|---|
| `op` | string | `op_name()` — `text line rect rrect oval arc poly rgn bits comment state unknown` |
| `port` | string `"0x%08lx"` | the record header's `CGrafPtr`. `content_table.h:239` calls it *"the window identity key"* |
| `ticks` | number | `TickCount` at capture |

Then exactly one payload shape, selected by `op`:

| op | keys |
|---|---|
| *(payload unreadable, any op)* | `detail: false` and nothing else |
| `text` | `pen:[h,v]` `font` `size` `face` `len` `fullLen` `trunc`(bool) `text`(string) |
| `line` | `from:[h,v]` `to:[h,v]` `pen:[pnH,pnV]` |
| `rect` `rrect` `oval` `arc` `poly` `rgn` | `verb` `rect:[l,t,r,b]` `ext:[e1,e2]` |
| `bits` | `src:[l,t,r,b]` `dst:[l,t,r,b]` `mode` `srcRowBytes` |
| `state` kind `clip` | `kind:"clip"` `rect:[l,t,r,b]` |
| `state` kind `origin` | `kind:"origin"` `origin:[h,v]` |
| `state` kind `fg`/`bg` | `kind:"fg"\|"bg"` `rgb:[r,g,b]` (0–65535, printed unsigned) |
| `comment`, `unknown` | `detail: false` (the emitter's `default:` arm) |

The drain tail, after `ops[]` (`qdtrace_json.c:457`): `cursor` `nextCursor`
`writeCursor` `pending` `records` `wraps` `more` `resync` `torn` `busy`
`lostBytes` `dropped`. Four booleans, four different reasons an answer is
short, and that file exists to keep them apart.

Coordinates are **port-local** — window content space. A `state`/`origin`
record shifts them; `content_table.h:229` defines `a,b` as the port origin.

## 2. What the host decodes

`now-host/Sources/MirrorKit/DisplayOp.swift`, `init?(fetched:)`. It reads:
`op ticks text pen font size face verb rect ext from to kind origin rgb src
dst`.

The vocabularies are nearly identical — the port kept the key names. What
the host does **not** read: `port`, `len`, `fullLen`, `trunc`, `mode`,
`srcRowBytes`, `detail`.

## 3. Where they disagree

Three real disagreements, all handled host-side in `QDTraceDecode.swift`
because this lane does not touch the guest wire format.

1. **`pen` means two different things.** `DisplayOp.pen` is documented
   `// [h, v]` and `DisplayReplay` uses it as a text baseline position. For a
   `line` record the guest's `pen` is `pn_h, pn_v` — the **pen size**
   (`content_table.h:251`, `NowContentLinePayload`), not a location. Nothing
   is mis-drawn today only because `DisplayReplay`'s line branch never reads
   `pen`. The decoder therefore **drops `pen` on `line` records** and carries
   it as `penSize` on the record wrapper. A size sitting in a field named for
   a position is a trap with a fuse in it.
2. **`detail: false` has no host field.** Such a record is a fact — *an op
   happened and we could not read its detail* — and the guest emitter says so
   in a comment. The decoder keeps the record (op/port/ticks) and counts it in
   `detailless`, so a summary can say how much of the traffic arrived blind.
   It does not invent geometry for it.
3. **`trunc`/`fullLen` are dropped, deliberately.** A truncated run
   (`kNowContentTextMax` bytes) draws as the bytes that arrived. The decoder
   counts truncated runs in `truncatedText` rather than silently rendering a
   short string as a whole one.

Ops the *renderer* will not draw are counted, not dropped silently:
`DisplayReplay` handles `state` (origin/fg), `text`, `line`, and
`rect`/`rrect`/`oval` at verbs 0/1/4. Everything else — `arc` `poly` `rgn`
`bits` `comment`, `state`/`clip`, `state`/`bg`, and the erase/invert verbs —
reaches the renderer and is skipped there. `QDTraceDrain.undrawn` is that
census.

## 4. The two gaps that are refusals, not omissions

### 4a. There is no A5 on the wire, so the host cannot arm the plane

`qdtrace start` **requires** `a5` and refuses zero by name (`qdtrace_cmd.c:217`,
error `no-target`: *"there is no arm-everything"*). The A5 exists in the
extension's anchor table (`contract/peek_table.h:447`, `NowPeekU32 a5;`) — and
**no NOW command emits it.** `observe`/`axsnap`'s process head
(`observe.c:337`) emits `name signature serialHi serialLo front bind
stampTicks`, and the scene emits a PSN. Neither is an A5.

Consequence, stated plainly: **this host can drain the ring and cannot start
it.** Until a guest verb reports the front process's A5 — or `qdtrace start`
grows a `front: true` target selector that resolves the A5 in the guest, where
it is already known — a drain returns zero records on a machine nobody armed
by hand. The join built in this lane is correct and will be empty.

This is refused rather than papered over. The alternatives considered and
rejected: guessing an A5 from a PSN (there is no relation between them);
arming everything (the guest refuses it by name and is right to); reading A5
through `peek` (NOW's peek surface does not expose the anchor table, and
inventing a below-the-line read to feed an above-the-line join is the wrong
door).

`MirrorContentJoin.armGap` is that refusal written into the code, so the pane
has a sentence to show instead of an empty content rect.

### 4b. `port` is the window identity key and the scene has no port

The record header's `port` is a `CGrafPtr`, and `content_table.h` calls it the
window identity key. A `Scene.Window.id` is `"<psn>/<title>#<z>"`
(`scene_build.c:197`) and carries no pointer. **There is no field common to
the two planes.** Coordinates cannot bridge it either: ops are port-local and
carry no global anchor, so a port's records cannot be matched against a
window's global rect.

So the join attaches ops to the front window under **one stated rule**, in
`MirrorContentJoin`:

- the drain's records resolve to **exactly one distinct `port`** → those ops
  attach to the front window (`Scene.Window.front == true`);
- **more than one port** → nothing attaches, and the join answers
  `.ambiguous(ports:)`. Two ports drew and the host cannot say which is which;
  picking one would be a coin flip presented as a mirror.
- **zero records** → nothing attaches, `.empty`.

The single-port case is a *rule*, not a measurement. It is sound in the sense
that `qdtrace start` arms **one A5 world**, i.e. one application; it will need
re-examining the first time a real drain is watched, because an application
that draws into its own offscreen `GWorld` produces a second port that is not
a window at all.

## 5. A transport note that is not a gap but will bite

`GuestListener.runCommand` takes `args: [String: String]` — every argument
reaches the guest as a JSON **string**. `qdtrace`'s `cursor` and `a5` are
parsed as strings by design (`qdtrace_cmd.c:84`, `parse_u32`, because a 32-bit
`long` cannot hold `0x80000000` signed). But `maxBytes`, `maxRecords` and
`ttlTicks` go through `now_json_find_int`, which is `strtol` on the raw value
(`json.c:58`); handed `"4096"` it reads the opening quote and returns 0.

So from this host those three are **unsettable** and fall back to their
defaults — `0` for the two drain budgets, which means "the whole ring" bounded
by the guest's 4096-byte output frame. That is the behaviour the join wants
anyway, so this lane sends neither. It is written down because the day someone
needs a real `maxRecords` it will look like the guest ignoring it.

## 6. Transport posture

One control command per join, issued **on ask** — the person's refresh button
or an act's follow-up scene, the same two triggers `fetchScene` already has.
No timer, no polling loop of its own, and it is a `command.request` rather
than a transfer, so it does not take the one bulk lane
(`qdtrace.h`: *"a drain is a bounded control answer, not a transfer"*).
`MirrorContentJoin` holds the cursor between joins so a second join reads
forward instead of re-reading the ring.

## 7. What was changed

- `MirrorKit/QDTraceDecode.swift` — new. The decoder: qdtrace drain JSON →
  `[QDTraceDrain.Record]` (port + op) plus the accounting and the honesty
  census. Pure, Foundation-only, no wire types, no Toolbox knowledge.
- `Host/MirrorContentJoin.swift` — new. The join: one drain command, the
  port rule above, ops onto the front window, and the A5 refusal.
- `Host/MirrorSceneAdapter.swift` — the false comment corrected. NOW *does*
  model a content plane; it is a separate command, not a key on the scene
  document, and `display: nil` there means "the scene document carried none",
  which is true.
- `Tests/MirrorKitTests/QDTraceDecodeTests.swift` — the decoder against
  literal JSON transcribed from `qdtrace_json.c`'s `snprintf` templates, not
  produced by the decoder.
- `Tests/HostTests/MirrorContentJoinTests.swift` — the port rule and the
  refusals.

## 8. What was actually verified, and what was not

- `swift build` and `swift build --build-tests` are green for the whole
  package (pre-existing Swift-6 concurrency warnings only).
- `QDTraceDecode` was **executed** against the literal guest JSON above — the
  MirrorKit sources compiled with `swiftc` into a scratch binary that
  exercises the decoder directly. Nineteen assertions, all green: the
  `line`-`pen` demotion, the `detail: false` census, `state/bg` and `arc`
  landing in `undrawn`, first-seen port order, `65535` surviving as unsigned,
  `torn` delivering nothing, a `status` reply not reading as a drain, and
  malformed records being skipped rather than counted.
- **The XCTest suites were not run.** This lane is one of nine sharing a Mac
  and only one `swift test` may run at a time; the orchestrator runs the gate
  (`scripts/test-all`) centrally. `QDTraceDecodeTests` and
  `MirrorContentJoinTests` compile; whether every assertion in them passes is
  the central gate's answer, not this lane's.
- **Nothing ran on a Macintosh, real or emulated.** No guest was built, no VM
  was booted, no drain was watched. The claim this lane makes is that the two
  halves now speak the same vocabulary *as written in their sources*.

`corpus_impact`: none from this lane directly. The durable claims here — no A5
on the wire, `port` is not a scene key — belong in a `data/findings/` row, and
this nested repo has no `data/` tree; the lane report hands them to the
orchestrator rather than inventing a corpus here.
