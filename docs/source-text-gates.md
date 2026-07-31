# Gates that prove something by reading source text

An audit of every gate in this repository that establishes a structural
property by **scanning source text** rather than by running the code — what
each one claims, whether it does it, and what it cannot catch.

Run on 2026-07-31, on branch `claude/gate-audit`. **The instrument is
mutation, not reading.** Every claim below was established by changing the
code the gate watches, confirming the change compiles and runs, and observing
whether the gate noticed. Where a mutation is described as passing, it built
both guests, passed the native suite, and passed the whole host suite.

## Why this class of gate needs auditing

These gates are cheap and they have caught real drift. They also share one
failure mode, and this audit brings the count of confirmed instances to
**seven**:

> **A comment that names the identifier satisfies a scan of the raw text.**

The comment is not incidental to the failure; it is *caused* by it. A function
worth gating is a function worth explaining, so the prose beside the code names
exactly the identifiers the gate looks for. **The better the comment, the more
reliably it hides the deletion.** Every one of the seven was found by accident
or by deliberate mutation — never by reading, because reading is what fails.

The shared remedy is `GateSource` (`now-host/Tests/HostTests/GateSource.swift`):
one reader, comments stripped. It is not a parser and does not pretend to be;
see *Limits inherent to reading text* below.

## The gates

Legend: **Load-bearing** — the gate fails when the property it names is
broken. **Was theatre** — it did not, and now does. **Partly theatre** — it
holds for the case it names but a stated part of its claim is unreachable.

