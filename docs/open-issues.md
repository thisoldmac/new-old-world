# Open issues

Things known to be wrong, unfinished, or unverified, with enough detail
to pick any one of them up cold. Nothing here is being worked on right
now; each is parked deliberately.

The distinction that matters in this list is **broken** (it does the
wrong thing) versus **unverified** (it may well be right, but no one has
watched it work on the PowerBook). Unverified is not a lesser problem —
several of tonight's bugs lived in code that looked obviously correct.

**Nothing on this page is corrected by editing it.** A claim that has
stopped being true gets a dated line saying so, under the entry that made
it. The history is the point: several entries here are worth more for the
shape of the mistake than for the fix.

## UNVERIFIED: P4 publishes nothing, and the reason named for it was wrong (2026-08-05)

**The symptom stands; the diagnosis attached to it does not.** A human drive on
2026-08-04 (guest `a4a59d37d100`, resident `67d5ef43`) found
`now_mirror_lifecycle` reporting **interaction generation 0** while structure sat
at 613025 and content at 1522260, and not one act settling `confirmed` in eight
minutes. That is real and still open.

The reason recorded alongside it was that the host's requested plane mask "flaps
between 7 and 15" with "the interaction bit (8) clear", pointing the repair at
`MirrorControlModel.requestedPlaneIDs`, `MirrorPlanePolicyStore`, and the arming
path. **That reading is wrong, and it points away from the defect.**
`contract/peek_table.h` states the bits once:

    kNowPeekTableCapAnchors = 1u << 0   P1
    kNowPeekTableCapTree    = 1u << 1   P2
    kNowPeekTableCapAct     = 1u << 2   P4   <- the act plane, BELOW P3
    kNowPeekTableCapContent = 1u << 3   P3

P4 sits below P3 because P3 asked for `1u << 2` while P4 already held it — the
near-miss recorded under "Two planes asked for the same bit" (2026-07-31). So
`cap=15 requested=7 active=7` says P4 **was requested and active**; the bit clear
in 7 is P3, whose request is a bounded lease by design
(`now_peek_claim_until`, from `qdtrace_cmd.c`), which is exactly what a mask
expiring and being reclaimed looks like. Host plane policy is not implicated by
that line. `now-guest-ppc/tests/peek_table_test.c` now pins each bit's value, so
the same misreading fails a gate rather than an evening.

**Where the defect actually has to be.** `mirror_probe.c :: plane_generation`
returns, for P4, `table->act_v2.resident_generation`. That word is written in
exactly one place — `now-guest-shared/src/now_act_guard.c`, where
`v2_echo_request` bumps it twice and `now_act_v2_note` bumps it twice per stage —
and both are reached only through `now_act_v2_begin`. Generation 0 therefore
means **`now_act_v2_begin` returned early on every act of the drive**, and it has
only three early exits:

- `now_act_plane_state(table) != kNowActPlaneReady` (length, caps or act_format),
- `cell->status != kNowPeekActStatusPending`,
- `cell->target_a5 != current_a5` — by design, since only the target process's
  own pump may proceed.

Which one is unproven. Note that arming is *not* a candidate: the same log line
that opened this arc shows the plane armed and active.

**A rig warning that cost this session its measurement.**
`/private/tmp/now-u7-extension-only/session.qcow2` carries the NOW Extension in
its file system, but its internal snapshots predate it: resuming
`--loadvm runner-ready` (a 2026-07-19 state) gives a guest reporting
`lifecycle=absent`, `cap=-`, which reads exactly like a dead P4 on a machine that
simply has no resident. Cold-boot it. Cold-booted here it still reported
`absent` while `stat` showed `NOW Extension` present with type `INIT` and creator
`NOWx` — the combination `scan_extensions_folder` is supposed to make impossible.
That contradiction is unexplained and is the next thing to pull on; until it is,
this template cannot demonstrate P4 either way.

## CYCLE 27 RETAINED-STATE CHECKPOINT; TWO ADVANCES, TWO BLOCKERS (2026-08-04)

The exact `d0a3e1a` host was driven through native Mirror mouse input and
compared with the explicitly identified QMP framebuffer oracle. Before that
drive, `scripts/test-all` passed 103 native tests, the PowerPC, 68K, and NOW
Extension cross-builds with their real Retro68 toolchains, and the full host
gate. This is tested and emulator-observed, not metal-verified and not a green
Mirror sweep.

Two earlier red cases advanced. Macintosh HD now opens with its item roster in
the first settled Finder scene instead of remaining blank until an unrelated
action. Key Caps now launches through a typed guest-Finder operation and comes
frontmost. Workshop resize and close also continued to mutate both surfaces,
and Workshop's structured content no longer disappeared during the observed
poll sequence.

Two blocking families remain. `Hide Finder` timed out without changing the
authoritative guest and produced no visibility-action line in the host log;
the retained visibility census correctly refused to confirm it, but dispatch
and observability are still broken. Key Caps is a successful launch with a
completely empty Mirror body: QMP shows the full keyboard while Mirror shows a
hatched unavailable region. That application has no standard controls, so its
draw-owned content needs an explicit structured placeholder until deferred
pixel transport is undertaken. Finder fidelity also remains partial, and
Sherlock was not re-driven in this continuation.

The apparent Apple-row count changed with the front application: NOW-front
began at AirPort, while Finder-front additionally exposed `About This
Computer`. Do not treat that contextual difference as destructive row loss
without an authoritative same-context comparison. Strict C27 rows remain
blocked because the captures do not include the complete correlated
operation/settlement/host-log/guest-log manifest. Exact identities, evidence
paths, and the bounded verdict are in
`docs/mirror-retained-planes-checkpoint-2026-08-04.md`.

## CYCLE 26 HIGH-WATER CHECKPOINT; APPLE REPAIRED, STATE MODEL OPEN (2026-08-04)

The exact C26 native host was driven through its Mirror and compared with QMP
guest captures. A later scene's empty Apple shell no longer erases complete
same-guest rows: the host retains only previously observed guest rows, keeps
the newest identity/geometry, marks the projection `expected-stale`, and never
invents an initial menu. The regression guard was watched fail under mutation
and pass after restoration. The full native/host gate passes; the cross-guest
build step skipped because Retro68 was unavailable on this shell path. This is
tested and emulator-observed, not metal-verified.

The direct sweep also fixes the verdict on several earlier reports. Macintosh
HD opens from Mirror input and Finder contents render. Date & Time opens, Set
Time Zone appears within 25 seconds, and Cancel works. Their fidelity remains
red: Date & Time lacks authoritative field values and explanatory text, and
the modal's guest city/country rows are blank in Mirror. Workshop structure
renders but its authoritative detail content is blank after the content ring
reports earlier bytes overwritten. Hide Finder briefly removes then restores
the window without changing the front application. `Windows > Workshop` is
refused because the guest never calls `MenuSelect`, so the window does not
reopen.

C26 is paused rather than falsely scored green: the strict evidence manifests
were not complete for every row. The durable build identities, direct sweep,
act-log evidence, paired images, and resume instructions are in
`docs/mirror-high-water-checkpoint-2026-08-04.md`. This checkpoint is the floor
for the host state-engine plan; no later implementation may trade these passes
for progress elsewhere.

### STATE ENGINE U7 READ PARITY BUILT; LIVE STAGING STILL OPEN (2026-08-04)

The native Mirror and MCP now have one state owner rather than parallel
observers. Local protocol v9 exposes status, snapshot, find, and wait as four
read-only projections over the existing session-pinned engine. They carry the
same snapshot ID, digest, stable process/window identities, freshness,
coverage, and generation counters the native renderer/evidence path reads.
Find is locally bounded and wait observes publication without polling the
guest or creating another cache.

Seven focused service/projection/codec tests pass. The derived MCP coverage
gate was watched failing because all four newly registered tools were absent
from `docs/mcp-coverage.md`, then passed after the rows were documented. This
is **tested, not yet live-parity verified**: the running host predates protocol
v9 and the development VM still has a stale guest application despite the
current NOW Extension.

**Later 2026-08-04 runtime correction:** protocol v9 was exercised through the
exact newly built Host and `now_mirror_status` returned the live engine's guest,
session, snapshot ID, sequence, digest, completeness, and both generations.
That proves the socket/read projection is live, but not whole-surface parity.
The first direct U8 preflight remained red: the cold Mirror acquired only a
desktop shell until the first Apple-menu click; that click recovered six
windows, but Finder and Date & Time content was blank/placeholder, the Apple
menu had no rows, and both `Windows > Workshop` and Application-menu Finder
selection refused because the displayed compatibility entities lacked stable
guest identities. The exact current extension file was then staged, but the
current guest application could not overwrite its running predecessor
(`create err -48`). The scoped Worker refuses both targeted quit and scripted
shutdown, so the image is explicitly **partially staged and not clean-saved**
until the visible app is quit and the full app/extension pair is cold-booted.

Two items remain explicitly deferred. The old `now_observe_elements` call
cannot be removed until the state engine owns structured control elements and
their capability references; removing it now would make the existing act rows
unaddressable. MCP mutation parity also remains off until a direct native
equivalent is proven against the exact staged guest. Neither API reach nor MCP
success can satisfy a direct-input/pixel gate.

### STRUCTURED LIST CONTENT PRESERVED; BROAD PANEL FIDELITY STILL RED (2026-08-04)

The Date & Time city/country failure was not an absent guest capability. The
NOW Extension already returned every List Manager cell as bounded row, column,
text, and selection records, but the application bridge collapsed the answer
to selected text before scene publication. The renderer then compounded the
loss by giving an unclassified DITL resource-control shell precedence over the
same live control after P2 had classified it as a list. The scene contract now
retains bounded `listCells` plus the guest's total count, marks the payload
complete only when every reported record is valid and present, and lets a
classified semantic control supersede only its matching unknown resource
shell. Focused native, IR decode/freeze, and renderer tests pass, and both PPC
guests plus the extension cross-build with the real Retro68 toolchains.

This is **built and tested, not emulator-verified**. The running VM disconnected
before the rebuilt extension could be cold-loaded, so no direct Mirror drive,
authoritative guest capture, or pixel comparison has yet proven the city and
country rows. Set Time Zone is currently known to be a titled Dialog Manager
window (`kind == 2`) with DITL items and stacking; the scene does not prove
whether the application is inside `ModalDialog`, so the host must not invent a
stronger alert/modal-loop claim.

The wider application/control-panel content problem remains red. P3
deliberately refuses to replace an application's existing custom QuickDraw
`grafProcs`; that is a safety boundary, not evidence that a blank interior is
acceptable. The next cold-boot sweep must collect multiple application and
control-panel surfaces in one pass, separating structured P2/DITL content,
settled P3 replay, and explicit unavailable placeholders before another shared
producer/renderer patch. A guest-side action performed outside the Mirror while
the connection was failing also demonstrated the expected-stale case: retained
same-session state is useful for continuity but must not be driven or scored as
current.

The same session ended with the guest showing the system bomb dialog
`“Finder” error type 10` after an earlier alert was dismissed, before reaching
a black powered-down framebuffer. The host log proves only that its Special >
Shut Down menu action was dispatched and the guest disconnected one second
later; it does not attribute the Finder crash to that action, P3, or the
unbooted list patch. Treat this as a blocking crash sentinel for the next cold
boot: record the resident extension identity, arm content conservatively, and
stop the sweep if Finder faults again.

**Later 2026-08-04 live correction:** the rebuilt extension and application
were cold-loaded, and a coherent QEMU memory sample reached the exact Set Time
Zone list control. The extension's `NWpt` semantic cell completed that request
as `UnsupportedCustom`; it did not return the city/country cells. The earlier
bridge-collapse diagnosis came from unit fixtures and is valid coverage for a
standard list, but it was not the live cause of this panel's blank rows. The
current guest classifier rejects any list box with a nonzero LDEF before
asking for its ListHandle. The generic, metal-compatible next step is to prove
the public List Manager backing record and widen the extension producer under
validated invariants, not special-case Date & Time or introduce pixels. The
read-only dev method and exact observed records are in
`docs/qemu-memory-oracle.md`.

The same run broadened the next batch before another extension rebuild.
Date & Time's base window has 20 DITL items and 21 controls but loses multiple
structured values and status strings. Sherlock has 35 live controls spanning
standard, edit, list-like, and application-defined definitions while its
Mirror is mostly structural shells. Key Caps has two windows and no controls
at all, so its missing keyboard is draw-owned and belongs to the explicit
placeholder/deferred-pixels path rather than the control-semantic patch. The
extension work remains open until the Date & Time and Sherlock control classes
are inventoried and patched together.

**Later 2026-08-04 implementation checkpoint:** P2 format v2 now classifies
Apple-owned controls through public `kControlKindTag`, reads bounded clock/text
values through public data tags, permits a public list-box ListHandle with a
nonzero drawing LDEF, offers every live control, and retains 64 compact class
facts plus four bounded list payloads. Sherlock's 35-control census therefore
cannot restart after eight entries, and typed-but-undecoded data browsers/user
panes/image wells produce explicit bounded placeholders. Key Caps remains the
separate zero-control, draw-owned placeholder case. Focused native/renderer
tests pass, the new placeholder guard was watched fail under mutation, and the
PPC, 68K, and flat-INIT Retro68 cross-builds pass. This is **built and tested,
not emulator-verified** until the new INIT is cold-loaded and the broad direct
Mirror sweep is repeated.

**Cold-load result:** the broad direct-input sweep is still red. Set Time Zone
and Sherlock retain bitmap-unavailable regions; the latter's newest settled P3
generation contains only its final CopyBits blit, so renderer ordering alone
cannot recover its structured controls. A paired state-engine/QEMU sample
showed Date & Time as the fresh front process while the live P2 request kept
naming one Finder control and the last completed response remained an older
`UnsupportedCustom` Date & Time base-control answer. The sample did not reach
the exact Set Time Zone list, so it neither verifies nor refutes the public
list-kind hypothesis and does not alone justify a scheduler rewrite. The
renderer now keeps unavailable CopyBits geometry behind structured ops and
lets a typed incomplete list suppress only its unknown DITL shell; both tests
were mutation-watched, but neither row is green without current P2 data.

A generic follow-up is now built and staged: a custom-signature control may
prove that it is List Manager-backed by successfully returning the public
`kControlListBoxListHandleTag` with the exact handle size. Apple-owned
non-lists are not probed, and a declined/malformed custom result stays
explicitly unsupported or invalid. The native semantic slice and real 68K
guest/flat-INIT cross-build pass; deleting the fallback fails its source guard.
The running VM still contains the prior resident code until a clean cold
reboot, so no UX claim has changed yet.

### STATE ENGINE U1A: TYPED COVERAGE AND LIFETIME IDENTITY BUILT (2026-08-04)

The IR v2 producer and MirrorKit consumer now agree on typed collection
coverage and durable process/window incarnation fields. Process census,
per-process window membership, and front-menubar coverage reach the wire as
`complete`, `partial`, `retracted`, `failed`, `stale`, or `unavailable` rather
than requiring a reducer to parse English diagnostics. The normative rule is
now explicit: only fresh complete parent coverage may prove deletion; weaker
coverage retains compatible state expected-stale and inert.

Native `scene_json_test`, MirrorKit IR-freeze tests, and host scene decode tests
pass. The test was first observed failing on both sides before the contract was
implemented. The cross-guest build gate skipped because Retro68 was unavailable
on this shell path, so this checkpoint is **tested, not guest-built and not
emulator-verified**. U1 remains open for exact Finder-item and application
visibility capability identities plus forced collector-exit coverage guards;
those must not be replaced with title/name matching merely to advance U2.

### STATE ENGINE U2A: PURE RECONCILIATION AND SETTLEMENT BUILT (2026-08-04)

MirrorKit now has session/process/window identities, an ordered scene
observation, a pure replica reducer, immutable projection metadata and semantic
digest, tombstones, and a separate pure operation reducer. Incomplete absence
retains compatible entities expected-stale, non-frontmost, and inert; only an
exact complete parent scope deletes. A complete process census plus complete
window membership for every process is the base-acquisition barrier. IR v1 is
still displayable but cannot enter durable maps or authorize deletion/action.

Fourteen focused reducer tests pass. A deliberate mutation that treated any
process coverage claim as complete made the background-retention test fail by
deleting New Old World, then the correct predicate was restored. The broader
MirrorKit suite is **not green**: seven historical fixtures compare current-v2
builder output with v1-stamped golden scenes. That pre-existing version
expectation is recorded rather than hidden or repaired inside this state slice.

This is still additive pure state, not visible Mirror behavior. Host shadow
plumbing, full producer coverage, content generations, bounded history,
capability-safe Finder/app actions, direct-input pixels, guest build, and VM
staging remain open. The implementation contract and limits are in
`docs/mirror-state-engine.md`.

### STATE ENGINE U3A: SESSION-PINNED SHADOW ENGINE WIRED (2026-08-04)

The host now keeps one shadow engine per exact `GuestKey` connection session,
publishes accepted projections into a bounded 32-snapshot/15-minute history,
and records bounded semantic differences against the still-visible legacy
scene. `NOWMirrorSource` pins the session it started on and sends structural
polls to that exact socket even after the active picker changes. Responses from
another session are ignored, and a second scene caller is refused instead of
silently replacing the first completion.

The old action and content paths remain active-session-only. This checkpoint
therefore pauses them and visibly refuses gestures whenever the selected Mac is
not the Mirror's pinned Mac; shadow state never authorizes mutation. A delayed
stop callback also cannot clear a newer Mirror binding. This is an honest
safety boundary, not the final addressed operation broker.

Five focused engine tests, the addressed two-guest polling test, and all 21
existing `NOWMirrorSourceTests` pass. The live C26 Mirror/VM were deliberately
not touched during this plumbing checkpoint. Full direct mouse/keyboard
preflight, shadow parity across Workshop/Finder/Date & Time, structured-content
and Finder enrichment reduction, native read cutover, guest build, and VM
staging remain open. The visible product is still the C26 legacy projection and
must not be described as state-engine-driven yet.

### STATE ENGINE U4A: ASYNC RENDER ENRICHMENT AND FRAME EXPORT BUILT (2026-08-04)

Settled QuickDraw content, cached Finder window items, and desktop items now
converge through the shadow engine after their exact structural sequence. The
pure enrichment path changes render-bearing fields only, requires the same
process/window incarnations and geometry, ignores stale sequences, and does not
publish semantic no-ops. Engine snapshots now expose stable structural and
content generations independently.

The native Mirror window also has an app-owned evidence export that pairs its
PNG with the full decoded engine scene, exact snapshot identity, guest/session,
sequence, digest, base completeness, and both generations. It refuses if the
visible legacy scene differs from shadow state or if the snapshot changes while
AppKit captures the frame. This is only the Mirror/state member of the strict
gate; it does not replace direct keyboard/mouse provenance, authoritative guest
capture, operation/settlement, or logs.

Ten focused engine/export tests plus nine content-plane and 21 Mirror-source
tests pass. The stale-enrichment guard was watched fail under mutation, then
restored. Guest-authored content epoch/generation metadata, typed
Finder/content coverage, the QMP-only oracle target split, live direct parity,
and visible read cutover remain open, so this is a **tested shadow checkpoint**,
not emulator-verified product behavior.

### STATE ENGINE U4B: EXECUTABLE QMP CODE IS ORACLE-ONLY (2026-08-04)

The QMP socket client, QMP-capable action dispatcher, and legacy live polling
controller now live in a separate `MirrorOracleKit` SwiftPM product.
`MirrorApp` opts into that development target; production NOW Host still links
only `MirrorKit` and `MirrorKitUI`. The Host app builds without the oracle
product, its binary contains none of the QMP handshake/dispatcher markers, two
host tests guard the manifest/source boundary, and the standalone legacy
MirrorApp still builds.

This is not yet the whole U4 cleanup: historical QMP-named action cases,
availability fields, and `MirrorTarget.qmp` remain in core data types even
though their executable behavior no longer links into NOW Host. Those types
must become platform-neutral or oracle-owned before U4 is complete. No live VM
or Mirror was touched, and this checkpoint changes no visible projection.

### STATE ENGINE U4C: PRODUCTION ACTION MODEL IS ORACLE-NEUTRAL (2026-08-04)

The remaining development-oracle vocabulary has been removed from production
state and action types. `MirrorTarget` now identifies only the guest wire and
machine. Positioned press, double-click, drag, menu tracking, and thumb
tracking are platform-neutral device actions behind `ActionPlanes.inputDevice`;
the optional QMP socket and its availability decision live in
`MirrorOracleKit`. `LiveMirrorController` exposes the adapter's actual planes,
so a development launch without a socket no longer advertises device tracking
that its dispatcher will refuse.

Sixty-one focused Mirror action/hit/Finder/scroll tests and 24 NOW source and
oracle-boundary tests pass. Both `MirrorApp` and production `Host` build, and
the Host binary contains none of the QMP client markers. The new model-source
guard was mutation-watched: adding a QMP sentinel to `ActionModel.swift`
failed the named test, and restoring the boundary passed it.

This is a **tested architecture checkpoint**, not visible or emulator-verified
progress. U4 still needs producer-owned content epochs, strict full-manifest
gate tooling, and live shadow parity; U5 read cutover, FIFO mutation, the
direct native input/pixel campaign, guest build, and staged VM remain open.
The live C26 Mirror and VM were deliberately left untouched.

### STATE ENGINE U4D: ORACLE CAPTURES ARE EXPLICIT AND IDENTITY-BOUND (2026-08-04)

`tools/shot` no longer guesses the newest `run/*/qmp.sock`. Each framebuffer
capture requires an explicit socket and a versioned oracle-identity artifact
that names the guest, exact connection session, guest build, QEMU VM name, and
socket. The helper verifies QMP `query-name` before `screendump` and emits a
capture sidecar with the same identity and capture timestamp.

The UX evidence gate requires that sidecar, joins its guest/session to the
engine state artifact, and rejects wrong build, VM, socket, frame, timestamp,
or missing sidecar. QMP remains observation-only; none of this supplies input
provenance. Twenty-eight scored-evidence tests and five shot-helper tests pass.
The socket-discovery guard was mutation-watched: restoring an implicit `find`
path failed the named test, then the explicit refusal was restored.

This is a **tested tooling checkpoint**, not a direct sweep. The operator still
has to create the identity artifact from the pinned live session, and a scored
row still needs native Mirror keyboard/mouse input, Mirror pixels, state,
operation settlement, both logs, stable generations, and human visual review.
The retained VM and Mirror were not touched.

### STATE ENGINE U4E: OVERWRITTEN CONTENT RETAINS THE LAST SETTLED DISPLAY (2026-08-04)

The content plane no longer clears a window's settled display when the guest
draw ring resyncs or reports overwritten bytes. It discards only the incomplete
accumulator and records the current guest `displayEpoch`/`generation` as a
replacement floor. Further records from that damaged generation are ignored;
only a strictly newer guest-authored epoch or generation may build a
replacement, and bounded `more` pages still cannot publish half a repaint.

All nine content-plane tests pass. The guard was mutation-watched by restoring
the old `settledOperations.removeAll()` transition: the retained-display test
failed at the resync and same-generation assertions, then passed after the
clear was removed again. This is the code-path repair for the C26 Workshop
blanking report, but it is only **tested**, not yet directly re-driven in the
native Mirror or compared with the guest. That row remains red until the full
sanity preflight and Workshop visual comparison are run on the new build.

### STATE ENGINE U4F: INACTIVE WINDOW CONTENT IS RETAINED, RUNTIME RECHECK OPEN (2026-08-04)

The first direct-input sweep of the U4E build reproduced a second destructive
transition that its ring-overwrite test did not cover. Selecting New Old World
left the Finder window visible but produced a frontless structural observation;
`NOWMirrorContentPlane.join` treated that bounded absence as a deletion and
cleared every settled display. Retargeting another front window also discarded
the accumulator identity used to find the last settled display. The Mirror
therefore oscillated between the Finder's 106 structured draw operations and a
five-operation `Bitmap unavailable` shell.

The content plane now records the last published identity separately from the
in-progress identity for each exact guest process/window slot. Frontless and
retarget observations retain compatible published content as expected-stale;
partial replacement pages keep drawing the settled display until the newer
guest epoch/generation finishes. Retention remains session-bounded and
`guestChanged` still clears it atomically.

Ten content-plane tests and all 21 Mirror-source tests pass. A mutation that
cleared the published identity on a frontless observation made
`testFrontlessObservationRetainsInactiveWindowDisplay` fail with a missing
display, then the correct transition was restored. This checkpoint remains
**tested, not emulator-verified** until the rebuilt host is directly driven
through the complete preflight.

That sweep also recorded action reds rather than hiding them: the Apple menu
and native Application menu rows rendered correctly; selecting New Old World
correctly activated only the application because its Workshop window was
closed, while `Windows > Workshop` failed to reopen it; clicking the inactive
Finder window was refused because the running guest accepted no `select`
window act; Hide Finder and Date & Time open were dispatched but did not
visibly settle. The source tree already carries `winact select`, so the
guest/build mismatch must be resolved by staging and proving the exact latest
extension and guest before treating those runtime results as current
implementation failures.

### STATE ENGINE U4G: ALL FOUR PLANES ARE RETAINED; LIVE REPROJECTION OPEN (2026-08-04)

Plane policy is no longer a destructive filter at the renderer adapters. The
session-pinned engine retains P1 structure in its replica, P2 semantics per
exact process/window/control or dialog-item identity, P3 content per exact
window identity and geometry, and P4 operation history in the same engine's
bounded journal. P1 cannot be disabled. Hiding P2 or P3 recomposes the current
snapshot without those contributions; showing either immediately restores the
cached contribution at the same guest sequence. Disabling P4 still gates
mutation, but policy changes cannot erase previously recorded attempts or
settlements. Evidence arriving while an optional plane is hidden is retained
for the next composition rather than discarded.

Cross-generation QuickDraw retention now belongs to the state owner rather
than `NOWMirrorContentPlane`. The adapter publishes only the newest settled
guest generation. If that generation is bitmap-only, the engine keeps
compatible prior non-bitmap operations—including their QuickDraw `state`
records—as expected-stale structured evidence. This addresses the observed
Sherlock transition where structured controls appeared briefly and were then
replaced by a CopyBits-unavailable overlay; it does not make bitmap pixels part
of the product path or turn Sherlock green by itself.

The focused state-engine, plane-domain, content-plane, and source suites pass.
Two guards were mutation-watched: dropping retained `state` operations fails
the structured-content test, and failing to cancel an old policy-refresh
sleeper fails the single-poll-cadence test. This remains **tested, not
emulator-verified** until the newly built host is directly driven through the
full sanity preflight, its live toggles are exercised, and every assessment is
paired with the authoritative guest capture.

The shipping review caught two lifecycle races before this checkpoint. A
pre-close scene completion could be accepted by a same-guest restart, and a
policy toggle could begin another structural request after scene transfer but
before that scene's content command settled. One run generation now invalidates
late callbacks, one cycle token covers scene plus content, and toggles made in
flight coalesce into one immediate follow-up. Policy lookup is also keyed by
the Mirror's pinned `GuestKey`, so changing the selected Mac cannot reproject
another session. The source tests now hold real scene/content completions and
count requests instead of inspecting source strings. Both lifecycle guards
were mutation-watched; the four focused suites pass 62 tests.

The first direct run of `ccf68a0` is recorded in
`docs/mirror-retained-planes-checkpoint-2026-08-04.md`. P2 and P3 live
reprojection behaved as designed: P3 could be hidden while P1/P2 remained,
P2 could be hidden while retained QuickDraw content remained, and restoring
P2 immediately restored the same semantic generation. The complete sanity
preflight is still red. Finder and Control Panels content arrived only after a
later polling cycle; Hide Finder remained unconfirmed; Date & Time's Finder
item was absent and therefore not actionable from the Mirror; Key Caps did not
launch; and Sherlock's structured content was again overwritten by a later
bitmap-only/invert observation. The last result is direct evidence that the
production renderer path still bypasses or obscures the engine retention that
the focused guard proves. Status is now **host-tested and partially
emulator-observed, not a green sweep and not metal-verified**.

The same sweep exposed a separate outcome-classification defect. Several
actions whose effects later appeared in authoritative pixels or scenes kept an
immediate `act-refused`, `outcome-unknown`, or
`dispatched-but-unconfirmed` label. A transport or resident-act answer is
attempt evidence, not the terminal verdict for the person's composite
operation. A refusal before any dispatch remains terminal; once any part of an
operation may have reached the guest, the operation stays non-green and
eligible for later same-session postcondition evidence. A later complete
authoritative observation may confirm that same operation; it must not erase
the earlier contradictory evidence or be attributed across another queued
operation.

### STATE ENGINE U6A: DIRECT OPERATIONS ARE SERIALIZED; CURRENT VM LACKS LIVE IDENTITY PROOF (2026-08-04)

The first direct-mutation state-engine slice is built and focused-tested. One
session-pinned FIFO now owns modeled native gestures and does not dispatch the
next gesture until the active one confirms or times out. Its operation journal
keeps displayed snapshot/sequence, exact entity, typed postcondition, attempt
reply, and later authoritative outcome separate. A post-dispatch
`act-refused` is therefore contradictory attempt evidence rather than a false
terminal verdict. Late complete scene evidence may confirm it; timeout remains
non-green and can later confirm only while no active retry makes attribution
ambiguous.

The direct run also exposed an unsafe bridge that is now closed. The running VM
can supply a compatibility scene that is drawable while the new replica cannot
mint stable identities for its windows/processes. The initial U6 code quietly
fell back to the legacy dispatcher in that case, recreating the raw
`act-refused` labels the broker was meant to replace. Modeled plans now refuse
before dispatch when identity is unavailable. The VM must be updated with the
current guest and extension before positive broker settlement can be scored.

After correcting two missed Computer Use targets, the live results were:

- Finder was selected first; the exposed `System Folder` title bar resolved to
  that exact second Finder window, but the stale guest refused `winact select`
  and the window did not come front.
- Selecting `New Old World` through the guest Application menu activated NOW
  and did not reopen its closed Workshop, which is correct.
- `Windows > Workshop` is the independent failing operation. It must create a
  named NOW window; the current guest does not call `MenuSelect`, so it remains
  red rather than borrowing success from application activation.

The focused gate currently covers FIFO serialization, contradictory refusal
then confirmation, timeout and late confirmation, same-postcondition retry
ambiguity, exact same-app window identity, Workshop named-window creation, and
the no-legacy-bypass rule. Mutation-checking removal of the FIFO guard made the
two-click test fail. This checkpoint is **tested and directly characterized,
not a green emulator sweep and not metal-verified**.

## CONTRACT FROZEN; UNIFICATION IMPLEMENTATION STILL OPEN (2026-08-03)

The unified NOW Extension prerequisite now starts from a source-derived
retirement ledger rather than the claim that AXPeek/QDPeek/Portal parity can be
remembered. The ordinary native guard derives 66 capability keys from the old
resident shared headers, agent dispatch, service, and staging paths. Each key
has a goal-facing outcome, allowed disposition, and one prerequisite proof
owner. Goal-relevant rows cannot close as a bounded refusal, retained fixture,
or retirement blocker. The older fold roadmap is historical; Mirror completion
plan 001 is blocked until the prerequisite completes and now retains only the
broker, broad renderer/UX, MCP, and later pixel work.

The scored-row gate also now enforces the full correlated evidence boundary.
A pass/fail needs native NOW Mirror keyboard/mouse provenance, Mirror pixels and
snapshot identity, a QMP observation capture within two seconds, decoded state,
plane state, terminal operation settlement, both host and guest logs, no
nonterminal operation, two unchanged pre-capture generation polls, and an
unchanged post-capture generation/owner-epoch reread. The previous gate was
watched accepting manifests without the new plane/settlement/log/quiescence
members; the focused test then failed seven cases before the validator changed.

This is **contract and guard work only**. No resident plane has been unified by
this entry, the focused corpus has not passed, and the development VM has not
yet been replaced with the final exact extension/application pair. Workshop and
menubar geometry remain the regression floor; Apple content, Finder/Date & Time
foreign content, direct controls, and truthful settlement remain red until the
direct-input paired sweep proves them.

### U2 source boundary implemented; resident runtime proof still open

The appended resident ABI now carries deterministic source and embedded build
identities, one canonical New Old World writer lease, named per-capability
owners, extension echo of the accepted owner epoch, and P1 cadence counters.
Content, interaction, scene, and Processes use the same owner union; the
Processes renewal is intentionally in its cooperative `idle()` callback, not
its repaint callback. Native layout, lease, resident-core, and guard tests pass,
and both guest applications plus the extension cross-build with the real
Retro68 toolchains.

That is **tested at the native/source boundary and builds, not emulator-
verified**. The generated INIT payload is about 59 KiB, above the INIT skill's
conservative 32 KiB audit budget (the preceding extension was already in this
size class and loaded on Mac OS 9). A disposable cold boot must still prove the
new exact `NWid` fingerprint, table identity, writer handoff, callback chaining,
and six-tick counters before any runtime row turns green. The stage image still
contains the older resident and must not be used as evidence for this build.

### U3 ABI checkpoint only; semantic resolvers remain red

The R11 evidence review is now durable in `docs/p2-semantic-evidence.md`. It
rejects every fact the bounded P1 reader already proves, rejects non-dialog
TextEdit from v1 because no documented safe root exists, and fixes a 32-record
envelope large enough for the measured 16-row Finder Apple menu. The table has
an appended exact-target P2 cell, explicit refusal/truncation states, and a
volatile generation-checked application copy. Mutation fixtures cover short
tables, stale/wrong identity, partial publication, overflow, resolver-kind
mismatch, and dishonest text completeness.

This is an **incomplete checkpoint**, not P2 behavior. NOW Extension does not
advertise or arm P2 yet. Invalid-handle-safe Control/Resource/List/Menu Manager
resolvers, request publication, scene joining, disabled-P2 degradation, and
the direct Date & Time/Apple UX proof all remain red. The ABI's ability to
represent those facts is not evidence that the guest has produced them.

**Update 2026-08-03: bounded partial P2 behavior is implemented, but the UX
rows remain red.** NOW Extension now advertises the plane and serves exact
standard List Manager state plus exact nonempty menu rows. The application
publishes at most one request per scene, joins only an owner/scene/object match,
retains bounded terminal facts across scenes, and resets them on owner change or
scene regression. Mirror renders a standard list as an explicitly partial,
selected-value-only list surface; it does not invent the unretained rows.
Native mutation fixtures and the real PPC, 68K, and flat-INIT cross-builds cover
this slice.

The Mac OS 9 system-root Apple submenu is still broken. The flat 68K INIT
cannot link the CarbonLib/CFM root-menu calls that expose the child behind the
empty Apple shell, and no undocumented trap or unproven Mixed Mode bridge was
substituted. That exact shell therefore returns `unsupported`. Direct Mirror
input against Date & Time and the Apple menu has not yet proved this partial
plane in the running guest, so neither case is green. The development stage
image also still contains the preceding resident build.

### U4 P3 lifecycle and coherent-redraw path built; runtime proof still red

P3 format v2 now arms one exact A5/window identity instead of every window in
a process. Every retained record carries the echoed PSN, exact A5 and port,
request generation, and resident display epoch. A retarget clears the old live
commit before rewriting any identity word; same-context target changes restore
only a still-live hook that NOW still owns, while dead or foreign-context rows
are forgotten by value and remain strict pass-through. The host joins only the
currently armed front window and rejects old process, window, generation, A5,
or display-epoch records, so pointer reuse cannot overlay a relaunched target.

After installing its exact hook, the resident requests one ordinary update and
does not call the application's draw handler itself. `InvalWindowRect` cannot
link into a flat 68K INIT, so this path uses the classic equivalent inside the
resident only: prove exact WindowList membership and hook ownership, save the
current port, set the target window port, call `InvalRect`, and restore the
saved port. It reports `redrawRequested` only after that sequence and
`redrawServiced` only after a later guest QuickDraw hook. A source-order guard
forbids `BeginUpdate`, `EndUpdate`, direct drawing, CopyBits, or event injection
in the shim.
The Carbon UI lexical audit flags `InvalRect`; that finding is expected for this
flat-INIT compatibility boundary, not waived for Carbon application source.

Native lifecycle/ring tests, the host/MirrorKit join tests, and the actual PPC
application and flat-68K extension cross-builds pass. This is **tested and
builds, not emulator-verified**. No guest has yet proved that a foreign Date &
Time window services the requested update, that target death/relaunch remains
safe at runtime, or that the resulting initial display is coherent. Bitmap and
CopyBits operations still carry only bounded geometry and render as explicit
`Bitmap unavailable` placeholders; no pixel transport was added. The stage
image still contains the preceding extension.

The U4 cross-build produced a 63,978-byte `INIT 128` (64,386-byte resource
fork), so the resident still exceeds the conservative 32 KiB inspection budget
and runtime loading remains a required gate. Its artifact SHA-256 is
`1b5ad7638477d974e71d6852d61ff428ea797d1690a3f4f1dd2b7f72264f9e11`;
the embedded source manifest is `ffe26237 08404b43 c9ae73ce c44e25aa
bb1c11a3` and build fingerprint is `707560f7 d034f202 a01a4a83 faa2c1c4
576c0239`.

### U5 P4 settlement is effect-owned; focused runtime proof remains red

P4 format v2 is appended after the original act cell, so the V1 act bytes and
every P1-P3 offset remain fixed. A request now carries one correlation,
canonical-writer epoch, exact A5 and PSN echo, source scene generation, typed
operation/object identity, and deadline. The resident may advance only its
monotonic requested/accepted/armed/fired/refused/expired evidence for that
tuple. PSN is correlation rather than resident authority: the foreign-context
safety boundary remains the exact A5 plus the operation-specific object guard.

That evidence is deliberately not the outcome. New Old World owns a bounded
16-record settlement history and reconciles a fired action against a later
normal-context scene and an operation-specific postcondition. Timeout remains
recorded if a later scene confirms the effect; writer replacement terminates
open records as session-changed. The host joins by correlation and renders a
checkmark only for `confirmed`. Refused, timed-out, session-changed, unknown,
and dispatched-but-unconfirmed remain visibly non-green. Successful keyboard,
typed-text, and Finder dispatches without a postcondition are explicitly
unconfirmed; activation requires the guest's own front-process reread, and
application visibility requires a Finder visibility reread. Menu acts require
the unique front PSN from the same scene rather than guessing the current app.

Native guard/settlement tests pass 100/100. The final host tree passes 1,289
tests with 54 opt-in skips; focused settlement presentation passes 17/17. The
real PPC, NOW-68K, and flat-INIT cross-builds pass. The final U5 extension is a
64,994-byte `INIT 128` in a 65,402-byte resource fork (65,536-byte MacBinary),
SHA-256
`76439badc2ef9499502592c4a3b533e657a768a6c7d89772a76e9bc36758fa7c`.
Its source manifest is `0fc7296f 1fd60fa0 4e7e5b68 b4a60944 a6174813` and
embedded build fingerprint is `b1e5890e 8cba499f 25c092c9 45d9e7c1
f54951b3`.

This is **tested and builds, not emulator-verified**. No direct-input sweep has
yet proved a menu, standard list, Date & Time Cancel, application visibility,
or window operation against its paired guest pixels and settlement. Operation
families without a stated postcondition honestly remain dispatched-but-
unconfirmed until that focused proof supplies one. The development stage image
still contains an older application/extension pair and is not evidence for U5.

### U6 one-extension lifecycle and plane policy built; runtime proof remains red

The wire contract is revision 2 and the PowerPC `mirror` command now reports a
schema-1 snapshot of only NOW Extension: exact lifecycle and build identity,
resident capability/request/active bits, heartbeat freshness, and one row for
each of Structure, Semantics, Content, and Interaction. The guest Console and
read-only Workshop use the same probe. The host decodes that object into one
plane domain, persists only optional-plane policy for an anchored machine,
keeps unanchored emulator policy session-local, and presents one native
Open/Close Mirror surface. No active UI asks for AXPeek, QDPeek, Portal,
`mirror-agent`, forwarded port 1420, QMP, or an external Mirror binary.

Policy now reaches named claims rather than stopping at toggles. Scene requests
carry the Semantics choice; Content off sends the bounded stop and retains an
explicit refusal if release fails; Interaction off refuses before dispatch and
logs the refusal. Structure is always required. Unsupported, enabled but
inactive, requested, refused, degraded, stale and active are distinct; an
actual resident-requested row degrades after five seconds without activation,
while a closed Mirror's legitimately inactive planes do not start that timer.
P1/P2/P4 claims stop renewing on close and expire through their ten-second
resident lease; P3 is released explicitly because its lease is much longer.

Focused native JSON/layout/lease tests and host domain/content/contract tests
pass, and the PowerPC guest, NOW-68K guest, and flat 68K extension cross-build
with the real Retro68 toolchains. One complete `scripts/test-all` run passed,
but two immediate primary-agent reruns exposed an unrelated nondeterministic
host-gate red: local guest-listener tests timed out waiting for loopback
connections in different cases (6 failures, then 8), while every named failure
passed when filtered and rerun alone. A stale C26 host process that had held
port 5250 since 20:25 was terminated before the second aggregate rerun, so that
process was real contention but does not explain the remaining suite-level
instability. Treat the focused U6 behavior as **tested and building** and the
aggregate host gate as unresolved red until a clean rerun is repeatable. This
is not emulator-verified. The revision-2 app/extension pair is not installed in the
development image, no direct keyboard/mouse Mirror sweep has compared its
pixels and mutations with a paired guest capture, and no metal claim is made.
U7 still owns runtime/staging retirement and the cleanly shut-down updated VM;
the old compatibility implementation remains internal seed material until
that slice, guarded from the active product UI.

## CYCLE 25 RED; SETUP CORRECTED BEFORE C26 (2026-08-03)

Cycle 25 directly re-ran the sanity preflight through the uniquely identified
C25 native host. Workshop resize and close both mutated the guest; their act
log rows answered `now-window-act-outcome-unknown`, while the paired guest
frames proved the operations landed. The Macintosh HD double-click likewise
dispatched and opened the guest Finder window.

Two real defects survived the sweep. Apple still opened a correctly placed but
empty dropdown, so resolving the empty low-memory shell only through
`GetMenuItemHierarchicalMenu` was insufficient. The next patch also checks the
installed menu with the same measured ID and the root item's hierarchical ID;
it remains red until C26 watches the rows. Separately, a locally synthesised
app-only selector still appeared whenever the guest Application menu was
absent. It collided with the native menu and necessarily dropped Hide, Hide
Others, and Show All. The custom dropdown, hit target, hover state, and action
route are now removed. Only guest menu `-16489` may open or act; missing menu
state is inert rather than replaced with a second control.

The sweep also made a setup error explicit. The extension *file* was staged,
but the running system had never cold-booted it. The first Mirror frame said
`content-plane-absent`, and the live act log later said "the NOW Extension is
not installed". The earlier carry-forward assumption that an old resident was
loaded was wrong. Therefore the missing foreign Finder and Date & Time windows
and menus in C25 are **not an implementation verdict**: foreign scene
collection was being tested without its resident plane.

The corrected local oracle is
`~/Lab/Assets/os91-qemu/now-mirror-stage.qcow2`. It contains the verified
`NOW Extension` and current `New Old World`, was stopped by a human-performed
guest shutdown (the exact QEMU PID exited on its own), and passed `qemu-img
check` before and after preservation. Its SHA-256 at creation was
`c466baa9a5455c343908e12197d68e57ffc7f07c140276a90c97a5ae2a137d70`.
Future extension changes must update and cleanly shut down this stage image
before a Mirror sweep; merely copying a new INIT into a running clone does not
change the resident code under test.

## CYCLE 24 RED BASELINE; FIX BUILT, NOT UX-VERIFIED (2026-08-03)

Cycle 24 was driven through the uniquely identified native C24 Mirror and
paired with QMP screendumps used only as the guest oracle. The restored
menubar geometry held: Apple, File, View, Windows, Help, the clock, and the
right-aligned Application menu matched the authoritative frame. The following
remained broken, and none is green merely because the subsequent patch builds:

- Apple opened a correctly placed but empty dropdown. The live low-memory
  MenuList supplies the system menu's measured identity and left edge, but its
  Apple MenuHandle carries no rows under CarbonLib. The patch now retains that
  identity/geometry and reads the corresponding submenu's rows from
  `AcquireRootMenu`; it needs a C25 native drive.
- Clicking bare desktop did not bring Finder forward. A NOW self-scene carries
  no Finder desktop-backdrop window, so desktop ownership resolved to nil. The
  patch falls back to the live Process Manager row with Finder signature
  `'MACS'`; it needs a C25 native drive.
- Hide New Old World did nothing. Hide, Hide Others, and Show All were generic
  menu commands even though menu -16489 is system-owned. They now resolve as
  typed visibility operations, preserve the guest's enabled/disabled state,
  and use the classic Finder on the guest. Each of the four switcher cases —
  Hide, Hide Others, Show All, and selecting another app — remains red until
  directly driven and compared in C25.
- Clicking NOW Workshop's close box resolved to the correct named window, then
  refused because the optional resident extension was absent. `winact` already
  had a direct self-window implementation, but an unconditional
  `now_act_ready()` check made it unreachable. The patch moves only self-window
  Window Manager acts ahead of that optional-plane gate; foreign windows and
  self controls still require their real application event path.
- Finder-front rendering remained a stale, disabled NOW Workshop with
  `content: no front window`. Workshop whole-frame fidelity also remains red.

The repository gate passes (90 native tests plus the host Debug/Release gate),
and an explicit Retro68 PowerPC Carbon cross-build passes. Mutation checks were
watched fail against the pre-patch self-window route and pre-preflight gate.
This is **tested, not emulator UX-verified and not metal-verified**.

Every future cycle now begins with a gate-enforced eight-step sanity preflight:
compare Workshop, compare the menubar, inspect Apple's real rows, resize and
close Workshop, double-click Macintosh HD, compare Finder, and hide Finder
through the native Application menu. Slice-specific work is currently Date &
Time. Every row is attempted before patching independent failures in a batch;
one red row does not erase coverage of later independent rows.

## WATCHED, FIDELITY STILL RED: Workshop reports its manually drawn structure (2026-08-03)

Cycle 19 paired the native Mirror with the authoritative guest and corrected an
earlier, too-narrow assessment: proper Control Manager chrome did not make the
Workshop render. Its entire 13-row sidebar, page header, explanatory text,
status line, and screenshot-page labels were absent. The bounded missing-content
placeholder was honest, but a nearly empty window is still red.

The Workshop now describes those manually drawn regions through the same scene
IR as controls: panels, placards, selection bands, separators, static text, and
bounded icon/picture placeholders carry `guest-workshop-model` provenance. The
host renders that structure from guest-authored data; it does not read or pipe
guest pixels. The Screenshots page also reports its current dimensions, depth,
streaming state, transport disclosure, and rate text. Actual icon and screenshot
art remains deliberately out of scope and visibly placeholder-backed.

Cycle 20 staged that build without rebooting the guest and drove the native
Mirror with Computer Use. A same-moment Mirror/QMP pair showed the structure
above while the resident content plane still reported absent. This proves the
fallback no longer depends on drawing capture: the empty/hatched Workshop
regression is fixed on the watched surface.

The whole-frame fidelity row is still red. Mirror showed Depth as numeric `4`
while the guest showed the selected popup title `8-bit`; it also overlapped the
preview placeholder text, and removed disabled controls when Finder was
frontmost instead of dimming them. Sidebar icon art remains a named placeholder
and is not scored while bitmap/picture work is out of scope. The popup-value
cause was in the guest producer: it looked only in the process menu list, while
the Appearance popup CDEF owns its MenuRef as control data. The producer now
asks `kControlPopupButtonMenuHandleTag` first and retains the old lookup as a
fallback. Cycle 21 watched the corrected Mirror value `8-bit` beside the same
guest value. Opening or choosing the popup remains red because the old resident
act plane was still absent; correct presentation is not evidence of mutation.

The same structural patch fixes the application switcher's asymmetric
geometry. The real guest menu title is correctly right-aligned even though Menu
Manager reports its nominal `left` as zero; its dropdown must therefore be
anchored to the right screen edge too. Ordinary menu hit spans now exclude that
special menu, and a missing Apple menu is synthesized independently. Cycle 20
watched the right switcher open at the right edge and switch Finder/New Old
World. It also proved the left Apple glyph was only a drawn fallback: clicking
it answered `nothing under the pointer`. An initial follow-up guessed menu id
128 from NOW's own resource convention. Cycle 21 disproved that guess live: the
Apple glyph remained inert. The preserved Aug 1 scene that produced the earlier
nearly faithful Mirror records Mac OS 9's system Apple menu as id 256. The self
scene now uses that measured system id so drawing, hit-testing, and MenuSelect
can share one guest object. It remains red until a later drive watches it open.

Cycle 20 also found that the synthesized switcher lists background-only
processes when Finder is frontmost. Choosing one refuses accurately as
`activate-background-only`, but those rows should not be offered by an
application switcher. The original switcher predicate already encoded the
data-driven distinction available here: frontmost, owns a visible window, or
owns the Finder desktop. The later unconditional process fallback caused this
regression. It is removed without a host signature allowlist; this remains red
until a later native drive watches the resulting roster.

## BUILT, NOT UX-VERIFIED: proven control roles survive the scene (2026-08-03)

The guest already derived exact roles for NOW-owned Control Manager controls,
including checkbox, radio, popup, group, progress, and disclosure controls.
`scene_json.c` then collapsed every proven role except scroll bars into
`pushButton`. The loss was in the producer, before Mirror rendered anything:
Workshop's checkboxes and Depth popup therefore arrived as authoritative
rounded buttons, and no renderer could recover the right kind honestly.

The scene now preserves each proven role, its applicable state or value, and
only the action that role advertises. Mirror draws those semantic kinds
directly; a v2 unknown no longer falls back to a title-and-geometry button
guess. CopyBits still carries no pixels by design, but its exact destination
now gets an explicit bounded placeholder instead of becoming unexplained
white space. Guest-native tests, the PPC cross-build, and offscreen render
tests pass. This is **not green** until a later drive clicks and types in the
native Mirror and compares the whole same-moment frame with the guest capture,
state, operation, and logs.

Update 2026-08-03, cycle 19: paired native frames confirmed the checkbox is
box-shaped, the disclosure triangle is visible, and the buttons retain button
chrome. The Depth popup still omitted its `8-bit` value, and the missing
Workshop structure made the whole-frame fidelity row fail. Those observations
are inputs to the patch above, not a green result.

## BROKEN: the staging reboot dirtied its own fresh clone (2026-08-03)

**Emulator-observed; deferred from the Mirror UX arc.** After
`tools/stage-ext.py`, the old `scripts/spin-up-ppc` sent QMP `quit`; the cold
boot of that same private clone then reported that the computer had not shut
down properly. “Fresh clone” described ownership, not cleanliness after a
host-side power cut. Later probes also found the current layers of both shared
OS 9 bases already presenting Disk First Aid before staging, so neither was a
valid oracle for proving a repaired stop path.

The first repair replaced `quit` with the parent `tools/shutdown-guest`, but
the live os91-runner Worker did not grant its required `script` verb. Its
hello advertised `click`, `key`, `type`, and `launch`; the Finder AppleScript
was correctly refused. Two posted clicks are not a fallback: the first opens
Special, then Finder is inside MenuSelect's tracking loop and the separately
posted second click does not complete the held menu gesture.

Several bounded guest-native probes were rejected: `ShutDwnStart`,
`ShutDwnPower`, Finder shutdown Apple Events, and an embedded OSA script did
not power the VM off; a 120-second observer left it intact. QMP power/eject
keys also failed, and relative-pointer capture was not a trustworthy held-menu
gesture. This remains **broken** and is explicitly punted until after the
Mirror's data-driven fidelity and direct-input loop are proven. Do not dismiss
Disk First Aid, and do not present QMP `quit` as a clean stop.

## WATCHED: the Workshop menu no longer overwrites the Apple slot (2026-08-03)

**Emulator-verified, not metal-verified.** The self-scene synthesized Help at
left coordinate zero. That is the Apple menu's slot, so NOW Mirror showed
Help over the left edge while the authoritative guest showed Apple, File,
View, Windows, Help. The scene now reads `MenuList.last_right`, and a fresh
paired live frame showed File, View, Windows, Help in the correct order.

This fixes one menu placement defect, not Workshop fidelity as a whole. The
live Mirror still lacks sidebar icon representations, draws several control
kinds with the wrong chrome, and defers CopyBits without a bounded
placeholder. The Workshop is no longer structurally empty; those whole-frame
mismatches remain red.

## WATCHED: a person drove the guest from NOW's mirror (2026-08-03)

**Emulator-verified.** Open Mirror on the Mirror page opens a NOW window
that renders the connected Mac and drives it. Watched, in the window, on
a live Power Mac G4:

| act | what happened |
|---|---|
| click a scroll arrow | the folder scrolled; status read "the lineDown of a scroll bar" |
| double-click a folder | it opened, BY NAME, and its window appeared |
| drag a title bar | the window moved to where it was dropped |
| pull a menu, pick a row | View → as List; the window changed to list view |
| press a key | "key e ✓" — the first keystroke ever to cross this wire |

None of it uses QMP, so all of it is shaped for metal.

### Objects first, which is what made the rest possible

A gesture now resolves to an OBJECT with identity — window, control,
menu row, app, Finder item, and the **desktop** — and the gesture rides
along as metadata the object interprets. Two things fall out that a
gesture-first model could not express:

- **An icon is reached by name.** NOW's contract has no click-at-a-point
  verb, so a desktop icon was previously unreachable by anything. As an
  object it is a file the Finder knows, and `select item "X" of desktop`
  works. Measured; so does `item "X" of window "T"`, while the
  remembered `target of window "T"` fails with osaErr -1753.
- **The point picks the part.** A press resolved as `.lineDown` of a
  scroll bar carries that, so no driver re-derives it from coordinates.

### Three defects the machine found that no gate could

- **Every number this host sent arrived as ZERO.** `CommandRequest.args`
  was `[String: String]`, so `part` crossed as `"21"`; the guest reads
  numbers with `strtol`, which stops at the quote. Measured on a live
  scroll bar: `21` moved it one line, `"21"` moved it somewhere else,
  and both replies said `dispatched`. Fixed on both sides — `CommandArg`
  carries a number as a number, and `now_json_read_int` distinguishes
  absent from present-and-unreadable so a quoted one is now a refusal
  that quotes the fix.
- **`key` was unreachable over the wire, always.** It read an argument
  called `name`; the guest scans a request FLAT, so it always got the
  envelope's own `"name": "key"` and refused every call as an unknown
  key name. The console face parses a typed line, so `key space` at the
  machine worked the whole time. Now `named`, and
  `arg_shadow_source_test.py` gates the whole class.
- **This Carbon guest cannot post a MODIFIED keystroke** and says so:
  `PPostEvent` is not in CarbonLib. So ⌘ menu items take the MenuSelect
  route, and `ActionPlanes.modifiedKeystrokes` records the difference
  rather than every shortcut failing quietly.

### Still open

- **Window interiors are empty.** The content plane (P3) has never
  captured a drawing op, so a document window is chrome around blank
  space. Finder windows are fine — their icons come from the Finder.
- **A scroll thumb cannot be dragged.** It needs a verb that SETS a
  control's value; `ctlact` presses a part at the control's own centre.
  Named as unsupported rather than approximated by paging, which would
  overshoot and read as a stutter.
- **No window raise.** `winact` serves move/resize/zoom/close; nothing
  selects one window among an application's own, so clicking a
  background window fronts its APP and the rest is the Finder's choice.
- **`role` is still a guess** (`min != max`), so About This Computer's
  memory bars are reported as scroll bars.
- **The process strip is drawn but not clickable.** `SceneRenderer` paints
  it at the bottom of the guest canvas, so its pixels are in GUEST
  coordinates and `HitTester` — which only knows what the scene
  contains — resolves a click there to whatever guest window is behind
  it. Switching applications works, through the Application menu at the
  top right (`appMenu` → `appMenuItem` → `activate`); the strip is the
  obvious-looking route and is the one that does nothing. Either it
  becomes a hit target or it should stop looking like one.

## The mirror NOW draws itself: built, gated, not yet WATCHED (2026-08-02)

**Unverified in the one way that counts.** "Open Mirror" on the Mirror
page opens a NOW window running Mirror's `LiveMirrorView` over
`NOWMirrorSource`, which polls `scene.request` and dispatches to the act
lane. Every link is proven against a live emulated Mac, separately:

| link | evidence |
|---|---|
| scene reaches the host | `NOWMirrorSource` is this host's FIRST caller of `requestScene` |
| it decodes as IR v1 | `SceneIRDecodeTests`, against a captured fixture |
| it draws | `SceneRenderTests`, and a person looked at the PNG |
| a pixel finds the right element | `SceneHitTestTests` (round trip) |
| the document agrees with the screen | `mirror-geometry-probe.py`, real QMP click |
| the act moves the machine | `act-parts-probe.py`, 60→156→60 by part code |

**Nobody has opened the window and clicked in it.** That is the gap, and
it is deliberately the human's: this side cannot screenshot the host
app's own window (mirror/CLAUDE.md), so the assembled product is judged
by a person or not at all. Both build systems compile it, Debug and
Release, which is a different and weaker claim.

### Known gaps in what it can drive

- **No positional click.** NOW's contract has no click-at-a-point verb
  (`asyncapi.yaml:3294`, deliberate). So a click on bare desktop, on a
  desktop icon, or in bare window content is a NAMED refusal rather than
  an act. Controls, menus, windows and keys all work; the Finder's icons
  do not, and that is the largest hole in "drive the Mac".
- **Interiors are empty.** The content plane (P3) has still never
  captured a drawing op, so windows render as chrome around blank space.
  The renderer is ready for it (`MirrorKitUI.DisplayReplay`); the guest
  side has never been armed in anger.
- **A raise is missing.** `winact` serves move/resize/zoom/close but
  nothing selects one window among an application's own, so a title-bar
  click still falls back to a QMP press — emulator only. This is stated
  in `MirrorAction.WindowAct` rather than invented.
- **`role` is a guess.** Derived from `min != max`, so About This
  Computer's memory bar graphs are reported as scrollbars and a click
  there asks a bar graph to scroll. The honest derivation needs the
  control's defProc, which the walk does not read.

## FIXED: the mirror could not have clicked, and no gate could see it (2026-08-02)

**Fixed on the guest, gated on the host, TESTED — not metal-verified.**

NOW's scene emitted `windows[].controls[].rect` in **global** screen
coordinates. IR v1 documents that field as content-relative, Mirror's own
`SceneBuilder` subtracts the content origin to produce one, and
`MirrorKit.HitTester` subtracts it from a click before it compares. So
every control was hit-tested against a box displaced by its own window's
origin.

Nothing errors when that happens, which is the entire problem. Measured
on a live Finder: a point computed from the centre of one scrollbar in
About This Computer resolved to a **different control ninety pixels
away**, and a point at the centre of another resolved to the **desktop**.
The render looked correct throughout — the same picture a person would
call working.

This is the cause underneath "The last functional gap: a person cannot
click the mirror" below. That entry described a chain with no join; this
is what the join would have been wired to had it existed, and it would
have mis-fired silently.

### Why nothing caught it

Both conventions are four honest integers, so:

- the decode gate passed (the document is structurally valid IR v1);
- the render gate passed (a displaced control still draws somewhere);
- the guest's own `scene_walk_test` **asserted the wrong space in so many
  words** — "a control's rect is translated to global coordinates" — and
  had done since the day it landed.

The only assertion that can hold this is one that names the space, so
there are now two:

- `now-guest-ppc/tests/scene_walk_test.c` — content-relative, stated,
  mutation-verified;
- `now-host/Tests/HostTests/SceneHitTestTests.swift` — a **round trip**:
  compute a control's own centre from the document, hit-test it, require
  the same control back. It cannot pass through a space mismatch. Run
  against the pre-fix fixture it fails naming both the control aimed at
  and what was hit instead.

### The second half, found by asking the machine

The control rects were only half of it. `windows[].rect` was the CONTENT
region, where IR v1 wants that region grown UP by a title bar — the
consumer recovers the content origin by adding the constant back, so a
producer that skips the growth puts every control in the window twenty
pixels low.

**The round-trip gate cannot see this one**, and that is worth
understanding rather than patching: it derives the click point from the
same rects it hit-tests, so an offset shared by both halves of the
document cancels exactly. It stayed green.

So `scripts/probes/mirror-geometry-probe.py` asks the Macintosh. It
computes the down arrow's position the way a renderer places it, delivers
a real hardware click there over QMP, and reads the control back:

    before   clicked (410,263)   value -4 -> -4    no change
             clicked (410,243)   value -4 -> 60    MOVED
    after    clicked (410,243)   value -4 -> 60    MOVED, downward
             clicked (410,263)   value 60 -> 60    no change

Its negative control displaces DOWNWARD, and passing requires the arrow
to scroll DOWN rather than merely to scroll. Both were learned in the
same hour: the first draft displaced upward into the page-up region,
watched the bar move for a legitimate reason, and reported inconclusive
on a build that was already correct.

### Still open

- `role` on a control is derived from `min != max`
  (`now-guest-ppc/src/scene/scene_json.c`), so About This Computer's
  **memory bar graphs are reported as scrollbars**. Harmless to render;
  it means `Scrollbar.part` computes arrow and thumb regions for a thing
  that has none, and a click there would ask a bar graph to scroll.
- The twenty-pixel title bar the two rectangles are related by is now
  stated in three places that share no header — `SceneBuilder
  .titleBarHeight`, the guest's `kNowSceneIRTitleBarHeight`, and the
  probe's own constant. The probe is what keeps them honest; there is no
  compile-time tie, and there cannot be one across a Swift package, a
  cross-compiled C guest and a Python instrument.
- The FALLBACK window path (`now_peek_windows_for_psn`, taken for the
  self process and for anything that does not bind) reports the
  STRUCTURE region, which is a third convention again. It has not been
  measured and no consumer has complained, because the windows that
  matter come from the bound path.

## "Agent: Running" was true and useless (2026-08-02)

**Fixed on the guest, unverified on a machine.** Measured on a live
guest: NOW's Mirror page (`now-guest-ppc/src/mirror/`) reported the agent
Running — correctly, the process was there — while that agent was bound
to a stale port out of the base image's own `mirror.port`, so every
connection from a host Mirror instance hit a QEMU forward with nothing
behind it and was reset. **RUNNING and SERVING are different facts and
the page reported one of them.**

Mirror's agent learns its TCP port from a text file called `mirror.port`
sitting beside it, read once at launch
(`mirror/guest/app/src/main.c :: read_port`, reached through
`set_dir_to_app` — the file is beside the application and nowhere else).
So the port file is now a fact of its own: `mirror_probe.c` reads it out
of the same folder its catalog walk already resolves for the agent
binary, and `MirrorFacts` carries three separable things — the process
state, whether the file is there, and the port it names. The page has a
Port row; the State row distinguishes running-and-named from
running-with-nothing-naming-a-port; the placard carries the number.
Enable REFUSES rather than launching an agent whose port nothing here can
name, before `LaunchApplication`, because the alternative is this page
manufacturing the state it was corrected for.

**What it deliberately does NOT say is "serving nothing".** `read_port()`
falls back to a compiled-in 1420 when the file is absent, so an agent
launched without one does bind something. The honest complaint is that
the number is then a property of a binary nobody on this side can
inspect — which is also why Mirror's own stager writes the file rather
than leaning on that default. A page that replaced one confident wrong
sentence with another would have learned nothing.

**Three things it still cannot see, and two of them need a socket.** It
cannot report the port the RUNNING process actually bound: that was read
at *its* launch and only re-reading the file now is available here, so a
restage underneath a live agent shows the new number beside the old
process. It cannot say anything answers on that port — nothing in this
application opens a socket to Mirror. And the port fields are refreshed
by the probe, not by the idle poll, because a file opened every second on
the idle path is the starvation rule in
[guest-ui-start-here.md](guest-ui-start-here.md); a `mirror.port` staged
while the page is open is stale there until the next action.

**And NOW's staging now writes it.** `tools/stage-ext.py` grew an
optional Mirror bundle (`NOW_STAGE_MIRROR=1`, `NOW_MIRROR_DIR`): the
three INITs, the agent, and `mirror.port` written with `overwrite` and
`truncate` rather than inherited from the base image. Off by default —
Mirror is a separate application and three more residents is not a thing
to put on a guest nobody asked to. `scripts/spin-up-ppc` needs no flag;
it passes its environment through. Host-cc tested
(`mirror_layout_test.c`, `mirror_port_staging_source_test.py`, both
mutation-watched); **nothing in this entry has run on a machine.**

## BROKEN: the scene and `observe` disagree about the same machine (2026-08-02)

**Measured**, one machine, one moment, Finder in front, guest build
`88507f25a8b9`:

| asked | answer |
|---|---|
| `axsnap` | Finder `bind=ok`, `hasWindows=true`, a5 `0x1f50f550`, fresh stamp |
| `observe(front)` | Finder, window "Desktop", with a minted ref |
| **`scene.request`** | **one window, and it is NOW's OWN** — no Finder at all |
| Mirror agent's `axtree` | the front app's window with **ten controls**, plus Desktop |

The scene enumerates all nine processes correctly and marks the Finder
front, so enumeration is not the gap. The Finder's app row carries **no
error token**, meaning its anchor resolved — the scene admitted none of
its windows and said nothing about why.

**Two readers in the same binary disagree about the same process at the
same instant.** `observe` goes through `now_ax_bind_process` and sees the
window; the scene goes through `peek_read.c :: resolve` →
`now_peek_windows_for_psn` and sees nothing. The capability is present
and reachable — the scene is not using the path that works.

**Why this matters beyond the bug.** This was run as the go/no-go for
dropping Mirror's agent and integrating fully. It answers it: NOW's scene
is **not** structurally poorer than the agent's. It already carries the
front application's MENU BAR (eight menus, eighty items) which the
agent's `axtree` does not carry at all, and the windows it is missing are
readable by code in the same binary. The agent is not compensating for
something NOW cannot do.

**Two instrument gaps found on the way**, both worth closing with the
reader:

- The per-process anchor **verdict** is computed (`scene_collect.c` hands
  it to `now_scene_add_process`) and **never encoded**. A process that
  resolved fine and yielded no windows is indistinguishable from one that
  genuinely has none — which is exactly what this investigation spent its
  time on.
- `kNowSceneAnchorNoWindows` produces no error token by design. Right for
  a process with no windows; wrong here.

**Not the cause, but fixed while here:** the scene path never armed the
anchor plane at all. It does now.

## FIXED: the act plane now acts inside foreign applications (2026-08-02)

**The diagnosis below was right and the repair is in.** `act_install`
installed the six trap patches once, on the first armed pass, in
whichever process pumped first — always NOW's own application, because
it is the one serving the wire. The patches were then not in the
dispatch path anywhere else. `act_install` now runs on each armed pass,
and `install_patch` returns early when the incumbent is already its own
shim — which makes a repeat install a no-op under a system-wide trap
table and a real install under a per-context one, correct either way,
and forecloses the fatal version where the chain points at itself.

**Measured after the change**, emulated Power Mac G4, dev INIT staged as
"NOW Ext PerCtx" per the resident charter:

| | before | after |
|---|---|---|
| `actselftest` vs NOW's own app | abi-agreed | abi-agreed |
| `actselftest` vs the **Finder** | `act-no-patch` | **abi-agreed** |
| `actselftest` vs **SimpleText** | `act-no-patch` | **abi-agreed** |
| `menuact` File/New Folder in the Finder | `act-not-taken`, 0 folders | **8/8 folders on the Desktop** |

The folder is the oracle — a fact on disk the Finder created, not
anything a verb said about itself. **This is the first time NOW's act
plane has acted inside an application that is not its own.**

**A second defect the fix exposed, also repaired.** With the plane
working, `menuact` actuated 8/8 and *reported* `act-not-armed` 8/8: the
resident arms and queues the press in one pass, so the application can
dequeue, call the trap, and have the patch answer — setting `fired`,
clearing `armed` — before this side looks at its snapshot. Reading
`armed` alone called a completed request one that never armed. A false
negative in the worst direction, since a caller that retries gets a
second folder. All three sites (`winact`, `ctlact`, `menuact`) now ask
whether the request reached the machine at all: armed OR already fired.
Re-measured: **8/8 actuated, 8/8 replied ok.**

**And the guard was re-tested, because it had never really been.** The
menu no-hijack case was re-run on the same boot that had just driven
File/New Folder 8/8: **0/17 hijacks, 17/17 clean chain-through, 3
dropped** (a dropped trial is one whose QMP stimulus missed, measuring
nothing). That is the number comparable to upstream's 0/19. The earlier
0/20 is not, and is marked void in the ledger: it was taken when the
plane could not fire in that process at all, so a guard that held and a
plane that could do nothing looked identical.

## The diagnosis, kept: the act plane arms in a foreign app and its click is never taken (2026-08-02)

**Measured, emulated Power Mac G4, guest build `3c6be9ffa460`, both
resident families staged.** Against the Finder, addressed by PSN, with a
`titleLeft` the scene supplied, `menuact` answers:

> `act-not-taken: armed, and the application never called MenuSelect`

Read that carefully, because it is good news and bad news in one
sentence. **Armed** means the extension's filter runs inside the
Finder's context, the guard matched the target, and the plane posted its
own press. **Never called MenuSelect** means the Finder did not consume
that press. `actselftest` refuses against the same process in the same
pass, while abi-agreeing against NOW's own application minutes earlier
on the same build.

**Every click-driven act verb depends on this one step.** `menuact`,
`ctlact` and `winact` all work by queueing a `mouseDown`/`mouseUp` with
`PPostEvent` from inside the target's context and letting the
application's own event loop dequeue it, call `FindWindow`, and call the
trap the patch answers (`ext/src/now_ext_act.c :: act_post_click`, and
the comment above it explains why the press is queued there rather than
by the application). If the press is never dequeued, the whole family is
inert in foreign applications no matter how correct the patches are.

**It matches a finding that was never written down.** The overnight arc
of 2026-08-01 (`claude/mirror-parity-overnight`) measured the same
family at 0/10 and recorded that a `PPostEvent`'d `mouseDown` is never
delivered to any app on this guest while a `keyDown` from the same
resident context IS. That branch's note lives in no document; this entry
is where it now lives.

**What it invalidates.** The menu no-hijack case's **0/20** cannot be
read as "the guard held" — a guard that held and a plane that cannot act
in that process produce the same zero, and this measurement says the
second is happening. Upstream's number has no such ambiguity because
Portal measured 18/20 hijacks *before* its guard was fixed, proving it
could act there. See the parity ledger.

**ANSWERED, 2026-08-02, once the verb was made to report the plane's own
error instead of the status.** Four `actselftest` calls on one boot,
guest build `b77ba1c82e50`:

| | target | answer |
|---|---|---|
| A | NOW's own app | `abi-agreed` |
| B | the Finder, by PSN | **`act-no-patch`** |
| C | SimpleText, by PSN | **`act-no-patch`** |
| D | NOW's own app again | `abi-agreed` |

D is the discriminator and it rules out the "only the first request since
boot works" reading: A and D both agree, B and C both refuse. So this is
about **whose context the patch is asked to fire in**.

And `act-no-patch` locates it exactly. `cell->patches` is one field in
one shared table — the same value whichever process reads it — so if the
GUARD's `patches_present` check were failing it would fail for NOW's app
too, and it does not. The refusal therefore comes from the other place
that returns `kNowPeekActErrNoPatch`: `act_serve_selftest`'s
`if (!cell->fired)`. The resident called `MenuSelect(0,0)` **from its own
68K code, inside the Finder's and SimpleText's contexts, and its own
patch did not fire** — while the identical call inside NOW's application
fires and returns exactly what it wrote.

**The measured fact, stated without a mechanism:** the act plane's trap
patch intercepts `MenuSelect` in the process whose context installed it,
and not in others. The `why` is not established. The prime suspect is
`act_install`'s one-shot `static int installed` in
`ext/src/now_ext_act.c`: it installs the six patches on the FIRST armed
pass in whatever process happens to pump first — which is NOW's own
application in every run so far — and never again. If Mac OS 9's trap
dispatch is not as system-wide as a classic 68K machine's for this case,
a one-shot install is exactly the shape of bug that produces this table.

**The obvious experiment does not work, and why it does not is itself
evidence.** The plan was: from a fresh boot, arm while a FOREIGN
application is frontmost so the first armed pass happens in its context,
and see whether the answers invert. But `act_install` runs on the first
pass *of whatever process pumps*, and **NOW's own application is always
pumping** — it is the one serving the wire the request arrived on. So the
install lands in NOW's context by construction, on every boot, no matter
which application is in front. Fronting cannot move it.

That is not a dead end; it explains why the table always comes out this
way round, and it makes the one-shot a stronger suspect rather than a
weaker one. It also means **the repair and the confirmation are the same
change**: make the install per-context (or prove the patch genuinely
system-wide some other way) and the foreign-application answers should
change. Per the resident-components charter that is developed as a
throwaway dev INIT under its own name before it is folded in, because it
edits the one file whose failure mode is a machine that will not boot.

**Narrowed earlier the same day.** The test
was repeated against **SimpleText** — a plain classic application,
launched, frontmost, and bound by the anchor plane (`bind=ok`, fresh
`a5`) — and the result is identical: `menuact` answers `act-not-taken`,
and `actselftest` answers `act-refused`. So:

- **It is not Finder-specific.** It is general to foreign applications.
- **It is not only about the posted click.** `actselftest` requires NO
  event to be dequeued by anybody: the resident calls `MenuSelect`
  itself, in the target's own context, and checks whether its own patch
  answered (`act_serve_selftest`). That refuses in SimpleText and in the
  Finder, while abi-agreeing in NOW's own application on the same build.

Since the anchor plane demonstrably runs in those same foreign contexts
on the same event-loop pass (it captures their A5s), the sharper question
is no longer "why is the press not delivered" but **"why does the act
pass not SERVE in a foreign process when the anchor pass in the same
filter plainly runs there?"** Candidates worth reading in order:
`now_ext_act_apply`'s verdict path and the A5 comparison it makes;
whether the act arm bit is still set in `arm_request` at the moment the
foreign process pumps, or has been withdrawn by the requesting
application first; and whether `act_install`'s one-shot `static int
installed` interacts with which process armed first.

The event-delivery question is still real for `menuact` and remains
open — but it is now downstream of this one, and fixing it first would
prove nothing.

## The Mirror page is a lifecycle now, and NOW cannot see residency (2026-08-02)

**Landed, and the thing it cannot do is worth writing down.** The Mirror
module used to print the shell commands it was about to run and spawn
`swift run` / `spin-up.sh` against Mirror's OWN throwaway emulator
session — so a person with a Mac connected had no way to mirror THAT Mac,
and a failed launch said nothing about why. It is now a module page that
owns one Mirror instance pointed at the connected guest
(`MirrorControlModel`, `MirrorProduct`, `MirrorControlView`): a status
card, a lifecycle card, and settings. `MirrorLauncherModel`,
`MirrorLauncherView` and their suite are gone, along with
`NOW_MIRROR_PATH` and the remembered-checkout default.

**The gap: NOW cannot tell whether Mirror's INITs are RESIDENT.** The
obvious probe is `Gestalt('TBax')` — the selector each INIT publishes at
startup. NOW's `gestalt` verb takes no selector: `run_gestalt` gathers a
fixed set and slices it by group, and the census `selectors` probe walks
a closed documented list. Worse, an unknown argument on that verb is
IGNORED rather than refused, so a host that sent one would get `ok:true`
carrying every group and no evidence of the selector at all — which reads
as a yes, which is the worst answer available. The page therefore asks
`software.list` over the `extensions` domain, which sees the Extensions
Manager disabled folder too, and reports **installed / disabled /
missing**, saying plainly that an INIT loads at boot and that this side
cannot see what is resident.

**CLOSED on the guest side, 2026-08-02 — and the host still does not
read it.** The `mirror` verb landed: contract first, then the guest's
wire face (`commands.c` → `mirror_json.c`) and its console face
(`console_model.c`), both rendering the same `MirrorFacts` the page
draws. Measured on an emulated Power Mac G4 with all three staged:
`AXPeek resident v4, QDPeek resident v1, Portal resident v4`, agent
stopped, port named 1420 — the residency answer this entry says the host
cannot get. NOW-68K answers `unknown-command`, and that is the ANSWER
rather than a gap: Mirror's agent is PowerPC/CFM and its build refuses
the 68K toolchain outright, so the residents have nothing to serve there
(declared in contract-coverage.md).

**What is still open is the two READERS.** `MirrorControlModel` still
calls `software.list` over the `extensions` domain and reports
installed/disabled/missing, so the page a person looks at is still one
step short of the truth the machine now tells; and there is no projection
row, so no agent can ask either (declared `unnoticed` with its
disposition in mcp-coverage.md). The verb is served and nothing reads it
— which is the mirror image of the split this entry was written about,
and worth not leaving long.

**The original diagnosis, kept because it is still why the verb exists.**
The PowerPC guest's own Mirror page (`now-guest-ppc/src/mirror/`) calls
Gestalt for all three selectors and distinguishes absent / resident /
other-version — on its own screen only. That is the wire-only-versus-console-only split
this repository has been bitten by before, in the other direction, and it
is why the host has to infer from a folder listing what the machine
already measured. Closing it is a contract change: either a `mirror` verb
serving `MirrorFacts` (which the console face already has, so it is the
cheaper half of command parity) or an optional `selector` argument on
`gestalt`. Either way the contract moves first, then both guests' faces,
the host projection, contract-coverage.md and the exact-set projection
suites — and whether NOW-68K serves it is the parity question that
arrives with it.

**Never run against a real Mirror.** The suite uses fakes throughout —
nothing in this arc spawned MirrorApp, opened a socket to port 1420, or
saw the page on screen. Specifically unproven: whether the launch
invocation brings up a live window against a NOW guest; whether the
emulator forward default (1724) matches the rig a person is actually
running; whether `mirror-agent` is the name the agent's process wears in
the guest's own `process.list` (it is the name Mirror's source and
`spin-up.sh` use, read rather than observed); and whether SIGTERM
releases the agent's single client slot as cleanly as the code assumes.
## The host suite fails when a NOW app is already running (2026-08-02)

**Environmental, not a defect in the code under test — but it reads
exactly like one.** `scripts/test-all` went red on the loopback
suites (`GuestListenerTests`, `GuestIdentityTests`,
`ConnectionsModelTests`, `MultiGuestListenerTests`,
`AgentIntegration*`) while two `New Old World.app` instances were
running on this Mac, one of them holding port 5250. Evidence that it
is contention and not the change under test:

- the same failures reproduce on the parent commit, with the change
  absent;
- a different subset fails on each run;
- `GuestListenerTests` passes 23/23 twice when run ALONE, and fails
  only inside the full run;
- every cloud suite (50 tests) passes in both.

The suites bind port 0, so this is not a simple port collision —
it is load and listener contention on a machine that is also running
the product. The metal rule (`MetalMachineGuard`: "a gate must check
the MACHINE is free", docs/68k-metal-runbook.md) has a host-side twin
that does not exist: nothing checks for a live `New Old World` before
the host gate binds. Until it does, a red host gate with a NOW app
running should be re-run with the app quit before it is believed —
in either direction.

## Photo sizes became long-edge stops; three metal defects fixed, none re-verified on metal (2026-08-02, latest)

**Unverified, deliberately labelled.** Metal feedback named three
things about the Photos save controls, and all three are fixed and
TESTED — nothing here has been looked at on the PowerBook since.

- **The Size caption overprinted the popup.** `view_draw` drew "Size"
  into `size_popup`'s own rect — a popup paints its value across the
  whole control, so the caption landed on top of it and read as
  garbage. The caption now has `CloudLayout.size_label` of its own, on
  the same row at the group box's left inset, the shape `dest_row` +
  `dest_btn` already used one line below. `cloud_layout_test.c`
  asserts `size_label.right <= size_popup.left` relationally, watched
  failing under a mutation that puts the caption back on the popup.
- **"Host default" is gone.** Every popup item now names a real size,
  and the host's configured setting arrives as data instead
  (`CloudReport.defaultSize`, additive) and is PRESELECTED. `cloud.get`
  from this guest always carries an explicit token.
- **The stops changed meaning.** `original` / `long640` / `long1024` /
  `long1600`, each naming the LONGEST edge (aspect preserved, never
  upscaling). The `fitN` fit boxes are **retired, not aliased** — see
  the contract's own `CloudGet.size` prose for why the graceful
  refusal is what let a deliberate semantic break skip a revision bump.

What only metal can settle:

- **The caption and popup side by side at 640x480.** The layout test
  proves they do not overlap in arithmetic; whether "Size" is legible
  beside a popup wearing "3024 x 4032" on a real 640-wide screen is a
  looking question, and the pane's inset clamp has never been seen.
- **A portrait photo actually arriving at 480x640.** The scale is
  proven twice off-machine (`PhotosProcessingTests` through the real
  CoreGraphics pipeline, `cloud_photo_size_test.c` for the guest's
  label arithmetic, both mutation-watched) but never against a real
  PHAsset with real EXIF orientation, which is the one input a
  fixture cannot fake honestly.
- **The preselect on a real report.** `defaultSize` riding the wire
  and moving the popup has run in no loopback test of the GUEST half
  — the guest's parser is unit-tested, the control mutation is not
  reachable from a host cc.
- **Whether anything still sends a retired token.** Nothing in this
  tree does; a stale build on the PowerBook would, and would get the
  named refusal rather than a wrong picture. Nobody has watched that
  refusal land in the guest's status line.

## RESOLVED: every modern classic-date field was silently dropped (2026-08-02)

### Fixed, tested — not yet re-verified on metal

Watched on metal 2026-08-02: the iCloud Photos list showed "--" in
Modified for every 2026 photo. Traced to `ClassicDate.guestWireSeconds`
(`now-host/Sources/Host/FileConverter.swift`), which stopped at
`Int32.max` — January 1972 in classic (1904-epoch) seconds — because
the deployed guest read the field with `strtol` into a signed 32-bit
`long`. Every date after that came back `nil` from the host function,
`modified` was omitted from the wire entirely, and the guest drew the
"unstated" dash instead. Not Photos-specific: `CloudServices.swift`,
`HostShare.swift` and `FilesModel.swift` all route through the same
function, so cloud listings and the drive/files browser carried the
same silent gap — every date after early 1972, on every listing
either guest reads.

A classic file date is actually **unsigned** seconds since 1904, good
to early 2040; the host's ceiling was simply wrong, not conservative.
Fix: the host stops clamping early (`guestWireSeconds` now just
forwards `macSeconds`'s own, correct, unsigned ceiling), and the guest
gained an unsigned reader to match — `now_json_find_u32`
(`now-guest-ppc/src/core/json.c`) and `now68k_json_find_u32`
(already existed on the 68K side for CRC32, just needed pointing at
this field) — used at every classic-seconds field either guest parses
off the wire: the PPC guest's cloud listing rows, browse/pull replies
(drive/files browser, `file.pull`), and both guests' `file.offer`
push.

A second, independent site carried the identical bug and is not
reached by `ClassicDate` at all: `GuestFileUploadCommands.begin`'s
own inline `modified <= Int32.max` clamp on the MCP agent-upload
path (a raw already-classic-seconds `Int`, not a `Date`). Found by
grepping `now-host/Sources` for `Int32.max` once the first site was
fixed. Two PRE-EXISTING host tests turned out to encode the bug as
correct behavior (asserting `.modified == nil` for a modern date) and
needed correcting alongside the fix — caught by running the full
host suite, not by writing new tests.

**Tested, nothing more; full account in
[icloud.md](icloud.md#every-modern-modified-date-silently-dropped-fixed-2026-08-02).**
Host XCTest and guest `json_native_test`/`cloud_model_test`/`test_putrx`
all pass, mutation-watched by hand. Nothing has run on the emulator or
the PowerBook since the fix — confirming a 2026 photo's Modified column
now draws a real date, rather than merely that the wire carries one, is
the next metal session's job.

## Drive's split-view pane has never run anywhere (2026-08-02, later still still)

**Unverified.** Drive stopped being the full-width flat list the
2026-08-01 entry below documents and went back to a list/detail split
— the SAME split every other iCloud view uses, not a second one
(`cloud_layout.c` computes one list/detail geometry and reuses it for
drive mode too, differing only in `list_top`, pushed down by the
breadcrumb row above it, and in the pane's own furniture below). The
destination row and Choose... moved off the old toolbar strip and
into the pane; the pull's moving bar and byte line moved there too,
reusing Photos' own `cloud_dl_bar_value`/`cloud_dl_bytes_line` idle
discipline against a different wire entry point
(`now_wire_get_active`, since Drive pulls through `now_wire_get_host`
rather than `cloud.get`); and the selected item's own name/kind/
size/date plus the double-click affordance line — which the
2026-08-01 review below moved onto the placard — moved back into the
pane, so the placard no longer changes on selection or on a pull's
byte count, only on durable folder/error/outcome news. No image
preview for drive files: a drive row carries no cloud item id, so a
later arc that wants one needs a real fetch-and-decode path, not this
pane's text — the seam is named in `cloud_drive_view.c`'s
`draw_item_card`.

`scripts/test-all` is green with each exit code read directly (79
native tests including `cloud_layout_test.c`'s rewritten, relational
drive-mode assertions — the old ones asserted full width and had to
change outright — both guest cross-builds, `swift test` at 1355
tests with 0 failures, `xcodebuild` Debug and Release), the new
layout assertions were watched failing via a deliberate mutation
before being trusted, and `audit_source.py` over both touched files
raised only already-reviewed lexical categories (the new
`SetControlValue` on the download bar is change-guarded, read back to
confirm). **None of this has run on the emulator or the PowerBook.**
The 2026-08-01 metal pass for Drive (below) predates every layout
Drive has worn since, including this one — what it proves is the
browsing logic (list, descend, Up, double-click fetch), not any pane
pixels. Before this can move past "tested": watch the split render at
640x480 and at a roomier size, select a folder and a file and confirm
the pane's text matches what the columns already say, start a pull
and watch the bar/byte line move in the pane while the placard stays
on the folder's own listing, and confirm Choose... still redirects a
pull's landing folder from its new position.

## The polish2 integration merged three UI arcs; the seam between them has never run (2026-08-02, later still)

**Unverified, and the specific claim is narrower than "the union is
untested."** `claude/polish2-drive-dest`, `claude/polish2-photos-cols`
and `claude/polish2-contacts` — each individually tested against the
shell as it existed on `claude/polish2-foundations` — merged onto
`claude/polish2-integration` with real conflicts in `cloud_module.c`
and `cloud_photos_view.c`, not just adjacent additions:

- **`cloud_module.c`**: `view_own_browser()`/`active_browser()`/
  `show_own_browser()` had to generalize from two view-owned browsers
  (Drive, Photos, from the drive-dest+photos-cols merge) to three
  (adding Contacts) rather than picking either side's flag check
  wholesale — a real design decision made at merge time, not a
  mechanical union.
- **`cloud_photos_view.c`**: photos-cols' own Data Browser (Name/Size/
  Modified columns, the Size popup's exact-resolution labels) had to be
  kept while adopting polish2-contacts' extraction of the preview
  GWorld/fetch state out of this file into the new shared
  `cloud_preview_well.c` — meaning Photos' preview path now goes
  through the well's rebind-on-select `note` callback for the first
  time. Photos' OWN branch never tested against that extraction
  (contacts' branch predates photos-cols' columns); contacts' OWN
  branch never tested against Photos having a Data Browser of its own.
  Neither branch's tests can have exercised this interaction, only the
  merged tree's tests can, and `scripts/test-all` at the pure-logic
  level cannot see a Toolbox-level selection/rebind race.

`scripts/test-all` is green on the merged tree (79 native tests
including all seven `cloud_*` ones, both guest cross-builds, the host
suites and the Xcode app target) and `audit_source.py` over every
touched `now-guest-ppc/src/cloud/*.c` file raised nothing new past
already-reviewed, already-guarded lexical patterns. **None of this ran
on the emulator or the PowerBook.** What only metal can prove, most
load-bearing first:

- **The preview well correctly rebinds across a Photos-to-Contacts
  switch on a REAL machine.** Select a photo, let its preview arrive
  on the new Data Browser, switch to Contacts mid-flight or right
  after, pick a card, and confirm the well's eviction/rebind hands the
  right pane its pixels — not a stale Photos preview drawn into the
  Contacts well, not a Contacts ask silently landing in the Photos
  pane.
- **Four browsers (shell, Drive, Photos, Contacts) sharing one window's
  activate/show lifecycle** — `cloud_activate`'s `lists[4]` and
  `show_own_browser`'s four-way dispatch are new arithmetic this merge
  wrote, unexercised past compiling and the pure geometry tests.
- Every per-branch metal gap already ledgered below (Contacts guest UI,
  Photos download UX, Photos preview) still applies undiminished — this
  entry is additionally about the THREE arcs running together, not a
  replacement for any of them.

## polish2-foundations: contract + host only, tested with fakes; the two real-data paths and the whole guest half are unbuilt (2026-08-02, later still)

**Unverified, deliberately labelled — and narrower than the other
2026-08-02 entries: no guest UI exists for any of this yet.** The
foundations arc (contract: `CloudGet.size` grows fit1440/fit2048,
`CloudListing` entries grow optional width/height, x-cloud contacts
gains `cloud.preview`; host: `PhotosCloudProvider.DownloadSize` grows
the same two boxes, `.list` fills width/height from
`PHAsset.pixelWidth`/`pixelHeight`, `ContactsCloudProvider.preview`
reuses the photos decode/fit/dither pipeline against
`CNContactThumbnailImageDataKey`) is TESTED — loopback-proven with
FAKE providers (`CloudServingTests`, `CloudModuleModelTests`) — and
none of it has touched a real PHAsset or CNContact. What only a
granted library/address book (this Mac's existing TCC grants) and
metal can prove, additional to the items already ledgered below for
`PhotosCloudProvider`:

- **`PHAsset.pixelWidth`/`pixelHeight` actually land in a real
  listing.** The fill is one line reading documented public
  properties, but "documented and public" is a code-reading claim
  until a real library's rows carry real numbers a person can compare
  against Photos.app.
- **`ContactsCloudProvider.preview` has never run granted.** The
  `CNContactThumbnailImageDataKey` fetch, a REAL contact that has a
  thumbnail, a real one that does not (proving the not-found "no
  photo" path fires from the actual store rather than only from a
  fake's scripted fault), and the reused pipeline against a real
  Contacts-app thumbnail's actual bytes (not the flat synthetic JPEG
  the loopback test generates) are all unexercised.
- **fit1440/fit2048 against a real multi-thousand-photo library.**
  `processedJPEG`'s box arithmetic is shared code already proven for
  the other three tokens (`PhotosProcessingTests`), so this is lower
  risk than a new pipeline — but "lower risk" is still a claim, not a
  measurement, until someone asks a real original at 2048x1536 and
  looks at the JPEG that comes back.
  *(2026-08-02, later: moot as written — all five `fitN` boxes were
  retired the same day for the four `longN` long-edge stops, and the
  unmeasured claim now belongs to those. See the long-edge entry at
  the top.)*
- **The guest half is entirely unbuilt.** Nothing here has a
  `now-guest-ppc` counterpart: no Size popup entries for the two new
  boxes, no exact-resolution-from-dimensions arithmetic on the guest
  side, no contacts card wired to ask `cloud.preview` or draw the "no
  photo" placeholder. This arc is contract + host seams for those
  pages to consume, not the pages themselves.

  **No longer true for the contacts half (2026-08-02, later still):**
  the contacts card now asks `cloud.preview` on selection and draws
  the "no photo" placeholder — see the Contacts guest UI entry below.
  The Size-popup entries and exact-resolution arithmetic remain
  unbuilt; those are Photos-only and this arc did not touch them.

## Contacts guest UI shipped tested; nothing has run past cross-compilation (2026-08-02, later still)

**Unverified, deliberately labelled — narrower than "tested" usually
reads here.** Built atop polish2-foundations: Contacts gets its own
Data Browser (Name/Company columns, `cloud_contacts_view.c`, the drive
browser's view-owned recipe), a real address-book card (photo well,
name, grouped rows — `cloud_contacts_card_layout` in
`cloud_contacts_card.c`), and a photo well shared with Photos
(`cloud_preview_well.c`, extracted from `cloud_photos_view.c`). What is
actually verified: the pure card layout is host-cc tested and
mutation-watched (`cloud_contacts_card_test.c`), and the PPC guest
cross-compiles clean with zero warnings. That is ALL — nothing here has
run against a live host wire, on the emulator, or on the PowerBook:

- **The Data Browser itself is unwatched.** Two real columns, its own
  UPPs, the fill-hilite call — all follow the drive browser's proven
  recipe, but "follows a proven recipe" is not the same claim as
  "watched drawing rows on the PB1400c."
- **The photo well's CopyBits landing is unwatched.** Reused verbatim
  from Photos' own preview (metal status there is itself only
  loopback-proven, see the entries below), but landing into a SMALLER
  well (48x48) rather than the photos pane is new geometry nobody has
  seen render.
- **The hand-drawn silhouette placeholder has never been seen.** A
  gray head-and-shoulders in two `PaintOval` calls, clipped to the
  well — geometry read by eye in the source, not by eye on a screen.
- **The preview-well extraction is a real behavior change for Photos,
  not just a file move.** `cloud_preview_well.c`'s `_select` rebinds
  the settle callback on every call, which changes exactly which
  view's pane gets invalidated when a late preview answer lands after
  the selection has moved on. Photos' preview path carried a metal
  pass before this refactor (2026-08-01); that pass does not cover the
  code as it exists now.
- **A contact WITH a real thumbnail has never been asked for.** The
  wire path is loopback-proven (polish2-foundations, above) with a
  synthetic JPEG; nothing here has asked a real granted `CNContactStore`
  for a real photo and watched it dither and land in the well.
- **The card became titled GROUP BOXES (2026-08-02, later still) and
  no box has ever been drawn.** The judged design replaced the flat
  label/value column with one `kControlGroupBoxTextTitleProc` control
  per section (Phone, Email, Address, Other), held as a fixed pool of
  four that a selection only retitles, moves and shows or hides. The
  pure half is host-cc tested and mutation-watched, and the guest
  cross-compiles — but the constructor is proven in this codebase only
  by `software_module.c`'s ONE static box, never by four that move and
  retitle under a live selection. Three specific things nobody has
  watched: whether `SetControlTitle` + `MoveControl` on a visible
  group box repaints cleanly on CarbonLib 1.6 rather than leaving
  frame debris; whether the hand-drawn rows survive the box's own
  redraw ordering inside an update event (the pane is invalidated once
  per settled sync, which SHOULD make that moot, and "should" is the
  word doing the work); and whether the `truncEnd` values read as
  intended in the 70-point column at the smallest pane.

## Photos download UX shipped tested; every visible behavior awaits metal (2026-08-02, later)

**Unverified, deliberately labelled.** The four-item download arc
(the pane's "Loading preview..." state; the download bar + byte count
off the new read-only `now_wire_receive_active`; the per-ask `size`
on `cloud.get` — contract-additive, host loopback-proven with watched
mutations, guest Size popup MENU 136; the guest-side destination
chooser redirecting a cloud-born offer through
`now_files_receive_begin_at`; and the receive-outcome seam replacing
the stuck "Receiving..." status) is TESTED at its decidable seams and
cross-compiles, and none of it has been watched on a machine. The
specific things only metal can prove:

- **The furniture rows draw where the geometry says** (size popup row,
  destination row, bar, byte line stacked over Save at 640x480), and
  the card/preview genuinely never draws under a live control.
- **The bar moves and the byte line ticks without flicker** during a
  real multi-hundred-KB receive — the change-gates are unit-tested,
  the pixels are not.
- **A redirected offer lands whole in the chosen folder** with type/
  creator/date stamped, and choosing the share root really is
  byte-identical (it never sets the override; only a code-reading
  claim so far).
- **The outcome line replaces the status at completion** on a real
  wire, including the refusal endings (exists / too-big / busy).
- **The popup CDEF under CarbonLib 1.6** accepts the fixed MENU 136
  the way the services popup accepts its rebuilt one — same recipe,
  never this menu.

## Photos preview + processing shipped tested; a granted library and metal own the rest (2026-08-02)

**Unverified, deliberately labelled.** The list+preview arc
(`cloud.preview` / `preview.begin` / `preview.end`, contract-additive;
`ClassicDither`; `cloud_photos_view.c`; the Downloads picker feeding
`cloud.photos.downloadSize` into the get pipeline) is TESTED — pure
ditherers with watched mutations, loopback serving with bytes-intact
and lane-exclusivity proofs, in-test JPEG/HEIC fixtures for the
resize pipeline, host-cc guest units — and none of it has met a
machine. What only a granted library and metal can prove:

- **The palette is the real one only by construction.** ClassicDither
  generates the standard 'clut' 8 layout (cube minus black slot, four
  ramps, black at 255) and dithers against it; the guest's GWorld
  wears whatever a NULL colour table gives an 8-bit depth. That the
  two tables are THE SAME TABLE on a real CarbonLib screen — the
  whole reason no palette travels — is a code-reading claim until a
  preview is looked at on the PowerBook. If colours arrive scrambled,
  suspect this first.
- **PhotosCloudProvider.preview has never run granted**: the
  local-bytes-only fetch, the busy bargain for an un-materialized
  original, and a real HEIC through decode->fit->dither all need this
  Mac's TCC grant.
- **The pane under a held lane** ("Preview after the download", the
  re-ask when selection moves mid-transfer) is guest logic past the
  pure units: builds only, exercised on no machine, and 1-bit asks
  (screens under 8-bit) have no fixture anywhere.
- **Downsized downloads against a real library**: processedJPEG is
  fixture-tested; a 48 MP original through `long640` (was `fit640`
  until the long-edge arc, same day) on the wire to a real guest is
  not.
- **Preview pacing on real hardware**: a 300x200 8-bit preview is
  ~60 KB, ~0.2 s at the measured 300 KiB/s — arithmetic, not a
  measurement; nobody has felt the selection-to-pixels latency at
  the PowerBook.
## The cloud.* family: real providers are untested, and the guest half does not exist (2026-08-01)

**Unverified / unfinished, deliberately.** The host serves
`cloud.services`/`list`/`detail`/`get` from a provider registry
(`now-host/Sources/Host/CloudServices.swift`), tested over a loopback
wire with FAKE providers only (`CloudServingTests`). Still unproven:

- **PhotosCloudProvider and ContactsCloudProvider have never run
  granted.** They need this Mac's TCC consent (usage strings are in the
  Xcode project; the iCloud page has the grant buttons). First run:
  turn each on in the host's iCloud page, grant, and ask over the wire
  — `cloud.list` paging against a real multi-thousand-photo library,
  the JPEG/HEIC transcode, and the busy-then-bytes path for an
  un-materialized original are all claims from code reading.
- **The guest module does not exist yet.** One Workshop page, service
  dropdown, per-service render (docs/icloud.md). Until it lands, the
  family is host-only and nothing exercises it end to end; when it
  lands, the guest's emitted cloud.* messages owe fixtures to
  GuestWireFixtureTests, and contract-coverage.md gains the family's
  guest rows.
- **cloud.get on a busy lane** refuses busy by unit-tested logic, but
  no test drives a real concurrent capture/stream against it.

Update 2026-08-01, late: the entitlements fix is METAL-ADJACENT
VERIFIED — with the hardened-runtime personal-information
entitlements signed in, the Grant Access buttons surface macOS's real
prompts, and with the grants given Michelle reports the granted
services working as intended against the PowerBook, fan-out included
("functional enough"; her detailed notes are pending and may reopen
items here). Narrower claims that remain untested by suites: the
Photos fetch cache against a real library-change event, non-English
Birthday parsing, unclipped long card values.

Update 2026-08-01, night: the fan-out landed (view seam, full-width
drive browser + Up, contacts card view, photos hardening, live
search) and its adversarial review's four must-fixes are in. Still
open from that review: PhotosCloudProvider's fetch cache has no test
(needs a granted library or a PHPhotoLibrary fake); contacts
Birthday parsing matches English month names only (non-English hosts
fall back to echoing text); long contact card values draw unclipped.
Native tests now number 76; everything since the last metal pass —
the whole fan-out — is tested, not metal-verified.

Update 2026-08-01, evening: METAL-VERIFIED for Drive on the
PowerBook 1400c — the cloud.services round trip, the dropdown, and
the in-page drive browser (list, descend, Up, double-click fetch)
all watched working. Three faults the first metal pass found are
fixed and their fixes watched: status_text garbage, popup menu
reachable only through GetControlData, first-ask-before-connect.
Still unproven: Photos and Contacts with real TCC grants, and
cloud.get end to end (no serving service had it enabled yet).

Update 2026-08-01, same day: the guest module LANDED
(`now-guest-ppc/src/cloud/`, docs/icloud.md) — parsers and geometry
native-tested and mutation-watched, all three guests cross-compile,
conformance gates cover the emitted asks. What remains unproven moves,
not shrinks: the page has never been drawn on any screen (emulator
pass owed first, then metal), the TCC-granted providers are still
untried, and no end-to-end ask has crossed a real wire.

Update 2026-08-01, later: the metal-verified drive browser above is
now a full-width flat list rather than the narrower list-beside-card
layout it was verified in — `cloud_layout.c` gained a drive-mode
variant (full width list, detail/save collapse to an anti-rect, a new
`up_btn` in the toolbar row) and the card pane's per-row detail and
pull progress both moved to the status placard
(`cloud_drive_view.c`'s draw is now NULL). **TESTED, not
metal-verified**: `scripts/test-all` is green (74 native tests
including new `cloud_layout_test.c` drive-mode cases, both guest
cross-builds, host gate), and the new geometry was watched failing via
a deliberate mutation, but nobody has driven this exact layout on the
PowerBook or the emulator — the metal pass this arc references above
predates this change. Before it: Data Browser's hierarchical/container
surface (disclosure triangles, a real tree) was investigated and found
**not proven viable** for this runtime — declared in the headers and
compiles clean against a real container-callback call
(`spikes/databrowser-container-probe`), but the container-specific
entry points were never in `spikes/databrowser`'s runtime symbol check
against CarbonLib 1.6.0 on the PB1400c, so the drive view stays the
flat, replace-on-navigate list it already had rather than adopt an
unverified tree. Reopening that is a rerun of the runtime probe with
four more symbol names, not another compile check — see
`spikes/databrowser-container-probe/README.md`.

Update 2026-08-01, later: Photos hardened for an enormous library
against FAKES only (docs/icloud.md > Hardened for an enormous
library) — `PhotosCloudProvider`'s PHAsset fetch cached per instance
and invalidated by `PHPhotoLibraryChangeObserver`, a 10,000-row paging
walk and the 4KB page bound proven and mutation-watched
(`CloudServingTests`), a 3MB photo riding the ordinary transfer lane
end to end, and the guest's cap-hit status wording made honest
(`cloud_listing_status`, native-tested and mutation-watched). None of
this touched a real PHPhotoLibrary: the cache's invalidation path, the
real fetch's actual cost at 40,000+ photos, and whether Photos'
authorization APIs behave as read on this Mac are all still claims
from code reading, folded into the TCC-grant item above rather than
duplicated here. `PHAssetResource`'s byte size stayed out of scope —
no public API exposes it short of downloading the resource — so
`CloudEntry.bytes` stays unstated for photos, deliberately, not as an
oversight.

Update 2026-08-01, later still: the three fan-out branches above (drive
full-width layout, Contacts card view, Photos hardening) are merged
into one tree (`claude/swarm-icloud-integration`, base
`claude/swarm-icloud-split`). One conflict, in `cloud_module.c`'s
`choose_service()`: the drive branch added a layout recompute on every
service switch, the contacts branch added per-service view dispatch —
both intents kept, dispatch then relayout. Two more conflicts, in this
file and docs/icloud.md, were two branches appending different ledger
paragraphs after the same anchor line rather than true disagreement —
both paragraphs kept. **TESTED, not metal-verified**: `scripts/test-all`
is green post-merge (75 native tests including `cloud_contacts_card_test`,
both guest cross-builds plus the NOW Extension, `swift test` at 1324
tests, `xcodebuild` Debug and Release) with the exit code read directly.
Nothing here changes what each branch's own entry above already says is
unproven — a clean merge does not prove Photos or Contacts against a
real TCC-granted library, or put the new drive layout or the Contacts
card in front of anyone on the PowerBook.

## iCloud Drive sharing is tested against fabricated stubs only (2026-08-01)

**Unverified.** The share now sees a directory logically — iCloud
placeholder stubs (`.name.icloud`) list under their logical names with
the size the stub's plist promises, and a `file.get` for one calls
`startDownloadingUbiquitousItem` and refuses `busy` with the reason
(`now-host/Sources/Host/HostShare.swift`, `HostShareCloudTests`). Every
test fabricates the stubs, so three claims rest on Apple keeping a shape
no contract guarantees, and none has been tried against a signed-in
iCloud Drive on this Mac:

- the stub is a binary plist whose size lives under `NSURLFileSizeKey`
  (the fallback chain — promised-item API, then an honest zero — makes
  a format change degrade to "size 0", not a failure);
- `startDownloadingUbiquitousItem(at:)` accepts the logical URL (the
  code retries with the stub URL, and swallows the error either way —
  the refusal is already on its way);
- a download actually materializes the file where `resolve` will find
  it on the retry.

Trying it is cheap: sign-in, point the Sharing picker at iCloud Drive,
browse from the emulator guest, pull an undownloaded file twice.
Metal-verified is further still.

The name bridge (`ClassicName`) closed a live defect on the way: listed
names were mangled one way (`hfsName`) and resolved verbatim, so any
name the projection changed was advertised and then unreachable —
`file.get` answered `not-found` for the listing's own spelling. Covered
by round-trip tests now (`HostShareTests`, "The name round trip"), but
the guest-side experience of fingerprinted names (`Report#1A2B.txt` in
the Files page, Data Browser column width, MacRoman rendering of "#")
has not been looked at on a real screen.

Related, found while mapping (2026-08-01): **the host's serving half
has no metal coverage at all.** `HostServingTests` is loopback-only,
and no `Metal*` suite exercises a real guest browsing this host's
share. The browse direction guest→host is metal-verified only from the
2026-07-20 arc, before the name bridge and placeholders landed.
## The Files path row names the share, unverified on metal (2026-08-01)

**Unverified.** `file.listing.root` now carries the host share's Finder
display name ("iCloud Drive", "Downloads") through the standard MacRoman
projection, instead of the raw POSIX path, and the guest's Files path
row renders it — breadcrumbs from the share root for subfolders, with
"Shared folder" kept only as the fallback for hosts predating the field.
Host side is tested end-to-end over loopback (`HostServingTests
.testTheRootListingNamesWhatIsShared`); the guest's label assembly is
split Toolbox-free (`files_path_label.c`) and pinned natively. What
nobody has watched: the row on a real screen — the root name arrives
over the wire UTF-8→MacRoman via `now_json_find_text`, and an accented
share name drawn through `DrawString` is exactly the kind of thing the
emulator has hidden before.
## The Mirror page has never been on a machine (2026-08-01)

**Unverified, and the whole page is unverified together.** The guest now
has a Mirror page in the Workshop (`now-guest-ppc/src/mirror/`): three
read-only rows for Mirror's resident extensions, three rows for its
agent, and Enable / Disable for the agent alone. It builds, and its value
core is covered by `mirror_layout_test.c`. Nothing about it has run on a
Macintosh.

What a machine has to settle, none of which a host test can:

- **That Gestalt answers at all.** The three selectors and the two or
  three longs read behind each of them (`'TBax'`, `'TBqd'`, `'TBpt'`)
  come from Mirror's own shared headers, cited in `mirror_probe.c`. If a
  selector answers with an address whose magic does not match, the page
  says absent — which is the safe direction, and also indistinguishable
  from "we read the wrong offset".
- **That the agent is found where the page looks.**
  `mirror/tools/stage-agent.py` puts the agent at
  `Macintosh HD:TimBotTu:mirror-dev:mirror-agent`; the page walks the
  boot volume to it and matches a running process by its
  `processAppSpec`. An agent staged anywhere else reads as not installed.
  There is no preference for the location and no browse button.
- **That `LaunchApplication` starts a faceless background application
  from a Carbon app**, and that a `kAEQuitApplication` reaches one that
  owns no menu bar. Both are ordinary calls; neither has been watched
  against this particular target.

**Why the agent is matched by file and not by creator.** Mirror's agent
is a Retro68 build with no creator override, so it carries the default
`'????'` — read out of the MacBinary header of
`mirror/guest/app/build/mirror-agent.bin`. So does every other Retro68
build on the machine, including the lab's own workers, which is why a
signature match would cheerfully report the Mirror agent running about
something else entirely. The signature is shown on the page and matched
on by nothing. If Mirror ever stamps a real creator, this becomes a
one-line change and a better rule.

**The three extensions are deliberately not switchable**, and the page
says so in two lines rather than offering a control that does nothing. A
file-move enable/disable *is* possible and is already proposed below
("an extension is a thing you enable, not a thing you launch") — it needs
a guest verb, a confirmation, and the restart notice in the *result*, and
none of that is what "status and enable/disable" asked for. Deferred, not
overlooked.

**No console or wire verb.** This is a UI-only page: it adds no
`x-commands` verb, no message type, and nothing to
docs/contract-coverage.md. The parity rule is about capabilities the two
faces of a guest reach, and nothing here is reachable from the wire
because nothing here was added to it. A `mirror` console verb would be a
real capability and would need both faces — worth doing, and not done.

**The View menu was one item short, and this fixed it.** Networking went
in on 2026-08-01 without a menu item, and the handler maps item number to
module id: Cmd-9 read "Logs" and selected Networking, Cmd-0 read
"Connection" and selected Logs, and Connection could not be reached from
the menu at all. Adding Mirror without repairing that would have moved
the mismatch along. Logs and Connection now carry no Command-key — the
digits ran out — and are one click away in the rail.

## The Mirror port was thrown away (2026-08-01)

**Settled, and it settles a great many entries below.** NOW's
re-implementation of Mirror's live-UI mirroring — `MirrorKit`,
`MirrorKitUI`, the Mirror module's model, view, scene adapter, action
driver, content join and window resolver, with their tests — has been
**deleted from `now-host`**. In the built app its menu bar was mostly
empty, its menus dropped down and did nothing, and nothing could be
launched, clicked, moved or resized. Mirror already does all of it,
working, on the same OS and the same emulator.

Mirror is now vendored whole at `mirror/` — its own wire, its own 68K
INITs, its own agent surface, its own SwiftPM package, built by nothing in
`now-host` — and NOW's Mirror module is a **launcher** for its two halves
(`MirrorLauncherModel`). The removed code is archived unchanged at
`archive/mirror-port-2026-08-01/`, whose README says what is worth reading
in it.

Update 2026-08-02: `MirrorLauncherModel` is itself gone. The launcher it
describes pointed at Mirror's own emulator session and showed the shell
lines it ran; the module now controls one Mirror instance aimed at the
CONNECTED guest. See the 2026-08-02 entry at the top of this page.

**So: every entry below that names `MirrorKit`, `MirrorKitUI`,
`MirrorModuleView`, `MirrorModuleModel`, `MirrorActionDriver`,
`MirrorSceneAdapter` or the Mirror pane describes code that is no longer
in this tree.** They are left standing per the rule at the top of this
page — the shape of the mistake is the value — but none of them is a
thing to pick up.

The lesson, which is not about Mirror: every acceptance number in that
work was measured by probe scripts against the wire verbs, and **the path
a person actually uses was never once tested end to end**. "`winact`
closed a window 10/10" and "a person can close a window in the mirror" are
different claims, and the gate only ever checked the first — so it stayed
green for two days while the product did nothing.

**Closed 2026-08-01: the guest spin-up works from here.** It used to
resolve the lab it borrows its emulator instruments from as its own parent
directory, which inside NOW is this repository rather than the TimBotTu
checkout that has them. Both scripts and both Python stagers now honour
`MIRROR_LAB_ROOT` and otherwise walk up until a directory actually holds
`tools/lib.sh`; `MirrorInstallation.lab` resolves it the same way and
passes its answer down, so the preflight and the run cannot disagree.

Emulator-verified, not merely built: `MIRROR_DISPLAY=1 tools/spin-up.sh`
from `now/mirror/` booted a fresh mac99 clone (anchor at 90s), staged all
three INITs, cold-rebooted with all three surviving, and the agent
answered — `oracle=ok v4`, `observe` 9 processes front=Finder, `axtree`
walking. Both preflight halves then read green against this checkout.

Two things it left behind:

- `stop-mirror.sh` had a worse version of the same bug and now refuses
  rather than proceed: with no lab found, `LAB` resolved to `/`, the QMP
  quit failed into its own `||` branch reporting "VM may already be down",
  and the `rm` then unlinked the session disk out from under a QEMU that
  was still running it.
- The standalone `timbottu/mirror` repository still carries the old
  resolution in all four files. It is not broken there — its parent really
  is the lab — but the vendored copy and the origin have diverged, and the
  walk-up version is the one that works in both geometries.

## The last functional gap: a person cannot click the mirror (2026-08-01)

**Retracted 2026-08-01, later the same day: the pane this describes no
longer exists.** See "The Mirror port was thrown away" above. The
diagnosis below is why it was thrown away rather than finished, and is
kept for that reason.

**Broken, in the sense of unfinished rather than wrong.** Every piece of
the act path exists and is tested, and the path has no join. An agent can
drive a Macintosh through the MCP act rows today. **A person clicking a
rendered control in the Mirror pane gets nothing** — not a refusal, not a
log line, nothing, because no code observes the click.

Three separate breaks in one chain. Each was verified against the tree on
2026-08-01, and none of them is recorded anywhere else.

### 1. The renderer has no hit-testing wired into it

`HitTester.hitTest(_:x:y:)`
(`now-host/Sources/MirrorKit/HitTester.swift:155`) has **no caller outside
the test bundle.** Nor does `ActionModel.click(on:count:mods:)`
(`ActionModel.swift:244`), which is the only thing that constructs a
`MirrorAction`. So at runtime **no `MirrorAction` is ever built**.

The pane draws and nothing more: `MirrorModuleView.swift` hands the scene
to `SceneView`, which wraps a `Canvas`, and there is no `onTapGesture`,
`DragGesture`, `.gesture(`, `onHover` or `contentShape` anywhere in
`MirrorKitUI/`, `MirrorModuleView.swift` or `MirrorModuleModel.swift`.
The pane's only interactive controls are *Close Scene*, *Look Now* /
*Look Again* and *Open Scene…*.

Other `HitTester` statics **are** live in production — `isDesktopBackdrop`,
`switchableApps`, `appMenuWidth`, `menubarHeight` — which is why the type
does not read as dead. The type is alive; the hit-testing is not.

### 2. The driver that would receive the gesture has no caller

`MirrorActionDriver` (`now-host/Sources/Host/MirrorActionDriver.swift:56`)
is the seam a pane would call. It is built, it is tested
(`MirrorActionDriverTests.swift`), and **the only thing that constructs it
is its own test.** This is the half that could be finished without a
machine, and it was; the pane is the half that wants one.

### 3. A window has no scene-side reference host-side

The guest emits `windows[].ref` — `now-guest-ppc/src/scene/scene_json.c:318`
(`put_ref(k, w->ref)`), set by `now_scene_set_window_ref`
(`scene_build.c:314`) off `now_obs_walk_window_ref`. It is an addition to
IR v1's window field set, taken under the accretive rule, and the reason
it was added is exactly this one: `winact` names a window, not a control.

**Neither host model has a field to put it in.**
`NOWSceneDocument.Window`
(`now-host/Sources/NOWAgentIntegration/AgentIntegrationSceneModels.swift:195`)
and `MirrorKit.Scene.Window` (`Scene.swift:155`) both carry
`id / app / psn / title / rect / front / z / visible / kind? / controls? /
text? / items?` and no `ref`. `NOWSceneCodec.decode` is a plain synthesized
`Codable`, so the key **decodes without error and is discarded.**
`MirrorSceneAdapter.window(from:)` never mentions it.

Control refs do survive (`NOWSceneDocument.Control.ref`, mapped at
`MirrorSceneAdapter.swift:188`). Window refs do not.

**So `winact` has no caller from a rendered scene.** The one place that
sends it — `AgentIntegrationActControl.swift:120` — takes its `window`
argument from an opaque `now-window-…` minted by `now_observe_elements`,
supplied by the agent caller. `MirrorActionDriver` has no `winact` route
at all.

**One correction to a phrasing that has been repeated:** `Scene.Window.id`
is **not** host-synthesised. It is minted by the guest at
`now-guest-ppc/src/scene/scene_build.c:197` as `"%ld.%lu/%s#%d"` —
`psn.hi.psn.lo/title#z` — deliberately in upstream `SceneBuilder`'s own
form, so an id minted here means what one minted there means. The host
carries it through unchanged (`MirrorSceneAdapter.swift:160`). It is a
*name*, not an address: nothing resolves it back to a `WindowPtr`.

### The five faces are `notReached`, and honestly so

Each act row declares `.appUI: .notReached` with its reason, and the
ledger is enforced both ways by
`HostFaceParityTests.appUIDivergences`:

| capability | file | line |
|---|---|---|
| `now_window_act` | `Projection/WindowActProjection.swift` | 72 |
| `now_control_act` | `Projection/ControlActProjection.swift` | 55 |
| `now_menu_act` | `Projection/MenuActProjection.swift` | 59 |
| `now_text_get` | `Projection/TextGetProjection.swift` | 43 |
| `now_text_set` | `Projection/TextSetProjection.swift` | 48 |

Eleven rows in total carry `.appUI: .notReached`; the other six are
`now_observe_elements`, `now_session_capabilities`,
`now_transfer_approved_artifact`, `now_guest_files_capabilities`,
`now_guest_files_upload_begin` and `now_guest_files_upload_append`.

**These declarations are the good news, not the bad.** Rule 3 is recorded
as *owed*, not waived, and the gate would have gone red if a row had
claimed a face it did not have. What is missing is the pane, and the pane
was correctly sequenced behind the thing it renders.

**One reason has aged, and is worth fixing when the pane lands.**
`WindowActProjection`'s reason says *"the host has no window observation to
select one from"*. That was true when it was written; the guest has emitted
`windows[].ref` since 2026-08-01. The half that is still true is that the
host model discards it.

### Two stale claims in source, found while verifying this

Recorded here because they are in `now-host/Sources/**` and this pass owns
no source:

- `MirrorSceneAdapter.swift:41-42` still says *"NOW's walk reads a
  ControlRecord and cannot name a ref, so it is `""`"*. The reference plane
  landed 2026-08-01; the code below the comment already maps
  `control.ref ?? ""` correctly. Comment only.
- `ActionModel.availability`'s `.key` / `.type` reason
  (`ActionModel.swift:130-137`) says *"NOW's contract declares no keystroke
  command."* The contract declares `key` at `contract/asyncapi.yaml:3024`.
  What is actually missing is a host **projection row** — tracked as W3 in
  [mcp-coverage.md](mcp-coverage.md). The refusal is right; its stated
  reason is not.

## `.activate` reports available and this host has no lane (2026-08-01)

**Broken, and it is a live inconsistency rather than a gap.**

`ActionModel.availability(.activate)` answers
`.available(command: "activate")` (`ActionModel.swift:140-142`), on the
grounds that a scene carries a process serial for every window. The
contract agrees that the verb exists — `contract/asyncapi.yaml:2923`
declares `activate`, taking `serialHi` / `serialLo`, described as *not a
second `front`*.

**This host carries no lane for it.** There is no `activate` case in
`AgentIntegrationLocalProtocol.Operation`. So `MirrorActionDriver.drive(_:)`
passes the `switch ActionModel.availability` guard — because availability
said yes — and lands in an explicit refusal at
`MirrorActionDriver.swift:145-155`:

> NOW's contract declares the activate command and this host carries no
> lane for it. The scene's process serial is not the opaque reference
> bring-to-front takes, so there is nothing to substitute.

**The refusal is the right call and should not be traded for a
substitution.** `now_bring_to_front` takes an opaque `now-process-…`
reference minted by `process.list`, validated by
`AgentIntegrationQuitPolicy.isValidReference`, and **re-listed and matched
by full observed identity before it acts**. A scene's bare `"hi.lo"` PSN
string was minted by no host-side observation. Bridging the two would mean
acting on an identity nothing on this side ever confirmed — which is the
exact property the quit/front family was built to have.

**What is actually owed** is either a lane (an `activate` operation, with
the serial's own validation story) or an availability answer that stops
saying yes. Today the row is the one act in the vocabulary that reports
sendable and has no route.

## `type` and `click` are unavailable by design; `key` is now mods-gated (2026-08-01, updated same day)

Not a defect. Recorded because *"why can't I type into the mirror"* is the
first question the pane will raise, and the answer is a hardware-era fact
rather than a to-do for the MODIFIED half — but a plain keystroke is no
longer one of these rows.

**Updated same day: `key` split into two answers, not one.** It read
`.unavailable` unconditionally when this section was first written; that
was too broad. `now-guest-ppc`'s `key` verb posts an unmodified keystroke
fine (`mods` is accepted as exactly 0) — the wall below is real for
`mods != 0` and was never a fact about `mods == 0`. `ActionModel
.availability(.key)` now reads:

| act | mods | answer | why |
|---|---|---|---|
| `key` | `== 0` | `.available(command: "key")` | the guest posts it; `MirrorActionDriver` routes it to `AgentIntegrationHostAdapter.key` and the pane's drawing (`MirrorModuleView` + `MirrorKeyCaptureView`) sends one on a keystroke |
| `key` | `!= 0` | `.unavailable` | the CarbonLib wall below — unchanged |
| `type` | any | `.unavailable` | NOW writes text through `textset` against a referenced control (`typeInto`), never through a bare typed action with no target |
| `click` | — | `.unavailable` | NOW's contract declares no positional click. A control is acted on through `ctlact` **by reference**, not by where it is drawn |

**Not verified even for `mods == 0`:** the pane's AppKit key-capture view
(`MirrorKeyCaptureView`) has not been exercised in the running app — no
display was attached to the work that added it. The specific, named risk
is in `docs/pane-keys-audit.md`: whether its `hitTest`-returns-nil design
actually leaves the drawing's existing click gesture untouched, and
whether focus reaches it reliably after a click. `swift build` and `swift
build --build-tests` both pass; nothing about the AppKit event path has
run.

**`key` still refuses modifiers outright.** An event's modifiers live on the
Event Manager's **queue element**, not in the message, and the only call
that hands that element back is `PPostEvent` — which CarbonLib does not
have (`CALL_NOT_IN_CARBON`). NOW's application is Carbon. So the guest can
queue a keystroke and cannot say what was held down while it was typed;
`mods` with any non-zero value answers `unsupported` and names the reason,
and `mods: 0` is accepted. The alternative — post the keystroke and drop
the modifier — is a defect upstream already paid for: a literal character
went into a document and the reply said success. Stated at
`contract/asyncapi.yaml:3036-3044`, in
[input-plane-decisions.md](input-plane-decisions.md), and in the guest at
`now-guest-ppc/src/input/input_args.c`.

**The reach exists, and only through the act plane's resident half.**
`ext/src/now_ext_act.c` is a **68K resident**, not Carbon, so it can do
what the application cannot: `act_post_click()`
(`now_ext_act.c:497-533`) sets `LMSetMouseLocation` and calls `PPostEvent`
for the press and the release itself, stamping `evtQWhere` and
`evtQModifiers`. That inversion is worth holding onto — the older, less
capable-looking half of this project is the half that can reach the queue
element.

## `MirrorKit.SceneIslands` kept its policy and lost its fetch (2026-08-01)

**Unfinished, and it will read as dead code to the next auditor.**

`SceneIslands` (`now-host/Sources/MirrorKit/SceneIslands.swift:20`) carries
upstream's capture / hold / shift policy for pixel islands intact. The
fetch it drives is an **injected closure** —
`typealias Capture = (Rect) throws -> PixelIsland` (line 24), consumed by
`attach(_:poll:capture:)` (line 53), `island(for:key:capture:)` (line 105)
and the metered `fetch(_:_:)` (line 168).

**Nothing supplies one.** The only construction site in the repository is
`IslandLifecycleTests.swift:41`. Nothing in `Sources/**` constructs
`SceneIslands` or calls `attach`.

The file says so itself, and the reason is real rather than an oversight:
the host's pixel path is `GuestListener.requestCapture` + `CaptureDecoder`,
and no code joins it to a rendered scene. Joining them is a decision about
the transfer lane — an island is a capture, and the lane is one transfer
wide — not a wiring job.

**Why it stayed:** the policy is the expensive part and it is tested. A
closure with no supplier is an honest shape for *we ported the judgement
and not the plumbing*; deleting it would throw away the judgement.

## The content plane has never run anywhere (2026-08-01)

**Unverified in the strongest sense on this list, and not a fault to
chase.**

The reader is complete and natively tested against fabricated rings —
`now-guest-ppc/src/content/qdtrace_read.c` (the ring walk and the
seqlock), `qdtrace_json.c` (the replies), `qdtrace_cmd.c` (the only
Toolbox, four subcommands: `status` / `start` / `stop` / `drain`),
registered at `commands.c:1376` with a help row.

**The writer has never executed on any Macintosh.** `ext/src/now_content.c`
and `now_content_logic.c` are the resident half that fills the ring at
draw time, and nothing has armed them — not on an emulator, not on metal,
not upstream in this shape. No captured output, fixture or run log for an
armed plane exists anywhere in the tree.

**So `qdtrace status` answers `content-plane-absent` on every machine that
exists, and that is correct.** The refusal is emitted at three sites
(`qdtrace_cmd.c:198` on `start`, `:275` on `stop`, `qdtrace_json.c:420` on
`drain`), gated on the caps bit `kNowPeekTableCapContent`
(`contract/peek_table.h:93`, `1u << 3` after the collision described
below). A run that gets `content-plane-absent` is not a failure. **A run
that gets anything else is news.**

One stale comment in guest source, flagged rather than fixed here:
`qdtrace_cmd.c:11-15` still says *"REGISTRATION IS NOT OURS"*. It is
registered.

### `qdtrace`'s `torn` retraction: what is covered and what is not

The brief this checkpoint was written against said `torn` was "the one
untested line". That is close and worth stating precisely, because the two
halves have different standing.

| Layer | Path | Covered? |
|---|---|---|
| Read | `qdtrace_read.c:307-326` — re-sample, `seq1 != seq0` **and** the writer lapped the cursor → `kNowQDDrainTorn`, `records = 0`, `resync = 1` | **Yes.** `qdtrace_read_test.c:526-543`, driven by a deterministic `lapping_sink` |
| JSON | `qdtrace_json.c:444-450` — rewind `e.pos` to `head`, discarding whatever ops were already serialized | **No**, and the test file names it as a gap (`qdtrace_json_test.c:19-28`) |

**Why the JSON line cannot be reached from a fixture:** getting there needs
a live writer lapping the ring *between* the seqlock sample and the
re-sample. No host fixture can stage that, and a fixture that could would
be staging the answer.

**The nearest thing to coverage is a proxy, and it is a real one.** `Busy`
takes the *same* retraction branch, and `test_busy_says_call_again`
(`qdtrace_json_test.c:344-355`) asserts the reply comes back with
`"ops":[]`. So the discard is exercised; what has never been exercised is
the discard **after ops were written into the buffer**.

**The falsifiable claim, for whoever gets the first armed run:** a `torn`
reply is `ok: true` with `"ops": []`, `"records": 0`, `"torn": true`,
`"resync": true`. The `"ops":[` is emitted *before* the walk
(`qdtrace_json.c:407-409`) and the retraction rewinds only as far as
`head`. **If a `torn` reply ever arrives carrying a non-empty `ops` array,
that is the defect** — it means ops survived a retraction that was
supposed to discard them, and every one of them is a reading of a ring the
writer had already overwritten.

Worth knowing about the shape: `torn` and `busy` are *successful* replies
carrying flags; `absent`, `mismatch` and `corrupt` are `ok: false` errors.
A caller that treats `torn` as an error will retry something that was
telling it to call again.

## Stale branches and two worktrees against a layout that is gone (2026-08-01)

Housekeeping, recorded rather than swept, because deleting another
session's work is not this pass's call.

**Four branches, none merged into `main`, none checked out anywhere:**

| Branch | Head | Behind main by | Unmerged commits |
|---|---|---|---|
| `claude/next-module-direction-02becd` | `3094e89` | 550 | 13 |
| `claude/laughing-tesla-b4cc41` | `686aa9c` | 605 | 10 |
| `fork/carbon-ui-cleanup` | `b185b8a` | 692 | 6 |
| `claude/guest-installer` | `664cfd0` | 423 | 5 |

**Two worktrees holding uncommitted edits against a directory layout that
no longer exists:**

- `.claude/worktrees/sweet-bouman-a714dd` — HEAD `a3f3adb`, branch
  `claude/sweet-bouman-a714dd`. Five modified files: `docs/open-issues.md`,
  `guest/src/commands.c`, `guest/src/wire.c`,
  `guest/tests/json_native_test.c`,
  `host/Tests/HostTests/GuestWireConformanceTests.swift`.
- `.claude/worktrees/youthful-lumiere-d6e7be` — HEAD `1cd1303`, and the
  branch checked out is **`claude/68k-pn-180c-9c0940`**, not the one the
  worktree is named for. One modified file: `guest68k/src/wire68.c`.

**Why they cannot simply be applied.** `main` has no `guest/`, `guest68k/`
or `host/` at top level — the trees are `now-guest-ppc/`, `now-guest-68k/`
and `now-host/`. Both worktrees sit on pre-rename commits. Salvaging an
edit means path-mapping `guest/src/` → `now-guest-ppc/src/`,
`guest68k/src/` → `now-guest-68k/src/`, `host/` → `now-host/`, onto files
that have moved *and changed substantially* across roughly 600 commits.

**The honest read is that these are almost certainly not worth salvaging**,
and the reason to write them down anyway is that an uncommitted edit in a
worktree is invisible to every other kind of audit. Whoever prunes them
should look at the five diffs first and record `corpus_impact` for
anything that turns out to be a finding.

## Two planes asked for the same bit, and one collision was silent (2026-07-31)

**Found and fixed during the fold-in, recorded because the near-miss is the
lesson.** The act plane (P4) and the content plane (P3) were ported by different
agents, in parallel, neither able to see the other's edits to
`contract/peek_table.h`. Both appended a capability bit and a state cell. Both
asked for **`1u << 2`** and for the offset **`36 + 60 * kNowPeekMaxAnchors`**.

The offset collision would have **failed a compile** — the header's static
asserts pin every offset, which is exactly what they are for.

The bit collision would have been **silent**, and it is the dangerous one:
arming the content plane would have armed **P4's six trap patches inside another
process.** A person switching on a QuickDraw op counter would have been patching
`MenuSelect`, `TrackControl` and `FindWindow` system-wide without asking for it.

P3 now sits at `1u << 3`, appended after P4's cell. The shim keyed on
`NOW_PEEK_TABLE_HAS_CAP_CONTENT` was deleted rather than left standing once it
had retired.

**What to carry forward:** the accretive discipline (`stamp_ticks` never moves,
gate on the format word, append only) was written for **versions** — one writer
extending a table over time. It says nothing about **two writers extending it at
once**, and parallel ports are now normal here. A test asserting that every cap
bit is distinct and every plane's cell offset is unique would have caught this at
the same moment the compiler caught the other half.

Related: `now_act_guard_test` went red on the append and was **right to** — it
spelled "one byte short of the act cell" as `sizeof(table) - 1`, which is true
only while that cell is the last field. A test written against the *end of a
struct* is a test that fails the next time anyone appends.

## `menuRowHeight` is a known-wrong constant (2026-07-31)

`now-host/Sources/MirrorKit/ActionModel.swift:92` hardcodes
`menuRowHeight = 16`, and `ActionDispatcher`'s `.menuDrag` releases on a point
computed from it. That is the uniform-row assumption upstream **measured** as a
**~30 px accumulated error** once a menu contains separators — the rows are not
uniform and the error compounds down the menu.

It survived the port because it is a constant rather than a mechanism, and
nothing crossing looked at it.

The fix upstream built for this is `MENU_GEOMETRY`, which the act-plane port
deliberately left behind on the grounds that *"nothing in NOW consumes item
rects."* **That reason has expired** — `ActionModel` consumes them implicitly, by
assuming them. Porting it needs a new resident op (`peek_table.h`, `ext/`, the
guard), so it is not a small change.

**Until then, prefer `menuact`**, which is identity-addressed and computes no
geometry at all. The drag path this constant serves is emulator-only, so the
blast radius is bounded — but a number that is wrong by 30 px two-thirds of the
way down a menu will find a way to be believed.

**Resolved 2026-08-01, on `audit/menu-honesty`.** The ruling in
`docs/input-plane-decisions.md` §3 was "measure the rows, or delete a
computation nothing performs" — and by the time this branch landed,
`menuSelect` already routed every item through `.menuInvoke`, so nothing
performed it. `menuRowHeight`, `ActionModel.menuItemPoint`, and the
`MirrorAction.menuDrag` case that was their only reader are deleted; no code
path in `now-host` computes a menu-item pixel point from a row-height
constant, live or dead. `menugeom` stays unported (still the riskiest call
in upstream's file, still serving nothing) — re-open only if a caller needs
an on-screen menu-item rect, per the re-open condition already on record.

## Proposed: an extension is a thing you enable, not a thing you launch (2026-07-31)

**Proposal, nothing built.** From the manual review pass, and recorded here
because it is a *new guest capability* rather than a UI gate — the gating half
(never offering Launch or Bring to Front for an extension or a faceless
background process) is being handled separately and is not this.

The user's shape for it:

> extensions can surface an enable / disable function that just moves the
> extension between Extensions and Extensions (Disabled), plus a message that
> changes will take effect after restart

Three things make this worth writing down before anyone builds it.

**It belongs on the guest, not composed on the host.** The mechanism is a file
move, and NOW already has a guest move verb — so the tempting cheap version is
the host composing "disable" out of two paths it constructs itself. That is the
projection layer *deciding*, which rule 2 forbids, and it breaks the first time
it meets a System Folder that is not where the host assumed: a non-English
system, a renamed volume, a machine with no `Extensions (Disabled)` folder yet.
The guest knows where its own System Folder is and whether the disabled folder
exists. The host should ask for "disable this extension", not for two paths.

**The restart notice is part of the capability, not decoration.** An INIT loads
at boot and only at boot, so a disable that reports success is telling the truth
about the file and a lie about the machine until it restarts. That gap is
exactly the class of thing this product refuses to paper over elsewhere — it
belongs in the *result*, not only in a label beside the button.

**It is a destructive-ish capability with an easy undo**, which puts it in the
same family as the Files verbs: it wants the same confirmation and audit
treatment, and an agent reaching it must appear in the audit line like any other
mutation. It is also a good candidate for the consent tiers — a read-only tier
should not be able to disable a system extension.

Open questions a builder must answer rather than assume: what happens when the
disabled folder does not exist (create it, or refuse?); whether re-enabling has
to remember where the file came from or can assume `Extensions`; and whether the
68K guest serves it at all.

## A refused `stream.start` closes its bracket (2026-07-31)

The bracket is opened optimistically — `activeStreamId` is set before the guest
has accepted — and its id is held by no pending map, so `recordGuestError` had
nothing to match: the refusal set `lastGuestError` and the bracket stayed open
on a stream that was never running. The 68K guest refuses `stream.start` every
time (`send_error_reply`, `now-guest-68k/src/core/wire68.c`), which makes this
that machine's ordinary behaviour rather than an edge case. `GuestListener` now
recognises its own bracket id: it closes on the refusal, with the guest's own
reason, and records the `stream.start` family through `observeFamily` in both
directions. **Tested, and mutation-proven both ways; no part of it has met a
Macintosh.**

**Unverified:**

- **Nobody has watched a real 68K Mac refuse a stream.** The whole arc is
  proven against a fake guest that answers `not-implemented` on cue. What that
  cannot show is what the person sees: the Screenshots page should say the
  machine does not serve live streaming and grey the button, instead of sitting
  on "Waiting for the first frame…". That is the gate, and it wants the
  PowerBook rather than an emulator, because the emulated guest is the one that
  serves the family.
- **A guest that serves the start and refuses a STOP is reasoned about, not
  observed.** Such a guest closes on the refusal rather than on the five-second
  fallback, and its `stream.stop` stays `unproven` rather than being recorded as
  a "no" — the three stream messages share one id, so the listener attributes a
  refusal to the open rather than guessing between them. No guest on the wire
  does this today, so the branch is untravelled.
- **The two capability stores still both exist.** `familyObservations` on the
  listener now has the `stream.start` answer, and `GuestCapabilityRecord` — the
  page-side store that exists precisely because the listener could not see this
  refusal — records it separately from `ScreenshotModuleModel`. Whether one of
  them should now absorb the other is a question this change makes askable and
  did not answer.

## The live stream reached the agent surface, and the bracket is a lease (2026-07-31)

`now_stream_screen` closes the last three unnoticed gaps in
[mcp-coverage.md](mcp-coverage.md) — `stream.start`, `stream.stop`,
`stream.refresh` — as **one row with three intentions**, so that list is now
empty. **Tested throughout; no part of it has met a Macintosh.**

**Unverified, and the first one decides whether the row should exist:**

- **Nobody has measured whether a frame is cheaper than a capture.** The whole
  premise is that an open bracket has the guest capturing continuously, so a
  frame is *waiting* rather than *starting* — against a capture measured at
  0.5–0.6 s on the 1400c. If it is not clearly cheaper on metal, the row's
  reason for existing is wrong. The procedure is section 8 of
  [metal-and-ux-review.md](metal-and-ux-review.md).
- **The default pace of 1000 ms was argued, not measured.** It exists because
  the contract's absent-means-the-guest's-floor (~15 fps) is a Macintosh
  grabbing fifteen screens a second for a caller that reads one per call. The
  right number is a measurement nobody has taken.
- **The ownership rule has never met a real companion.** Both halves are
  mutation-proven against injected values — a pid set and a movable clock —
  and both rest on an assumption about a real MCP companion's process: that it
  outlives a single call and dies with its client. If that is wrong, the
  liveness half is dead weight and the lease is doing all the work.
- **Nobody has seen contention happen.** An agent's stream turns the person's
  live view on and greys out their Capture button; the sentences that explain
  that, on the Screenshots page and on the Agent page, have not been in front
  of anybody.

**Three decisions worth revisiting rather than defects:**

- **`readOnlyHint: true`, so the row sits at the Read Only consent tier.** It
  is honest — a stream observes and changes nothing — and it means a machine
  that consented to being *read* has consented to a bracket that keeps
  reading, for as long as an agent keeps calling. **The two tiers cannot
  express duration**, which is the same gap `now_reveal_item` fell into from
  the other side, and more evidence for the middle tier. Declaring the row
  non-read-only to buy Full Access was rejected: it would corrupt the
  annotation agents actually read.
- **No maximum duration.** An agent that keeps asking for frames is watching,
  and a ceiling would be a number with nothing behind it. The person can end
  any stream in one click. The cost is real and stated: a calling agent can
  hold a 1400c's screen lane indefinitely.
- **Capture does not end an agent's stream.** The person wins by clicking Stop
  Streaming, not by pressing Capture — a button that says Capture and also
  silently ends somebody else's work does two things and shows one. If the UX
  pass finds that annoying enough, the other design is a small change.

**One lesson that generalises past this row**, recorded in
[source-text-gates.md](source-text-gates.md): **an asynchronous negative
assertion is a gate that cannot fail.** Two ownership guards were deletable
with the suite green because "no `stream.stop` was sent" was read off the fake
guest immediately after the call, before the message could have arrived. The
cure is ordering against the wire, not sleeping — and applying it failed on
unmutated code, which is how a real lease-renewal defect was found.

## The agent surface can be seen, and refused (2026-07-31)

[Plan 006](plans/2026-07-30-006-feat-now-mcp-module-and-guest-consent-plan.md)
is built except its guest-side half. The host tracks companions, an **Agent**
module shows what they have done, and `HostProjectionDispatch` refuses a call
the connected machine has not consented to. **Tested throughout; no part of it
has met a Macintosh, and no person has looked at the pane.**

**Unverified, and the list is the point:**

- **Nobody has seen the module.** Everything asserted about it is about the
  model's words, not how they land in a window. The state most worth looking at
  is `.neverAttached`, because it is what the pane says on most machines for
  most of their lives. A screenshot on the host Mac closes this.
- **No real companion has ever attached.** Presence, the 120-second active
  window and the `LOCAL_PEERPID` identity are all reasoned rather than observed
  against real agent traffic. Pid reuse can merge two short-lived companions
  into one — it undercounts rather than inventing, and is documented where it
  happens.
- **The ceiling has never met a guest that answers.** No guest sends
  `hello.agent` yet except the PPC guest's hardcoded `full`, so `disabled` and
  `read-only` have been exercised only against fixtures.
- **The audit stream is per-launch and in memory**, unlike the log, which can
  persist. A person looking for last week's agent activity needs the log.

**Two decisions worth revisiting rather than defects:**

- **`now_reveal_item` derives Full Access, against plan 006's stated intent
  that reveal is safe.** Not a bug and not a slip: the row publishes
  `readOnlyHint: false` because it takes over the screen of whoever is sitting
  there, and the tier derives from the published annotation rather than a
  hand-maintained list — which is one of that plan's own stop conditions. The
  real cause is that **two tiers cannot express reveal**: derive from
  `readOnlyHint` and it is Full Access, derive from `destructiveHint` and so is
  *upload*, which writes to somebody's disk. Reveal is the case that fell in
  the gap when read / safe-write / full collapsed to two, and it is the
  evidence for reinstating the middle tier when something has actually used the
  first two.
- **Silence still fails open.** Recorded in the schema as a decision, not a
  property, with the installer's arrival named as the moment to revisit.

**One known skew:** a host built before this change rejects an audit report
carrying the new `denied` outcome. It costs one log line on a mixed install and
never a failed call — deliberately cheaper than bumping the local protocol
version, which would make such a host reject every request instead.

## Debts the parity phase left behind (2026-07-31)

Twelve capabilities landed across twenty-six projection rows. These are the
things that arc noticed and did not stop to fix, collected here rather than
left in twelve agents' reports.

**Gates that were not what they claimed:**

- **Two source-scanning gates were decorative and nobody knew.** The `hello`
  seam gate and the `build` gate each searched raw source for identifiers that
  their own explanatory comments also contained, so a mutation deleting the
  real call left each gate reading its own prose and passing. The `build` gate
  shipped that morning, mutation-proven at the time, and was hollow by lunch.
  Both now share a comment-stripping reader. **Whether a third exists is being
  audited**; the result belongs beside this entry.
- **`MCPCoverageTests` catches an omission and not its inverse.** A capability
  that fails to add a `familyPolicy` row is named loudly. One that adds a row
  for a *command*, which needs none, passes in silence. Found by the machine-
  facts row, which has a test whose docstring claims the asymmetry and
  demonstrates it.
- **The guest-identity guard fires on prose.** It scans `Projection/` for guest
  names with comments included and has rejected **doc comments four times this
  week**, once per agent, costing an amend each. It is right about the rule and
  over-broad about the medium.

**Timeouts classified wrong, twice:**

The batched verb edit assigned each new operation a local receive window, and
two were wrong in the same direction — a host bound shorter than the work it
was waiting on. `guest_file_mutation` took the 2-second read-only window
against a 20-second guest-side change watchdog, so a slow `PBCatMove` could
time out locally on a call the machine then completed. `census` took the same
2-second window although its `overview` probe synthesizes every other probe.
Both were patched by whoever tripped over them. **The whole table deserves one
pass**, because the third instance will present as a machine fault.

**Unexercised:**

Ten of the twelve capabilities have never crossed a real wire — only capture
and addressing are metal-verified. The capability ledger reads `unproven` on
every guest by construction for several families, because the listener records
no observation for them. That is honest and it means the first real call is
also the first evidence.

**Still open by decision:**

Streaming (`stream.start`/`.stop`/`.refresh`) is the last unnoticed gap and the
one genuinely undecided item. The 68K half of download stays a planned gap
until `HostProjection` can express a **disjunctive** requirement — `requires` is
a conjunction today, so a row needing "`file.get` or the `put` verb" cannot say
so.

## The machine's vote is carried (2026-07-31)

`hello` now has an optional `agent` field — `disabled`, `read-only`,
`full`, or nothing — and the host decodes it, keeps it on the session
health record, the roster row and
`AgentIntegrationSessionHealth.Guest`, and writes it into the connect
log line when the machine said something. That is section 2 of
[plan 006](plans/2026-07-30-006-feat-now-mcp-module-and-guest-consent-plan.md).
**Tested**; nothing here has met a Macintosh.

The three unfinished things, and they are unfinished on purpose:

- ~~**Nothing enforces it.**~~ **Enforcement landed the same day** — see
  "The agent surface can be seen, and refused" below. It went exactly
  where this entry said it belonged: `HostProjectionDispatch`, on the
  same line as the audit event. A machine sending `disabled` is now
  refused.
- **Absence fails OPEN**, which is a decision recorded in the schema and
  not a property of the field. It matches today's default-on behaviour
  and keeps every deployed machine working. The moment to revisit is when
  the installer ships and silence stops being the common case.
- **Nothing on either machine can change the answer.** The PowerPC guest
  answers `full` from `now_agent_access()`, a function with no
  preference and no switch behind it yet; the guest toggle, the mid-call
  prompt and the installer's AI-BAD path all land there. NOW-68K sends
  no `agent` at all — it has no switch to report and no installer, so it
  is a guest that has not been asked rather than one that answered.

## The parity slice's capture lane and addressing met the PowerBook (2026-07-30)

Two capabilities of the [parity
slice](plans/2026-07-29-004-feat-now-tbt-classic-parity-slice-plan.md)
had been proven at the codec and socket layers and never on hardware.
Both have a gate now, and both ran on the **PB1400c (10.91.5.47) on
2026-07-29** — `MetalCaptureProjectionTests`, `MetalAddressingTests`,
over `MetalAgentLocalSurface`. The rig is the shipped stack at every
layer but the dispatch, which the file writes itself, mirroring
`App.swift`.

### Metal-verified

`now_capture_screen`, end to end from the agent face:

| | measured | notes |
|---|---|---|
| screen | 800x600 | |
| PNG at 1bpp | 25,110 B in 4 pages | 8 KiB pages |
| PNG at 8bpp | 38,833 B in 5 pages | |
| largest local response | 11,643 of 16,384 B | the local cap, enforced by the code that enforces it in production |
| guest-side transfer | 278–349 ms | |

The claim no fake can make is the one that carries the entry: the
reassembled bytes are decoded with ImageIO and their pixel dimensions
checked against what the guest reported. **Mutation-checked** — one
flipped byte in one fetched page fails the run as
`now-capture-digest-mismatch`.

Addressing, four of the five selector states:

| selector | outcome | status |
|---|---|---|
| absent | answered by the driven machine | metal-verified |
| the driven machine's id, and its session id | answered by that machine | metal-verified |
| a machine that is not connected | `now-guest-not-connected` | metal-verified |
| a session id whose connection ended | `now-guest-session-ended` | metal-verified |
| a machine connected but not driven | `now-guest-not-addressed` | **not verified — see below** |

**Mutation-checked**: bypassing the refusal has the PowerBook answer for
a machine nobody has ever seen, which is the substitution the scheme
exists to prevent.

### Not verified: the fifth selector state

`now-guest-not-addressed` means *connected but not driven*, and **one
connection cannot be in that state** — the host refuses to re-point the
console out from under whoever is at the machine, so the condition needs
two live sessions to exist at all. `testAConnectedButNotDrivenMachineIsRefused`
runs when a second peer is present and reports exactly what it needed
when it is not.

It was exercised only with a supplied second peer
(`NOW_METAL_SECOND_PEER`), and the distinction matters: the refusal is a
decision **the host** makes — it holds two sessions, drives one, and a
caller named the other. Nothing about that decision depends on what the
far end of the second socket is, only on its being there. So a run with
`tools/fakeguest.py` as the second peer is evidence about the **host's
addressing decision and about no guest at all**; per AGENTS.md nothing
verified against that harness may be called metal-verified. Unconditional
coverage wants a second real Mac — or a QEMU guest — dialling the same
port while the run waits.

### `capture.request` reads `unproven` on every guest, by construction

The capability ledger cannot say more, and the reason is not the guest's:
`GuestListener.requestCapture` is **not wrapped by `observing`/`observeFamily`**,
so a settled capture records no family observation, and `CaptureFailure`
carries a human sentence rather than the guest's typed refusal code, so
there is nothing for the ledger to file even if it were wrapped. A
capture is also deliberately not probed — it costs a whole screen grab
and holds the connection's only transfer lane — so nothing else settles
the row either. `unproven` is the truthful answer and leaves the
capability callable; the note is in
`AgentIntegrationCapabilityLedger.swift` beside the row. Fixing it is a
behaviour change in the listener: give the capture lane a typed code and
put the request through `observing`.

### `census.request` joins it, and its page bound is unmeasured

`now_hardware_census` landed against the same two gaps and neither is
new to it.

- **`unproven` on every guest, by construction.**
  `GuestListener.requestCensus` is not wrapped by
  `observing`/`observeFamily` either, and the listener's own failure path
  folds a guest's typed refusal code into a `CensusReport` note
  (`"[code] message"`) rather than keeping it typed — so there is nothing
  for the ledger to file even if the request were wrapped. The family is
  also not probed, and its reason is sharper than capture's: the probe
  argument is **required**, so a probe would have to choose one, and the
  registry's default is `overview` — the synthesis that arranges what
  every other probe read. Same cure as capture's: a typed code plus
  `observing` in the listener.
- **The adapter's 30 s page bound is a guess, and declared as one.**
  `census.request` has no guest-side watchdog, so
  `AgentIntegrationCensus.pageTimeout` is the only bound on a probe. Not
  one census probe has ever run against a Macintosh
  ([contract-coverage.md](contract-coverage.md)), so the number is the
  same order as the measurements beside it — `catsearch` ~20 s per pass,
  the `software.list` sweep ~4 s — and the first metal run is what
  replaces it. The local surface's window for the operation was moved off
  the 2 s read-only one at the same time, for the same reason: a page is
  16 rows, and what costs is the probe.

### `software.list` is the family that DOES settle, and no agent has settled it

Worth recording as the contrast to the two rows above rather than as a defect,
because it is the shape those two are missing: `GuestListener.listSoftware` IS
wrapped by `observing`, so an ordinary `now_software_inventory` call moves the
ledger row to the guest's own answer and makes a later `probeCostly` report
free. That is the cure capture and the census want, already working one lane
over.

What is unverified is everything downstream of it:

- **No guest has served this family to an agent face.**
  [contract-coverage.md](contract-coverage.md) already records the software
  family as *tested only* — no guest has run the sweep for anyone — and
  `now_software_inventory` inherits that unchanged. The 25 tests behind it are
  over a real socket and a fake guest.
- **The ~4 s sweep figure is one disk's.** It is metal-measured, but by
  `catsearch` on the 1400c. NOW-68K's `apps` path has two shapes the number
  has never covered: the 48-FSSpec cache, and the `PBCatSearch`-unusable
  fallback that walks the volume root. Neither has been timed on that machine,
  so nothing here knows whether the listener's 30 s watchdog is generous or
  tight there.
- **The `note` sentences have never crossed a real wire.** Both are asserted
  against the guest's own literals, which proves the host carries whatever it
  is handed; it does not prove a 68K Mac with 60 applications actually emits
  the truncation note rather than a short page and silence.

### The face-reachability proofs are textual, deliberately

Three coverage gates landed with the slice, and none of them proves what
a reader may assume:

- **`HostFaceReach.reached(file:symbol:)` is `file.contains(symbol)` and
  nothing more.** It catches the failure it was built for — the
  affordance deleted or renamed, the file gone — and cannot catch an
  affordance that is still *spelled* and no longer *reachable*: a call
  site wrapped in `if false` or `#if`, a control left permanently
  `.disabled(true)`, a symbol surviving only in a comment or a
  `#Preview`, or the whole view no longer instantiated because its module
  left the sidebar registry with file and symbol untouched. Documented at
  the declaration rather than mechanised, because the mechanical version
  is a Swift-source reachability analysis and the honest cheap gate plus a
  stated limit beats a gate whose weakness nobody wrote down.
- **The MCP-face check is textual over `NOWMCPServer`'s registry loop** —
  it matches `registry.projections.map` and
  `registry.projection(named:)`. A `guard … continue` added inside the
  loop body would skip a row without changing any matched string. It is
  still the stronger of the two: a loop fails uniformly, where a
  hand-built pane fails one row at a time.
- **`docs/mcp-coverage.md` and `MCPCoverageTests` are tested only.** No
  part of the registry-versus-contract join has been read against a
  guest; the `Served` column claims only what a dispatch table answers.
  `contract-coverage.md` owns the how-far-proven axis and this file does
  not duplicate it.

### Nine served capabilities that nothing asks for

`docs/mcp-coverage.md` derived the gap table and found the hand analysis
had undercounted: **nine capabilities are `unnoticed`** — served by a
guest right now with nothing in this repository arguing for their
absence. They are absent because the question never came up, which is the
`process.list` drift `command-parity.md` was written for, one layer out.

`stream.start`, `stream.stop`, `stream.refresh`, `catsearch`, `gestalt`,
`putstat`, `reveal`, `shotdiag`, `vprobe`. Two are worth naming on their
own:

- **`gestalt`** is the largest single gap: one PPC verb answering CPU,
  memory, OS, network and hardware for the whole machine, served
  throughout, reachable from **no face**.
- **`shotdiag`** is the verb that found the 180c's 24-bit addressing
  defect — precisely what someone standing at a misbehaving machine wants
  — and is reachable from nothing.

They were ten; `capture.cancel` left the list by being **decided** rather
than by being built.

**Updated 2026-07-30: all three diagnostics are now reachable, and only the
streaming bracket is left on that list.** `vprobe`, `shotdiag` and `putstat`
are `now_framebuffer_probe`, `now_capture_diagnostics` and
`now_transfer_diagnostics`, plus a Diagnostics module — three rows for one
plan item and one wire operation, because `requires` is a conjunction and no
guest serves all three (the argument is in `docs/mcp-coverage.md`, "One
capability is three rows"). **Tested, not metal-verified**: nothing in this
row set has run against a Macintosh, and the two unverified things worth
naming are that the module's per-card availability reads the connected
machine's own `help` table (so a machine that never answers `help` leaves all
three cards `unknown`, which is stated rather than guessed past), and that the
host's 40 s bound on a diagnostic is the **only** watchdog in the chain —
neither `vprobe` nor `shotdiag` has a guest-side give-up, so a 68030 slower
than that bound would read as a refusal and nobody has timed one.

### `AgentIntegrationLocalProtocol.swift` is the real serialization point

Any capability needing a new client verb edits four things in that one
file — an operation case, a result case, a response field and init
parameter, and a strict-decode branch — at the tails of three lists.
**Those three tails conflicted on every merge that touched them this
slice**: the audit gate, the codec fix, its harvest, and the capture
template. Always trivially, always needing a human decision. It belongs
on the collision-hazard list beside `contract/asyncapi.yaml` and the
`scripts/test-native` manifest: **one owning agent per phase**, and
prefer batching a phase's verbs into a single edit over one agent per
capability. W0.1's registry removed the tool-enum switch, which made the
shared-file hazard look solved; it was displaced here.

### Four hand-maintained capability lists survive the registry

So "one file plus one row" is true of the **row** and not of the
capability. Each is trivial alone; eight times over it is a serialized
edit on shared test files.

| List | Where |
|---|---|
| known-names set | `HostProjectionRegistryTests` |
| approved-tool list | `NOWAgentCompanionTests` |
| exhaustive switch over the operation enum | `AgentIntegrationSocketTests`, `NOWAgentCompanionTests` |
| assertion matching a doc heading that names the tool **count** literally | `MCPCoverageTests` (`## What the thirteen reach`) |

The last is the worst: every new capability renames a heading in
`docs/mcp-coverage.md` and a string in a test. Worth fixing before a wide
phase, not during one.

### An integer command argument cannot ride `CommandRequest.args`

`CommandRequest.args` is `[String: String]`, so every typed argument
reaches the guest quoted. A guest reading an integer argument uses
`now_json_find_int`, which is `strtol` on the byte after the colon —
`strtol("\"40\"")` is 0. The failure is silent in the worst way: `tail`'s
`run_tail` clamps 0 up to 1, so a caller asking for forty log lines gets
**one**, with `ok:true` and nothing anywhere saying so.

Nothing had met this edge because `launch`, `reveal`, `help` and the census
all take strings; `tail` (P1 #9) is the first host-side caller whose typed
argument is a number. It sends the count on `line` instead, which the
contract declares for that verb (`x-commands.tail.x-line`) and which
`run_tail` reaches precisely when no typed `lines` is present, with a test
that fails if somebody tidies it back into `args`.

**Unfixed, and it will bite the next numeric argument.** The fix is a typed
args value on both sides of the wire, which is a `contract/asyncapi.yaml` +
both-guests change and belongs to one owning agent, not to whichever
capability trips over it. Until then: an integer argument goes on the line,
and a reviewer seeing a number in an `args` dictionary should ask what the
guest parses it with.

### The guest log is readable by an agent and has not been read on metal

`now_guest_log_tail` (P1 #9) is **tested, not metal-verified**. Two things
about it are worth knowing before it is trusted on a real machine:

- The audit line it writes under `app` shares the state of every other
  agent-facing log line — see *The agent audit line has never been read on
  a real run* below.
- It is the first row that returns text the machine wrote, so it is the
  first that can disclose a name from **outside** `guestRoot`: the guest's
  own `get`, `put` and `files` lines quote the items they handled. That is
  argued and recorded in [mcp-coverage.md](mcp-coverage.md) rather than
  accidental, but it is a widening over the Files family's authority and a
  reviewer should agree with it explicitly rather than inherit it.

### A schema rejection surfaces as the wrong error

`AgentIntegrationLocalServer` replies to a `decodeRequest` failure with
`.init(error:)` and no request id, so the response carries
`requestID: nil`. The client checks the id first
(`decoded.requestID == request.requestID`), so the caller sees **"Local
response request ID did not match"** rather than the `invalid-request`
error anyone would grep for. Minor, and explanatory: it is why the
`guestSelector` defect below presented as a mismatched id rather than as
the schema rejection it was.

### Dead code

`AgentIntegrationLocalProtocol.strictObject(_:keys:)` — the private
overload that also requires the keys to be *present* — has no callers.
Both call sites use `strictObject(_:allowedKeys:)`.

### `vprobe`'s `CopyBits failed` is not `capture.request`'s

`MetalCaptureProjectionTests` was written expecting the guest might
refuse, because an earlier `vprobe` on this PowerBook reported `CopyBits
failed`. **It did not reproduce**: two clean captures at two depths. The
two paths differ — `vprobe` measures framebuffer reads on its own bands,
the capture lane stages through the guest's normal screen grab — so a
`CopyBits` failure in one is not evidence about the other. Recorded so
nobody conflates them again, and so the reverse is also clear: had the
capture been refused for that reason, it would have been a finding about
this machine and not a defect in the gate.

**This distinction is now carried by the product rather than only by this
ledger (2026-07-30).** `vprobe` has a face on both sides — the
`now_framebuffer_probe` tool and the Diagnostics module's first card — so the
misreading is available to more people than the two who wrote these
paragraphs. The tool description states it, and the card states it **before**
the probe is run rather than beneath a number that has already sent someone
looking for a bug in Screenshots.

## `PRODUCT_VERSION` cannot tell two builds apart (2026-07-30)

### Broken

`PRODUCT_VERSION` is `"0.1.0"` in
`now-guest-ppc/src/core/product_identity.h` and was **also `"0.1.0"` on
the build previously deployed to the 1400c**. It rides `hello` and is
what `now_session_health` reports, so the one string a host has for "is
this the build I just deployed" answers the same for every build there
has ever been.

This cost a real misdiagnosis on **2026-07-30**: a stale guest on the
1400c was failing every exec test, and the version string gave no signal
that the machine was running old code. The metal gates now assert which
build answered from the host-observed address and from the guest's own
verb table, **never** from `PRODUCT_VERSION` — which is the right
workaround and not a fix.

The fix is a build identity that changes when the build does. NOW already
has `build_stamp.c`, which CMake touches at the end of every build and
AGENTS.md already tells a human to check before believing a test result;
putting that stamp where `hello` can carry it is the cheap version.
(Hypothesis, not measured: the 68K guest has its own version string and
is likely to have the same weakness.)

## The agent audit line has never been read on a real run (2026-07-29)

### Unverified

Every capability the MCP face invokes now emits one audit event, and the
host writes it under the `agent` area of its log
([agent-integration.md](agent-integration.md#every-agent-call-leaves-a-trace)).
The gate is mutation-checked and the whole path is exercised over a real
private socket in `NOWAgentAuditTests` — but with a fake host at the far
end. **Nobody has yet driven the running app from a real MCP client and
read the lines out of `~/Library/Logs/now-logs`.** The host app's own
handler for the operation (the `.audit` case in `App.swift`) is the one
piece with no automated cover, because nothing in this tree tests that
closure; the line's format is tested one layer in, at
`AgentIntegrationAuditLog`.

Two known gaps, stated rather than left to be discovered:

- A call still waiting on a 32-second launch has not been logged yet. The
  event is emitted once, when the outcome is known — a begun/ended pair
  would double this face's local round-trips per call — so a launch in
  flight is invisible until it settles, and one that takes the process
  down is never logged at all.
- A malformed `guest` selector is refused by the face before any
  capability is invoked, so it names no capability and emits nothing.
  (Still true, and now true one layer deeper: since 2026-07-29 the codec
  refuses an empty selector as well — same consequence for the audit
  line.)

**The 2026-07-29 metal run did not touch this.** `MetalAgentLocalSurface`
refuses `.audit` by name, along with every other operation that could
change the machine, so nothing about the audit path was exercised on the
PowerBook. This entry stands unchanged.

## RESOLVED: local schema v7's addressing could not survive its own codec (2026-07-29)

### Fixed, and metal-verified

Both defects are fixed on this slice and the path is
**metal-verified on the PB1400c (10.91.5.47), 2026-07-29** for four of
the five selector states. The table, and why the fifth state one
connection cannot reach, are in "The parity slice's capture lane and
addressing met the PowerBook" above.

What the fix is:

- `decodeRequest` admits `guestSelector` — once, in the top-level
  allowlist, and as a **conditional** per-operation key added only when
  the caller actually sent it, so an absent selector stays absent rather
  than becoming a required field on every operation.
- An **empty** selector is now refused as its own error ("Local request
  names an empty machine") rather than reaching the adapter as a third
  state that is neither nil nor an id. Validated in the codec and not only
  in the companion, because the companion is not the trust boundary: any
  process of this uid can write that socket.
- `decodeResponse` admits `notAddressed` **and counts it in the
  exactly-one-of guard**, beside the operation results rather than outside
  them — the refusal is set *instead* of an answer, so a response carrying
  both is malformed for the same reason two results are.
- `AgentIntegrationAddressingCodecTests` asserts, from a `Mirror` over the
  request type and over the response type, that each allowlist admits
  **every field on it** — derived rather than listed. That is what makes
  the whole defect class visible rather than these two instances of it.

### What was wrong, kept because the shape recurs

Found while adding the audit operation; both were on `main`, both
untested, and `grep -rn "guestSelector\|notAddressed" now-host/Tests`
returned nothing, which is why neither was failing anything.

- `decodeRequest` omitted `guestSelector` from its `allowedKeys` and from
  every operation's `expectedKeys` — a *strict* object check — so any
  request that actually named a machine was rejected as not matching the
  schema. Nil selectors are omitted by the encoder, which is why the
  single-Mac path kept working and the whole machine-id / session-id
  scheme landed 2026-07-28 could not work through this path at all.
- `decodeResponse` omitted `notAddressed` from its allowlist, so the
  refusal `SocketAgentIntegrationClient` is specifically written to pass
  through as itself arrived as `now-host-invalid-response`: a real refusal
  wearing a protocol error.

Two omissions of one shape is the lesson, not either omission: an
allowlist and the fields it is supposed to admit are two lists that drift
silently, in both directions, and nothing observed it here until an
unrelated feature needed the field.

## NOW-68K has a hardware census, and none of it has run (2026-07-28)

### Unverified, in the strongest sense on this list

NOW-68K answers all fourteen probes of the contract's `x-census`
registry, on both faces (`census.request` on the wire, the `census` verb
for a person), where it previously answered every one of them `refused`
with the note "no probes implemented". **Not one probe has run on a
Macintosh** - emulated or metal.

That is worth stating sharply because the automated cover looks better
than it is. `test_census.c` (native, 680 checks) covers the page, the
cursor arithmetic, the frame bound and both renderers, and the host
decodes three pinned frames. All of that is the half with no Toolbox in
it. Every PROBE is Gestalt, the GDevice list, `PBHGetVInfo`, the drive
queue, the unit table, ADB, `GetSysPPtr` and the Power Manager, and no
gate in this repository can reach any of them.

What a first pass should look at, in rough order of what could plausibly
be wrong:

- **`drivers`** is the riskiest walk. It reads the Device Manager unit
  table from `LMGetUTableBase`, and a driver's name is a Pascal string at
  offset 18 of the driver header - reached through a HANDLE for a
  RAM-based driver and a POINTER for a ROM-based one (`dRAMBasedMask`).
  The flag is checked rather than assumed, but the check has never been
  exercised. Bad names, or a hang, would point here.
- **`power`** picks its call from `gestaltPMgrDispatchExists`:
  `GetScaledBatteryInfo` (a `_PowerMgrDispatch` selector) where that bit
  is set, the classic `BatteryStatus` otherwise. A 180c under 7.1 is
  expected to take the second path. If the machine takes the first and
  the selector is not really there, that is a crash and not a bad row.
- **`pram`** should read `valid $A8` on a machine with a live PRAM
  battery and something else on the 180c, whose battery is dead (the
  entry below). If it reports `$A8` there, the byte is not saying what
  this probe claims it says.
- **`adb`** should find two devices on the PowerBook (keyboard and
  trackball) and may find none under an emulator, which answers
  `absent` - correctly, and worth not misreading as a defect.
- **`ata`, `pccard`, `pci`** should all answer `absent` on the 180c and
  the Q800, each with its reason. An `absent` there is the probe working.

### What is deliberately NOT served, with the reason

Two of the fourteen answer `refused`, which means this build declined to
look rather than the machine saying no:

- **`scsi`.** The contract calls it the declared exception to
  passive-by-rule - an INQUIRY bus scan is active bus I/O - and says
  attended first runs on real hardware are the expected discipline. The
  180c's internal disk is on that bus, nobody has ever attended a scan
  from this guest, and a wedged target on a cooperatively-scheduled
  68030 is a power cycle. `drives` and `volumes` answer what is attached
  without touching it. **Doing this properly means someone in front of
  the machine**, which is the whole reason it is parked.
- **`selectors`.** The PowerPC guest walks a snapshotted table of
  documented Gestalt selectors; that table is 32 KB of names, against a
  384 KB partition. `identity` carries the rows a person actually reads.

### Cost, measured

The 68K binary grew 197,248 -> 215,808 bytes of code (+18.1 KB, ~4.7% of
the partition), and the census owns two ~1.1 KB BSS pages - one in
`wire68.c` for the wire, one in `commands68.c` for the console, separate
because a request arriving while somebody is reading must not overwrite
the page they are reading. Most of the code is the notes: fourteen
probes' worth of sentences explaining what `absent` means on this
machine. That is the trade this subsystem exists to make.

### Still missing beside it

`gestalt` - the five-group verb - is now the largest thing NOW-68K does
not serve, and it is mostly a renderer: `health.c` already samples the
facts and the census now reports most of them again. A host asking for
it by name still gets `unknown-command`.
## NOW-68K's software listing has never touched a disk (2026-07-28)

`software.list` and the `sw` verb are served on NOW-68K
(`now-guest-68k/src/software/`). The status is **tested**, and the half
that is tested is the half with no Toolbox in it.

### Unverified

- **The sweep has never run.** `n68_swenum.c` is pure Toolbox and no gate
  in this tree can reach it. Nothing has confirmed that `PBCatSearchSync`
  finds a single application on a System 7.1 volume, that the disabled
  sibling folders resolve through `FindFolder`, that the parent-chain
  climb produces a launchable HFS path, or that a folder domain's
  two-catalog cursor lands on the right item at the boundary. The
  emulator (`scripts/q800-68k`) can answer all of those and has not been
  asked.
- **The timing is a guess.** The contract records ~4 s cold for the
  equivalent sweep on a PowerBook 1400c. The 180c is a 33 MHz 68030 with
  a much smaller, much older disk, and nobody has measured it. The
  budget in force is `proc_launch_search_seconds()` (20 s by default,
  shared with `launch`), so the honest statement is that the sweep will
  either finish or truncate inside 20 s — not that it finishes.
- **The pump has never been exercised under load.** The sweep calls
  `proc_yield_ticks()` between slices, which runs `wire_idle()` and can
  re-enter the frame reader. That is the DEFECT 3 path proc68.c
  documents; it is guarded by the same single `pumping` flag, which is
  precisely why the pump was exported rather than copied. Nothing has
  pipelined a second request into a running sweep to watch it hold.
- **48 may be the wrong bound.** `NOW68K_SWLIST_APP_CACHE_MAX` was
  chosen from the memory budget (3360 bytes of BSS), not from a count of
  what is on the 180c's disk. If that machine has 200 applications the
  listing is honest and mostly useless; if it has 30 the bound never
  fires. One `sw apps` on metal answers it.

### Open

- **No `version`, no `running`.** Both are omitted on this guest with
  their reasons written down (contract-coverage.md). `version` is the
  one a person is most likely to want, and the bounded way in exists —
  a page is at most ten entries, so ten resource-fork opens — if the
  heap on a 4 MB machine turns out to tolerate it. That is a
  measurement, not a decision, and it has not been taken.
- **`launch` and the listing do not share a search.** `proc68.c` sweeps
  for one named application and `n68_swenum.c` sweeps for all of them;
  the SHAPE is shared (slice, budget, retry, fallback) and the code is
  not. Two sweeps that drift would disagree about which applications
  this machine has, which is the `two-halves-never-met-in-a-test` shape
  one file over. Worth folding together the next time both are open.

## The 180c's garbled capture was 24-bit addressing (2026-07-28)

### Fixed, and confirmed on metal by remedy

A screenshot taken on the PowerBook 180c saved correctly to that machine's
own Desktop and arrived at the host as **structured noise**. `shotdiag`,
run on the 180c, answered it in one pass:

```
Base          0xFC080000
StripAddress  0x00080000
Addressing    24-bit (!)
Walk row 0    04 0F 0D 07 01 04 02 0E 0F 02 0B 0D 08 01 03 0A
Walk again    04 0F 0D 07 01 04 02 0E 0F 02 0B 0D 08 01 03 0A
Blit row 0    00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
Verdict       DIFFERS at byte 0 - wrong memory
```

The machine was in **24-bit addressing**, so the top byte of the
framebuffer's address was thrown away and every raw read went to
`0x00080000` — main RAM. `Walk` and `Walk again` agreeing proves the screen
held still, so the run is valid. `Blit row 0` (CopyBits) is correct, which
is why the on-disk PICT was always fine: QuickDraw resolves addressing
itself. **Confirmed by remedy** — 32-bit addressing switched on in the
Memory control panel, and captures crossed correctly at once.

### Why the earlier refutation was wrong, and the lesson in it

A previous pass retired this exact hypothesis on the grounds that
`vprobe`'s fidelity sweep reported **480/480 rows matching** at base
`0xFC080000` (docs/vram-readout-68k.md, 2026-07-25), so the base must have
been reachable. Re-run beside `shotdiag` three days later, the same sweep
on the same machine reported **480/480 differ, 1st 0**. Nothing had
changed but the Memory control panel setting, which had reverted on its
own — **the PRAM battery is dead**.

So `vprobe` was broken in exactly the same way as the capture, and the
inference drawn from their difference ("the difference between them is the
file the capture opens first") was drawn from a measurement taken in a
different machine state. Two runs of one probe on one machine are not
comparable unless the addressing mode is recorded beside them. `vprobe`
now carries an **Addressing** row for that reason.

### The fix

`core/screen68.c` decides, from the machine's actual state, how a raw read
reaches the framebuffer:

- **32-bit capable** (Gestalt `gestaltAddressingModeAttr` /
  `gestalt32BitCapable`, confirmed by performing the switch once and
  checking low memory `0x0CB2` moved) → `SwapMMUMode(true32b)` around the
  VRAM copy, always, whichever mode the machine is currently in. The mode
  can change between the check and the read — the File Manager runs in
  between on the capture path — so the switch is not conditional on it.
- **not capable, address survives 24 bits** → read it as it is.
- **not capable, address does not survive 24 bits** → refuse the capture
  with a reason. Wrong pixels are worse than a refusal.

**24-bit is the expected state of a vintage Mac, not an anomaly.** Most of
these machines have dead PRAM batteries and come up with 32-bit addressing
off however it was left. Asking a human to set it is not a fix: it reverts
on the next power cycle and reads as a regression.

**The switch wraps the VRAM copy and nothing else.** While switched, the
machine is in an addressing mode the rest of the system was not told
about, so no Toolbox or OS call may be made — and the staged capture
interleaves the read with PackBits and File Manager writes. The copy goes
out through a `row_copy` hook on `N68ShotWireSink`, which keeps
`n68_shotwire_emit()` Toolbox-free (the host `cc` still compiles and drives
it) while the dereference itself happens where the Toolbox is allowed. The
hook is **required**: a NULL is refused rather than filled in with memcpy,
because a caller that forgot would send main RAM at full speed with every
test green.

**`StripAddress` is a different question and is not the fix.** Stripping
`0xFC080000` *is* the bug, spelled deliberately. It is used as a predicate
on the screen's base ("does this address survive 24-bit mode?") and as a
normalisation of the offscreen **band's** base, which is a Memory Manager
block whose top byte is master-pointer flags in 24-bit mode. It never
rewrites the framebuffer address.

There are exactly two addressing modes on a Mac, 24-bit and 32-bit. There
is no 16-bit mode; "16-bit" in `vprobe`'s readout is a read WIDTH and
"8-bit" beside the screen is colour DEPTH.

### Unverified

**Tested, not metal-verified.** The fix has not run on the 180c — nobody
here has a machine. Both guests cross-build, `scripts/test-all` is green,
and the emitted 68K code contains the `_SwapMMUMode` trap (`0xA05D`)
inline, so it links. What a metal pass should show, on a machine left in
its default 24-bit mode:

- `shotdiag` → `Addressing 24-bit`, `Raw read SwapMMUMode to 32-bit`,
  `Walk row 0` equal to `Blit row 0`, `Verdict identical - the base is
  right`.
- `vprobe` in the same session → `Addressing 24-bit, 32-bit for reads` and
  `Fidelity MATCH (480 rows)`, with the bandwidth rows unchanged from
  2026-07-25 (a switch is two traps against passes of 150 ms).
- A capture over the wire, decoded, showing the 180c's screen — with no
  visit to the Memory control panel.

If `Raw read` reads `REFUSED - unreachable`, the machine reported itself
not 32-bit capable and the framebuffer is above 16 MB; that combination is
believed impossible and would be the thing to report.

## Two guests on one port (2026-07-28)

The host serves several guests at once, told apart by the identity in
their `hello` (the name, trimmed and case-folded). Both PowerBooks can
dial one port, and the window can be pointed at either. **Tested, not
metal-verified** — neither machine has been near this, and the emulator
has not either. Nothing below has ever run against a real classic Mac.

One guest is ACTIVE: every request-shaped call (`runCommand`, `exec`,
`listFiles`, `requestCapture`, the modules, the agent projection) drives
that one. What a guest gets regardless is the half it initiates — its
pings, its pushes, and our share served back down its own socket.

### Choosing which Mac

`GuestListener.selectGuest` is now reachable two ways: a pop-up in the
sidebar footer, which appears only when a second machine is connected,
and **Guest ▸ Drive** in the menu bar, rebuilt as the menu opens.

Each module model decides for itself what a switch means to it, and the
decisions are not the same — the reasoning is at each `Snapshot` type,
and the mechanism is one small cache (`GuestScopedState.swift`):

- **Kept per machine**, because it cannot be re-fetched or is expensive
  to: the console scrollback, history and completions; the screenshot
  history; the census dossier; the software inventory; the Files
  breadcrumb and listing.
- **Discarded on a switch**, because it goes stale on its own machine
  faster than a person can read it: the process table. Also every
  in-flight thing — stream brackets, sweeps, loads — which the listener
  has already failed by then.
- **Dropped rather than parked**: a queue of files still waiting to be
  sent. They were meant for the other Mac; the module says so.

A machine that DISCONNECTS keeps its parked state (the same machine
dialling back in finds its own scrollback), except the software
inventory, which dies with the connection exactly as it did before —
a redeployed guest has a different disk.

### A pushed capture now says which Mac sent it

`CaptureDelivery` carries the sender's name and key, stamped in
`Session` from the socket it arrived on. A background machine's push is
filed under that machine — it no longer appears in the driven Mac's
history — and the system notification names the right Mac. It is still
auto-saved to the landing pad, and it does NOT take the clipboard.

**No contract field was added and none was needed.** Which machine sent
a message is answered exactly by which socket it arrived on; a name in
the payload would be a second, weaker copy of that fact. Both guests are
unchanged, and neither now differs from the other.

Visible consequence, not yet addressed: a background push is announced
and saved but appears in no list until you switch to that machine.

### Open

- **Pending requests share one id space across guests.** Ids are drawn
  from one host-side sequence so they cannot collide, and answers from a
  non-active connection are now dropped rather than settling somebody
  else's waiter — but the maps themselves are still flat on the listener
  rather than per guest. A switch fails what was in flight instead of
  keeping it.
- **One stream, one capture, one put, host-wide.** Two guests cannot
  stream at once; the second is refused `stream-busy`. Honest, but a
  limit nobody chose for its own sake.
- **Nothing on screen says a background Mac is doing anything.** The
  picker names the machines and nothing more: a push that landed under
  the other one, a transfer it started, an error it reported are all
  invisible until you switch to it. The roster is the obvious place for
  a badge, and it does not have one.
- **One stream, one capture, one put, host-wide** (see above), and with
  it the reason MCP addressing is an assertion rather than a switch.

### A guest is addressed by a machine id, mapped to its address

Identity used to be the folded `hello.name`. Two consequences, both
wrong: two Macs calling themselves the same thing were ONE guest and the
second was refused `busy`, and — because a deployed guest runs under its
MacBinary name and that name carries the version — every redeploy minted
a phantom machine. An identifier that changes when you deploy is not an
identifier.

There are three identities now, kept apart on purpose
(`now-host/Sources/Host/GuestIdentity.swift`):

| | what it is | who asserts it | changes when |
| --- | --- | --- | --- |
| **machine id** | `pb1400c` — the handle a person or an agent types | the HOST assigns it | only a human rename |
| **session id** | `pb1400c-<uuid>` — one connection | the host mints it at hello | every dial |
| **address** | the peer IP off the `NWConnection` | host-OBSERVED | DHCP |
| display name | `NOW Guest 0.14` | the GUEST asserts it | every deploy |

The roster pairs them: the picker and the Drive menu read
`pb1400c — NOW Guest 0.14`, the log line adds the address, and a caller
gets the id and session id together.

**No contract change, and none was needed.** The address is host-side
knowledge, arriving on the socket; the name is already in `hello`.
Neither guest is touched, neither now differs from the other, and
`docs/contract-coverage.md` is unchanged because nothing about what a
guest SERVES moved.

**Where the id comes from.** Assigned host-side and persisted host-side
(`GuestRegistry`), anchored on the observed address plus a fingerprint
(the hello's os and its name with the version stripped). The reasoning,
including why Gestalt cannot supply one — no serial number;
`gestaltMachineType` is a MODEL; `gestaltSerialAttr` is serial PORTS —
is written out at the top of that file. First sight is `guest-1`,
addressable with zero configuration and flagged auto-assigned; a human
rename makes it `pb1400c`.

**The rules, and what each costs.** An id never silently rebinds:
adoption needs address AND fingerprint to match, so a stranger inheriting
a DHCP lease does not inherit `pb1400c` — and the same rule means a Mac
whose lease changes costs the human one rename. Two machines never
collapse onto one id: ordinals are unique and a rename onto a taken id is
refused naming the holder. Where the address cannot tell machines apart —
loopback, and therefore every emulated guest and every test — a slot
completes the anchor, and the row says `idIsAnchored: false` rather than
pretending.

**The MCP surface is addressable** (local protocol v7). Every tool takes
an optional `guest`: a machine id ("whatever is connected to that Mac
now", which follows a reconnection) or a session id (precise, and refused
`now-guest-session-ended` once that connection is over rather than being
answered by its successor — the same staleness contract the process and
quit references already keep). `now_session_health` reports the driven
machine's reference and the WHOLE roster, so a caller can discover the
ids. Availability by capability is untouched: this decides which machine
a question reaches, never what a machine can do.

Open, from this slice:

- **Addressing is an assertion, not a switch.** Naming a machine the host
  is not driving is refused `now-guest-not-addressed`, with the driven
  machine and the roster in the message. It cannot be answered, because
  the request-shaped listener API drives one session at a time and every
  waiter map is still flat (above). Making an agent call re-point it
  would also take the console out from under whoever is sitting at it —
  a policy question, not just a plumbing one.
- **Not every projection names the guest yet.** Session health, the
  process snapshot and the roster do. Launch, quit, artifact transfer and
  the Files results still carry only the session UUID. They cannot answer
  for the wrong machine — addressing is checked before any of them — but
  a caller reading one of those results alone still has to remember what
  it asked about.
- **The real fix is still a guest-minted id in `hello`.** A stable id the
  MACHINE knows would survive a DHCP change without a rename and would
  tell two emulated guests apart. It is a contract change and both
  guests, deliberately not half-implemented here. The candidates and
  their failure modes — boot volume creation date (a cloned disk yields
  two machines with one id), a self-assigned id in the guest's own
  preferences (PPC preferences key off the BINARY'S name, so a side build
  mints a new one), PRAM (wiped every power cycle on the 180c), the
  Ethernet address (it belongs to a SCSI-Ethernet dongle that moves) —
  are recorded in `GuestRegistry`'s header so the next attempt starts
  where this one stopped.
- **The address is not on the agent surface, on purpose.** The host
  observes it and uses it internally; the companion is told the id, the
  session id and the display name, and nothing about where anything is.
  Being able to NAME a machine does not require being told its address.
  The human-facing halves — the app's roster and its log — do show it,
  because that is the human's own desk.

## The README shows neither interface (2026-07-28)

**Missing, not broken.** There are no screenshots of either half, in a
project whose entire subject is two Macintosh interfaces. A reader is
being asked to take the interesting part on faith, and the README says
so rather than quietly not mentioning it.

Wants: the guest's Workshop window on the classic Mac (the Files page
with a real listing is the most legible single frame), and the host
window from the same session, so the two images are visibly the same
connection from both ends. On real hardware if possible — an emulator
capture is honest, but a photograph of the PowerBook says more about
what this is for.

What to capture and the rules for it (native size, nothing identifying
in frame) are in [images/README.md](images/README.md). Michelle is
taking these; the row closes when they land.

## The 180c, 2026-07-26: two suites metal-verified, the ladder not (0.22)

Five branches merged, deployed as `NOW-68K 0.22`, and run against the
PowerBook. What is now metal-verified, what is not, and three defects
the attempt found.

### Metal-verified on 0.22

- `Metal68KTests` — dial, handshake, keepalive, bounded catalog search,
  farewell, redial. 3 run, 2 skipped, 0 failures, **50.8 s**.
- `Metal68KContractTests` — 3 run, 0 failures, **72.7 s**. Individually:
  an unimplemented message refused in 6.4 s, a second request during a
  confirm wait handled in 15.6 s, an oversized control frame costing one
  message rather than the wire in 67.3 s.

**The control plane is healthy on this machine.** That is the whole of
what tonight added to the metal column.

### Still NOT metal-verified

**The file family, both directions.** `Metal68KPutTests` never produced
a usable result: contended the first time (below), killed the second
when the machine was rested. Receive and send remain emulator-verified
only, and the emulator's ~350 KB/s receive is a 68040's number that
predicts nothing here. No `NOWBASE` baseline lines were captured either
— neither run reached the point of emitting any.

### Broken

- **The handoff cannot retire a build older than `isSelf`.** The
  identity gate correctly refuses to name a process the guest has not
  marked as itself, and 0.19 predates `ProcessListing.isSelf` — so it
  declined to guess, and could not proceed. A one-time migration cliff
  created by the fix itself: the first build carrying the field has to
  be launched some other way. Worth deciding whether the gate should
  accept an explicitly-named outgoing build for this case, or whether
  the answer is simply "a human double-clicks once".
- **`launch` with a colon-bearing HFS path did not launch.** Asked over
  the wire to launch `Macintosh HD:Lab:now-68k:NOW-68K 0.22`, the
  running 0.19 returned no reply within 40 s and the application did not
  start; a human launched it by hand. `proc_launch_named` is documented
  to treat a colon-bearing string as a full path and skip the catalog
  search — which is also the step `deploy-68k --handoff` depends on, so
  this is very likely the root of both failures rather than two.
  **Not diagnosed**; the machine is resting.
- **`Metal68KContractTests` was failing by SUCCEEDING.** Its canary for
  "an unimplemented message is refused and says so" was `file.list`,
  which the browse branch implemented — so the guest answered success
  and the test reported a defect that was really a feature. Repointed to
  `file.move`. A test whose subject is a GAP has to be repointed every
  time that gap closes; picking a message nobody will ever implement is
  the worse alternative.

### The machine set its own limits

A 1 MB push moved **606208 of 1048576 bytes** with 77 progress reports
at a healthy cadence, then stopped; every rung after it got **0 of N**,
including the empty and one-byte cases. Round-trip went from
14.4/21.4/28.4 ms idle to 39.3/266.7/439.5 ms. That run was contended by
another session deploying into the same folder mid-ladder, so it is not
cleanly attributable — but the shape is a silent MacTCP wedge, not a
throughput limit, and a machine that is merely slow does not fail a
zero-byte transfer.

Later that evening the display began to flicker and the machine was
rested. The same panel failed mid-session days earlier.

The 4 MB rung exists to find protocol bugs at scale and the emulator
finds those for free, while on this machine a serial multi-megabyte push
is what wedged the stack. The parent corpus carries the envelope as
`vintage-laptop-sustained-load-envelope`: **ladders on the emulator,
character on the metal, sessions in minutes.** If the boundary is ever
worth finding, the experiment holds total bytes constant and varies
burst size and rest between bursts rather than climbing a size ladder.

## The 68K file family's browse half (2026-07-26)

`file.list` / `file.listing` and the `ls` command. Additive: both messages
were already in `contract/asyncapi.yaml`, already decoded by the host, and
already served by the PowerPC guest — checked before designing, and
nothing in the contract changed. NOW-68K now serves 15 inbound message
types.

### Broken

Nothing found in this pass. What the pass DID find is below, under
unverified — most of it is about what a small frame costs.

### Unverified

- **Indexed catalog cost at a deep cursor is unmeasured.** `PBGetCatInfo`
  at index N on a large folder is not O(1), so a host paging into a
  thousand-entry folder pays more per page the further in it goes. Never
  measured, on either machine. If it ever needs bounding, the bound
  belongs in `n68_fileenum.c` as a wall-clock budget with an honest
  "truncated at the budget" answer — `proc68.c`'s
  `kLaunchSearchBudgetTicks` is the local pattern — and NOT as a silently
  short page. Nothing pages a large folder today, which is the only
  reason this is parked.
- **Nothing has browsed the 180c.** Emulator-verified only, on a Quadra
  800 under Mac OS 8.1: a host lists files it just pushed, walks a
  twelve-file folder across several pages losing nothing and duplicating
  nothing, gets a `file.refuse` (not a timeout) for a folder that is not
  there, and sees the same entries through `ls`. That rig is a 68040 with
  128 MB and a cached disk; the 180c is a 68030 with 4 MB and a real one.
  `Metal68KBrowseTests` is the gate to point at it.
- **A worst-case page carries ONE entry.** This guest's outbound payload
  cap is 1024 bytes against the PowerPC guest's 4 KB, and an HFS name of
  31 accented characters escapes to 186 bytes of `\uXXXX`. The
  arithmetic is pinned by static asserts and by
  `test_filelist.c`, so this is correct behaviour rather than a defect —
  but a host that assumed a page means a folder would be wrong here in a
  way it is not against the other guest. Never observed: no folder on
  either test machine has names like that.
- **A UTF-8 path does not resolve.** NOW-68K has no UTF-8-to-MacRoman
  decoder, so a host asking for `Café:Notes` sends bytes this guest
  cannot turn into an HFS name and gets `not-found`. Truthful, and the
  same property the receive half already has (`n68_putrx.c`), so the two
  halves at least agree — but a folder a person can see in the Finder is
  a folder the Files module cannot open. The PowerPC guest decodes
  (`now_json_find_text`); this one needs the same table before it can.
  `GuestWireConformanceTests.testHfsPathArgumentsAreTextDecoded` does not
  catch it, because it checks for the wrong FUNCTION and this guest's
  scanner has a different name.
- **`identity` is absent from every entry.** Deliberate — it is a
  precondition token for mutations this guest does not serve, and nothing
  in `now-host/Sources` reads it. It is the first field to add if
  `file.move`, `file.trash` or `file.get` ever land here, and adding it
  costs ~30 bytes of a 1024-byte page, which is roughly one entry.
- **Three row-array commands still answer inside
  `now68k_commands_dispatch`.** `help`, `ps` and `vprobe`. The result
  type `docs/command-parity.md` called for now exists (`N68CmdRows`) and
  `ls` uses it; moving the other three is a refactor of working code that
  was deliberately not done in the same change as a new message family.
## An abandoned transfer wedged NOW-68K against all future ones (2026-07-26)

`file.cancel` appeared nowhere in `wire68.c`'s dispatch. The guest sent
`file.progress` and handled no cancel inbound, so the question nobody had
answered was what it actually did when a host walked away mid-transfer.
The answer was worse than "it leaks a staging file", and the ledger
entry is the finding rather than the fix.

### What it did, measured before anything was changed

A fake host (a probe, not a fixture — it speaks just enough of the
contract to arm a transfer and then abandon it) against `0.19` on the
Quadra 800 emulator, all on ONE connection that stayed up throughout:

```
-> file.begin transfer 11 ... 8 KB of bulk ... file.cancel {transfer:11}
<- {"type":"error","code":"not-implemented","message":"unsupported message type"}
-> file.offer id 2
<- {"type":"file.refuse","id":2,"code":"busy","reason":"a transfer is already in flight"}
-> command.request put
<- {"ok":false,"error":{"code":"put-refused","message":"a file is arriving right now"}}
```

The guest **answered the cancel with `not-implemented` and kept
holding the transfer**. Every later transfer, in either direction, was
refused for the life of the connection — the lane is one transfer wide
and shared across both — and pings were answered normally the whole
time, so from the host's side the guest looked healthy and simply
refused to move a byte ever again.

### Why nothing rescued it

- **There is no transfer timeout, and there is no message for "I have
  lost interest".** An abandoned transfer is indistinguishable from a
  slow one, and neither `n68_putrx` nor `n68_puttx` carries a clock.
- **The only clock in reach is `service_live()`'s 65 s no-traffic
  watchdog, and it is the wrong one.** It is a property of the
  CONNECTION — `kWireDeadTicks` since the last inbound byte — and the
  guest's own 30 s keepalive ping keeps being answered, so on a live
  connection it never fires. A DROPPED connection was always fine
  (`reset_read_state` cancels both directions, which closes the
  outbound fork and deletes the staging file); the case nobody had
  established is a host that stays connected and stops caring.
- The receive half held its staging file (`NOW incoming <hex>`) open
  for a transfer that would never end. Observed as the wedge; the
  orphan on the Desktop follows from the staging file never being
  discarded and was not separately confirmed on the baseline disk.

### The send half had a second door into the same wedge

Found on the way. The host sends `file.cancel` **and** `file.done`
together the moment its sink fails (`GuestListener.swift ::
failInboundStream`), and `n68_puttx_done()` acted only in
`kN68SendEnded` — so a `file.done` arriving while bytes were still going
out was dropped, the guest streamed the rest of the file at a host that
had already discarded it, and then parked in `kN68SendEnded` waiting for
a reply that had already been and gone. The host does not send a second
one: `finishFile` returns early for a transfer it is discarding. **A
receiver's `file.done` is final whenever it arrives**; requiring our own
`file.end` first is what made the park permanent.

### Fixed, and what the fix is verified to do

No contract change was needed — `FileCancel` and `file.done`'s
`cancelled` code were already there, which is worth recording because
the gap was entirely on the implementing side. `file.begin`'s `transfer`
is now remembered, because `file.cancel` names a transfer and carries no
id, so nothing else could tell a live cancel from a late one.

Same probe, same emulator, `0.20`:

| Probe step | Result |
|---|---|
| cancel a push after 8 KB | `file.done ok:false code:cancelled received:8192 cleanup:temp-discarded` |
| offer again immediately | accepted, completed, CRC-confirmed |
| cancel the guest's own send mid-stream | `file.end ok:false`, **0 bulk frames after the cancel** |
| ask for that send again | offered again — the lane is free |

`cleanup:temp-discarded` was checked against the disk rather than
believed: `hls` on the session image afterwards shows the completed
`After Cancel` and **no `NOW incoming`** staging file. (`xfer_tmp_1` in
that listing predates this work by weeks and is base-image debris.)

The deliverability claim in `n68_puttx.h` rule 3 held up under the one
case it exists for: the cancel was acted on one chunk after it arrived,
not at the end of the transfer. A staged bulk frame nobody has seen is
dropped; one already part-way out finishes, because a frame cut short is
a desynchronised wire rather than a cancelled transfer.

### Still open

- **Not on the 180c.** Emulator-verified only, and the emulator is a
  68040 with 128 MB. The behaviour under test is a state machine rather
  than a rate, so it should carry — but nobody has watched it.
- ~~**A cancel has no console face.**~~ Closed in the same pass. It is
  a `cancel` verb now — contract's `x-commands` first, then
  `commands68.c`, which the console reaches through
  `now68k_commands_run` without conwin.c gaining a second dispatch, so
  both faces run one implementation and `help` lists it. Verified on
  the emulator from the console face specifically: `help` shows the
  row, a quiet machine answers `nothing-to-cancel` rather than
  pretending, and the verb produces the same `file.done ok:false
  code:cancelled cleanup:temp-discarded` the wire message does. The
  PowerPC guest deliberately gains no verb — a host cancels it from
  the Files UI and a person at that guest from its own Workshop — and
  that decision is named with its reason in
  `CommandRegistryTests.notOnThePowerPCGuest` rather than left as a
  silent gap.
- **The other 65 s window is unexamined.** A host that abandons a
  transfer AND stops answering pings is cleaned up by the watchdog, but
  no one has watched that path either, and it is the only path in which
  a transfer's cleanup depends on a timer.
- The probe lives in a scratchpad, not the repository. Turning it into
  a metal gate belongs with whoever is working on that harness; it
  needs `requireTheBuildUnderTest()` before anything it reports can be
  believed.
## `front`, on both faces of both guests (2026-07-26)

`process.front` had been on the PowerPC guest's wire since the Processes
module was built, and there was no way to **type** it — not at either
guest's own keyboard, and not from the host console, which is a dumb
shell that knows no message families. A capability reachable only by
clicking a button in one module is the `ps` shape exactly
([command-parity.md](command-parity.md)).

So `front` is now a contract `x-command` served by both guests, over the
same list → match → re-validate → act → re-check composition `quit`
uses, and NOW-68K additionally answers the `process.front` drive verb it
did not before. Its outcomes are deliberately not `quit`'s with the
words changed: `not-running` is ok:**false** here (nothing can bring
forward a process that is not there, where quit was asked to produce
exactly that state), and NOW itself is a fair target (fronting severs
nothing; quitting would cut the reply mid-send).

### Unverified

- **The confirm branch has never run.** `SetFrontProcess` returning
  noErr means the switch was *scheduled*; it lands when the guest
  yields, and both guests yield with an event mask of zero. Whether a
  process switch completes inside that yield is **unproven on either
  machine** — if it does not, `front` will report `unconfirmed` every
  time while the screen plainly shows the switch happened. That is
  visible and diagnosable rather than a silent lie, which is why it is
  written this way, but it is the first thing to watch on metal.
- Nothing else here has been on a machine either: both guests build
  clean, the host suite is green, and no PowerBook has run it.

### Open

- **`front`'s argument parser is not natively testable.** `quit`'s
  grammar lives Toolbox-free in `proc_quit_args.c` and has its own
  native test; `front`'s is four lines of trim-and-unquote, static in
  each guest's command file, and duplicated across the two. It is small
  enough that a shared module would be more moving parts than it saves —
  but it is the second copy of a grammar, which is how the first one
  started.

## `quit` targets a process identity, not a file name (2026-07-26)

The handoff's retire step named the outgoing build `"NOW-68K " + <the
version it reported in hello>` — a FILE NAME derived from a compiled
constant. They agree by convention only. On 2026-07-25 a build deployed
as `NOW-68K 0.18` reported `0.16`, so the retire sent
`quit NOW-68K 0.16`, the guest answered honestly that nothing of that
name was running, the old build kept running, and a 4 MB machine was
left with two NOW-68Ks. Nothing was broken on the guest; the identifier
was invented on the host.

Fixed by naming the target the way a machine should:

- `process.listing` gained **`isSelf`** (contract first), set by both
  guests on their own row. It is the only trustworthy answer to "which
  process is on the other end of this connection".
- NOW-68K now answers the contract's **`process.quit`** drive verb —
  re-validate the PSN, refuse self, send — over `proc_quit_psn`, the
  same three steps `proc_quit_named` ends with. It does not confirm, and
  that is the contract's decision: `process.result.ok` means DELIVERED,
  and there is no field that could tell a granted quit from a declined
  one. A caller confirms by re-reading `process.list`.
- The `quit` command still takes a name, because a person types what
  `ps` shows them. `ps` now says `self` on that row, on both guests.

### Unverified

- **None of it has been on a machine.** Both guests build clean and the
  host suite is green (511 tests), but `isSelf`, `process.quit` on
  NOW-68K, and the PSN-targeted handoff have not run on the 180c. The
  loopback test `HandoffIdentityTests` reproduces the version/name
  disagreement over scripted guests and watches the old derivation fail
  — that proves this side never invents an identifier, and proves
  nothing about the Toolbox code.
- **The first handoff has to be launched by hand.** The build currently
  on the 180c is 0.19: it serves `process.list` without `isSelf` and
  does not answer `process.quit` at all. `Handoff68K.identifySelf` fails
  with a message saying so rather than falling back to a name — a
  fallback would be the defect, reintroduced. From 0.20 onward the
  handoff is automatic again.
- **`process.front` and `process.shot` are still unimplemented on
  NOW-68K.** They fall through to `send_error_reply`, visibly. Only the
  verb the handoff needed was added; the family is deliberately partial
  rather than quietly half-served.

### Open

- The host's `ProcessEntry.id` is `name#code#creator`, so two processes
  of the same name collide in the table's identity — exactly the case
  `isSelf` and the PSN exist to handle, one layer up. Not hit by
  anything today; worth the PSN when it is.

## The 68K file family, both directions in one tree (2026-07-25 night)

Three branches merged and verified together: the receive half (MacBinary,
Desktop landing, the `FSClose` fork repair), the send half (the
byte-source sender), and the version-bump commit that carried them to the
machine. What that merge found, and what it left open.

### Broken

- **~~The two halves disagreed about where files live.~~** Fixed in this
  pass, and worth keeping in the ledger for how it hid. Receiving landed
  on the Desktop, sending read from the application's own folder; each
  branch was self-consistent, so no reviewer of either could see it. It
  survived the merge (no textual conflict — two roots in two files), 27
  native tests, 508 host tests, both Xcode configs, and `-Werror`. The
  round-trip ladder on the emulator named it as `fnfErr` on all ten
  rungs. **A cross-direction test is the only kind that could have
  caught this, and it could not exist while the halves were on separate
  branches.** `now68k_desktop_folder` is now published from
  `n68_putfile.h` and both directions read it.
- **A merge can drop an `#include` with no conflict.** `git` took one
  side's include block wholesale and `<Processes.h>` went with it. The
  block was never marked conflicted, so reviewing the conflicted hunks
  would not have shown it. `-Werror` caught it; nothing else would have
  until link time.
- **A conflict region can cut a function mid-body.** The resolution
  looked complete — every declaration present — and the function simply
  never closed, which the compiler reported as four *unrelated*
  functions being "defined but not used" and a fifth reaching the end of
  a non-void function. The error names never mention the function that
  is actually broken.
- **The handoff's retire step may quit the wrong build.** `NOW-68K 0.17`
  reached the 180c and its log reads `wire: connected` then `cmd: quit
  ok 0` — the incoming build took a quit and executed it, where the
  outgoing one was meant to. Not diagnosed, and **not confirmed**: the
  run it came from was contended (see below), so this is a suspicion
  with a log line behind it, not a defect with a repro.

### Unverified

- **Neither direction has moved a byte on the 180c.** Both are
  emulator-verified on a Quadra 800 under Mac OS 8.1 — receive 4 MB in
  11.7 s (350 KB/s, 512 progress reports, CRC-confirmed), send 4 MB in
  1.8 s, MacBinary both forks, control lane 0.05 s idle against 0.10 s
  during a 1 MB push. A 68040 with 128 MB is not a 68030 with 4 MB, and
  the send rate in particular reads off a disk the emulator caches —
  read it as "the path works", never as a rate.
- **The PackBits ratio and encode cost are unmeasured.** `vprobe` has
  the framebuffer READ at 159 ms for a 300 KB frame
  ([docs/vram-readout-68k.md](vram-readout-68k.md)); nobody has measured
  what compressing it costs on a 33 MHz 68030, and **the ratio is what
  decides whether screenshots are viable over MacTCP at all**. No branch
  in this repository implements PackBits. The send half was built as a
  byte source (`n68_bytesrc.h`) precisely so a capture can feed the pipe
  in bands rather than buffer 300 KB against a 384 KB partition — that
  shape held through the merge, so a screenshot sender does not need a
  second send path.

### Two host sessions can contend for one PowerBook, invisibly

A metal run of these suites on 2026-07-25 held port 5252 for the better
part of an hour while another session deployed a build into the same
folder mid-ladder. The results were unattributable: a 1 MB push stalled
at 606208 bytes and every rung after it timed out at `0 of N`. The most
likely cause is contention rather than a defect — NetPresenz serving an
FTP upload while NOW-68K received a push, both on MacTCP, on a 68030
with 4 MB — but nothing proves that either, which is the point.

**`requireTheBuildUnderTest()` would not have caught it.** That guard
asks whether the connected guest is the right *guest*, and it was. The
gap is that nothing establishes whether the *machine* is already busy.
`lsof -iTCP:<port>` before a run answers it in a second. The existing
rule covers several guests reaching one listener; this is several
listeners reaching one guest, and it is not written down anywhere else.

**Fixed on 2026-07-26**, test-side only — see `MetalMachineGuard` and
[68k-metal-runbook.md](68k-metal-runbook.md). Before any 68K metal suite
binds, it establishes that nothing else on this Mac holds the port and
(when `NOW_METAL_MACHINE` names the guest's address) that nothing else
is talking to the machine, and fails in about a second naming the
process rather than producing an unattributable result. It also reports
a bind failure as a bind failure: the suites used to wait out a full
120 s and say "no guest dialled in", which aims the diagnosis at the
Macintosh for a fault entirely on this side.

What it still cannot see is below, and it is the honest limit of the
fix.

### A host cannot ask a 68K guest whether it is busy

**Found 2026-07-26 while building the guard above; no code changed.**

NOW-68K knows perfectly well whether it is mid-transfer in either
direction, and renders exactly that: `xfer` reports an active receive
with its byte count, an active send, and the last completed one either
way. **There is no way for a host to ask.** `xfer` is console-only by a
recorded decision (`CommandParityTests :: consoleOnly` — "renders the
file.* family's state; the host reads it from file.progress and
file.done instead"), and the PowerPC guest's wire-only `putstat` has no
68K counterpart.

That reasoning holds for a host that is *driving* the transfer, which is
the case it was written for: such a host has the progress messages. It
does not hold for a host that wants to know whether the machine is free
before it starts — which is precisely the question the contended run
needed to ask and could not. So contention detection is host-side only,
and the guard says so rather than guessing.

Not fixed here, because it is a product change and this pass was tests
and documentation. If it is taken up, the cheap version is a `busy`
verb (or an `xfer` promoted to both faces per
[command-parity.md](command-parity.md)) answering the two booleans and
the two byte counts `N68PutStatus` / `N68SendStatus` already hold. The
gap it would close is real but narrow: it tells a second session that
the machine is busy, and tells it nothing about who has it.

Related and unresolved: the name a build has on the disk and the version
it reports on the wire are established by different means, and a guest
answering `"version":"0.16"` was found on a machine whose deploy folder
had just gained a file named `NOW-68K 0.18`. Whether those were the same
application was never established. `deploy-68k` stamps both from one
source, so this only arises when something bypasses it.

### `--filter Metal68K` used to report a failure that meant nothing

**Fixed 2026-07-26**, test-side only. `Metal68KHandoffTests` is a deploy
step, not a coverage gate: it needs a freshly uploaded build and the
exact HFS path of it, which only `scripts/deploy-68k --handoff` knows.
It used to FAIL when those were absent, on the argument that asking for
a metal run with no build to hand off to is a broken invocation — sound
in isolation, but `--filter Metal68K` catches that class too, so every
ordinary 68K metal pass reported one red that meant nothing. A red that
always fires is a red nobody reads.

It now SKIPS when `NOW_68K_NEW_APP` is unset, with the same second
opt-in shape `MetalQuitTests` already uses for the dirty-document case
("NOW_METAL=1 alone does not say a human is at the keyboard"). Set but
EMPTY is still a failure, because that is somebody having tried.

This is a deliberate exception to "a metal gate fails rather than
skips", and it is narrow: the thing being skipped is a deploy action,
not evidence about the guest.

### NOW-68K cannot send the same file twice, and says it can

**Found 2026-07-26 on the emulator, by the repeat sampling above; no
code changed.**

`n68_puttx.c`'s offer never sets `overwrite`, so the host applies the
contract's default of false (`GuestListener.acceptOffer`) and REFUSES
the second offer of a name the share already holds. That is defensible
policy — the host will not silently replace a file — but the guest end
of it is not honest:

- `put <name>` has ALREADY answered `ok` by then, because the command
  returns as soon as the offer is away (deliberately: a command that
  blocked for a multi-megabyte transfer would hold a `command.result`
  for minutes). So the person who typed it is told it worked.
- The refusal arrives afterwards as `file.refuse`, and the only place it
  surfaces is `xfer`'s "last FAILED" line — which nobody has a reason to
  type after being told `ok`.

From the host side it presents as a transfer that never starts: the
offer goes out and nothing ever arrives. It cost a 300 s timeout per
sample to work out, and read exactly like the machine having gone away
— the same signature as the contended run, from an entirely different
cause, which is worth knowing on its own.

Not fixed here (product change; this pass was tests and docs). Three
candidate fixes and they are not equivalent: the guest could set
`overwrite` on its offer (wrong — that hands a guest the right to
replace files on the host), the host could decline more visibly, or the
guest could hold the send's outcome somewhere `put`'s caller can reach.
The last is the one that matches the direction the contract already
takes for progress.

The suites work around it by naming every sample separately
(`RT<size>r<rep>`), which is a harness fix and not a fix.

### Two `swift test` runs on one Mac fail three suites

**Found 2026-07-26, reproduced deterministically; pre-existing, no code
changed.** Three suites share state outside the process:
`HostLogTests` and `LoggingSpecTests` both write
`~/Library/Logs/now-logs`, and `HostAppStateWiringTests` binds a fixed
port 52981. Running two `swift test` processes concurrently fails them
every time.

It surfaced here because a metal pass and an ordinary gate run overlapped
by a few seconds, and the result was two failures that vanished on
re-run — the flakiness signature, from a cause that is not flaky at all.
Worth fixing at some point (a per-process log path and an ephemeral
port), and worth knowing meanwhile: the runbook says one at a time.

### What a 68K metal run should record

[68k-metal-baseline.md](68k-metal-baseline.md). In short: the suites now
emit one greppable `NOWBASE` line per measurement, carrying the
conditions (build, machine, port) beside the numbers, because the
2026-07-25 run's numbers were real and unattributable. `NOW_METAL_REPEATS=3`
takes three samples of every rung at or above 1 MB, so a rate can be
told from an interruption — which one sample from this machine
demonstrably cannot do.

## Host -> guest file transfer on NOW-68K (2026-07-25)

NOW-68K receives a pushed file. Offer, accept, stream, checksum, done -
the contract's `hostPutsFiles` sequence, served by the guest that
previously discarded every bulk frame to stay in frame sync.

**Emulator-verified, NOT metal-verified.** Everything below was measured
on a Quadra 800 under Mac OS 8.1 with 128 MB (`scripts/q800-68k`). The
real target is a 68030 under System 7.1 with 4 MB. What carries over is
correctness; what does not is every number in the table.

| Size | Result (emulator) |
|---|---|
| 0, 1, 8191, 8192, 8193 B | ok - the boundaries either side of one frame |
| 64 KB | ok, 299 KB/s |
| 256 KB | ok, 348 KB/s |
| 1 MB | ok, 357 KB/s |
| **4 MB** | **ok, 11.6 s, 352 KB/s, 512 progress reports** |

The 4 MB file was pulled back off the disk image with hfsutils and is
**byte-identical** to what was sent (CRC-32 `A627E416`, agreeing with
zlib and with the guest's own). The catalog shows exact sizes rather
than allocation-block-rounded ones, so the `Allocate` + EOF-trim pair
works, and no `NOW incoming ...` staging file was left behind.

The guest's event loop is not starved by the receive path: `help`
round-tripped in 0.05 s during a 1 MB transfer against 0.06 s idle.

## MacBinary on NOW-68K: the fork corruption, found and fenced (2026-07-26)

Full record: **[68k-file-receive.md](68k-file-receive.md)**. In short.

`FSClose` of a written resource fork on Mac OS 8.1 splices 77 bytes of
File Manager catalog state into the fork's first block at offset 48 - an
in-memory record layout that matches nothing on disk. Deterministic:
every resource-carrying MacBinary file, every run; data forks never; a
MacBinary file with an empty data fork never affected.

Pinned by three structural facts, in this order: the splice is
sub-sector, so the bytes were wrong in RAM and no allocation-level
theory survives; the spliced content carries the staging name and
`BINA` but both FINAL fork lengths, which brackets the write to the
close window and explains why disabling `Allocate`, `SetEOF`,
`FSpRename`, `FSpSetFInfo` and `PBSetCatInfo` each missed; and read-back
probes read clean before the close and spliced after it, 5/5.

The guest keeps the fork's first 512 bytes as written, re-reads them
after the close and after the rename, rewrites them when they diverge,
and re-verifies through a fresh open. Unrepairable before rename fails
the transfer; after rename it deletes the file rather than leave a
corrupt application to be double-clicked. Detected 5/5, repaired in one
round 5/5, raw disk clean, both forks byte-identical.

**Still open, and the first is the one that matters:**

1. **System 7.1 on the real 180c is untested** - the 7.5.3 image in the
   lab has no MacTCP, so the OS discriminator is blocked. The shipped
   probes double as the experiment: push one MacBinary file and the log
   either names the scribble or stays silent. Either answer is safe.
2. QEMU's contribution is not separated from 8.1 itself.
3. The PowerPC guest's resource forks have never been byte-verified.

### What is deliberately not there

- **No resume.** The guest never reports `have`, which the contract
  reads as "start from the beginning". Partials are always discarded.
  Deliberate: resume is an open hang on the PowerPC side (see the large
  transfer notes) and a 4 MB transfer is not long enough to make
  restarting a hardship.
- **~~Receive only.~~** Superseded — NOW-68K now sends as well as
  receives; see the next section. `file.list`, `file.move`,
  `file.trash` and the host-initiated PULL (`file.get`) still answer the
  generic not-implemented error, so the guest can push a file it is told
  to push but cannot serve a host that wants to browse or fetch.
- **~~The destination is the application's own folder.~~** Superseded —
  **files land on the Desktop, and nothing is gated.** NOW-68K has no
  preferences and no share root, so there is nothing to read a
  destination out of. The Desktop needs no state to name and is where a
  person looks for something that arrived. `path` from the offer still
  resolves relative to it and a host may reach a subfolder — deliberate
  until the browse/ls verbs exist, because a boundary drawn before
  there is anything to browse is a guess dressed as a policy. It was
  briefly the application's own folder, which meant a host could write
  into the System Folder. The send half still reads its SOURCE from the
  application's own folder (`now68k_app_folder`), which is a different
  root for a different direction and deliberately so.

### Open

1. **Nothing has run on the PowerBook 180c.** Everything above is an
   emulator result. The 180c has 4 MB against the emulator's 128, a
   68030 against a 68040, and MacTCP that has already been observed to
   wedge silently on that machine. A 4 MB transfer into a 384 KB
   partition is exactly the shape that behaves differently there.
2. **A contract gap: `FileRefuse.code` has no value for "this receiver
   cannot handle that".** An unrecognized container is reported as
   `io-error` with the truth only in `reason`, which is a lie of
   category - nothing failed, the request was never serviceable. The
   honest fix is an additive enum value in the contract, which touches
   both halves and was out of scope for a spike. (Unknown containers are
   now REFUSED rather than treated as `data`; writing an unknown
   envelope out as a raw fork produces a file of the wrong length and
   the wrong shape and blames the disk.)
3. **`FileOffer.modified` has no stated units in the contract.** Both
   guests treat it as Mac-epoch seconds (it goes straight into
   `ioFlMdDat`), and the two agreeing is the only reason it works. It
   should be written down.
4. **The host never uses the `chunk` it negotiates.** `hello.chunk` is
   computed and echoed (`GuestListener.swift`), but the file sender's
   frame size is a hardcoded 8192. NOW-68K advertises 4096 for a stated
   MacTCP reason and is sent 8 KB frames regardless. Harmless today - the
   guest streams and needs no frame-sized buffer - but the negotiation
   is decorative, and a guest that genuinely could not take 8 KB would
   have no way to say so.
5. **The application partition is getting tight.** This pass cost
   +19408 bytes (~5% of 384 KB), leaving roughly 184 KB of image before
   stack and heap. Preferred == minimum on a 4 MB machine, so there is
   nothing to borrow. The next addition this size needs the budget
   looked at rather than assumed.
6. **`g_sink` is still 256 bytes**, inherited from when it was a pure
   discard sink. A 4 MB transfer therefore makes ~32 passes per 8 KB
   frame. Cheap memcpys, but it is a knob nobody has measured on the
   180c, where BSS is the scarcer resource.

## Guest -> host file transfer on NOW-68K (2026-07-25)

The other direction. NOW-68K makes the offer, streams the bulk frames
and closes with a checksum: `file.offer` -> `file.accept` ->
`file.begin` -> bulk -> `file.end` -> `file.done`. **Additive — no
contract schema changed.** Every message and every field already
existed, is already served by the host (`GuestListener.onAcceptOffer` /
`finishInbound`) and is already sent by the PowerPC guest; that was
verified against the schemas rather than assumed.

**Emulator-verified, NOT metal-verified.** Measured on a Quadra 800
under Mac OS 8.1 with 128 MB (`scripts/q800-68k`), driven by
`Metal68KSendTests`. The real target is a 68030 under System 7.1 with
4 MB. What carries over is correctness; what does not is every number.

Each case pushes a known pattern to the guest, asks the guest to send
that same file back, and compares the bytes **the host still holds**
against the bytes that came back. Nothing in the comparison comes from
the guest's own accounting — not its progress, not its CRC, not its
byte count, because a sender marking its own work proves nothing.

| Size | Result (emulator) |
|---|---|
| 0, 1, 4095, 4096, 4097, 8192 B | ok — the boundaries either side of one chunk |
| 64 KB | ok, 313 KB/s |
| 256 KB | ok, 1227 KB/s |
| 1 MB | ok, 2198 KB/s |
| **4 MB** | **ok, 2.5 s, 1648 KB/s, byte-identical** |

Sending reads from a disk the emulator caches, so these rates are
several times the receive direction's 352 KB/s and mean nothing about
the 180c, where the read is a real one off a real disk.

**The wire-sharing rule holds under real back-pressure**, which is the
claim nothing off-metal can check: during a 4 MB send, 28 `help`
requests were answered, **none dropped, worst 0.10 s**. That is the
rule working — control drains before bulk, and a reply waits for the
chunk in flight rather than for the transfer.

The 0-byte case is worth its row: a zero-length source sends **no bulk
frame at all**, begin then end, and the receiver closes out correctly
rather than waiting for a stream that never comes.

### It is a byte-source sender, not a file sender

The point of the shape, stated because it is the thing most likely to
be undone by someone in a hurry. The source is an interface
(`n68_bytesrc.h`) with four promises: it knows its length before the
first fill, it returns promptly, it does not allocate, and it never
touches the wire. A file (`n68_filesrc.h`) is the FIRST implementation,
not the only intended one — a screen capture is ~300 KB against a
384 KB partition, so it can never be a buffer and cannot be staged to a
disk that may not have room. **If a screenshot ever needs a second,
parallel send path, this was built wrong.**

### How bulk and control share the wire

Stated once in `n68_puttx.h` and enforced in `flush_outbound()`:

1. Bulk never touches the four 1024-byte control slots; it has one
   dedicated 4104-byte slot, so no volume of bulk can consume the slot
   a `command.result` needs.
2. A frame already being handed to `net_queue_send` finishes before any
   other frame's first byte.
3. Otherwise control drains before bulk, so a reply queued mid-transfer
   waits for the chunk in flight (~12 ms) and never for the transfer.
4. Back-pressure is `net_queue_send`'s short accept and nothing else.

Rule 4 is the one that will read as a bug later, so: this side does
**not** need the receiver's `file.progress` to clock itself and the
host **does**. MacTCP's staging buffer is small and reports truthfully
and synchronously how much room is left; the host writes into
Network.framework, which accepts essentially unbounded writes and so
tells it nothing. Two senders, two mechanisms, neither one the other's
bug.

### Parity: `put` is on both faces here, and console-only on the PPC guest

Deliberate, and the two guests genuinely differ. A host driving the
PowerPC guest reaches the same capability through `file.list` and
`file.get`, so that guest needs no verb. NOW-68K is the machine whose
display has already failed mid-session and whose host console is a dumb
shell with no knowledge of message families — so on that guest the
capability is a verb in `commands68.c`'s table, reachable from both
faces through one implementation. The contract declares `put` in
`x-commands` first, per AGENTS.md.

`CommandRegistryTests` had to learn this: it assumed the registry IS
the PowerPC guest's command set. NOW-68K always answered a strict
subset, which that test never had to notice; `put` is the first command
going the other way, and it is named in `notOnThePowerPCGuest` with its
reason rather than subtracted silently.

### Open

1. **Nothing has sent a byte on the 180c.** The emulator results above
   say the code is correct; they say nothing about a 68030 with 4 MB,
   whose MacTCP has already been observed to wedge silently. Reading a
   4 MB file off a real disk while streaming it is exactly the shape
   that behaves differently there.
2. **Several guests can reach one listener, and one of them is not
   yours.** Every QEMU guest on this Mac sees the host as `10.0.2.2`
   under user-mode networking, so any session's VM can answer any
   session's listener. This cost real time: the first run of
   `Metal68KSendTests` reported `unknown-command` for `put` from a
   guest that was simply another branch's build — and the refusal test
   PASSED against it, because "unknown command" is also a refusal with
   a reason. `requireTheBuildUnderTest()` now asks the connected guest
   whether `help` lists `put` before believing anything it says. Run
   with `NOW_METAL_PORT` set to something nothing else is dialling.
3. **No MacBinary, so no application and no resource fork.** The data
   fork only — which is the contract's own default for a both-forks
   file, so it is legal rather than a shortcut, but it means a file
   whose content lives in its resource fork (most classic Mac
   applications, every ResEdit document) arrives empty or meaningless.
   This is the natural SECOND implementation of `N68ByteSourceOps` —
   header, data fork, padding, resource fork, each in bands — and
   writing it is the real test of whether the interface earns its keep.
4. **The source is limited to the application's own folder.** Same
   weakness the receive half has and for the same reason: NOW-68K has
   no share root. `put` takes a leaf name, not a path.
5. **One transfer at a time is enforced across both directions**, and
   the answer to a second request is `busy` with a reason. Not
   exercised against a host that offers a push while a send is in
   flight — the check exists and has never been raced.
6. **A contract gap, the mirror of the receive half's.** `FileEnd` has
   no way to say "the sender's own source let it down", so
   `kN68SendSourceFailed`, `kN68SendShort` and `kN68SendLong` all
   render as `io-error` with the truth only in the reason. Same honest
   fix: an additive enum value.
7. **The contract's operations index is asymmetric about this
   direction, and was before this change.** `guestServesFiles` lists
   `file.begin`/`end`/`progress`/`refuse`/`listing` but not
   `file.offer`; `file.accept` and `file.done` appear in **no**
   operation at all, in either direction, though both sides send both.
   The schemas are complete and correct — this is the index above them.
   Left alone rather than fixed in passing: it is a contract edit that
   touches how both halves are described and deserves its own pass.
8. **`sendMs` is computed from `TickCount` at 1/60 s.** Fine for a
   figure the contract types as advisory, but it is not milliseconds
   measured, it is ticks scaled.

### Two defects found by this pass, in code that predates it

- **`GuestWireConformanceTests` could not see `bye`.** Its C-literal
  scanner did not understand character literals, so the three `'"'` in
  wire68.c's `read_string_field` inverted its quote parity and every
  literal after them was read inside-out. `bye` had been piecemeal since
  the day it was written and never appeared in the cannot-check set -
  the set read complete and was not, inside the mechanism built to
  prevent exactly that. Fixed, and `bye` has the fixture it should
  always have had.
- **The console printed one line's tail on the end of the next.**
  `now68k_fmt_append_*` do not NUL-terminate, and every builder in
  `conwin.c` declares `char line[80]` inside its loop, so a line shorter
  than the one before it trailed that one's tail: "files land in Startup
  Items" rendered as "files land in Startup Itemsbytes". `show_help` and
  `show_processes` had it latent and only escaped because their lines
  happen to grow rather than shrink. All emission now goes through
  `con_out_built`, which terminates. **No native test could have caught
  this** - it is pixels, and it was found by looking at a screen.

## Deferred by decision

**NOW agent-integration V0 is complete** (2026-07-24). All five bounded
projections are implemented, tested, and covered by one combined
PowerBook acceptance receipt: `now_session_health`,
`now_list_processes`, exact safe launch, revalidated cooperative quit,
and receipt-only approved artifact transfer through the existing put
lane. The pass also observed typed host absence, automatic guest redial,
new session identity, stale-reference refusal, and unchanged ordinary
Files/Connection UI. Exact evidence and limits live in
[`agent-integration.md`](agent-integration.md).

The artifact pass found one compatibility defect and closed it before
V0 closeout: modern classic-epoch dates saturated the deployed guest's
signed 32-bit JSON reader and stamped January 1972. Host→guest lanes now
omit an optional date outside the deployed reader's range; the numeric
guard, wire omission, mutation failure, and corrected live listing are
recorded in [`files.md`](files.md#classic-date-compatibility-boundary).
The first disposable evidence file retains its bad stamp; no destructive
cleanup was attempted.

The companion still has no guest component, lifecycle control, raw-path
input, shell or general filesystem surface, force-quit surface, or
CodeKitten/shared-transport dependency. Sustained load,
destination-byte read-back, and any shared-transport extraction remain
outside V0 rather than hidden completion claims.

**Guest-initiated change controls.** The browser on the classic side can
list, navigate and pull, but offers no rename, delete, new folder or
move. Michelle punted this 2026-07-20: write and overwrite were the
goals of the slice and both work.

Worth knowing before anyone reopens it: `file.move`, `file.trash`,
`file.restore` and `file.mkdir` already exist in the contract, the guest
already SERVES all four, and `HostShare` learned to serve them too
(2026-07-20, 13 tests). So the wire and both servers are done and the
only missing piece is guest UI — plus a decision about undo, which the
host side keeps on whoever initiated the action. **That host-side
implementation currently has no client.** It is tested and symmetric,
and it is also unused code until this is picked up; anyone auditing for
dead weight should know it was built deliberately, not left over.

## In flight elsewhere

**The unified Workshop landed** on `claude/guest-workshop-unified-a3aab9`
(2026-07-21): one window, a hand-drawn sidebar rail, and all four
modules (Screenshots, Files, Console, Connection) behind the
`WorkshopModuleOps` contract. The five old windows and the Connection
dialog are deleted, and all four pages were watched working on the
PowerBook the same night. The codex branch `codex/guest-console-invert`
is **abandoned by decision** (Michelle, 2026-07-21) — do not merge it.
Its one still-valuable idea, the **async OT connect path** (`160ed85`),
was reimplemented against `claude/processes-module-cb2d9c` on
2026-07-21 (see "An unreachable host presents as a hang" below); the
branch itself stays abandoned.

**The Processes page landed and is metal-verified** (2026-07-21,
`main` at `22f129a`; spec in `processes-and-peek.md`). The fifth
Workshop module: a split view with a Data Browser process list
(icon-and-text column, header sort) on the left and a detail pane
(kind, type/creator, memory text + partition bar, launch date) on the
right, plus Bring to Front and Ask to Quit (confirm -> quit Apple
Event -> keep the PSN until the walk proves the process gone ->
`(no reply)` after 10 s). The `peek.h` seam ships answering "NOW
Extension not installed"; the group box renders it. Watched working on
the PowerBook the same day. This is **rung 0** of the extension ladder
- everything above it (the NOW Extension itself, `process.*`/`peek.*`
wire families, the semantic mirror) is still ahead.

The detour that dominated the arc was NOT the Processes page - it was
reaching the Connection settings to repoint a chip that was listening
on the wrong port. That exposed two real, now-fixed defects, both
metal-verified: the async-connect launch wedge, and Connection field
editing (see below). The Processes page itself was good across those
rounds.

**NOW Extension M0 is metal-verified** (2026-07-21, rung 1, `ext/`).
The guest's first resident code: a 68K INIT publishing the shared
table, registering Gestalt `'NWex'`, and chaining a jGNE heartbeat
filter. Booted on the PB1400c at 9.1; the app's `now_peek_status()`
probed it and the Processes group box read "NOW Extension active."
That proves install, DetachResource residency, Gestalt registration,
table validation across the compiler boundary, and a live jGNE chain -
the whole of M0. Size ~48 KB (Retro68 flat runtime), loads at 9.1;
8.6 loader ceiling still unprobed (waits on the 3400c). The recovery
drill (Shift-boot off, drag-out) and the QEMU-clone pre-check remain
good practice for the next resident change but M0 itself is done.

**Rung 2a is metal-verified** (2026-07-21) - the anchor plane and the
first foreign-memory read. The extension's jGNE filter, once the
Processes page arms the plane, records each process's low-memory
CurrentA5/WindowList/MenuList into A5-keyed slots. Clicking a process in
NOW's list reads THAT process's front-window global bounds (the
per-process `axtree` behaviour): PSN -> partition
(`GetProcessInformation`) -> the fresh anchor whose A5 lies in that
partition (the correlation, validated by containment) -> `strucRgn` ->
`rgnBBox`, every foreign pointer checked inside the partition OR the
system heap before it is dereferenced (`peek_validate.c`, native-tested
+ mutation-checked), byte reads at fixed classic offsets. Watched on the
PB1400c: NOW's own window read correct, and Finder read "516 x 557 at
(7, 25)" - a real other process's window - once the validation was
widened to accept the system heap (partition-only read "unreadable",
exactly tbt's axtree lesson). The foreign read lives in the app, never
the extension.

Known texture, not a defect and not fixable: the readout is only as
fresh as the target process's last event-loop pass. Window state is a
SNAPSHOT captured by the filter when the process pumps - classic Mac OS
has no cross-process live window feed (`axtree` had the identical
limit), so no reader can re-take it on demand. There is deliberately no
time-based freshness gate on WHETHER to read: the A5-in-partition match
and the fail-closed validation, not a clock, prove a slot is this
process's, and the app carries the last good read across a stale blip.
But staleness is surfaced HONESTLY (the AXPeek/qdpeek discipline, which
hit this same wall): the reader reports the anchor's capture tick, and
the detail's Windows header shows "as of a moment ago" / "as of N min
ago" once the snapshot ages past ~3 s - an actively-pumping app stays
live with no marker. An app that never pumped since arming reads "no
anchor yet" until it does; an app with no windows reads "none open". Still open for a later pass: whether any app keeps its
window structures in a zone neither the partition nor the system heap
covers (would read "unreadable"); and rung 2b, cropping the actual Front
& Capture to the rect.

**Rung 2b - Front & Capture is metal-verified** (2026-07-21). The first
USE of the window bounds, and the anchor plane's first real artifact: a
"Front & Capture" button in the NOW Extension group box brings the
selected process forward, DEFERS the capture to a later idle (~0.75 s, so
nothing nests an event loop - the main loop's WaitNextEvent yields let
the target come forward and redraw), reads the now-front window's fresh
bounds, crops the capture to them (`capture_screen_rect` - one blit,
clamped to the screen), saves a PICT to the Desktop, and restores NOW.
Watched on the PB1400c: a captured window PICT, well-formed 8-bit with
its CLUT and PackBits rows, opened as the real window. So the whole rung
proves out end to end: extension captures anchors -> app validates and
reads bounds -> app crops a genuine screenshot to them.

**Rung 3 - the `process.*` wire family is metal-verified, host Processes
module metal-verified** (2026-07-21). The contract
gained
`process.list`/`process.listing` (symmetric, paginated by a 1-based
cursor, entries capped at 24 a page). The guest serves its own Process
Manager walk on request (`serve_process_list` in `wire.c`: name, kind of
application/background/finder, code/creator 4CCs, sizeKB, front). The
host answers the mirror direction with its own running apps
(`HostProcesses` off `NSWorkspace` - the degraded plane: modern macOS
gives no OSType code/creator and no classic partition size, so those
fields are honestly absent), and can ASK via `GuestListener.listProcesses`.
Tested here: a byte-accurate guest fixture (multi-`snprintf`, so the
conformance check names it as needing one), a `process.list`/`.listing`
round-trip, and the conformance known-partial set. A `NOW_METAL` test
(`MetalProcessTests`) pages the real PowerBook's process table onto the
host and prints it; run on the PB1400c (2026-07-21) it read 8 processes
correctly classified - the `appe` faceless-background set (Control Strip,
Folder Actions, ORiNOCO Monitor, tbt-appe), the Finder by `FNDR`, three
`APPL`s, and the guest itself flagged front. The host now DISPLAYS it: a
read-only Processes module (`ProcessesModel`/`ProcessesModuleView`) that
pages the whole table in on refresh, groups it into Applications (with
the Finder) and Background, flags the front process, captions each row
with kind/4CCs/partition size, and reads as the snapshot it is ("as of
HH:MM:SS"). Metal-verified on the PB1400c: the pane drew the machine's 7
processes correctly grouped and flagged.

**The one-way direction is by design, not a gap.** NOW drives old-from-
new - the host is the cockpit, the guest the operated machine - so
host-sees-guest is the product and guest-sees-host is a non-goal. The
guest issues no verbs at the host and has no ASK/UI for the host's
processes, on purpose. The wire family stays symmetric in MEANING, but
the host serves nothing back: the dead `HostProcesses`/`NSWorkspace`
serve was removed rather than kept as ballast (2026-07-22).

**Drive verbs added (2026-07-22).** The Processes pane grew three actions
on the selected row, all host->guest: Bring to Front (`process.front` ->
`SetFrontProcess`), Ask to Quit (`process.quit` -> a 'quit' Apple Event it
may decline), and Screenshot App. Each names its target by the PSN the
listing now carries (`psnHigh`/`psnLow`); the guest re-validates the PSN
against a live process before acting, and refuses a quit of NOW itself -
that would sever the wire mid-reply. `process.front`/`.quit` share one
`process.result` reply; their Toolbox calls are factored into
`proc_actions.c` so the guest page and the wire handler use one
implementation. **Front, Quit, and the self-quit refusal are
metal-verified on the PB1400c.**

Screenshot App is its own verb, `process.shot`: the guest fronts the
process, waits ~0.75 s for it to repaint (a deferred service pass, like
the page's Front & Capture), reads its front window's fresh bounds off
the anchor plane, captures ONLY that rectangle (`capture_screen_rect`),
restores NOW, and delivers the crop over the capture transport - it
reuses `arm_transfer`/capture.begin so the host receives it exactly as
any capture, landing in the Screenshots module. The guest owns the
timing, so the host-side delay hack is gone. **Metal-verified cropping
Finder and Strider on the PB1400c** (2026-07-22). When the window bounds
cannot be read - a genuinely windowless process - it falls back to a
full-screen capture rather than erroring: the app is front, so the screen
with it on it is a truthful answer.

**Self-read fixed** (2026-07-22): NOW reading its OWN windows returned
"unreadable" (in the detail pane and to `process.shot`, which then failed
"capture ended without a begin"). Cause: the anchor plane walks foreign
memory at the classic 68K `WindowRecord` offsets, and NOW is a Carbon app
whose own window records do not sit there. `now_peek_windows_for_psn` /
`now_peek_window_count` now special-case self (`SameProcess` with
`GetCurrentProcess`) and read NOW's own windows straight from the Window
Manager (`FrontWindow`/`GetNextWindow`/`GetWindowBounds`/`GetWTitle`) -
no reason to go foreign for oneself. So self now crops like any other
process; the full-screen fallback remains only for the truly windowless.
**Metal-verified on the PB1400c** (2026-07-22): the detail pane reads
NOW's own windows and Screenshot App crops NOW's Workshop window.

With that, the whole drive arc is metal-verified: Bring to Front, Ask to
Quit, the self-quit refusal, and Screenshot App cropping Finder, Strider,
and NOW itself.

**Smell, now fixed (tested, not yet metal-verified):** the host's process
list could hold stale PSNs across a guest relaunch, and a drive verb on a
stale PSN failed (safely - the guest re-validated and answered ok:false /
capture.end ok:false) until a manual Refresh. The list now notices the
connection itself: `ProcessesModel` drops its whole table the instant the
connection leaves `.connected` (rows belong to one connection, and the
next guest reconnects with fresh PSNs), and the view re-reads on any
transition back to connected - so a reconnect, or a pane reopened after
one, reads afresh without a manual Refresh. Clearing on disconnect also
covers the case the view's `.onChange` cannot see, a reconnect that
happens while the Processes pane is closed. Host suite passes and the app
builds; still needs a metal pass (relaunch the guest, confirm the list
updates and the three drive verbs work with no Refresh). `process.launch`
(opening an
app that is not yet running) is the honest next verb; it needs a
path/signature to name an unlaunched app, not a PSN. Everything is tested
(contract round-trips incl. `process.shot`, a guest `process.result`
fixture, the drivable/PSN decode) and builds clean on both halves.

**Metal found one rung-0 bug, now fixed:** the detail pane's "Launched"
line read "1/1/04" for every process. `ProcessInfoRec.processLaunchDate`
is ticks since boot, not a 1904-epoch date, so `LongDateString` clamped
it. Now rendered as elapsed time via `proc_uptime_text` (pure, native-
tested, watched failing by mutation): "3 min ago", "2 hr 14 min ago".

**Workshop follow-ups, deliberately not done in the arc:** a CarbonLib
1.6 launch gate (wire.c still surfaces `kConnNeedsCarbonLib` at connect
time instead); the capture disclosure's expanded state is session-only,
not persisted; the Files page's Send File button sits in the share block
rather than the header placard the spec drew; and the sidebar has no
focus ring, so Tab reaches controls but never the rail (arrows work
whenever no field has focus).

## Broken

**Hard system crash (error 10) on quit — root-caused and fixed, metal
soak pending (2026-07-23).** Twice, quitting NOW hard-crashed the guest
(error 10, a Line-F/unimplemented-instruction exception) and required a
reboot; not every quit, and the app logged its own clean "stopped"
first. Root cause: a shutdown use-after-free in every Data Browser
module. `workshop_close` disposes each module (`g_ops[i]->dispose()`)
BEFORE `DisposeWindow`, but each module's dispose freed its Data Browser
item-data/notification/compare UPPs while the browser control was still
live in the window — on the belief that "the window took the controls
with it," which the call order makes false. `DisposeWindow` then tore
down that live browser, which fires item notifications (removal, a
deselect) through the now-freed UPPs. On PPC a UPP is a transition
vector; once freed and reused, that call lands in garbage — an illegal
instruction that corrupts the system heap, hence the reboot. Intermittent
because it depends on whether the freed block was reused yet and whether
the browser still held items to notify on. Fixed in all four DB modules
(software, processes, census, files_browser_view): `DisposeControl` the
browser FIRST — while its UPPs and model are still valid — then free the
UPPs, then the model. Builds clean under `-Werror`. **Unverified:** an
intermittent crash cannot be proven gone by one quit; it needs a soak of
repeated quits from each Data Browser page on the PowerBook. The Processes
page was "metal-verified" and still carried this — the verification never
included a quit-crash soak, which the ledger should now expect. To make a
recurrence diagnosable, teardown now leaves a FLUSHED breadcrumb before
each step (`quit: closing connection` → `stopping pump` → `removing
handlers` → `disposing window` → `clean`) and closes the log LAST: a
crash log that ends at `quit: disposing window` says the fix did not
hold; one that reaches `quit: clean`/`stopped` is a clean teardown.
Ordinary log lines sit in the disk cache and a crash loses them, so the
breadcrumbs force `FlushVol` (`now_log_flush`), the same guarantee
`now_log` already gives an error line.

**Resume by offset hangs.** A transfer resumed against a matching
partial does not complete. The failing test is committed rather than
skipped (`MetalLargeTransferTests`), which is the right shape: the
feature announces its own absence. See `docs/large-transfers.md`.

**One large transfer in about six degrades badly.** 12 MB normally lands
at ~293 KB/s; occasionally a run collapses anyway. The mechanism behind
the common case is understood and fixed — this residual says the
understanding is not complete. Measured, not reasoned about; the numbers
are in `docs/large-transfers.md`.

**An unreachable host presents as a hang.** Reimplemented on
`claude/processes-module-cb2d9c` (2026-07-21) after the wedge bit again
on metal: `now-guest-processes` decoded under a fresh name, found no
prefs, dialed `10.0.2.2`, and a synchronous `OTConnect` to an address
that never answers blocks INSIDE the call — before the first update
event, so the window stays blank and only a force quit ends it. The fix
is the codex branch's shape (`160ed85`) rebuilt against this tree: the
endpoint goes asynchronous for the dial only, a notifier publishes one
flag, the main loop finishes or fails the connect, and the endpoint
returns to synchronous before the hello. `now_log_open()` also moved
above `conn_init()` so this failure finally leaves a log.
`ot_connect_source_test.py` pins the sequence — it was watched failing
against the pre-patch sources — because this fix has now been lost
once. **Metal-verified 2026-07-21** on the PB1400c: launched with no
prefs it dials the gateway and the UI stays alive and drivable, where
before it wedged blank. (The emulator forgives the synchronous form,
so this could only ever be proven on hardware.)

**The Connection fields were dead once Connection became a page**
(fixed 2026-07-21, `claude/processes-module-cb2d9c`). Address and port
took no clicks. The real cause, after two wrong guesses: the Workshop
window had **no root control**, so it had no control-embedding
hierarchy, so `SetKeyboardFocus` could not work and an edit-text
control could take neither focus, clicks, nor keystrokes. This is the
same wall the Console hit on metal - "the edit-text field never took a
keystroke" - which is why it hand-rolled its input. Connection is the
only page that uses edit-text controls; every other page's controls
(buttons, checkboxes, popups, Data Browser, scrollbar) respond through
`TrackControl`/`HandleControlClick`, which need no focus, so only
Connection was affected.

Two dead ends before the fix, both worth recording because they are
the wrong instinct:

1. `FindControlUnderMouse` instead of `FindControl` - no effect, because
   the window had no embedding hierarchy to be wrong about.
2. Adding a root control to the window. It got the field to *focus* but
   it still took no mouse or keys (the Appearance edit-text control just
   does not work for entry in this WaitNextEvent app), AND it **broke
   every other control in the group**: a root control turns the
   group-box control into an embedder, and an embedded control only
   receives clicks when HIToolbox's standard Carbon Event handler routes
   them, which this app deliberately does not install. So the retry
   popup and checkbox - which had worked - went dead too. The root
   control was removed.

The fix that holds: no root control anywhere (controls stay flat
siblings the classic Control Manager hit-tests directly, with plain
`FindControl`), and text entry moved out of the page entirely. Address
and port are drawn **read-only**; an **Edit** button opens a
movable-modal **dialog** (`conn_edit_dialog.c`, DLOG/DITL 301) whose
entry the **Dialog Manager** drives - `GetNewDialog` +
`ModalDialog(now_pump_modal_filter())` + `GetDialogItemText` on
`editText` items. That is the exact mechanism the original Connection
dialog used before the Workshop rewrite, proven on this PowerBook; its
own window has its own text handling, independent of the Workshop
window. The filter pumps the wire; validation stays in `conn_fields.c`.

Net change from the last metal-verified state is only the Connection
dialog: every page's control handling is back to no-root + `FindControl`.

**Metal-verified 2026-07-21** on the PB1400c: the "Other Mac"
popup/checkbox/Edit button click, the Edit dialog's fields take clicks
and keys, and Save repoints the connection - which is how the
wrong-port chip got corrected. Screenshots/Files/Console unchanged.

**Type-select does nothing in the browser list.** Selection,
double-click and header sorting all work; typing a letter does not jump.
`SetKeyboardFocus` is set and the key reaches the control. Universal
Interfaces 3.4 has no type-select column flag, so the likely answer is
that Data Browser wants the Carbon Event path — which means an event-
model migration, and the Carbon UI skill explicitly warns against
running two competing top-level loops in a mature `WaitNextEvent` app.
Not load-bearing; parked as a known gap rather than chased.

## Unverified on the machine

Everything here builds and passes its tests. None of it has been watched
working on the PowerBook.

- **The `gestalt` reply's truncation path** (2026-07-30, branch
  `claude/goofy-sutherland-3e6cf4`). `run_gestalt` used to write every
  structural byte of its JSON — the `[`, `]`, `,` and the quotes around
  each label and value — with a bare `out[pos++]`, checking the cap only
  around the escaped text and once more at the very end, *after* all the
  unchecked writes. It never bit: a whole-machine gestalt is about 26
  rows and sits well inside the 3072-byte buffer `wire.c` passes. But
  `kGestaltMaxRows` is 48 and a `GestaltRow` is 96 bytes, so a machine
  answering more selectors, or one more group, would have run past the
  caller's buffer rather than truncating.

  The serializer now lives in `now-guest-ppc/src/commands/gestalt_json.c`,
  split out precisely so the host `cc` can run it at caps no Macintosh
  will ever produce — `gestalt_json_test.c` sweeps every cap from the
  floor to 6000 with a poisoned guard region past the bound. That sweep
  found a second defect the hand-picked sizes missed: the `]` closing a
  group is a write like any other and can be the one that hits the
  bound, and clearing `group_open` regardless left an array nothing
  closed.

  A truncated reply now says so, in a `notice` group carrying
  `["truncated", "<n> rows omitted - reply buffer full"]` (contract:
  `x-commands/gestalt/output`), because a short reply and a machine with
  fewer facts to report were previously indistinguishable. Room for it is
  held back from the cap up front — a buffer too full for rows is also
  too full for the sentence explaining why.

  **What has not happened:** no real gather has ever been large enough to
  truncate, so the notice has never crossed the wire from a Macintosh,
  and no host UI has been seen rendering it. The host's console shows
  command.result groups generically, so it should appear as a group named
  `notice` with one row; that is inferred from the code, not watched.
  Anyone with a machine that answers unusually many selectors is the
  first person who could confirm it.

- **`ps` on NOW-68K's wire** (2026-07-25, branch
  `claude/host-console-remote-shell`). The dumb-shell console landed and
  `ps` still came back `unknown-command` from a 68K guest that ran it
  perfectly at its own keyboard: it had been added to `conwin.c` alone,
  reading the `process.list` family the wire already served. A message
  family serves a module, not a person — the host console sends commands
  and nothing else — so `ps` is now in `commands68.c`'s table and its
  reply is built by `n68_proclist_render_ps()` from the same
  `proc_list_rows()` walk that feeds `process.listing` and the guest's
  own console text.

  Tested here: the new renderer's shape, its empty case, its refusal at a
  hopeless cap and its worst-case row bound (`test_proclist.c`, and the
  truncation guard watched failing by mutation); two host fixtures for
  the reply as the guest writes it; and a new parity test,
  `testEveryVerbTheSixtyEightKConsoleAnswersIsAlsoOnItsWire`, watched
  naming exactly this bug when `ps` is pulled back out. The 68K guest
  cross-compiles clean. **Unverified:** nobody has typed `ps` into the
  host console against a real 68K Mac. Two things to watch when someone
  does — the truncation row (`["...", "N more not shown"]`) appears only
  on a machine running more processes than a 1 KB control frame holds,
  which is roughly a dozen and may never happen on a 7.1 machine; and the
  detail column is meant to read identically to the PowerPC guest's, which
  no run has yet compared side by side.

- **The dumb-shell console, both guests** (2026-07-25, branch
  `thread/host-menu-dumb-console`). The host console no longer knows what
  commands the guest has: it sends `command.request` with `line` — the raw
  text a human typed — and renders whatever comes back. Every argument
  grammar moved to the machine that serves the verb
  (`now-guest-ppc/src/commands/cmd_line.c`, natively tested by mutation), `help` became an
  x-command answered from the one doc table each guest already showed its
  own console (`now-guest-ppc/src/commands/cmd_help.c`,
  `now-guest-68k/src/commands/commands68.c`), and the host's Tab completion is that
  answer at runtime.

  Tested here: 459 host tests, the two new native guest tests, and both
  guests cross-compile clean at `-Wall -Wextra -Werror`. **Nothing has
  been typed into a console on either machine.** What that leaves
  specifically unverified:

  - `gestalt` slicing now happens guest-side from the line (`--full`,
    `--cpu`, …). Absent-`line` behaviour is unchanged for modules, but no
    human has typed `gestalt --memory` at a PowerBook.
  - `screenshot --depth 8 --no-save` and `tail 40` parse from the line
    for the first time; the old host-side parsers are gone.
  - `help` on the PowerPC guest builds a ~1.2 KB reply against a 4 KB
    control frame with a byte-budget truncation row. The budget is
    reasoned, not measured on the wire.
  - `help` on NOW-68K builds into a 512-byte payload buffer and measures
    ~260 by hand-count. It has never been sent.
  - The MacRoman decode of an accented path typed as a console line
    (`ls Café:Notes`) is covered by a native test on the decoder, not by
    a file with that name on a real HFS volume.

- **⌘Q's farewell, on metal** (2026-07-25, same branch). The host now
  returns `terminateLater` and waits for `bye shutting-down` to reach the
  socket before the process ends, bounded at 0.5 s. Tested here by
  sequencing (mutation-verified: a shutDown that reports synchronously
  fails), and the menu bar and its Quit item were driven live through
  accessibility on this Mac. **Not verified:** that the ⌘Q *keystroke*
  dispatches (script-driven activation is refused in this environment, so
  the item was clicked rather than typed), and that a PowerBook watching
  the wire draws the right conclusion — the guest's own "host went away"
  handling has not been observed against a real quit.

- **`quit <name>` — the deploy loop's missing half** (2026-07-25,
  branch `thread/guest-quit-command`). A console command and x-command
  that composes `process.list` → match by name → re-validate →
  `process.quit` → **re-list**, so it can report `gone` apart from
  `still-running`. Design, outcome table and the decisions behind each
  case: [`processes-and-peek.md`](processes-and-peek.md#quit-name--the-same-action-named-the-way-a-person-names-it).

  **Emulator-verified, end to end, on mac99 / OS 9.1 / CarbonLib 1.6** —
  both invocation paths, and every outcome the composition can produce:

  | Watched | Result |
  |---|---|
  | Guest console `quit SimpleText` | `"SimpleText" is gone (0.3 s)` |
  | Guest console `quit --no-wait SimpleText` | `asked "SimpleText" to quit; NOT confirmed (--no-wait)` |
  | Guest console `help quit` | renders |
  | Wire `quit SimpleText` | `gone (0.1 s)`, and confirmed absent by an independent `process.list` |
  | Wire, dirty document | `[quit-declined] … is STILL RUNNING after 4 s`, with SimpleText visibly sitting on its Save dialog |
  | Wire, nothing of that name | `not-running`, `ok:true` |
  | Wire, its own name | `[quit-refused]`, and still there afterwards |
  | Wire, no target / unknown flag | `[quit-bad-args]` |

  The acceptance driver is committed: `MetalQuitTests` (`NOW_METAL=1`,
  plus `NOW_QUIT_DIRTY=1` for the human-in-the-loop declined case).

  **What the PowerBook still has to settle.** The emulator says nothing
  about *timing* on a 117 MHz 603e: SimpleText answered in 0.1–0.3 s
  there, and the 6 s default was chosen for a slower machine, not
  measured on one. Nor has the deliberate stall been felt on metal — for
  up to `--wait N` the guest's window does not repaint (it keeps
  servicing the wire; see [`nested-loops.md`](nested-loops.md)), and
  "does that read as a hang?" is a question about a real screen. An
  isolated copy is staged at `Lab:now-quit` on the 1400c (its own name,
  so its own preferences; fork sizes verified against the local
  MacBinary, 565127 / 2439). Being non-canonical it starts with no
  preferences and dials 10.0.2.2, so the **console** path needs no host
  at all — that is the one to run first. The real target is NetPresenz
  on a 180c, which is a different machine and a different client.

- **`catsearch` — the Software module's feasibility probe** (2026-07-22).
  Times a whole-volume `PBCatSearch` sweep for APPL files on the startup
  volume, in 15-tick slices, cold then warm. Console verb on both sides
  (contract `x-commands`, guest `commands.c`, host `ConsoleModel`).
  **Metal-verified on the 1400c** (guest console path; same-day emulator
  run agreed in shape): 22,127 files / 2,411 folders, 601 APPL hits,
  cold sweep **228 ticks = 3.8 s in 184 slices**, warm 172 ticks =
  2.9 s, longest slice 3 ticks against the 15-tick budget, zero
  restarts. Two conclusions the Software module can build on: a full
  inventory sweep is affordable as background `idle()` work (~50 ms
  worst slice), and 184 slices ≈ the catalog arriving one 16 KB opt
  buffer per call — so the buffer size, not `ioSearchTime`, is the
  real slice-length dial. Warm is barely cheaper than cold; do not
  design around the cache. The host-console invocation was watched
  working too (2026-07-22, post-merge build), so both invocation paths
  are metal-verified — including MacRoman-high-byte names in
  `First hits` crossing the wire through the `\uXXXX` escaper.

- **Software rung 3 begins: the page is registered and appears**
  (2026-07-22, spec in `software-module.md`, mock in
  `mockups/software-mockup.html`). The six-edit registration for a new
  nav module landed and is **emulator-verified**: Software shows as the
  6th rail row (a boxed-app-tiles `ics#` 136) between Hardware and the
  pinned Logs/Connection pair, Cmd-6 selects it, and it draws the live
  installed-software overview (139 extensions, 33 control panels, …).
  The delicate part — inserting Software as id 6 pushed Logs 6→7 and
  Connection 7→8, the first insert to move an existing non-pinned id —
  bumped prefs to **format 14** with a remap lifting both; the
  save/load round-trip is verified (quit + relaunch reopened on
  Software). Two supporting pieces are host-cc tested and integrated:
  `software_layout.c` (split-view geometry) and `sw_vers_parse.c` +
  `now_software_read_version()` (the `'vers'` parse extracted to a unit
  with a mutation watched failing under ASan; the per-row primitive the
  trickle will call). **Still ahead on this rung** (the frame is drawn,
  these land on it): the interactive Data Browser with the FSSpec-
  bearing item model, the domain popup, live search, the launch/front/
  quit/reveal buttons, and the idle-paced version trickle. None of that
  is metal-verified yet — only the emulator, and only the page's
  appearance + prefs migration.
  - **Interactive cut (2026-07-22):** first version was hand-drawn and
    metal-tested the same day; the second metal round found real
    problems, all fixed and re-verified in the emulator:
    - **The module leaked port state.** Three `RGBBackColor(white)`
      calls on the one shared Workshop window turned EVERY page's
      background white. Fixed by rule, not by restore: the module
      never touches the background color — white interiors are
      fore-painted with `PaintRect`. Watched fixed (Hardware gray
      again after visiting Software).
    - **The list is a real Data Browser now** (the processes_module
      pattern): Platinum header buttons, native four-column sort,
      native truncation/scrolling. Loading appends items and versions
      update one cell — the flashing was the hand-drawn list's
      invalidation model, and it is gone with the list.
    - **Domains cache in memory for the run** (lazy NewPtr each);
      switching rebuilds the browser from the cache, never the disk;
      Rescan is the only re-read; the apps sweep is resumable across
      switches. Watched: Extensions ↔ Applications both ways, the
      restore instant with versions intact.
    - The search field takes its click (focus ring); the detail pane
      is a group box with theme fonts and the selection's icon
      (`GetIconRef` on first selection only, cached for the run).
    **Emulator-watched:** sweep→browser fill, version cells trickling,
    live search (8 of 205), the domain popup driven by a genuine held
    QMP drag, cache restores, page-switch persistence, the bg fix.
    **Not watched, needs a human click:** row click-to-select and the
    search focus ring — a control experiment showed the metal-verified
    Processes browser ALSO ignores injected clicks (atomic and
    QMP-held), so this is an injection-vs-DataBrowser artifact, not a
    known defect; still, only a hand on a mouse closes it.
  - **Fourth round (2026-07-22):** the third metal round's four asks.
    The residual flashing was batched *sorted* inserts shuffling
    visible rows — the browser is now fed nothing mid-sweep (the
    placard counts arrivals) and populates ONCE at sweep end, watched.
    **Duplicate groups**: same-name items collapse under a container
    row (disclosure in the Name column, "N items", aggregate size,
    running-if-any; parents disclose, never select) — watched as
    "now-guest · 2 items · 1.0M · running" with indented per-version
    children, isolated by search ("2 of 206"). **Where:** the full
    path, wrapped, in the detail — watched, computed on selection
    never in draw. **Show in Finder**: alias in a 'misc'/'mvis' Apple
    Event, Finder fronted — watched revealing Note Pad in Apple
    Extras, matching the detail exactly. **Bring to Front / Quit**:
    wired over the metal-verified `proc_actions` with a fresh
    at-act-time PSN join; unwatched as buttons (the VM's only running
    singleton is the injection channel itself). Also unwatched:
    groups' collapsed-default on the unfiltered list. Nothing in this
    round is metal-verified yet.
  - **Metal feedback on the host page (2026-07-23), two fixes.**
    (1) **The `®` was passed down poorly.** A launch/reveal from the
    host against an app with a non-ASCII name ("Adobe Photoshop® 5.0")
    came back "no such file", the echoed path double-mangled to `¬Æ`.
    Cause: the host sends HFS names as UTF-8 (® = `0xC2 0xAE`), but
    `run_launch`/`run_vers`/`run_reveal` read `target` with
    `now_json_find_string` (a raw byte copy), so `FSMakeFSSpec` never
    saw the MacRoman byte (`0xA8`). Fixed by reading `target` with
    `now_json_find_text` — the inbound half of `now_json_escape`, which
    decodes `\u` and raw UTF-8 back to MacRoman (a json_native_test case
    pins the ® round trip). **The same latent bug in the Files path
    commands** (mv/trash/restore/mkdir/offer/list/get in wire.c, console
    `ls`) was fixed in the same defect class by a parallel task — see
    "Non-ASCII paths INBOUND" in the Files section, guarded by
    `test_inbound_hfs_path` and a source-reading conformance test.
    (2) **Selection hilite
    hugged the text.** The Data Browser's default
    `kDataBrowserTableViewMinimalHilite` draws the selection only behind
    each cell's glyphs, so a selected row read as three disconnected
    patches; switched to `kDataBrowserTableViewFillHilite` for one
    continuous full-row bar (CarbonLib 1.1+, we floor at 1.6). Guest
    builds clean under `-Werror`; both **unverified on metal** — the
    reveal round trip needs the connected session, and the hilite is a
    visual change to watch on the PowerBook.
  - **Host page reaches parity: split-pane, detail, reveal
    (2026-07-22).** The host Software page grew a second half. It is now
    an `HSplitView` — the inventory Table on the left, a detail pane on
    the right carrying the selected item's version, size, state, kind,
    and full path (selectable), with **Launch** and **Show in Finder**
    beneath it. Search was already there; it stays, above the split.
    "Show in Finder" is a **new wire verb, `reveal`** — launch's
    read-only twin: it resolves a target exactly as launch and vers do
    (path / `#n` / bare name) but reveals ANY item (an extension, a
    control panel), since it opens nothing. The guest serves it by
    sending its OWN Finder a `kAEMakeObjectsVisible` for the item's
    alias then fronting the Finder — the same `now_software_reveal` the
    guest page's own button uses, now reachable from the host and the
    console (`reveal <name|path|#n>`). Contract-first: the `reveal`
    x-command is declared, answered in `commands.c`, and offered by the
    host console — `CommandRegistryTests`' three-way agreement holds.
    Host suite green (276) incl. a reveal test; guest builds clean under
    `-Werror`; audit clean. **Never run live**: like rung 4, the reveal
    round trip and the split-pane page both await a connected session
    with both new builds. `reveal` from the host console against a live
    guest, and the detail pane's two buttons, are the one-sitting check.
  - **Rung 4 lands (2026-07-22): versions on the wire + the host
    Software page.** `serve_software_list` now fills each served
    entry's version (a page's worth of fork opens per request, bounded,
    explicitly asked for); the contract, fixture, and Swift docs agree.
    `SoftwareModel`/`SoftwareModuleView` mirror the guest page
    host-side — domain picker over a Table, client-side search, Launch
    by the entry's path (the guest's words shown either way), the
    listing's `note` surfaced verbatim — registered between Hardware
    and the footer. Host suite green incl. `SoftwareModelTests` and the
    updated registry manifest. **Never run live, all of it**: the
    `software.list` round trip (and now the version enrichment and the
    page on top of it) awaits the first connected session with both new
    builds — `swpage extensions` in the host console, then the Software
    page itself, is the one-sitting check.
  - **Fifth round (2026-07-22):** the metal report "a collapsed group
    will not re-expand" was a real contract miss: closing a container
    REMOVES its children (the Data Browser's own behavior) and
    item_notify ignored container notifications, so reopen had nothing
    to show. Fixed: kDataBrowserContainerOpened re-adds the group's
    children, idempotent via GetDataBrowserItemCount. **Unwatched** —
    the disclosure triangle defeats click injection; the repro is on
    the PowerBook. Also added: a **draggable splitter** between the
    panes (gray XOR outline, own StillDown loop pumping the wire —
    nested-loops.md row added — clamps tested host-cc, session-only
    width). **Watched end to end** in the emulator. Bonus close: a
    press-MOVE-release drives the Data Browser under injection, so
    **row click-to-select is now watched** (previously the oldest gap).
    Known nit: below ~260px list width the fixed columns clip; a
    tighter clamp is a one-liner when it bothers. The whole-window
    redraw on module switch is spun off as its own task (parent
    container, not this module).
  - **Sixth round (2026-07-22):** the search field repainted the whole
    module per keystroke — Remove-all/Add-all, an unconditional detail
    invalidation, the group qsort, and a catalog walk, every key.
    Typing now refilters by DIFF against a view set (delta rows only,
    groups leave children-first), the detail is touched only when the
    selection actually changed, and there is no auto-pick mid-typing.
    The full rebuild remains for content changes. Per the redraw
    contract added to `classic-mac-carbon-ui` the same day. Emulator-
    watched: the selection and detail pane SURVIVE keystrokes
    untouched; a filtered-out selection clears once. The reduced
    repaint itself, like all flicker, only reads on metal.
    - The field itself still blinked (whole-field invalidate + full
      white repaint per key). Typing now echoes the DELTA directly —
      the contract's immediate-feedback exception: erase from the end
      of the unchanged prefix only, draw the tail + caret, clip
      restored, nothing invalidated; draw_search reproduces the same
      pixels at any real update. Emulator-watched ("quicktime" typed
      and backspaced entirely through the echo path).

- **Software rungs 1–2: resumable sweep, `vers`, running tags, and the
  `software.list` family** (2026-07-22, spec in `software-module.md`).
  Rung 1 is **emulator-verified**: `sw extensions` tagged exactly the
  three running `appe` files the harness's process list names
  (Control Strip Extension, DVD AutoLauncher, FBC Indexing Scheduler),
  and `vers SimpleText` read Version 1.4 / "1.4.0 final" / the Get Info
  string / Product 1.1 by name-search resolution. Known texture:
  Application Switcher runs but is untagged — its process appSpec
  evidently names the System file, and the strict FSSpec compare
  declines to guess; that is the join being honest, not a defect.
  Rung 2 (the wire family, served from a one-domain cache with
  full-path launch keys) **builds and is host-tested** — fixtures pin
  the piecemeal listing including a MacRoman ® — but has **never run
  live end to end**: it needs the new host build connected to the new
  guest build, driven by the host console's `swpage [domain] [cursor]`.
  - **First metal round (2026-07-22, partial):** `sw apps` and `vers`
    ran on the 1400c from the host console. Two findings, both closed
    the same day: `launch` from the host dispatched as unknown-command
    — the host sorts JSON keys, `args` precedes `name`, and the guest
    scans frames FLAT, so launch's arg named "name" was read as the
    command name (arg renamed `target`; the never-shadow-an-envelope-key
    rule now lives in the contract's x-commands preamble); and `vers`
    on a bare name met the disk's several SimpleTexts — it now shows
    every match path-first instead of refusing, `launch`'s ambiguity
    refusal names the paths, and a duplicate finder (same/different
    version, user-driven consolidation) is marked in the spec as later
    work.
  - **Second metal round (2026-07-22, same day):** the multi-match
    view worked but truncated paths mid-folder, and retyping a full
    HFS path to disambiguate is brutal. Both fixed: matches print as
    a **numbered list whose paths wrap** across continuation rows,
    the list is **stored on the guest**, and `launch #2` / `vers #2`
    pick from it — either console, one wire frame. launch's ambiguity
    answers a distinct `launch-ambiguous` code for a future host UI.
    Emulator-verified with a manufactured duplicate (two now-guests:
    refusal listed both full paths, `vers #2` read the picked copy,
    `launch #1` launched).
  - **Third metal round → launch redesign (2026-07-22, same day):**
    the numbered-pick flow worked on the 1400c but read as too much
    ceremony for "just open it." `launch <name>` now launches the
    **highest-versioned** copy and names it in the reply (a visible
    answer, not a hidden guess); `launch <name> <version>` forces a
    copy by its short version string; full path and `#n` still work.
    The whole arg is tried as a literal name first, so "Sherlock 2"
    stays whole. Emulator-verified (newest-of-2, version pick,
    wrong-version message, single-match plain launch).
  - **Fourth round → `-v` flag (2026-07-22):** launch-newest became
    too surprising to reason about (which version won?), so the shape
    settled: `launch [-v VERSION] NAME`, NAME the whole remainder
    (spaces need no quotes; quotes stripped if used), a bare ambiguous
    name launches the FIRST found and names its version (one fork
    open, no walk), `-v` forces a copy, positional `Name 1.2.3` retired
    with a "did you mean -v" hint. Emulator-verified: quote-strip,
    first-of-2-with-version, the hint. The `-v` launch flag is
    **metal-verified** (Michelle, 2026-07-22, human-typed — the
    emulator keystroke injection had dropped its leading chars, an
    input artifact, never the code). The `software.list` wire family
    (`swpage`) remains the one never-run-live path — it needs a host
    linked to the guest, deferred until the guest page is dialed in.

- **`sw` and `launch` — the software family's first verbs** (2026-07-22).
  The Software module's data layer (`software.c`) surfaced as console
  verbs on both sides before the page exists. `sw` inventories the
  special folders live (Extensions Manager's disabled siblings tagged
  "(off)") and pages applications via the catsearch-verified APPL sweep,
  stopped at one page; `launch` opens an application by exact-name
  search or full HFS path, refuses ambiguous names, and logs outcomes
  under `sw` — it is the family's one mutation. Versions are
  deliberately absent: one `'vers'` read per file is the expensive
  path, deferred to the module's lazy detail.
  **Emulator-verified** (OS 9.1 clone): overview counts (139/33/0/13),
  `sw extensions` with types+sizes, `sw apps` page with the more
  marker, and `launch SimpleText` bringing a live SimpleText to front.
  **Not yet watched on the 1400c**, and the guest's LOCAL `launch`
  intentionally does not log (only the wire path does — same rule as
  `ls`/`ps`); the host-console invocations of both verbs are
  host-tested but unrun live.

- **A page switch paints once, and only what changed** (2026-07-22).
  Michelle watched Workshop page switches repaint the whole window on
  the PowerBook — rail, placards, everything. The investigation found
  the container's *invalidation* was already scoped (header/body/status
  plus the two selection rows); the churn was in the *painting*, three
  ways: `HideControl`/`ShowControl` draw immediately, so
  `show(false)`/`show(true)` repainted the pane piecemeal before the
  update event repainted it again; the update handler's full-port
  `EraseRect` painted the invalidated rail rows theme-gray a beat before
  the rail's own white erase; and `DrawControls` followed by
  `UpdateControls` drew every control twice per update. All three fixed
  in `workshop_window.c` alone: the swap runs under an empty clip and
  paints exactly once at the coalesced update, the erase narrowed to the
  body plus the sidebar gutter outside the rail panel (the placards and
  the rail fill their own faces), and one `UpdateControls` pass.
  Emulator-verified: all seven pages cycle with no stale pixels, zoom
  leaves the gutter clean, controls still track after switches. **Watch
  on metal:** that the rail genuinely stops flashing at the machine's
  real drawing speed — the emulator is too fast to show a flash either
  way. One module-side offender remains, out of the container's scope:
  the copy-pasted `set_status` in screenshots/census/connection
  invalidates a full-width bottom strip (port bounds, bottom 23 px) that
  crosses the rail's foot, so the Connection row can still flick when a
  module's status line changes. The module fix is to invalidate the
  status placard's rect, not the port's.
- **The Logs page, both machines** (2026-07-22). A Monaco dump of the
  in-memory log ring that follows the tail live like a terminal, with
  Invert and Log-to-disk switches. The **guest** page was watched working
  on the PB1400c; the footer move, the invert switch, and the whole
  **host** module are built and tested but unrun since.
  - **Placement.** Pinned in the footer below the divider, directly above
    Connection — a `logs_row` on the guest (id 6, Connection 7), a
    `.footer` descriptor before `settings` on the host. The host footer
    row now shows link status only for the row that IS the link.
  - **Guest scrollback.** The ring grew 200 -> 2000 lines (`kLogKept`),
    ~240 KB of statics against a 6 MB partition. `run_tail`'s stack index
    was decoupled from `kLogKept` so it stays 48, not 2000, pointers.
  - **Disk toggle.** `now_log_set_disk`/`now_log_disk_on` (guest) and
    `HostLog.setPersistsToDisk` gate the file at runtime; the ring is
    always live. Default on (crash survival is the point). Both switches
    reflect the ACTUAL state, so a failed open reads as off. On the host
    the file is now a switch, not opened at launch — `LogsModel` applies
    the saved choice.
  - **Invert.** A dark canvas like Console, saved per page. Guest prefs
    reached format 13 for it (12 was the disk field + Connection renumber);
    the host keeps `logsInvert` in UserDefaults.
  - **Watch on metal:** the host module unrun entirely; on the guest, that
    the invert switch redraws cleanly and the footer pair (Logs above
    Connection, under the divider) lays out at 640x480.
- **`ps` and `census` console commands + guest verb logging**
  (2026-07-22). The two new modules — Processes and Hardware/census —
  had no console verb and logged nothing; both are now closed.
  - **Console.** `ps` (flat process list, the reading of `process.list`
    the Processes module drives) and `census [probe]` (one probe page,
    the flat cousin of `censusExchange`) were added across all three
    halves — contract `x-commands`, guest `commands.c` dispatch, host
    `ConsoleModel` offer + help — the way `ls` is to `file.list`.
    `CommandRegistryTests` reads all three and is green, so the set
    agrees and every offered command has help. The guest's own console
    (`console_model.c`) renders both locally too.
  - **Logging.** The guest drive verbs (`process.front`/`quit`/`shot`),
    census outcomes, and the process-list refresh now log their shape
    with the wire id (areas `proc`, `census`). The refusal *reasons*
    that used to live only on the wire now reach the log. `process.list`
    logs once per refresh (cursor 1), never per page, to stay off the
    per-chunk heartbeat rule.
  - **Verified only here:** host suite (263 tests) green, `audit_source.py`
    clean, the census/json header chains compile under
    `cc -Wall -Wextra -Werror`. **Not** cross-compiled — no Retro68
    toolchain this session, so the guest-only additions (`run_ps`,
    `run_census`, the two console handlers, the `wire.c` log lines) are
    not even at *builds* yet. First metal run should confirm `ps`,
    `census pci`/`ata`/etc., and that a declined `quit` shows in the log.
- **The Processes page's product pass** (2026-07-21) - built and
  suite-green, unrun on metal. All app-side (extension unchanged):
  - **Kind grouping.** Processes are classed from `processMode`
    (`modeOnlyBackground`), not guessed from the `'appe'` type. The list
    sorts front-process first, then applications, a divider row, then
    background-only - kind and front-ness are the sort axes, never
    window state, so a row never jumps when a window opens/closes.
  - **Row badges.** Front app reads "(front)"; apps show their window
    count ("3 windows"); windowless and background rows show none - the
    windowed/windowless distinction, visible without selecting.
  - **Richer detail.** CPU time (`processActiveTime`), accurate Kind
    with "(frontmost)", and a Windows section listing each window's
    title + size (up to 3, "...and N more"), read through the anchor
    plane's validated foreign path (now walking the `nextWindow` chain
    and reading `titleHandle`). Menus line is a reserved STUB - the
    anchor captures `MenuList`, the walk is a later pass.

  **Watch on metal:** the **divider row** is a non-process sentinel item
  in the Data Browser (`kDividerItem`), non-selectable by bouncing the
  selection off it - the one bit of fake-row territory in an otherwise
  proven-DB design; confirm it draws between the groups and cannot be
  selected. Also that window titles read correctly (another foreign
  pointer hop, `titleHandle`), and that per-app window-count reads every
  second don't cost visible time on the 33 MHz metal.
- **Prefs v10 module renumbering.** Connection moved 4 to 5; a v9 file
  should reopen on the page the person had (the remap is three lines
  in `now_prefs_load`), exercised only by reasoning - same status as
  the v9 note below.
- **Corners of the Workshop no one has exercised anywhere:** the send
  progress bar actually moving, and the preview well at 16/32-bit
  depths. (The first metal pass found two bugs - a mute Console
  edit-text and Modified dates clamped to 1/19/72 by signed
  DateString - both fixed the same night and metal-verified the next
  morning, 2026-07-21.)
- **Prefs v9.** Reads v1-v8 files and seeds the Console page from a
  legacy console_open flag; exercised only by reasoning, not by an old
  prefs file on the machine.
- **The host serving move / trash / restore / mkdir.** 13 tests, zero
  minutes of machine time. No client asks for it yet (see above).
- **Accented file names.** macOS stores names decomposed, so "café" is
  "cafe" plus a combining accent, and MacRoman has the letter but not
  the mark — every accented name was arriving as "cafe_". The fix
  composes first. Nobody has pulled an accented file to the PowerBook.
- **Non-ASCII paths INBOUND, host to guest.** The complement of the
  above, and the same defect class as the Software fix: the host sends
  every path UTF-8 (® is `0xC2 0xAE`), but `FSMakeFSSpec` wants the
  MacRoman byte (`0xA8`). The guest's file-op verbs were pulling
  `path`/`toPath`/`trashedAs` with `now_json_find_string`, which does
  not convert, so a move/trash/restore/mkdir/list of any non-ASCII name
  looked for a file that does not exist. Fixed by switching those
  extractors (and `file.offer`'s `name`, and console `ls`) to
  `now_json_find_text`; `container`/`fileType`/`creator`/tokens stay
  find_string, ASCII by contract. Guarded two ways —
  `json_native_test.c :: test_inbound_hfs_path` proves `café®` decodes
  to `0x8E 0xA8` (and that find_string leaves the raw four bytes), and
  `GuestWireConformanceTests :: testHfsPathArgumentsAreTextDecoded`
  reads the C and fails if any of those keys reverts to find_string
  (mutation-verified). **Tested, not metal-verified:** no one has moved
  or trashed an accented file from the host to the PowerBook.
- **The Finder reveal button.** "Open" in the browser sends `odoc` to
  the Finder with an alias to the downloads folder. Standard, and
  untested on metal; it is `kAENoReply` so it should not block, but that
  is reasoning rather than evidence.
- **The Hardware census module (slice 1).** New Workshop page: a passive
  census of this Mac, three Carbon-clean probes (gestalt full
  selector-table walk, video GDevice walk, volumes PBHGetVInfo), served
  over the new symmetric `census.request`/`census.report` family and
  shown in a split pane (probe list left, rows right). Builds clean
  (whole guest links; the ics# 133 chip icon compiles) and the host
  suite is green (242 tests), including a guest→host refusal round trip,
  the census.report fixture, and a mutation-checked serializer. **Not
  watched on the PowerBook.** Specific unknowns for the first metal pass:
  (1) two Data Browsers in one window — one is proven by the Files page,
  two side by side is not; (2) the full ~203-selector Gestalt walk
  paging 16 at a time; (3) the chip icon actually plotting from `ics#`
  133 rather than losing to a System family at that id. See
  docs/adding-a-workshop-module.md.
- **The host Hardware module — runs and reads the GUEST's census**
  (2026-07-22). A native macOS dossier: a `census` module in the sidebar
  (`CensusModel` + `CensusModuleView`), a probe list on the left and the
  selected probe's rows on the right, a Run Census sweep and per-probe
  rerun. It is a REQUESTER only — it asks the guest and displays the
  reports, following the `more`/`cursor` pagination to accumulate a
  probe's rows one page per request. The host probe registry
  (`CensusProbes.all`) is a copy of the guest's `k_probes[]` and the
  contract's `x-probes`; `CensusProbeRegistryTests` pins the set to the
  contract and the order to the guest, so a probe grown on one side and
  forgotten here fails a test. **Tested, not seen against a real guest.**
  `CensusModuleModelTests` drives the whole request→report path over the
  loopback listener with a scripted guest (pagination, cursor threading,
  outcome/note propagation, the full sweep, the disconnected guard, and
  rerun-replaces-not-appends); the SwiftUI view itself has not been run
  against a connected PowerBook.
- **The host does NOT serve its own census, by design.** The `census`
  family is symmetric in the contract, but the guest is the machine with
  hardware worth asking about; the host is the requester. When the guest
  sends the host a `census.request`, the host answers `refused` ("the
  host does not serve a census yet"). That is a deliberate, permanent-
  feeling asymmetry now, not a scheduled stub — a host self-census (IOKit/
  sysctl) is not planned as part of this feature.
- **The `ata` and `pccard` probes reach 68K-trap-only managers through a
  metal-proven Mixed Mode dispatch** (`census_trap.c`, 2026-07-22). The
  1400c's ATA Manager ($AAF1) and PC Card Manager ($AAF0) are trap-only
  — no CFM fragment, and `gestaltATAAttr` answers falsely absent — so a
  PowerPC Carbon app cannot import them. `census_trap.c` reaches them the
  way the parent project proved safe after four machine wedges (corpus
  `cis-metal-safe-mixed-mode-fix`): a hand-built M68K `RoutineDescriptor`
  so `CallUniversalProc` thunks PPC→68K, `CallUniversalProc` resolved from
  InterfaceLib and called **variadically** (a fixed-arg pointer leaves the
  args in registers → Type 1 bus error), and each thunk keeping its RTS
  return address on the stack. The mechanism itself is **metal-verified**
  by `spikes/census-trap`: selftest `$4242`, then real traps.
  - `pccard` (CSGetCardServicesInfo, selector 7) is **metal-verified** on
    the 1400c: CS 2.01, 4 sockets, Apple vendor string. Read-only, touches
    no socket or card, so it runs in the sweep. A card's own identity
    (its CIS) stays OUT until a gated design — the CIS is what froze the
    1400c historically (`pb1400-pccard-trap-only`).
  - `ata` (IDENTIFY DEVICE) reaches the manager and it answers `noErr`,
    but on the 1400c internal drive the IDENTIFY buffer comes back
    **empty** (metal, 2026-07-22 — buffer dumped all-zeros for the one
    device that answers, device id `$0000`). So the row honestly reports
    the device *present* without a model. A drive that fills the buffer
    decodes into model/capacity/firmware; that path is **builds-only**.
    Getting model/serial off *this* drive is a separate follow-up
    (`kATAMgrBusInquiry` enumeration, or `kATAMgrExecIO` issuing a raw
    IDENTIFY task file rather than the manager's empty DriveIdentify) —
    deferred, banked with the wins per Michelle's call.
  - The whole integrated page — `pccard`/`ata` running inside the census
    sweep and rail — is **tested and builds** here; it has **not** yet
    been metal-verified as a page (only the underlying trap calls have).
- **The `power` probe.** Slice-2 follow-up (2026-07-21). Carbon-clean
  (BatteryCount / GetScaledBatteryInfo, gated on `gestaltPowerMgrAttr`)
  and low-risk. Compiles, links and passes its decoder unit tests; has
  not run in the page on metal.
- **`network` and `software` probes, deferred as future modules**
  (decided 2026-07-21). Network (Open Transport interfaces and TCP/IP
  config) and installed-software (extensions and control panels with
  their `vers`) are both Carbon-clean and were scoped OUT of the census
  probe rail — Michelle's call was to grow them as their own future
  Workshop pages rather than more rows on Hardware. Not built; recorded
  so the intent is not lost.
- **The rail has no scroll bar.** At fourteen probes the hand-drawn probe
  rail fits the standard window (~371px of rail for 352px of rows at
  25px/row) but overflows below about the minimum window. `draw_rail` now
  clips the row list to the rail rect, so the tail truncates cleanly
  instead of painting over the button strip — but truncated rows are then
  unreachable. This is the point where the rail needs a real vertical
  scroll bar rather than shorter rows; it lands with the extension
  "witness" tier that adds the next probes.

## Reverse file streaming is bounded and verified on the machine

The 2026-07-24 reverse-path pass removed both whole-artifact buffers.
The guest now opens the source forks only after acceptance and emits one
bounded frame at a time, including MacBinary header/fork/padding
segments. The host writes each frame to a same-folder temporary file,
preflights free space, computes CRC-32 incrementally, sends batched
`file.progress`, verifies count and optional checksum, and only then
moves or stream-converts the result into place. Cancel, truncation,
checksum failure, write failure, and disconnect all delete the partial.

The native host suite exercises 256 KiB, 2 MiB, and 16 MiB payloads with
a fixed 32 KiB append bound, CRC/truncation/overrun/cancel cleanup,
atomic materialization, and text conversion across a chunk boundary.
Both guest send entry points have a source gate against whole-file
allocation, and the Retro68 guest build passes.

The bounded path is **metal-verified** on the PowerBook 1400c
(2026-07-24). A separately named guest on port 5252 preserved the
canonical pairing and persistent preferences. Data-fork pulls at 32767,
32768, 32769, 256 KiB, 1 MiB, and 4 MiB matched their generated content
and independent CRC-32. MacRoman/CR conversion and explicit MacBinary
data/resource-fork fidelity passed. Cancelling a 4 MiB pull removed its
host partial and left the session responsive. The guest process
partition was 6506 KB before and after; the 4 MiB pull added 2.23 MiB
peak host RSS and 1.94 MiB live malloc bytes.

Those numbers are bounded observations, not a transfer-rate guarantee.
The metal pass did not exceed 4 MiB, run longer than two minutes, mutate
a source during transfer, or measure guest free heap. It does not prove
rate hardening.

Reverse resume remains deliberately absent. A deployed guest supplies
no source identity before the receiver chooses an offset, so the host
cannot prove a retained partial belongs to the current source. An
interruption therefore deletes the partial and retries from zero. Adding
resume safely needs an additive guest-issued source token (and fixtures
for old peers), not an offset guessed from a filename and size.

## Structural work deferred on the host

A cleanup pass (2026-07-20) applied what was cheap and left three
extractions from `GuestListener.swift`, which is 2094 lines:

- `Session` is built with 28 `on...` closures, 25 of which only forward
  to a listener method. A `weak var owner` or a delegate protocol
  collapses about 180 lines, and adding a message stops meaning edits in
  four places.
- The share-serving block (~140 lines) touches only `share`, `session`
  and `state`. It is a file server living inside a listener.
- The outbound write path (~400 lines) shares one invariant — nothing
  may write to the connection while a bulk frame is half-written —
  currently enforced by a flag two unrelated methods must remember to
  check. As its own type the flag cannot be forgotten.

These were skipped on purpose. Two reviews proposed DIFFERENT
reorganisations of the same file, and the receiving-half work above
implies a third (one transfer sink rather than three accumulators).
Doing any one now makes the others harder, and only the receiving half
has a consequence beyond tidiness. Whoever takes that should take these
with it.

## V1 host product work is planned, not implemented

The [NOW V1 host product roadmap](plans/2026-07-24-002-feat-now-v1-host-product-roadmap-plan.md)
starts only after the optional MCP companion V0 is complete. It commits a
persistent target catalog and host-side improvements to Files, Processes,
Software, the menu bar, quit policy, and Settings while retaining the
current guest-dials-host, one-port, single-session transport.

V1 explicitly defers a guest listener, multi-session runtime, mobile
transport, and shared protocol service. Any common-protocol extraction
waits for CodeKitten's separate listener, pairing/security,
health/latency, recovery, cooperative-loop, and adversarial multi-peer
proof and would begin in another worktree. The exact target-switcher
information architecture, pairing-conflict UX, thumbnail and history
retention, inventory analyses, local-browser defaults, and remembered
module-state policies remain intentionally open.

## MCP V0.5 guest Files command seam has a tested staged-upload slice

The approved
[NOW MCP V0.5 guest-files roadmap](plans/2026-07-24-003-feat-now-mcp-v0-5-files-command-roadmap-plan.md)
now has its first host-owned command slices: an explicit, persisted and versioned
root-relative `guestRoot` policy; canonical HFS path validation; capability,
one-page listing, and bounded exact-stat commands; typed receipts; and normal
host audit lines. It also has a create-only staged upload command: private
disk-aware reservation, ordered 8 KiB-or-smaller chunks, SHA-256 sealing, a
file-backed sender through the existing transfer lane, and bounded progress,
reservation, finalization, integrity, and cleanup evidence. No host path crosses
the API. The destination parent must already exist: this slice does not
implicitly implement `mkdir`. The existing private local socket and
client-launched stdio companion
project those completed commands; download, mkdir, overwrite, move, delete,
tree deployment, and prune remain unavailable.

The read-only slice composes the existing `file.list` exchange and therefore
adds no guest message or guest code. It is **tested** against fake paired
sessions, including root escape, invalid policy recovery, empty and populated
listings, paging bounds, stale sessions, concurrency, and host-product
noninterference, plus local-schema and stdio validation. A bounded
2026-07-24 PowerBook 1400c acceptance verified capability discovery, two
16-entry root pages with cursors 17 and 33, and exact stat. The first live
page exposed one legal HFS name containing control bytes; path validation now
keeps those exact MacRoman names addressable, rejects only untransportable
NUL, and escapes them in audit text. Download and every broader mutation remain
unverified and unavailable.

The staged-upload slice is **tested**, including host-space refusal, ordered
offsets, integrity failure cleanup, dead-process orphan recovery, root escape,
unavailable/stale sessions, replay, concurrent commit, malformed local/MCP
requests and MacBinary, strict guest completion evidence, late-collision
preservation, stale-accept invalidation, cleanup-needed recovery, guest refusal
evidence, and unchanged one-at-a-time transfer ownership. Host staging and
outbound reads use bounded off-UI-actor disk I/O. The host builds and the
Retro68 guest cross-builds cleanly. It is
**not metal-verified**: no new disposable upload was sent to the PowerBook in
this slice, so real-volume reservation values, Finder-visible finalization,
fork/type/creator fidelity, interruption cleanup, and live throughput remain
open.

The reconciliation also exposed two pre-metal hardening gaps. Host byte
reservation does not yet cap the number of active stages, so repeated
zero-byte or tiny begins can retain bounded-lifetime records without consuming
meaningful byte quota. A stage is bound to session and policy version but not
to an opaque active-share identity, so a human share change between begin and
commit is not yet a typed stale condition. Both must be resolved and tested
before staged upload advances to attended PowerBook acceptance.

Invalid persisted `guestRoot` recovery currently rejects the malformed value,
logs the event, and restores the approved share-root default. That is the
implemented and tested behavior, but it can broaden a future narrowed policy.
Fail-closed recovery versus explicit rebinding remains a policy decision before
an Integrations UI can configure narrower roots.

The reverse-streaming prerequisite is now integrated: the guest reads outbound
forks one bounded frame at a time, and the host receives into a private disk
sink with progress, length/CRC validation, interruption cleanup, and atomic
finalization. This does not expose arbitrary download. That capability remains
gated on a typed NOW command, root/size policy, deterministic receipts and
audit, and an explicit MCP projection. Reverse resume also remains separately
deferred pending a contract-first guest source-identity rule.

The combined V0.5 tree—root-scoped capability/list/stat, create-only staged
upload, and reverse streaming—has been reconciled and promoted to local
`main`. The read-only commands and reverse transport carry the bounded metal
evidence stated above; staged upload is implemented and tested but remains
unrun on the PowerBook. This integration did not add download, mkdir,
overwrite, move, delete, tree deployment, prune, broad host filesystem access,
plugin infrastructure, resume, or transfer-rate hardening.

Mutation is gated separately on guest-side revalidation of an opaque file
observation. Listings now carry a responder-generated opaque catalog identity,
and the host mints short-lived session/root-bound observation references, but
no mutation accepts them yet. The current move/Trash/restore/mkdir messages
still act by path alone; host-only precondition checks would permit a changed
item to be acted on between check and use. The exact guest-side revalidation
field and command behavior remain the next contract-first mutation gate. Tree
deployment and mandatory-preview manifest prune follow only after it.

## The companion against a partial guest: capability-derived, unverified on metal

NOW has two guests now, and the agent-integration companion was written
against one of them. It is now guest-agnostic — but only two of its
projections have ever been watched against a guest that implements part of
the contract, and neither of those was the new one.

**What changed.** A twelfth tool, `now_session_capabilities`, reports what
the connected guest can do and therefore which tools are available against
it. The derivation has exactly two sources and neither is identity:

- **Commands** come from `help`, which both guests serve on the wire, one
  fetch per connection. It is the same live source the host console's Tab
  completion already uses, so a guest that grows a verb becomes usable
  without a companion release.
- **Message families** are not in any command table — that gap is how `ps`
  shipped wire-only here — so they are established by asking. Every family
  request the host makes records its own outcome as it settles, and the
  report additionally probes the read-only families it can settle cheaply
  (`process.list`, `file.list`). It never probes a family whose smallest
  request changes the guest (`process.quit`, `file.put`), and it probes
  `software.list` only on request because that first page is a whole-volume
  sweep. Those stay **`unproven`**, a third state that explicitly does not
  mean "no" — collapsing it into "no" is how a report would start
  understating a machine it never asked.

`AgentIntegrationCapabilityTests` fails the build if any deciding file in
the companion surface reads a hello field or names a guest. That guard
exists because the same mistake already happened in the other direction:
`MetalQuitTests` derived a guest's abilities from its hello name and went
stale the same afternoon that guest grew `process.list`, understating its
own evidence with nothing failing.

**The refusal path, which was half-built.** `GuestListener.recordGuestError`
claimed to route a guest `error` to "every waiter" and routed three of the
six maps. Process listings, software listings and process results — exactly
what a partial guest refuses — still sat on their 15 s and 30 s watchdogs
and arrived with `timeout` instead of the guest's reason. All six are routed
now. The mutation that removed three of them reproduced the original
symptom: 15 s, 30 s and 15 s waits, each arriving as `timeout`.

That mutation also exposed a hazard in the first version of the fix: it
cleared the watchdog before routing, so a waiter kind the function forgot
would have had neither an answer nor a timeout and would have hung forever
rather than merely slowly. The watchdog is now cleared only when a waiter
was actually answered.

**What this does NOT change.** No safety property moved. Opaque
session-bound references, revalidation before use, one-use receipts,
create-only uploads, and the rule that no guest path or PSN crosses the
adapter are all as they were. In particular `now_request_quit` was **not**
made to work against a guest without `process.quit`: the opaque-reference
and PSN-revalidation model has nothing to stand on there, so the tool is
unavailable in typed form and that is the whole answer.

**Unverified.** All of it is **tested** here — twelve projections, 490 host
tests, both xcodebuild configurations — and none of it is
**metal-verified**. Specifically open:

- No capability report has been taken against the PowerBook 180c. The
  fake partial guest in the tests answers `not-implemented` the way
  `now-guest-68k/src/core/wire68.c` does, but a fake guest proves the host's half
  twice and the guest's half not at all.
- `now_list_processes` against NOW-68K is the tool this arc claims is newly
  possible, and it has not been called against that machine. The 68K's
  `process.listing` does carry PSNs, so references will be minted there —
  what happens when one is offered to `now_request_quit` and the guest
  refuses `process.quit` is tested against a fake and unobserved for real.
- The `help` command table parse is exercised against a synthetic table.
  Neither guest's real `help` output has been fed to the ledger.
- `software.list` probing is opt-in on the stated grounds that a guest which
  does not implement it refuses instantly. That asymmetry is reasoning, not
  a measurement; the ~4 s figure for a guest that does implement it comes
  from the earlier 1400c catalog sweeps, not from this code path.
- The local protocol moved to v6 and the capabilities call gets a 90 s
  response window because it may wait on several guest-side watchdogs in
  turn. That number is a sum of the existing bounds, not an observed one.

## NOW-68K: what has not been on the machine

The 68K guest for the PowerBook 180c is metal-proven for dial, handshake,
keepalive, health, logging, clean quit, `launch` and the `gone` path of
`quit`. Everything below has been built and cross-compiled and has never
run **on a Macintosh** — some of it now runs under host-compiled native
tests, which is a different and lesser thing, and each entry says which.
Listed because "we shipped it and here is what we still do not know" is
the useful half.

- **The interactive console is a SECOND WINDOW, by decision, and that is
  a standing exception rather than drift** (2026-07-25). Every other
  statement this project makes about guest UI says the opposite: the
  Carbon guest's rule is that a new feature is a Workshop module and
  never a window (`docs/adding-a-workshop-module.md`), `window.h` and
  this README both describe NOW-68K as one page with no tabs, and
  `now-guest-68k.r`'s `SIZE` comment agrees. Michelle asked for the console
  in its own window on this guest, and it is implemented that way.

  The reason it is defensible: the main window's console pane is a **log
  viewer** — it shows what the wire and the status line said, it takes no
  input, and this change leaves it exactly as it was. An interactive
  console needs a keyboard focus, an edit field, an insertion point and a
  key-by-key event path, and the one 512×300 page already carries three
  connection fields, two controls, a status line and a health readout.
  Making it carry both would mean shrinking the log viewer to a few rows
  or growing the window past the 180c's 640×480 panel.

  **The next feature is still a page on the main window** unless someone
  writes down a reason this good. `conwin.h`'s header comment carries the
  same paragraph so it is read by whoever edits the code, not only by
  whoever reads the ledger.

- **The console runs the command table, not a copy of it — and only the
  seam is tested** (2026-07-25). `commands68.c` used to run a command and
  emit its `command.result` JSON in one pass, which is fine with one
  reader and impossible with two. It now fills an `N68CmdResult` (the
  facts, no formatting) via `now68k_commands_run()`, and
  `now-guest-68k/src/commands/n68_cmdresult.c` holds **both** renderers side by side:
  JSON for the wire, text for the console. Adding a command means one
  case in `now68k_commands_run` and nothing else — it appears in both
  places in the same commit. This is deliberately aimed at the parent
  corpus finding `two-halves-never-met-in-a-test`.

  What is proven: `now-guest-68k/tests/test_cmdresult.c` (50 checks) pins the
  JSON bytes for all three reply shapes against literals written out in
  full — not assembled from the renderer's own pieces — and walks six
  outcomes through both renderers asserting they never disagree about the
  `ok` bit or the error code. `now-guest-shared/tests/console_history_test.c`
  (38 checks — it was `now-guest-68k/tests/test_history.c` until the
  history became one file both guests compile) covers the arrow-key
  history, including the two cases that are wrong in most first attempts:
  "nothing further that way" must leave the field alone rather than clear
  it, and a walk must not re-capture a recalled entry as the half-typed
  line. Both were wrong in the PowerPC guest's own copy, which is why
  there is now only one.

  **The wire did not change, and that was checked differentially rather
  than assumed.** A scratch harness ran the *old* `finish_error` /
  `finish_ok_row1` / `finish_ok_row2`, extracted verbatim from `4a7703f`,
  beside the new renderer over 1,092 combinations of reply shape ×
  message × error code × output capacity (512 down to 0, including the
  caps where the compact fallback fires): **0 differences**, in both the
  bytes and the returned length. The harness first reported 37, which was
  a real finding — the new `N68CmdResult` copies the message into a fixed
  160-byte member where the old builders took an unbounded pointer, so a
  message longer than 159 bytes now truncates instead of falling back.
  That case is structurally unreachable (`kDetailCap` is *defined as*
  `kN68CmdTextCap`, and every message source is one of those buffers),
  and it is written down in `n68_cmdresult.h` rather than left for
  someone to rediscover.

  What is **not** proven anywhere: that `launch` and `quit` behave the
  same when driven from the console as from the wire. Both paths call the
  same `now68k_commands_run`, which is the point of the design, but no
  test drives the console path (it needs a Toolbox) and no metal run has
  done it by hand. That is the first thing to check on the machine.

- **The console has never run on the PowerBook.** It builds under the 68K
  toolchain at `-O2 -Wall -Wextra -Werror` and its Toolbox-free halves
  pass their native tests; nothing more. Specifically unproven on metal:

  - **Up/Down history.** The interception happens before `TEKey` because
    TextEdit given `kUpArrowCharCode`/`kDownArrowCharCode` moves the
    insertion point between display lines, which is a no-op in a one-line
    field. That reading is verified-document (Events.h constants read
    from the installed Universal Interfaces: up 30, down 31), not
    verified-target.
  - **Left/right cursor movement**, which is deliberately handed to
    `TEKey` rather than reimplemented. Same evidence level.
  - **Option-Up/Option-Down scrollback.** `kPageUpCharCode` /
    `kPageDownCharCode` (11, 12) are also accepted, but the 180c's
    built-in keyboard has no dedicated page keys, so Option-arrow is the
    binding that has to work on the target and it has never been pressed
    there. Command-arrow was not available: `MenuKey` in `main.c`
    consumes every Command chord first.
  - **The two-window event routing.** `main.c` now routes update,
    activate, click and key events by the window they name rather than
    assuming one exists. A mistake here does not crash — it draws the
    wrong window or types into the wrong field — and nothing off-metal
    catches that.
  - **The memory cost — measured at link time, not on the machine.**
    Against `4a7703f` built the same way, the console and the seam it
    needed cost **text +4,428 and bss +10,954 = +15,382 bytes, +4.0% of
    the 384 KB partition** (`m68k-apple-macos-size` over the object
    files). The BSS is an 8.2 KB scrollback ring plus a 2.3 KB history,
    beside `window.c`'s existing 9,186 bytes. What that does NOT include,
    and what nobody has sized: the `WindowRecord` and the `TERec` plus
    its text Handle that the Toolbox allocates out of the application
    heap when the window is opened. With ~231 KB free that is very
    probably fine and it has not been watched.

- **The console cannot copy text out, and its scrollback is 32 lines.**
  The output pane is drawn text, not a `TERec`, so a click in it does
  nothing and there is no way to get a result off the machine except by
  reading it. The 32-line ring is `n68_console_ring.h`'s compile-time
  capacity, shared with the main window's log viewer; Option-arrow paging
  makes all 32 reachable, but a long `quit` transcript still ages out.
  Both are deliberate: a selectable output pane means a second `TERec`
  and its text Handle, and a deeper ring is 256 bytes a line.

- **The declined quit — METAL-VERIFIED 2026-07-25.** The whole re-list
  composition exists so a target that stops to ask about an unsaved
  document answers `ok:false` / `quit-declined` rather than claiming
  success, and it had never run anywhere. On the 180c, against a
  TeachText holding typed-but-unsaved text:
  `[quit-declined] quit: TeachText is still running - declined, or busy`.
  `MetalQuitTests :: testADirtyDocumentDeclinesAndSaysSo`
  (`NOW_QUIT_DIRTY=1 NOW_QUIT_NO_LAUNCH=1 NOW_QUIT_APP=TeachText`).

  Two things the run taught that the design had not:

  **`quit-ambiguous` also ran, by accident, and was right.** The test
  launches its victim before quitting it; against a TeachText a human had
  already opened, that produced a second copy, and `quit` refused the
  whole request rather than guess which one was meant. Correct behaviour,
  never previously exercised — and a test that manufactured the very
  ambiguity it then failed on. Hence `NOW_QUIT_NO_LAUNCH`.

  **The 68K re-check WAS weaker than the sentence "still running"
  suggests** — true when written, and fixed since by `process.list`. With no `process.list`, confirmation is a second `quit`
  through the same subsystem, and it came back "asked TeachText; not
  confirmed (wait_ticks <= 0)". The assertion that holds is only that the
  target did not answer `not-running`. That is real evidence and it is
  not corroboration; the run says so in its own output.
- **The farewell — METAL-VERIFIED 2026-07-25.** A menu quit on the 180c
  produced `now-68k is shutting down` on the host, which is the bye path;
  the abortive one reads `Connection lost`. `Metal68KTests
  :: testTheFarewellIsOrderly` (`NOW_68K_BYE=1`, human at the keyboard,
  because the guest refuses to quit itself).
- **The redial — METAL-VERIFIED 2026-07-25.** Host dropped mid-session
  and restarted; the guest redialled and re-helloed in 15.5 s.
  `Metal68KTests :: testTheGuestComesBackAfterTheHostGoesAway`
  (`NOW_68K_REDIAL=1`; the cadence is human-armed by design, so the
  checkbox is part of the test's precondition). The reconnect
  re-handshakes, as the contract requires.
- **Oversized control frames — now tested, still never sent.** The
  skip-not-fatal path (a frame larger than our 4 KB buffer but inside the
  protocol's 32 KB) is covered off-metal since 2026-07-25: the reader
  moved to `now-guest-68k/src/core/n68_reader.c` behind an ops table, and
  `now-guest-68k/tests/test_reader.c` drives it through a scripted transport —
  the oversized frame is skipped **and the next frame still parses**,
  which is the actual claim, under four chunkings plus a stall at every
  one of ~380 byte offsets. What that does not prove: **nothing in NOW
  has ever sent one.** The host does not produce a control frame over
  4 KB, so the reader's contract is proven and the host's honouring of it
  is not.
- **FIXED 2026-07-25 — `launch` of a name not on the disk never answered.**
  Watched broken on the 180c three times (60 s, 150 s, 300 s), then
  watched fixed on the same machine: `NOW-68K 0.6` answers in **2.5 s**
  with "nothing named X is on the startup volume". Kept in full below
  because the diagnosis was wrong twice before it was right, and the
  wrong turns are the reusable part.

  The cause was one limit stated three times in two units, smallest
  winning: the builder's buffer 512 (a literal in `wire68.c`), the
  module's documented floor 320 (`commands68.h` prose), the outbound slot
  160 (sized by a comment reading "hello (~110), ping (~30), or an error
  reply (~95)" — true when this guest had no commands, never revisited
  when `launch` and `quit` arrived). The reply built correctly at 166
  bytes; `commands68.c`'s compact fallback never fired, because from the
  builder's side nothing was wrong; the slot dropped it. Both numbers now
  come from `commands68.h` (`NOW68K_COMMAND_RESULT_CAP`), +704 bytes BSS.

  The original diagnosis, retained:

  What the guest's own log says: `cmd: launch refused -50`, then
  `command.result dropped, outbound queue full`. So the search RAN and
  RETURNED — `launch` is not hanging — and the reply was built and then
  thrown away on the way to the wire.

  Two theories died on the way to that, both worth keeping because each
  cost a metal run. **(1) The guest goes deaf inside `PBCatSearchSync`
  and writes its reply to a socket the host's idle timeout already
  killed.** Refuted: the metal test now watches the wire during the
  search, and it stayed up for the whole 150 s with keepalives answered —
  `yield_ticks(0)` pumps between slices exactly as intended. **(2) The
  reply is too long for the 160-byte outbound slot.** "Refuted" by
  reading `commands68.c`'s compact fallback — and this refutation was
  itself wrong, which is the lesson worth keeping. The fallback exists
  and would have fitted; it never ran, because the builder had 512 bytes
  and succeeded. Reading one half of a size mismatch and concluding the
  other half is fine is how the mismatch survived in the first place.

  What is actually established is narrower: `enqueue_control_send`
  refused the payload, and its 0 return covers **two** different failures
  — payload too big for a slot, and both slots busy
  (`kWireOutQueueDepth` is 2) — which every caller logged with the same
  sentence. That is why the log could not settle it. 0.5 logged them
  apart, and the very next run on the machine said it outright:
  `wire: send dropped - payload too big for a slot, bytes 166`.

  **The method note, which is the transferable part.** Two theories, two
  metal runs, both wrong, and the thing that ended it was not a better
  theory — it was making the log able to tell two causes apart. One
  message covering two failures is what turned a five-minute question
  into an hour, and the fix for that was three lines. When a log cannot
  distinguish the candidates, instrument before theorising again.

- **`launch` at scale.** The catalog search is double-bounded on purpose —
  a whole-volume Finder search has hard-wedged this fleet before — but it
  has only resolved an application sitting in an obvious place. The
  truncation branch is still unproven: the one metal attempt at it never
  got its answer back (above), so whether the bound reports honestly is
  exactly as unknown as it was this morning.
- **The confirm wait under load.** It yields with an event mask of zero and
  pumps the wire each pass, with a re-entrancy guard so a command arriving
  mid-wait cannot recurse into it. Neither the pump nor the guard has been
  observed under a second concurrent request.

- **`error` has a fixture and has still never been emitted.** (2026-07-25,
  closing the old "`hello`, `ping` and `error` are not conformance-checked"
  entry.) All three now have hand-written fixtures in
  `GuestWireFixtureTests`, derived by compiling the guest's own emitters
  with the host `cc` rather than by reading the C — a fixture written from
  the decoder's side would test one half twice. `hello` and `ping` have
  also run live against a real host. `error` has not, anywhere: reaching
  it needs the host to send a live-state message type NOW-68K does not
  handle, which nothing does today. The fixture is a claim about
  `send_error_reply`, not evidence from a capture. Its negative-id echo is
  reachable in principle and has never been observed.

  Worth correcting in the same breath, because it was written down wrong
  here: `unknown-command` and `refused` are **not** `error` shapes on this
  guest. `unknown-command` is a `command.result` error object and
  `refused` a `census.report` outcome; `wire68.c` routes both away from
  `send_error_reply` on purpose, because the wrong envelope leaves a
  different waiter blocked. The `error` emitter has one code,
  `not-implemented`, in two shapes. `command.result` is the one message
  still in the cannot-check set with no fixture at all.

- **Three oddities in the 68K frame reader, found and deliberately not
  fixed** (2026-07-25, during the extraction to `n68_reader.c`). The
  extraction was kept pure because the code is metal-proven and no
  PowerBook was on the LAN to re-verify a behaviour change against; these
  are the things a fix would have quietly changed. (1) `RS_HEADER` and
  `RS_BODY` return on a short read while `RS_SKIP` loops and calls `take`
  once more — harmless, one no-op call per drained bulk frame, and it is
  why `n68_reader_drain()` means "one event-loop pass" rather than "read
  everything available". (2) `handle_control_message`'s empty-frame branch
  is dead: the reader short-circuits zero-length control frames before
  dispatch, so there are two copies of that log string and one cannot
  fire. (3) `frames_in` counts skipped frames but not the fatal
  oversized one, so it means "frames whose header we accepted" rather than
  "frames received" — probably intended, but the stat's name does not say
  so.

- **The extraction is METAL-VERIFIED (2026-07-25).** It was
  argued-faithful only — structure, call order and a clean `-O2 -Werror`
  build — until `NOW-68K 0.4` ran on the 180c: handshake, one
  guest-driven keepalive answered after the 30 s silence, and a control
  frame round trip afterwards. `Metal68KTests
  :: testTheWireStillWorksAfterTheReaderExtraction`. The version bump is
  what makes it attributable — 0.3 predates the extraction and the wire
  carries no other way to tell two builds apart.

Both of the things that were known-wrong here are fixed (2026-07-25):

- **The metal gate no longer reads green when it never ran.** Under
  `NOW_METAL=1`, the port being held and no Mac dialling in are two
  distinct failures with distinct messages rather than skips; the only
  skips left are the opt-ins themselves (`NOW_METAL`, and `NOW_QUIT_DIRTY`
  for the case that needs a human at the keyboard). Guest identity now
  comes from the hello handshake, and where NOW-68K cannot serve the
  independent `process.list` confirmation the run says **WEAKER** out loud
  in its output and in every failure string. Watched directly: unset skips
  3 clean, `NOW_METAL=1` with nothing dialling in fails at 120.1 s, and a
  deliberately lying guest is caught on both the strong and the weak path.
  It is **tested**, not metal-verified — the guests were simulated by
  `tools/fakeguest.py`, which is a claim about the harness and never about
  a guest.

- **The contract's reconnect clause is amended.** Cadence is guest policy,
  capped backoff is the reference default, and the one surviving
  obligation is a ≥1 s floor between dial attempts. No revision bump:
  nothing changes shape and an older peer cannot tell. NOW-68K already
  clamped to the floor; the PowerPC guest reached it only incidentally
  through a prefs range check and now enforces it at the wire.

## vprobe on the 180c: measured, and what it does not cover

`vprobe` is **metal-verified** on the PB180c (2026-07-25, `NOW-68K 0.16`):
ran in 3.0 s, whole-frame on every row, answered in one frame, and the
wire survived it. Numbers and their reading:
[vram-readout-68k.md](vram-readout-68k.md).

The hypothesis it was built around resolved cleanly and in the direction
that costs us: `MOVEM.L` does **not** burst on this machine (6% over
unrolled `move.l`), and the reread row explains it — the VRAM is uncached,
and burst fills are cache-line fills. The unexpected result is a **~16-bit
width ceiling**: 8→16-bit more than doubles the rate, 16→32-bit buys 12%.
The 1400c's "the bus charges per transaction" does not transfer.

Unverified, and worth naming because the numbers will get quoted:

- **The CopyBits row is fifteen banded calls, not one blit.** Best raw
  beats it 1.54×, which is the opposite of the 1400c result — but an
  unknown share of that gap is per-call overhead. It is a floor on the
  margin, not the margin.
- **Nothing at a non-native depth was measured.** That is precisely where
  the 1400c's raw-vs-CopyBits margin evaporated, so the one number most
  likely to mislead a future capture stage is the one not taken.
- **`fmove.d` is content-dependent** — extended conversion, and a 68882
  handles denormals slowly — so it is what an FPU reader costs on that
  screen, not a bus figure.
- **`Microseconds()` has no availability gate.** Its trap is assumed
  present on 7.1 from documentation; a wrong availability test fails in
  the wrong direction (disabling vprobe where it works), so none was
  added. It answered with 37 µs resolution on the 180c, which settles the
  assumption for this machine and no other.
- **`fmovem.x` was not measured** — no conversion, no exception path, and
  the one row that might have rescued the FPU result. The reply cannot
  carry a 17th row; the honest next step if the `fmove.d` number ever
  looks wrong.

## The capture tx: staged, and crossing the wire on the emulator

Slice two — the pixels reaching the host — **works on the Quadra 800**
(OS 8.1, 640x480x8, 2026-07-26). The host sends `capture.request`, the
guest stages a PackBits capture, announces `capture.begin`, streams it
down the bulk lane and closes with `capture.end ok:true`; the host
decodes the palette and the packed rows into a pixel-accurate PNG of the
guest's screen. 137,783 bytes for a full frame, every byte accounted for
(`consumed 137783 of 137783`), 2.2:1 on that busy desktop. **Nothing has
run on the 180c**, and the emulator's `captureMs 16, encodeMs 3` are a
68040 reading host memory — meaningless as predictions, as ever.

Two ways to send exist now and they are not rivals:

- **staged** (`shotstage68.c`) — pack the whole frame to a scratch file in
  the published root, whose size is then an exact fact, and stream that
  file through the tested file source. Costs a disk round trip; buys
  compression. This is the one that crossed.
- **streaming** (`shotsrc68.c`) — read the framebuffer straight down the
  wire as `raw`, no staging and no scratch file, at ~300 KB. Built and
  native-tested; **not yet routed**, because the staged path answered
  `capture.request` first and one lane is one transfer wide.

The header of `n68_bytesrc.h` argues against staging ("cannot be staged
to a temporary file first either"). It was written before anyone had
measured a capture, and it is right about 300 KB and wrong about 65 KB.
That argument is now answered with numbers rather than overridden.

**PICT is not the wire format, and the contract said so first.**
`CaptureBegin.encoding` is `raw | packbits`, described as "NOT PICT: modern
macOS cannot decode QuickDraw pictures, so the wire uses a format both
sides own". So none of `shot68.c`'s picture machinery is on this path. The
stream is the palette as RGB triples, then rows top to bottom — which the
host already decodes, because the PowerPC guest already sends it. The
envelope is built field for field from `now-guest-ppc/src/core/wire.c`'s, and
`bytes` includes the palette (the contract's one-line description says
`rowBytes * height`; the sender that exists sends `GetHandleSize` of
palette-plus-rows, and the host agrees with the sender).

**The pull/push problem, which is why the source reads the screen and not
the picture.** `shot68.c` hands the whole frame to QuickDraw in ONE
`CopyBits` that runs for ~480 ms and cannot be suspended. `fill()` is a
pull. There is no way to pull from inside a call that is pushing — no
threads, no coroutines, and the banded recording that would have made it
incremental is the thing that killed QuickDraw on the third band. So the
source reads the framebuffer directly through the shared walk, which is
exactly what `raw` already is. PICT stays the disk format. The two paths
meet at the screen and nowhere else.

**This rung sends `raw`, and packbits is blocked on a real constraint,
not on effort.** `n68_bytesrc.h`'s first promise is that `total` is exact
before the first fill, because `capture.begin` carries the byte count and
the receiver sizes its staging from it. For raw that is arithmetic. For
packbits it is not knowable without packing, and this machine cannot hold
a packed frame to measure one:

- the packed frame is **not bounded**. The 180c's own desktop packs 4.7:1
  (65.6 KB), but PackBits *expands* incompressible data, so the worst case
  is ~303 KB against a 384 KB partition. "Usually fits" is not a budget.
- a counting pass then an emitting pass would produce an exact number for
  a screen that no longer exists. The two passes read the display at
  different moments, so their lengths can differ — and `capture.begin`
  would then be a lie the receiver sized its buffer from. Worse than
  sending more bytes.

So packbits over this lane needs **a decision, not code**: either stage
the packed frame in a temporary file (whose size IS exact — the 180c wrote
65 KB in ~800 ms, and `screenshot` already writes that file today), or a
contract that can carry a transfer of unknown length. Neither is taken
here. The cost of the rung that needs no argument is stated plainly: raw
is ~300 KB where packed would be ~65 KB on a quiet screen, and on this
machine's wire that difference is the whole user-visible experience.

**Two bugs the wire found that no test could have.** Both are recorded
because both are the same shape — a thing that is only wrong when two
real halves meet:

1. **The staged file was written where the sender does not look.** Staging
   put it beside the application; `n68_filesrc` reads from the published
   root (the Desktop). The capture staged perfectly, 137,760 bytes, and
   then could not be found. This is the *second* time this tree has made
   exactly this mistake — `n68_putfile.h` records the send and receive
   halves briefly disagreeing about the root, and says only a real file
   system can notice. `now68k_desktop_folder()` is the one place it is
   decided and now this uses it too.
2. **`capture.begin` announced `raw` while the payload was `packbits`.**
   The envelope builder was written for the streaming rung and hardcoded
   the word; the staged rung reused it. Every native test passed — they
   only ever built raw plans — and the guest sent 137,794 perfectly
   correct packed bytes under a label telling the host to read 307,968
   unpacked ones. The encoding is a parameter now, and a native test pins
   both spellings.

### RESOLVED: the 180c's wire capture arrived garbled — 24-bit addressing

Superseded by the entry at the top of this file, which carries the metal
evidence, the fix and what is still unverified. **The reasoning recorded
here was wrong and is kept because being wrong in this particular way cost
two passes.**

What was written here: the `StripAddress`/`SwapMMUMode` hypothesis "is
contradicted by this tree's own metal evidence", because `vprobe`'s
fidelity sweep reported MATCH (480 rows) at base `0xFC080000`, and because
that base "is only reachable with 32-bit addressing on", so the machine
must have been in 32-bit mode.

Both halves were true of the session they were measured in and neither
generalised. The 180c's **PRAM battery is dead**, so its Memory control
panel setting reverts to 24-bit on every power cycle; the vprobe run and
the garbled capture were in different machine states, three days apart.
Re-run beside `shotdiag`, the same sweep reported 480/480 rows DIFFERING.
The address does read like a 32-bit one because `GetPixBaseAddr` returns
what QuickDraw knows — QuickDraw is not the thing that truncates it, the
CPU is, at the moment of the dereference.

**The lesson worth keeping.** A measurement retired a hypothesis, and the
measurement did not carry the state it depended on. Everything raw this
tree measures on a 68K Mac is now reported beside its addressing mode for
that reason.

**What did change: the walk now has a gate.** The framebuffer walk was
the one part of the lane no test could reach — it sat between an `FSSpec`
and a `ShieldCursor`, and the only other reader of that memory (`vprobe`)
merely *times* it, so a wrong base reads at full speed and every number
stays green. `n68_shotwire_emit()` now owns the walk with no Toolbox in
it, `shotstage68.c` keeps the file, the cursor and the clock behind hooks,
and `test_shotemit.c` drives it over a synthetic framebuffer whose padding
is poisoned, decoding the result with the **host's** PackBits decoder
transcribed from `CaptureDecoder.swift` rather than this guest's own
unpacker. Both stride shapes are driven: 640-over-640 (the 180c, where a
stride bug is invisible) and 640-over-1024 (the Quadra, where it is not).
Mutation-verified — reintroducing the stride confusion fails the Quadra
shape and the poison check and leaves the 180c shape green, which is the
whole argument for testing both.

**What that gate does NOT prove.** It proves the arithmetic and the
encoding, over memory the host cc can allocate. It cannot say anything
about whether `sc.base` points at the 180c's framebuffer, which is the
open question. Tested, not metal-verified.

**What is left before metal.** Nothing structural — this is a deploy and
a run. Worth doing on the 180c specifically because every timing number
so far is an emulator's, and because the compression that makes this lane
worth having was 4.7:1 there against 2.2:1 here.

**One thing that already works and is worth knowing.** `screenshot`
followed by `put` gets pixels to the host *today*, using two shipped
verbs and no new code — as a PICT, which the host cannot render but can
store. That is a stopgap, not the lane.

## `screenshot` on NOW-68K: metal-verified, and what it measured

`screenshot` slice one is implemented on NOW-68K
(`shot68.c` / `n68_shot.c`, contract-declared already — nothing in
`contract/asyncapi.yaml` changed to add it). It captures the screen,
encodes a packed 8-bit PICT, writes it to the guest's own desktop as
`Screenshot YYYY-MM-DD HH.MM.SS` (type `PICT`, creator `ttxt`), and
returns the measurement rows. No pixels cross the wire; that is slice
two and belongs to the bulk-send work.

**Metal-verified on the PowerBook 180c** (System 7.1, 640x480x8, 4 MB,
2026-07-26) — deployed as a spike (`NOW-68K shot 0.14+shot`, its own
folder and its own dev-settings file so the current build's 5252 was never
touched), launched by asking the running build to `launch` it by path, and
driven over the wire on 5050. Three captures: one `--no-save` and two
saves. Both files landed on the guest's desktop with distinct names, and
one was pulled back over FTP and **decoded here** — 640x480, `pixelSize`
8, 256-entry colour table, and the 180c's own screen, correctly. The
capture ran inside the partition with room to spare (the guest reported
`free=489K max=179K` at the time; the capture's ceiling is ~21 KB).

**The numbers, which are the point of the slice:**

| | 180c (metal) | notes |
|---|---|---|
| read | 187–227 ms | matches vprobe's ~200 ms banded CopyBits |
| pack | 431–542 ms | **the unknown this slice existed to measure** |
| write | ~800 ms | 65 KB to the internal disk |
| output | 65,648–65,692 B | full 640x480x8 frame |
| ratio | **4.7:1** | |

**Packing costs about 2.4x the read, not 10x.** The worst case in
`shot68.c` was written assuming up to 10x and is therefore conservative by
a wide margin: a whole capture is ~1.5 s wall clock, against a ~65 s
death timer. And **4.7:1 on a real desktop means a frame is 65 KB**, not
300 — which is the number slice two turns on, and it is a far friendlier
number than the emulator's 2.2:1 suggested (the emulator's desktop was
busier; a real 180c desktop packs better).

**The 180c's clock is not set** — its PRAM battery is dead, and the 2020
capacitor/battery work is queued for that machine anyway. Both captures
were named `Screenshot 1904-01-01 23.49.0x`, the Mac epoch, which is what
`GetTime` returned. The naming code is doing the right thing with the
wrong input. What is worth keeping is that the per-second collision guard
is carrying more weight on this machine than it was written for: every
session after a restart starts near the same instant, so the tick-stamped
fallback — not the timestamp — is what keeps shots from overwriting each
other until that battery is replaced.

**Also verified on the Quadra 800 emulator** (OS 8.1, 640x480x8, 2026-07-25):
run from the guest's own console, three captures in one session
(`--no-save`, then two saves), the app survived all three, both files
landed with distinct names, and one of them was pulled off the disk image
with `hfsutils` and **decoded on the host** — 640x480, `pixelSize` 8, a
256-entry colour table, and pixel-for-pixel the screen at the moment of
the command with the cursor shielded out of it. That is the strongest
statement available short of hardware: the picture is not merely a file,
it is the right picture.

**The emulator settled nothing about TIME, and said so at the time.** It
reported `read 0 ms, pack 23 ms, write 8 ms` — a 68040 with a
host-memory framebuffer. Its 2.2:1 ratio also did not carry: the 180c's
own desktop packs to 4.7:1. Both were correctly labelled as proving the
code RUNS and produces the right picture, and nothing more; the metal run
is what produced numbers.

Still unverified, and named because these are the ones that will bite:

- **Only one screen has been captured, and it was quiet.** 4.7:1 is a
  desktop with two windows on it. A screen full of dithered photographic
  content will pack far worse, and nothing here establishes a floor.
- **The timing split is a difference of two passes.** `read_ms` is a real
  banded-CopyBits measurement (vprobe's, on vprobe's band); `encode_ms`
  is the recording pass minus the read minus the write, so it carries
  both passes' noise. On a machine where packing dominates that is fine;
  if the two ever land close together the number degrades to noise, and
  it is floored at zero rather than allowed to go negative.
- **8-bit only, by refusal.** A screen at any other depth is declined
  with a sentence naming the depth. `CopyBits` would convert for free but
  the 1400c showed a non-native path eats the whole margin
  (`vram-readout.md`), and nobody has measured that here.
- **The capture does not pump the wire.** Bounded by arithmetic at ~10 s
  worst case against the host's ~65 s death timer (`kShotWorstCaseMs`) —
  measured at ~1.5 s, so the bound is conservative by ~7x,
  deliberately, because a pumped event can move a window mid-recording
  and tear the picture. If a real 180c ever exceeds that bound the fix is
  to band the PUMP, not the picture.

One refactor rode along with this and is worth naming: **`vprobe`'s walk
to the framebuffer and its one-band GWorld moved out of `vprobe68.c` into
`screen68.c`**, unchanged, because `screenshot` needed the same three
answers and a second copy of a fail-closed geometry check is one copy
that falls behind. `vprobe` is metal-verified on the 180c; the moved
version is not, and the move was verbatim rather than a rewrite, but
"verbatim" is a claim about the diff and not about the machine.

### The banded recording that had to be abandoned — worth knowing

The first implementation recorded the picture **a band at a time** into a
640x32 offscreen port, which is the obvious way to bound memory and is
what the task was scoped around. On System 8.1 it **killed the
application on the third band, every time**, while QuickDraw was writing
that band's colour table. It was bisected on the emulator against the
guest's own log:

- not the file: `--no-save` (no `FSWrite` at all) died identically;
- not the geometry: removing `SetOrigin` and recording every band at the
  port's top died identically;
- not the partition: 2 MB instead of 384 KB died identically;
- not the put proc: it was entered correctly and had already streamed
  6.7 KB across two good bands, and the partial PICT recovered from the
  disk image decodes as two valid `PackBitsRect` opcodes.

The cure was to stop banding the *destination* at all, which the design
did not need: **a picture being recorded is never drawn into.** QuickDraw
diverts the bottleneck and hands the source pixels to the put proc, so
the destination port supplies only a coordinate space, a depth and a clip
— and the Window Manager's colour port is all three for free. One
recording `CopyBits` over the whole frame, one colour table instead of
fifteen, ~21 KB ceiling, and none of the above. The root cause inside
QuickDraw was never identified; if anyone reopens banded recording, that
is the thing to find first.

## The 180c, 2026-07-25 evening: everything automated is green

The display came back (a via that wiggled against its pad, found by
beeping continuity, reflowed). `NOW-68K 0.14` landed itself by handoff and
every automated gate passed against it: the reader extraction, `ps`, the
bounded `launch` search, the redial, the `error` refusal, the
oversized-frame skip with frame sync surviving, two overlapping requests,
and `quit`'s whole outcome table including the self-refusal.

**`quit`'s confirmation on this guest is now STRONG.** With
`process.list` served, a disappearance is re-checked against a different
code path instead of by re-asking `quit`. `MetalQuitTests` probes for the
capability rather than deriving it from the hello name, because deriving
it meant the file kept understating its own evidence the moment the guest
grew.

**Three defects were in the GATES, not the guest**, and the worst of them
had been reading green:

- The self-refusal case quit `now-guest-68k` — the CMake target name —
  while a deployed build runs as `NOW-68K 0.14`, its MacBinary name. It
  asked to quit a process that does not exist, got "nothing named that is
  running", asserted nothing, and passed. It had never once tested the
  behaviour it is named for.
- The harness raced its own teardown: `stop()` reports `.idle` while
  `NWListener` cancels asynchronously, so the next test in a suite bound a
  port its predecessor still held. Two of five failing while three passed
  against the same live guest is a race, not a busy port.
- The strength banner was printed before the capability probe ran, so it
  announced the strength assumed rather than the one measured.

Understating evidence is the same species of dishonesty as overstating it,
and it is harder to catch because nothing fails.

## The console, and what it is not verified to do

- **NOW-68K's interactive console is METAL-VERIFIED** (2026-07-25,
  evening). Watched by a human at the 180c after its display was
  repaired: `ps`, `help` (rendering the shared command table plus the
  console-local verbs), and **up/down history** — the last of which had
  never been observed anywhere, on metal or in an emulator, and was the
  feature the console was asked for.

  The two redraw bugs found in the q800 emulator earlier the same day
  were one cause: `draw_output` and `draw_input` drew without erasing
  first, and the Window Manager erases only what it newly exposes, so a
  rectangle the app invalidates itself keeps its old pixels. The command
  stayed on screen after Return looking unrun — inviting a second Return,
  which for `quit` or `launch` repeats a real action — and `clear`
  appeared broken while working perfectly. Neither was reachable by a
  native test; they are pixels.

- **The console pane cannot be copied out.** A click in the output pane
  does nothing on purpose: it is drawn text, not a TERec. Reading a long
  result means retyping it. Real gap, not a decision anyone would defend
  on its merits.

## Rough edges

**A console line reaching a guest older than `line` is misread, not
refused.** Such a guest ignores the field and runs the command bare, so
`ls Lab:Code` lists the share root and says nothing about the path it
dropped. The field is additive by the contract's own rules — an unknown
field is ignored — and this is the one place that politeness costs
honesty. Both guests in this tree read it; the exposure is an older
binary still sitting on a machine, which is a realistic state for the
PowerBook. Stated beside the field in `contract/asyncapi.yaml` rather
than only here.

**No `help`, no completion.** Tab completion is the guest's own answer,
so a guest that does not serve `help` has none — deliberately, because a
host-side fallback list is exactly what was removed. It does mean a shell
that offers nothing until the guest is updated, and `help` there answers
`unknown-command`, which reads as an error rather than as "this build is
old".

**Reverse streaming still needs longer and adversarial metal evidence.**
The PowerBook ladder now covers direct data-fork and MacBinary pulls
through 4 MiB plus cancellation. It does not yet cover a transfer longer
than two minutes, a file larger than 4 MiB, source mutation during a
pull, or direct guest free-heap measurement.

**The build stamp can read a few minutes early.** CMake touches
`build_stamp.c` at the END of a build, so the stamp reflects when that
file was last compiled rather than when the binary was linked. It has
already caused one "is this the build I think it is?" moment, and the
verification ritual depends on it. `touch now-guest-ppc/src/core/build_stamp.c`
before a build forces it current.

**The wire fixtures are transcribed by hand.** `GuestWireFixtureTests`
holds copies of the strings `wire.c` emits. `GuestWireConformanceTests`
reads the source directly and needs no maintenance, but it cannot
reconstruct the three messages built across several `snprintf` calls
(`file.listing`, `file.result`, `command.result`), which is why the
hand-written copies exist. They can drift.

**The browser stops at 128 rows** (`kMaxRows`) and says so in its status
line rather than paging further.

**No icons in the browser list.** `GetIconRef` is present on the machine
(the type/creator lookup a listing off the wire needs, since it has no
file to ask about) and `GetIconRefFromTypeInfo` is absent. Nothing uses
either yet; the list is text-only.
