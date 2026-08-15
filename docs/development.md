---
search:
  exclude: true
---

<!-- now-doc-provenance: generated reviewed=false -->

# Projects and Development

NOW has a headless project and build lane for classic Macintosh software. It
does not make the classic Mac's disk a host checkout and it does not make
CodeKitten a build dependency. The two project homes remain distinct:

- A **host-home** project is authoritative beneath the host app's Application
  Support `New Old World/Projects` directory.
- A **guest-home** project is authoritative beneath the Projects folder a
  person selected in the PPC guest's Projects page. NOW imports a verified
  snapshot into its private history mirror and gives an agent a persistent host
  workspace. Editing and committing that workspace does not edit the active
  guest project.

This distinction matters most when the only original is on the classic Mac.
Import creates the recoverable host scratch/history copy the agent needs for
iterative edits and Git commits, while the guest tree remains the authority
until a separately built candidate is promoted.

## Project and history ownership

`Project.ckp` begins with `CKPROJECT 1`. The portable contract and golden
fixtures live in [`contract/project/`](../contract/project/); NOW's Swift and C
parsers and CodeKitten's pure core use the same fixtures. The format declares
source membership, a target and configuration, an exact toolchain pin,
declarative build actions and a product path with required four-character type
and creator codes. Every declared file may also carry a `file-info` record for
its Finder type, creator and flags. Data and resource forks are two views of
that one logical file; source digests bind both forks and the Finder identity.
`Build/` is reserved for generated artifacts and excluded from source digests.

The host Projects store accepts only opaque project/workspace references and
canonical relative paths. It rejects absolute paths, `..`, links, stale
revisions and stale per-file digests. An accepted atomic batch produces a
revision receipt and a commit written by NOW's small Git object writer; no
system `git`, user configuration or agent-visible Git command is involved.
Normal paths remain ordinary data-fork Git blobs, while each commit's private
`.now-classic` tree carries a complete MacBinary recovery package and index for
every logical file. This keeps the repository useful to normal Git tools
without making resource forks or Finder metadata unrecoverable.
Workspaces and receipts persist across host restarts. A workspace holding the
only copy of unpromoted commits cannot be silently discarded.

For guest-home work the publication sequence is deliberately longer:

1. Page and recheck one active guest manifest, then import every listed file.
2. Open or resume a host workspace at that verified guest digest.
3. Materialize a new inactive candidate beneath the guest's private
   `.NOW Candidates` directory using the existing bounded transfer lane.
4. Recompute the candidate digest on the guest and seal it before building.
5. Build the candidate in place. A successful build marks that exact candidate.
6. Promote only if the active guest digest still equals the workspace's base
   digest. The old tree is moved to `.NOW Backups`; a failed move attempts to
   restore it. Divergence preserves both trees and refuses promotion.

The private import/candidate scopes are not Files scopes and are absent from
generic Files, Chat and MCP schemas.

## Toolchains and jobs

Toolchains belong to the PPC guest. A person chooses one root in the guest
Projects page; NOW resolves it by volume and directory identity and
qualifies an MPW installation by measuring ToolServer and its version. The
selected project must pin the exact measured ID and version. Neither an agent
nor a project file can register an arbitrary guest path.

The first backend renders a closed `compile`, `rez`, `link`, `copy`, `stage`
and `metadata` action vocabulary into MPW ToolServer work. There is no shell,
MPW command string, AppleScript or generic launch target in the project,
contract or agent schema. One asynchronous job owns ToolServer at a time. The
Workshop continues to idle and pump the wire; cancellation is terminal and
late output remains quarantined behind the old job identity.

A terminal build report names the job, project/candidate, exact toolchain,
source SHA-256, action progress, transcript, product reference, data/resource
fork sizes, type/creator and a SHA-256 over both product forks plus that
metadata. Build success does not launch anything. Run rechecks those bytes and
metadata, calls `LaunchApplication`, and separately verifies that the returned
process serial belongs to the exact product before reporting acceptance.

NOW-68K does not register these commands. Capability discovery therefore says
Development is unavailable rather than inferring support from the guest name
or CPU.