| Gate | What it claims | Verified how | What it cannot catch | Verdict |
|---|---|---|---|---|
| `GuestWireConformanceTests.testGuestChecksDiskReservationBeforeAcceptingUpload` | The guest claims disk space with `SetEOF` and handles the failure before accepting an upload | **M1**: deleted the reservation block, left the three pinned lines in the comment that replaced it — passed | Pins three *lines*; proves they are written, not that they run, in that order, or before `file.accept`. An uncalled helper containing all three passes | Was theatre → **load-bearing** |
| `GuestWireConformanceTests.testEveryGuestMessageDecodes` | Every whole message the guest sends decodes on the host | **M3**: renamed the guest's `file.end` to `transfer.end` — passed. Probing showed the `file.`-prefix carve-out only ever sees `X.end`, the scanner's own `%s` placeholder, so it could never fire | Messages assembled across several calls (see `piecemealCoverage`); a type computed from a `%s` is only as good as the `computedTypes` list | Was theatre → **load-bearing** |
| `GuestWireConformanceTests.testHfsPathArgumentsAreTextDecoded` | HFS path arguments are read with `now_json_find_text`, not `now_json_find_string` | Comments stripped; direction is safe (a comment can only add hits to a check demanding zero) | The key list is hand-written. Nothing in the contract marks a field as a filename, so a new path-bearing key is invisible | **Load-bearing**, bounded |
| `GuestWireConformanceTests` hello gates (`build`, `agent`, single-`snprintf`, argument order) | The PowerPC hello fills `build` and `agent` from their seams, in the order the format string names them | Predecessor: swapping the two arguments left every gate green while the machine read as refusing consent; renaming `send_hello` turned three gates into a silent `XCTSkip` | Nothing below the argument-position level; a seam that returns a constant still passes | **Load-bearing** |
| `CommandParityTests` — the two-face rule | Every guest capability is reachable from both the console and the wire | Predecessor: three mutations (a second process walk hidden by its own comment; the delegation check satisfied by a longer prefix; a dead premise passing via `guard … else { return }`). **M2** (this audit): a console-only verb in `conwin.c` — a second dispatch site no gate read — passed | `#if 0` is not a comment and is not stripped, so a disabled dispatch still counts as one (direction is conservative). A verb dispatched other than by `strcmp(name, …)` is invisible | Was partly theatre → **load-bearing** |
| `CommandParityTests.testEveryDispatchSiteIsOneThisFileReads` | The file's list of dispatch sites is the complete set (new gate, this audit) | **M2b**: a `strcmp(name, …)` in an unlisted file fails; **M2c**: the same in a comment does not | Only finds sites spelled `strcmp(name,` | **Load-bearing** |
| `CommandRegistryTests` | The command registry's help table, the contract and the console agree | Predecessor: routed through `GateSource`; the `answered()` window opens at the first `void now_command_run(` | A forward declaration above the definition widens the window to the whole file. Recorded in place; no such declaration exists today | **Load-bearing**, bounded |
| `CensusProbeRegistryTests` — the probe rails | Each guest's probe table matches the contract | Predecessor: swapping two gathers (`{ "pci", gather_scsi }`) passed all four rail checks — every check read the quoted name, none the function beside it. Now paired | A naming convention, not proof that `gather_pci` reads PCI. Filing one row's data under another's name is caught; a gather that lies is not | **Load-bearing** as a pairing check |
| `GuestWireFixtureTests` — the 68K version pin | Wire fixtures pin the version the 68K guest actually sends | Predecessor: a commented-out older `#define NOW68K_APP_VERSION` above the live one re-pinned every fixture, consistently enough that nothing failed. Comments now stripped | Takes the first regex match; a second live `#define` would still win by position | **Load-bearing** |
| `GuestStreamingSourceTests` — the streaming counts | Both entry points arm the file transfer; the deadline resets on the same branch as the byte count | Predecessor: deleting `arm_file_transfer(` on the `file.get` path and leaving a comment kept the count-of-3 | The positional window in the staging check: a helper hoisted above it walks through. Documented rather than replaced — a call graph is a bigger promise than a text scan can keep | **Load-bearing**, bounded |
| `MCPCoverageTests` — the Served column | The coverage matrix's Served column reflects what each guest answers | Predecessor: a dispatch arm renamed with the old `strcmp` left in a comment kept the column claiming a capability NOW-68K had stopped answering | Four regexes over guest C; a capability served by a route those regexes do not spell | Was theatre → **load-bearing** |
| `CaptureProjectionTests` | The capture panel and the menu reach the projection | Predecessor found it — **a source-text gate nobody had listed**. Comments now stripped | Points at `HostFaceReach` for the rest of its limits | **Load-bearing**, bounded |
| `AgentIntegrationCapabilityTests.testNoCompanionCodeBranchesOnGuestIdentity` | The companion decides availability by capability, never by which guest dialled in | Predecessor: widened from 5 hand-named files to three trees walked recursively (43 files had been invisible). **M4** (this audit): a decider returning `guest.operatingSystem == "9"` passed — the needle list spelled `Session.swift`'s names, and all four of its hits were in the one file the check excludes | `name` and `version` cannot be needles — ordinary words in almost every file. A comparison spelling the token another way (`guest.name.hasPrefix("now-")`, a constant defined elsewhere) still passes; tested and recorded | Was partly theatre → **load-bearing** |
| `HostFaceParityTests.testTheMCPFaceIsDerivedFromTheRenderersOwnLoop` | Every registered row is on the MCP face *structurally*, because the renderer maps the registry | **M5**: replaced `registry.projections.map` with a filtered map dropping one capability, left the original in the comment above — passed, with a row silently missing from the tool list | That the loop *reaches* every row; only that the two spellings are present | Was theatre → **load-bearing** |
| `HostFaceParityTests.testEveryAppUIReachIsProvenByTheAppsOwnSource` | Every claimed app-UI affordance exists in the file the row names | Now reads through `GateSource` (same fix as above) | **The fifth rot mode**: a symbol appearing *several* times. `now_list_processes` names `model.refresh()`, which its view contains three times — deleting the Refresh button compiles and passes. Documented at `HostFaceReach.reached` | **Load-bearing**, with a named blind spot |
| `HostFaceParityTests.testAppIntentsIsUniformlyNotYetReachedUntilThatFaceExists` | No file imports AppIntents while every row declares that face unbuilt | Deliberately still reads raw | A comment can only make it fire — a loud false failure, never a quiet pass. The one check here whose direction makes stripping unnecessary | **Load-bearing** |
| `HostProjectionAuditTests.testTheCompanionEntryPointPassesTheLocalSink` | The companion's MCP face is handed the sink that reaches the person's log | **M6**: passed a sink whose `record` does nothing, left `audit: LocalAuditSink()` in the comment above — passed, with every agent-driven action reaching no log a person reads | That the sink's `record` does anything; only that the argument is spelled | Was theatre → **load-bearing** |
| `HostProjectionAuditTests.testNothingButTheDispatchInvokesAProjection` | Only `HostProjectionDispatch` invokes a projection, so every invocation emits an audit event | Predecessor documented the hole | Forgives any line containing `dispatch.invoke(` — a local named `dispatch` bound to a projection invokes with no audit event and passes. **No text check can tell what a name is bound to.** The real fix is narrowing `invoke`'s visibility, a production change | **Partly theatre**, documented, deliberately not papered over |
| `LoggingSpecTests` — the hot path | No disk write on the per-chunk path | Predecessor documented the hole | Matches one literal, `now_log(`; a one-line macro alias defeats it and builds clean. Its hot list is three hand-written entries and names neither of NOW-68K's transfer paths | **Partly theatre**, documented |
| `scripts/test-native` — the manifest | Every native test file is listed | Predecessor documented the hole | Greps its own text, comments included, and by substring. No basename currently sits only in a comment | **Load-bearing** by luck, documented |
| `now-guest-ppc/tests/ot_connect_source_test.py` | The Open Transport connect path keeps its shape | Predecessor documented the hole | Takes first occurrences, so a forward declaration silently shrinks its window. Neither function has one today | **Load-bearing** by luck, documented |
| `.github/workflows/ci.yml` — reject private lab values | No RFC1918 address, absolute home path, or tracked `.env.lab` in the tree | Not mutated here (CI-side); already carries its own history | Greps the whole tree **including its own file**, so it is written to spell no address itself. Its own recorded near-miss: an earlier `\b` in the pattern made `git grep -E` match nothing and read green while checking nothing | **Load-bearing**, self-aware |

