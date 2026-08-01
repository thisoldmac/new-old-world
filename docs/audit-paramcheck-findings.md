# Audit lane: wiring the unknown-parameter guard (2026-08-01)

Assigned lane: wire `MirrorKit.ParamCheck` (`now-host/Sources/MirrorKit/ParamCheck.swift`)
into every mutating method on the agent surface, because it was ported from
`timbottu/mirror` 2026-07-31 and has zero call sites.

**Finding: the guard is not missing. It already exists, under a different
name, wired more broadly and tested more strictly than `ParamCheck` itself
was. Wiring `ParamCheck` on top of it would add a second, competing
unknown-parameter mechanism, not close a gap.**

## What is actually running today

`HostProjectionArguments` (`Projection/HostProjection.swift`) carries
`refusalForUnknownMembers(tool:accepting:)`, and `HostProjectionDispatch`
(`Projection/HostProjectionDispatch.swift:60-63`) calls it **for every
registered projection, before `invoke` runs** — not opt-in per method. Every
conformer to `HostProjection` must declare `acceptedArguments: Set<String>`
(no default implementation, so a new row fails to compile without one), and
`HostProjectionArgumentStrictnessTests` (`now-host/Tests/HostTests/`) asserts,
registry-wide:

1. `acceptedArguments` equals the `properties` keys of the row's own published
   `inputSchema` (`testEveryRowsAcceptedSetIsExactlyItsPublishedSchemasProperties`)
   — so the declaration cannot drift from what a caller was told.
2. Every schema also declares `additionalProperties: false`
   (`testEveryRowsSchemaDeclaresItselfClosed`).
3. Every registered row refuses an unknown key, and the refusal names both the
   key it got and every key it accepts
   (`testEveryRowRefusesAKeyItDoesNotKnow`,
   `testTheRefusalNamesBothWhatArrivedAndWhatTheRowAccepts`).
4. The gate is enforced at **dispatch**, so a row that reads its arguments
   carelessly is still refused before it runs
   (`testARowThatIgnoresItsArgumentsIsStillRefusedBeforeItRuns`, using a
   fixture `CarelessProjection` built for exactly this).
5. The `guest` envelope member is lifted once, centrally, before any row sees
   its arguments (`HostProjectionArguments.envelopeMembers`), so no row can
   forget to exempt it.

I verified this directly on the priority methods named in the brief:
`MenuActProjection`, `WindowActProjection`, `ControlActProjection`, and
`TextSetProjection` all declare `acceptedArguments` and are gated centrally
through `HostProjectionDispatch`. Every other file in
`NOWAgentIntegration/Projection/` that conforms to `HostProjection` is gated
the same way, compile-enforced — I did not find a conformer missing
`acceptedArguments`.

This is not the same code as `ParamCheck` moved over; it is a NOW-native
mechanism (dated 2026-07-31/08-01 in its own comments) built to the same
lesson but stronger in three ways `ParamCheck` is not: shared at the dispatch
call site rather than per-call-site discipline, cross-checked against the
published schema by test rather than hand-maintained, and covering the whole
registry rather than an "priority methods" subset.

## Why `ParamCheck` has zero call sites

`now-host/Sources/MirrorKit/PORTING.md` explains the crossing: MirrorKit's
*archaeology* (scene model, IR, hit testing) was ported wholesale from
`timbottu/mirror` on 2026-07-31, deliberately, because re-deriving it without
a real Mac is waste. The wire layer was explicitly **not** ported —
`WireClient`, `ScenePoller`, `MirrorTarget`, and the QMP executors were all
cut, with a table in that same doc explaining why each one had to be
reimplemented against NOW's own contract rather than reused. `ParamCheck` is
wire-adjacent policy (it validates a Mirror-shaped RPC envelope: a method
name, an argument set, an `envelope` of `session`/`settle`/`settleTimeoutMs`)
that came across anyway under "nothing else was dropped, no source file was
trimmed to make the build pass" — i.e. it rode along with the scene-model
archaeology without anyone asking whether NOW's own wire needed it. It didn't,
because NOW had already built (or was building, in the same window) its own
version at the `HostProjection` layer.

Concretely, `ParamCheck.envelope` names `session`, `settle`, and
`settleTimeoutMs`. I grepped the whole host tree: none of those three strings
appears anywhere outside `ParamCheck.swift` and `ParamCheckTests.swift`. NOW's
actual envelope is `{"guest"}` (`HostProjectionArguments.envelopeMembers`).
`ParamCheck` is validating a request shape NOW's wire does not have.

## What I did not do, and why

