# Mirror retained-planes checkpoint — 2026-08-04

This checkpoint records the first direct drive of the retained state-engine
implementation at `ccf68a0`. It follows the earlier high-water checkpoint in
`docs/mirror-high-water-checkpoint-2026-08-04.md`; it does not replace or
reinterpret that baseline. The purpose of this run was to prove that plane
policy is a reversible projection over retained guest evidence, then collect a
full UX batch before another patch loop.

Overall status: **host-tested; partially emulator-observed; not a green Mirror
sweep; not metal-verified**.

## Exact run identity

| Item | Exact value |
|---|---|
| Branch | `codex/recover-ptolemy-ux-loop` |
| Host source | `ccf68a0056c47f6e81678b154a4234be20879b6d` |
| Host executable SHA-256 | `6db4fe4da0857eb08193d93819eaf9ff93eab70793e911e8f7d42ff694c640fc` |
| Host launch | Debug app with `--mirror-scale 0.9` |
| Guest | `guest-2`, session `2cc462d9-a285-419d-b2b5-3ad19f4528ad` |
| Guest application build | `a4a59d37d100` |
| Resident build reported by host | `67d5ef434db7def800d4ba35690c43b2434ccf32` |
| Resident planes | capability `15`, requested `15`, active `15` after the sweep |
| QEMU oracle | `NOW U8 cad8e57 public list probe` |
| VM overlay | `/private/tmp/now-u7-extension-only/session.qcow2` |
| Host log | `~/Library/Logs/now-logs/2026-08-04 185319.log` |

The QEMU name records the oracle experiment that produced this overlay; it is
not a claim that the running application and resident component were rebuilt
from `cad8e57`. QMP was used only for identified framebuffer captures. Every
scored mutation began with mouse input in the native Mirror.

## Build and review evidence

The focused state-engine, plane-domain, content-plane, and source suites pass
62 tests. The full host gate passes 1,308 SwiftPM tests with 54 opt-in metal
skips and builds the application target in Debug and Release. The state-engine
review found and repaired four pre-drive defects: late pre-close scene
acceptance, scene/content overlap during policy changes, policy lookup against
the active picker instead of the pinned guest, and a source-text cadence test
that did not prove behavior. The resulting lifecycle guards use held real
scene and content completions.

The QuickDraw structured-retention and single-cadence guards were
mutation-watched. Removing retained QuickDraw `state` records fails the
structured-content test; retaining the old rearm sleeper fails the cadence
test. These are automated proofs, not substitutes for the direct drive below.

## Direct-input preflight and batch findings

| Check | Result | Direct observation |
|---|---|---|
| Workshop baseline | Pass for this run | The native Mirror and identified guest capture agreed on the Workshop window, menus, sidebar, labels, fields, and buttons. Bitmap placeholders remain unscored. |
| Menubar and Apple menu | Pass for this run | With Workshop frontmost, the menubar occupied the correct blocks and the Apple menu contained the guest-provided rows from AirPort through Stickies. |
| Workshop resize | Visual pass; settlement red | A Mirror grow-box drag resized both Mirror and guest. The operation remained `unknown` because dispatch alone is not guest-visible effect evidence. |
| Workshop close | Pass | A Mirror close-box click removed the window in both surfaces and later scene evidence confirmed it. |
| Macintosh HD open | Pass | A Mirror double-click opened the Finder window and brought Finder frontmost. |
| Finder first content | **Red** | The new window initially showed only `Bitmap unavailable`. Structured folders and labels arrived roughly one later polling cycle, after the next switcher interaction. A newly opened structured window may not be blank while the state owner waits for another unrelated action. |
| Hide Finder | **Red** | `Hide Finder` changed the front application to Sherlock but stayed `dispatched-but-unconfirmed`; the paired guest capture still contained the Finder window behind Sherlock. |
| Sherlock | **Red** | Frames and some edit-field structure appeared, then a later one-op/invert generation replaced the visible window with a full `Bitmap unavailable` surface. This reproduces the exact cross-generation retention failure the engine guard was meant to prevent, so the current live path is not yet honoring that guard end to end. |
| Finder selection | Pass | Selecting Finder in the switcher brought it and its Macintosh HD window frontmost in both surfaces. |
| System Folder and Control Panels | Delayed/red | Both windows opened from direct Mirror input, but each was blank for several seconds before structured items arrived. |
| Date & Time icon | **Red/blocking** | The authoritative Control Panels window contained Date & Time. Mirror omitted both its icon and label. A double-click at the paired guest coordinate hit only the front window and reported `that window is already front`, so the required Date & Time content/modal slice could not be reached through the Mirror. |
| Select NOW with Workshop closed | Pass | Selecting New Old World in the switcher brought the application front without reopening its closed Workshop. |
| `Windows > Workshop` | Pass in this run | The direct guest menu action reopened Workshop and later scene evidence confirmed it. This repairs the earlier high-water red for the exact runtime tested here. |
| Key Caps launch | **Red** | Selecting Key Caps from the Mirror Apple menu produced an `unknown` menu operation and no guest state change. |