Since 2026-08-14 the guest page is a client of those same commands rather than
a settings screen: it lists the projects under the chosen root, remembers which
one this Mac is working on (NowPrefs V28, an identity rather than a folder
reference), and starts a build or a run by handing the same command functions
the host drives a request it builds locally. One walk of the Projects root now
serves the catalog, the find-by-id both the build and candidate paths use, and
the page; there were three. The page also keeps a session-scoped ring of the
last eight settled jobs, which is deliberately not on the wire — the host
watches each job settle as it drives it, and the durable record of a build
remains the ToolServer transcript in the project's own `Build` folder.

## Human and agent surfaces

The host Projects module and agent adapter call the same project,
workspace, candidate, build, promotion and run services. The compact agent
surface is split into:

- `now_projects` for the app-owned project catalog, bounded reads, atomic
  applies, history and recoverable workspaces;
- `now_development_environment` for path-free guest/toolchain qualification;
- `now_development` for import, stage, promote, build, cancel and exact run.

Host Projects writes are product-owned same-user authority and stay confined to
the app-owned root. Guest imports require the guest's Read Only grant; staging,
building, promotion and run require Full. Ordinary machine-only Chat turns do
not receive the three Development schemas. A transcript mentioning projects,
source, CodeKitten, MPW, a toolchain or a build opts that turn into the same
registry and dispatch used by MCP.

“Open in CodeKitten” is human-only in the initial surface. The PPC guest finds
CodeKitten by creator in each mounted volume's Desktop database and launches it
if needed. The host polls cooperatively until it can send one standard `odoc`
for the active `Project.ckp`, waits for the AppleEvent reply while continuing to
pump the wire, validates `ckproject.open-receipt/1`, then brings CodeKitten
forward. Dispatch-only or malformed replies are refusals, not document
acceptance. No build or sync path requires the IDE to exist. The PPC onboarding
disk can carry a separately supplied CodeKitten MacBinary as a
selected-by-default optional application, which makes initial installation one
transfer without turning that distribution seam into a runtime dependency.

## Verification and current limits

The project/history, parser, operation journal, projection, Chat-filter and
parity behavior is tested locally, and both guests cross-compile. The earlier
complete host-home build/run/dialog lane remains **metal-verified** on the
PowerBook 1400c: guest build `33bfe4e3e211` qualified
`mpw-ffff-00007b37@structural-1`, built both forks of an `APPL/H14E` product,
matched the launched process, exposed its alert through retained semantics and
left no process after dismissal.

The autonomous-loop hardening is **emulator-verified**, not newly
metal-verified. A session-private mac99/OS 9.1 guest running build
`27e37aeeaa0a` qualified `mpw-ffff-00000cf0@structural-1`. Its base image was
`be32b70a7fe546b144be76627bf4f20a1777a6fa2fb3e202ef1cd4f059ffe8e2`;
the staged resident reported source manifest `28ef6c07ee6d` and fingerprint
`085c4ebf8457`. Every development and guest-file action below used the real
authenticated HTTP MCP listener; no action fell back to stdio. The run
exercised:

- a three-action Hello World build, typed `ckproject.test-receipt/1`, semantic
  dismissal, fresh process-exit read and candidate cleanup;
- a fork-bearing host-home project whose nonempty source resource fork and
  `TEXT/MPS ` identity survived an MPW build and exact-product test;
- a six-file Memory Meter project with a real MrC failure, repair, cancelled
  job, required restage, successful build, exact-product test, semantic
  dismissal and candidate cleanup;
- creation of a guest-only project through the typed fork-aware Files surface,
  import into host scratch, host edit and commit, inactive build and typed test,
  successful promotion at the imported base digest, then a second built
  candidate refused as `guest-diverged` after an active guest edit. Restoring
  through Trash did not reproduce the logical-file digest; an exact typed
  re-upload did, after which promotion completed at project revision 3.

The guest catalog removes the opaque-ID import prerequisite. Projects and
Development mutation calls now require caller attempt IDs and the host keeps a
bounded durable response journal, so reconnect/restart retries recover the
same response. `loop-status` inventories active work and retained candidates.
The local compatibility preflight names host build, companion protocol,
projection catalog digest/version and schema revisions; stale peers receive a
typed incompatibility before domain dispatch. Projects and Development publish
operation-discriminated schemas, including exclusive project-revision and
workspace-commit apply branches.

