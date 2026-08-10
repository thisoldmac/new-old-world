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
the IDE to exist. The PPC onboarding disk can carry a separately supplied
CodeKitten MacBinary as a selected-by-default optional application, which makes
initial installation one transfer without turning that distribution seam into
a runtime dependency.

## Verification and current limits

The project/history, parser, job, projection, Chat-filter and parity behavior
is tested locally, and both guests cross-compile. The complete host-home lane is
also emulator-verified on a private mac99/OS 9.1 guest with MPW. Guest build
`44a214ae1141` qualified `mpw-ffff-00000cf0@structural-1`; MCP created and
revised project `95ceb07504374a568705336a5728d19a`, including a nonempty source
resource fork and `TEXT/MPS ` Finder identities. NOW transported each logical
file as MacBinary, sealed candidate `candidate-1c3ca2817afe4c24` at exact source
digest `2d692e6239cb90862bb1a15c7d6f42ce63ea9026ac35663e9c41913725e417d0`,
completed MrC, PPCLink and Rez, and measured `APPL/H14E` product
`product-5c96932bd4b1cd44` at 1,832 data-fork and 578 resource-fork bytes.
`now_development run` matched its process identity, and retained semantic UI
then observed the frontmost `HelloForks` alert and its enabled `OK` dialog item.
After a semantic dismissal the process disappeared and the built candidate was
discarded cleanly.

The same preservation path is now metal-verified on the PowerBook 1400c. Guest
build `33bfe4e3e211` qualified the machine's own
`mpw-ffff-00007b37@structural-1`; MCP revised only the toolchain pin in that
fork-bearing host project, sealed candidate `candidate-d4752f9e46d84f9c` at
source digest `6c3e96f8e4e368fc5004e2817ab9bcc087bd1eacba5bdd5cb0437c3b77a13669`,
and completed all three MrC/PPCLink/Rez actions. Product
`product-cf2b162d6ea8648a` measured `APPL/H14E`, 1,832 data bytes and 578
resource bytes, at digest
`cf2b162d6ea8648a7108b10b3732994ebc647f39c40ba74a1986ada1f6e564a8`.
Exact-product run matched process identity; retained semantic UI and the person
at the PowerBook observed the live Hello World alert; after dismissal a fresh
process list showed the application absent, and candidate discard succeeded.

That is full host-home build/run/dialog evidence on metal. It is not evidence
for guest-home promotion. Guest import/workspace refresh, divergent and
successful promotion, and CodeKitten handoff have not run in the emulator or
on the PowerBook. A separate onboarding smoke transferred the exact
CodeKitten payload and `LaunchApplication` accepted it, but the process exited
before the five-second observation; that is a failed runtime gate, not handoff
evidence. The earlier PowerBook refusal of the first source as “not a TEXT
file” is retained as the evidence that led to first-class fork and Finder
identity transport; the successful rung above closes that specific metal gap.

Two preservation/settlement limits are still open and are intentionally not
hidden behind a successful receipt:

- The first agent and host surface has distinct build and run receipts, but no
  typed test operation or test receipt yet. Treating Build or Run as Test would
  erase the result boundary required by the project contract; the next slice
  must define a closed declarative test plan and its expected product identity
  before adding that operation.

- The CodeKitten `odoc` send is asynchronous. NOW proves launch, event
  dispatch and foregrounding, but does not yet receive the handler's returned
  acceptance result. Metal acceptance must retire that distinction rather than
  relabel dispatch as acceptance.

The manual host import sheet also asks for the opaque guest project ID; a
bounded guest-project catalog is not yet a human discovery surface. These
limits and the remaining emulator/metal rungs are tracked in
[`open-issues.md`](open-issues.md).
