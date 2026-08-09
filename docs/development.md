# Projects and Development

NOW has a headless project and build lane for classic Macintosh software. It
does not make the classic Mac's disk a host checkout and it does not make
CodeKitten a build dependency. The two project homes remain distinct:

- A **host-home** project is authoritative beneath the host app's Application
  Support `New Old World/Projects` directory.
- A **guest-home** project is authoritative beneath the Projects folder a
  person selected in the PPC guest's Development page. NOW imports a verified
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
declarative build actions and a product. `Build/` is reserved for generated
artifacts and excluded from source digests.

The host Projects store accepts only opaque project/workspace references and
canonical relative paths. It rejects absolute paths, `..`, links, stale
revisions and stale per-file digests. An accepted atomic batch produces a
revision receipt and a commit written by NOW's small Git object writer; no
system `git`, user configuration or agent-visible Git command is involved.
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
Development page; NOW resolves it by volume and directory identity and
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

## Human and agent surfaces

The host Development module and agent adapter call the same project,
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
CodeKitten by creator in each mounted volume's Desktop database, launches it if
needed, and returns immediately. The host polls cooperatively until it can send
one standard `odoc` for the active `Project.ckp`, then brings CodeKitten
forward. CodeKitten implements that handler, but no build or sync path requires
the IDE to exist.

## Verification and current limits

The project/history, parser, job, projection, Chat-filter and parity behavior
is tested locally, and both guests cross-compile. No Development workflow has
yet run in the PPC emulator or on a PowerBook, so it is not emulator-verified
or metal-verified.

Two preservation/settlement limits are still open and are intentionally not
hidden behind a successful receipt:

- The first agent and host surface has distinct build and run receipts, but no
  typed test operation or test receipt yet. Treating Build or Run as Test would
  erase the result boundary required by the project contract; the next slice
  must define a closed declarative test plan and its expected product identity
  before adding that operation.

- Source-tree manifests currently bind data-fork SHA-256 only. A nonempty
  source resource fork is refused both when the host stages a candidate and
  when the guest manifests or serves an import, so the lane fails instead of
  silently losing it. Finder type/creator are not yet represented in the host
  Git mirror or candidate receipt. Product measurement covers both forks and
  metadata.
- The CodeKitten `odoc` send is asynchronous. NOW proves launch, event
  dispatch and foregrounding, but does not yet receive the handler's returned
  acceptance result. Metal acceptance must retire that distinction rather than
  relabel dispatch as acceptance.

The manual host import sheet also asks for the opaque guest project ID; a
bounded guest-project catalog is not yet a human discovery surface. These
limits and the missing emulator/metal rungs are tracked in
[`open-issues.md`](open-issues.md).