I did not wire `ParamCheck` into the act/text-set projections. Doing so would
mean picking one of two outcomes, both bad:

- Make it a second, parallel gate alongside `refusalForUnknownMembers` — two
  mechanisms disagreeing is exactly the "surface advertises one spelling and
  accepts another" failure the existing test suite polices for.
- Rewrite each row to route through `ParamCheck.unknown`/`.message` instead of
  `HostProjectionArguments`, which throws away the schema round-trip
  guarantee (property 1 above) and the dispatch-level enforcement (property
  4) for a per-call-site pattern that is easier to add a row without.

## Recommendation (orchestrator decides)

`ParamCheck.swift` and `ParamCheckTests.swift` are dead code, and I believe
they should be deleted rather than wired: everything they were meant to
prevent is already prevented, more strongly, at
`HostProjectionArguments`/`HostProjectionDispatch`. I left them in place and
did not delete them myself — deleting ported code that another lane may be
mid-edit on is not this lane's call, and the brief asked me to wire, not to
prune. Flagging for the orchestrator to decide: delete both files, or leave
`ParamCheck` as an inert, documented port-artifact (its doc comment is
accurate and harmless either way).

## Contract-promised-but-unread parameters: none found

Upstream's three examples (`scope`, `allowDrag`, `windowItem`) were checked
against NOW directly, not assumed absent:

- `allowDrag` does not appear anywhere in `now-host/Sources`.
- `windowItem` exists only as an internal `HitTester`/`ActionModel` enum case
  (`MirrorKit/HitTester.swift`), never as an MCP schema property or accepted
  argument.
- `scope` exists as an **output** field on `now_observe_elements`'s
  `observation` object (`ObserveElementsProjection.swift:200`, `:215`),
  documented as part of the reply. It is not in that row's `inputSchema`
  (`serialHi`/`serialLo` only) and not in `acceptedArguments`, so there is no
  input parameter of that name for the guard to fail to enforce.

More generally, this class of bug is structurally harder to reintroduce here
than it was upstream: `HostProjectionArgumentStrictnessTests` mechanically
asserts `acceptedArguments == inputSchema.properties` for every registered
row, so a schema key with no corresponding read (or vice versa) fails a test
by construction — it does not depend on a human noticing the drift. I did not
find a case where it doesn't hold; I did not exhaustively re-derive every
row's accepted set from its decode function by hand (that is what the test
does continuously), but spot-checked `AgentIntegrationWindowActRequest.decode`
(`Projection/MirrorActModels.swift`), which goes further than the schema
check: it computes `present == expected` over the *actual argument keys*
per-action and refuses a mismatch before touching any of them, independent of
the shared dispatch gate.

## Held-scene / observation age: not applicable as asked, and already
## covered where it would matter

`now_observe_elements` (the projection closest to upstream's "find") has
**no host-side cache to go stale**: its only implementation today is the
default `AgentIntegrationClient.observeElements`, which returns
`.unavailable(.noObservationLane(...))` — there is no concrete
`SocketAgentIntegrationClient.observeElements` yet (grepped; it does not
exist). When it is implemented, per `MirrorActModels.swift`'s doc comments,
it is meant to be a live walk per call, not a served cache — and its reply
already carries a per-process `stampTicks` ("The TickCount at which this
slice of the walk was taken, by the machine that took it") plus `truncated`
and `live` fields describing the reply's own currency. So the specific
regression upstream hit — a held scene answered with no age, making a
successful reopen look like a failure — has no analog to reproduce yet, and
the schema for when it lands already has an age field.

More broadly across the host layer: I found a repeated, explicit design rule
against host-side caching of guest state (`SoftwareInventoryProjection`,
`HardwareCensusProjection`, `MachineFactsProjection`, `SessionCapabilities
Projection` doc comments all independently state variants of "a host holding
a stale copy would refuse a probe a newer guest serves" / "answering from a
cached copy would be this host answering for the machine"). Where caching does
exist, it is explicitly the **guest's** own cache with documented
rebuild-on-cursor-1 semantics (`SoftwareInventoryProjection`), not a silent
host-side hold. `CaptureScreenProjection` and `StreamScreenProjection` both
have a typed `.stale`/`.staleFrame` refusal rather than serving an old frame
silently. I did not find a NOW observe-shaped projection that serves a held
answer without saying how old it is.

## Verification

`swift build` in `now-host/` — see commit for the exact log. Not run:
`swift test` (per lane instructions — one `swift test` at a time on this
machine; the orchestrator runs the real gate). Nothing here has run against a
Macintosh, emulated or real.