## Gates nobody had listed

Three, and two of them were found by this audit:

1. **`CaptureProjectionTests`** — found by the predecessor, simply absent from
   every list of source-text gates.
2. **`conwin.c` as a dispatch site** (M2). Not an unlisted *gate* but an
   unlisted *input*: `CommandParityTests` read NOW-68K's console face from
   `n68_exec.c` alone while `conwin.c` dispatched too — and several assertions
   in that file name `conwin.c` in their prose while reading the other file.
   The fix generalises: `testEveryDispatchSiteIsOneThisFileReads` now walks
   both guests and fails when the set of dispatch sites changes, so the next
   one cannot be unlisted.
3. **`HostFaceParityTests` and `HostProjectionAuditTests`** as members of this
   family at all. Both read repository source with `contains`; neither had been
   routed through `GateSource` or counted among the gates this class covers.

## Mutations that passed when they should not have

Six in this audit, on top of the predecessor's seven. Each built and ran.

| # | Mutation | What it revealed |
|---|---|---|
| **M1** | Delete the `SetEOF` disk reservation from `fileshare.c`; leave the three pinned lines in a comment | The comment-satisfies-scan defect, fourth instance. Every write extends the file; a full disk becomes a late, misleading transfer failure — the exact outcome the gate's prose claims it prevents |
| **M2** | Add a console-only verb `scrollback` to `conwin.c` | A whole dispatch site was unread. The machine gains a capability a person at the PowerBook can reach and the host cannot — the `ps` defect the file was written for, committed inside it |
| **M3** | Rename the guest's `file.end` to `transfer.end` | The `file.`-prefix carve-out in the decode gate had never been able to fire: the only message reaching it is `X.end`, the scanner's own placeholder. Meanwhile every genuinely undecodable non-`file.` type passed in silence |
| **M4** | A decider returning `guest.operatingSystem == "9"` | The identity guard's needle list was written in `Session.swift`'s vocabulary (`guestName`/`guestOS`/`guestVersion`) while the guarded trees call the same facts `name`/`version`/`operatingSystem`. Sixty files were scanned for three words that could only appear in the one file excluded |
| **M5** | Replace `registry.projections.map` with a filtered map dropping one capability; leave the original in a comment | The premise the entire `.reachedByRegistry` MCP face rests on. One row silently missing from the tool list while every row still claimed the face and the gate agreed |
| **M6** | Hand the companion an audit sink whose `record` does nothing; leave `audit: LocalAuditSink()` in a comment | Every agent-driven action on the machine reaches no log a person reads — rule 3's whole point |

**One mutation was invalid and is recorded as such.** M5b (renaming
`model.capture()` to break the app-UI reach check) **failed to build**, because
a test elsewhere calls it. A mutation that does not compile produces no
assertions and looks exactly like proof; it was discarded rather than counted.
This has now happened three times on this arc, which is why every mutation
above states that it built.

## Fixed versus documented, and why

**Fixed** — where the fix was cheap and did not weaken the gate:

- Comment stripping routed through `GateSource` in `GuestWireConformanceTests`
  (two direct reads), `HostFaceParityTests`, and
  `HostProjectionAuditTests.testTheCompanionEntryPointPassesTheLocalSink`.
- The decode gate's carve-out replaced by `computedTypes`, so `file.end` and
  `capture.end` are both decoded for real and any other unknown type fails.
- NOW-68K's console face read from both its dispatch files, plus a census that
  fails when the set of dispatch sites changes.
- `operatingSystem` added as an identity needle; `AgentIntegrationModels`
  joined `AgentIntegrationSessionHealth` as a *carrier* of identity rather
  than a decider.

**Documented rather than fixed** — where the limit is inherent, the reasoning
is written where the next author will read it, at the site of the claim:

- `HostProjectionAuditTests`' `dispatch.invoke(` forgiveness. No text check can
  tell what a name is bound to. The real fix is narrowing `invoke`'s
  visibility, which is a production change and belongs on its own.
- `HostFaceReach.reached`'s fifth rot mode (a symbol appearing several times).
  This is the standing decision not to paper over text-scanning limits with a
  partial parser, and everything else here defers to it.