The Date & Time row was not bypassed with MCP, QMP input, or a direct click in
the emulator. The inability to reach a guest-visible item from the Mirror is
the finding. The modal and Cancel rows remain unscored in this run rather than
inheriting their results from the earlier checkpoint.

## Live plane reprojection

The plane controls were exercised in the running host while the same guest
session and Mirror window remained alive:

- P3 Content off changed the Mirror status to `content off` while P1 structure
  and P2 native controls remained visible. The content generation was retained
  rather than reset.
- P2 Semantics off removed the native control overlay while the P3 QuickDraw
  text and shapes remained visible underneath.
- P2 Semantics on immediately restored the same semantic generation, `1232`,
  before any new semantic generation was observed.
- P1 remained enabled and non-interactive in the policy UI.
- A proposed P4 check was invalid because the coordinate landed in the host
  window rather than the Mirror. It was discarded, P4 was restored, and no P4
  live result is claimed. Automated coverage still proves that policy changes
  do not erase the operation journal.

This establishes the architectural point: P1–P4 are retained state-engine
contributions. Policy chooses what the Mirror projects and whether it accepts
new interaction; policy is not a destructive cache toggle. It does not yet
establish that every production render path reads those retained shelves
correctly—the Sherlock overwrite is direct counter-evidence.

## Next patch batch

Keep the next changes narrow and land them together only after tracing their
shared producer path:

1. make a newly opened structured Finder window publish its first usable
   content without waiting for a later unrelated interaction;
2. trace why Sherlock's later bitmap-only/invert observation bypasses or
   obscures the engine-retained structured QuickDraw contribution;
3. make omitted Finder items such as Date & Time retain at least their
   data-driven name and actionable hit target when their icon bitmap is
   unavailable;
4. reconcile Hide Finder against authoritative visibility instead of treating
   application activation as the requested hide effect;
5. trace Key Caps' unknown Apple-menu operation and preserve the rule that a
   blank custom-draw surface is red even though its bitmap art is deferred;
6. rerun the complete preflight before returning to Date & Time, Set Time Zone,
   Sherlock, and Key Caps as one batch.

At checkpoint close, all four plane switches were restored to on. The host and
VM were deliberately left running for manual inspection; their PIDs are not
durable identity and are therefore omitted.

## Follow-up implementation checkpoint

The first batch found above is now implemented but still requires a new direct
sweep before any red row changes status:

- structured P3 retention now uses the renderer's actual supported operation
  vocabulary, so Sherlock's undrawable invert cannot erase retained text and
  controls;
- Finder item rosters are read in bounded pages carrying a stable total, so a
  later Control Panels item such as Date & Time cannot be silently truncated;
- self-targeted Apple-menu commands now reach the guest application's normal
  Apple-menu handler, including desk accessories such as Key Caps;
- process visibility is now a retained P1 shelf with `complete`, `partial`, and
  expected-`stale` coverage. Hide, Hide Others, and Show All carry exact typed
  postconditions and cannot turn green until a later complete guest census
  matches every expected process;
- the host projection reports unknown process visibility as unknown rather
  than inventing `true` from mere process presence.

The Finder paging, Sherlock structured-retention, and visibility matching
guards were each watched fail under deliberate mutation and pass after the
implementation was restored. Focused host suites are green; this is not yet a
direct-input or emulator-visual result.