The same NOW-owned dispatcher is reachable through client-launched stdio mode
and an authenticated loopback HTTP listener in the normal app. The
cross-transport parity gate compares initialize and notification lifecycle, ping,
resources, prompts, complete tool descriptors and schemas, real tool results,
and protocol errors. Both transports run the same 46-tool no-host conformance
recipe. HTTP additionally validates the loopback Host, bearer token and Origin;
bounds session count and lifetime; supports explicit session deletion; rejects
ambiguous framing; and has an incremental-request liveness gate. Against
the VM, HTTP served 31 tools, returned typed refusals for 14, left the one
human-approved transfer explicitly gated, and produced zero failed or uncovered
rows.

The varied loop was recorded before the HTTP listener moved from a separately
shipped companion into the normal NOW app. The corrected ownership path keeps
the dispatcher and transport implementation, passes the exact stdio/HTTP
parity, security, liveness and full-catalog gates, and completed an
authenticated app-owned HTTP call to the exact private VM session. The full
four-loop recipe was not repeated after that move: the attached-toolchain
cold-boot fixture did not auto-launch its worker, so the acceptance stopped
instead of using out-of-band QMP input.

The live loop found an idempotency-collision reporting defect: the host rejected
a reused attempt ID, but its response ID made the MCP adapter call it an invalid
host response. Pending and collision responses now carry the current request
ID and cross both transports as typed `attempt-pending` or
`attempt-collision`. The exact old response fails the regression test, and the
rebuilt host and its HTTP listener returned `attempt-collision` on the running VM.

Semantic snapshot, target lookup and planning now resolve through the same
published `MirrorStateEngine` authority. `now_semantic_ui_wait_for_settlement`
waits by journal operation ID. A direct semantic action for which no
postcondition exists terminates as `unconfirmed`, not falsely `confirmed`; the
VM acceptance proved that receipt and then used a fresh process list to prove
the application actually exited.

Current limits and friction remain explicit:

- HTTP was introduced during this slice without prior scope approval. It is now
  retained with the parity, authentication, session and liveness gates above;
  that completion does not erase the process failure that created the extra
  workstream.
- CodeKitten remains optional and separately owned. NOW now requires a positive
  versioned document-acceptance receipt, but shared fixtures and any neutral
  pure project/receipt module still need coordinated sibling-repository work.
- The portable Development starter-pack manifest and relocatable onboarding
  input are implemented and validated, but this repository does not contain a
  redistributable MPW payload. Toolchain licensing/provenance must be settled
  before a one-image NOW + CodeKitten + MPW pack can pass its acceptance rung.
- The hardening changes have not yet repeated the full loop on the PowerBook.
  The previous metal evidence still covers fork-aware host-home build/run and
  human-observed dialog behavior, not the new test, retry, guest-home promotion
  or semantic-settlement receipts.
- `loop-status` can retain candidate receipts from an ended guest session while
  `stage-status` on the current session says `candidate-unavailable`; those
  receipts need a session identity or an explicit host-only abandon policy
  before the recovery guidance can be fully composable.
- The guest Files stat surface reports fork sizes and type/creator but not
  Finder flags. Trash/restore therefore could not explain why apparently
  restored bytes failed the project digest; exact typed upload recovered the
  project, but the missing identity observation is still a diagnostic gap.
- The version-1 typed test deliberately leaves the launched app running so a
  semantic assertion can inspect it. A loop must dismiss or quit it before
  candidate discard. Cancelling a build is terminal for that candidate and
  requires discard/restage; neither behavior should be inferred from a generic
  retry.
- The 2026-08-14 guest page (projects list, persisted selection, Build/Run,
  job ring) **has not run on any machine**. It cross-compiles, its layout and
  its catalog serializer are native-tested and mutation-watched, and that is
  the whole of the evidence: nothing has drawn it on the emulator or the
  PowerBook, and neither the console `development-project catalog` grammar nor
  the V28 preferences round-trip has been exercised outside the host compiler.
- The final VM session ended with its HFS volume marked dirty even though its
  source image is clean, the shutdown applet completed, disk writes quiesced,
  QEMU exited, and `qemu-img check` passed. That is a rig cleanup failure, not
  a Development-loop result. `shutdown-guest.py` now verifies HFS after QEMU
  releases the disk and fails rather than calling quiet "already unmounted".
  The disposable session remains preserved as the negative artifact.

The exact findings and residual gates are tracked in
[`open-issues.md`](open-issues.md) and the completed
[hardening plan](plans/2026-08-10-031-feat-development-agent-loop-hardening-plan.md).