- `LoggingSpecTests`' single literal, defeated by a macro alias.
- The reservation check's three pinned lines proving authorship, not
  reachability.
- The HFS path key list, and the identity guard's inability to use `name` or
  `version` as needles.
- `testNothingButTheDispatchInvokesAProjection` and the AppIntents scan keep
  reading **raw** on purpose: both assert an absence, so a comment can only
  produce a loud false failure, never a quiet pass — and the first reports line
  numbers that stripping would shift off the real source.

## Limits inherent to reading text

Stated once, because every gate above inherits them. A stripped scan still
cannot tell:

- a live call from a dead one (`#if 0` is not a comment);
- an argument from a token that merely appears in the body;
- a reachable control from a spelled one;
- what a name is bound to;
- one occurrence of a symbol from three.

Where a gate's claim depends on one of these, the honest move is to say so at
the site of the claim rather than to build an elaborate check that gives false
confidence. That trade was made deliberately at `HostFaceReach.reached` and is
followed throughout.

## Hypotheses that did not survive

These say which gates genuinely hold, and are recorded because a failed
mutation is evidence.

- **A guest could stop including `contract/wire_limits.h` and define its own
  limits.** It does not compile, and the native suite fails four ways
  (predecessor). The wire-limits agreement is enforced by the toolchain, not
  only by a gate.
- **A doc comment naming a guest could defeat the identity guard.** It does
  not — verified after the fix, in a file that otherwise obeys the rule. The
  predecessor's trade (strip comments, buy 43 more files) holds.
- **A `strcmp(name, …)` in a comment could invent a dispatch site.** It does
  not; the census reads through `GateSource`.
- **Swapping a census probe's gather without also swapping its name.** Caught —
  but by `-Werror=unused-function`, not by any test (predecessor).

## A gate added after this audit, which deliberately reads no source text

2026-07-31, `HostProjectionArgumentStrictnessTests`, on branch
`fork/param-strict`. Recorded here because the obvious way to build it was as
a member of this family, and it is not one — the reasoning is the useful part.

The property it gates: every host projection's `acceptedArguments` — the key
namespace the dispatch now enforces — equals the `properties` of the
`inputSchema` that row publishes. The declaration exists so a caller who
writes `destinationPath` where the row's name is `toPath` gets a refusal
naming both spellings instead of a guess; the gate exists because a
hand-written accepted set that has drifted from the published schema is the
same fail-open surface with better manners.

The source-text version of that check is easy to picture and would have been
wrong twice over. It would have had to find each row's schema literal by
regex, which puts it squarely under this file's standing limits — a key
spelled in a comment counts, a key composed rather than quoted does not
appear, and seven rows state parts of their schema through shared fragments
(`GuestFilesSchema.path`, `HostProjectionSchema.emptyInput`) that no scan can
resolve. `HostProjectionConsentTests` had already met exactly this and says
so: it reads the **rendered descriptor** rather than the source, because rows
declaring their annotations through a shared fragment "look silent to a
`grep`".

So the gate calls `mcpDescriptor` and compares dictionaries. `Set` equality is
not a proxy for the property; it *is* the property, and it holds for a
fragment-composed schema as readily as a literal one.

**The general rule this suggests, for the next gate in this repository:** scan
source text only when the thing being asserted has no run-time representation.
Reach, dispatch sites and hot paths have none — a call site is not an object
you can ask a question of, which is why those gates read text and why they
carry the limits above. A schema, an annotation, or a declared set *is* an
object at run time, and reading it costs nothing and inherits none of them.

Mutation-checked, all three built and ran: deleting the shared gate turned 3
test cases red (25 assertions); dropping the envelope exemption turned 1 red;
misspelling one row's declaration turned 3 red, including that row's own
pre-existing behaviour test. Full counts in the commit message.

## On the question of whether stripping comments weakens the identity guard

Asked deliberately, and answered: **no.**

The instinct is that a guest name in a comment beside a decision is evidence
the author was reasoning from identity. It is — but it is evidence about an
*author*, not about the *code*, and the gate's claim is about code. A comment
cannot branch. What the raw scan bought was a weak proxy at a high
false-positive rate; it fired on doc comments four times in one week, once per
agent, an amend each, always on prose *explaining* the rule in a file that
obeyed it.

What it **cost** was the surface. Keeping that noise tolerable was the reason
the gate scanned one non-recursive directory plus five hand-named files — 5 of
the 26 in `Host/Automation`, none of the 22 in `NOWAgentIntegration` outside
`Projection/`. An identity branch in any of the other forty-three was
invisible. That hole was larger than the one the comments were making noise
about, and this audit then found a further one (M4) that the noise had never
been protecting against at all.

The strip pays for the surface. That is the trade, and it is the right one.
