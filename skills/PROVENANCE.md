<!-- now-doc-provenance: generated reviewed=false -->

# Where these skills came from

The eight `classic-mac-*` trees here are a **vendored copy**, extracted
from a skill repository that lives outside this project:

- **Source**: a `classic-mac-development` skill repository outside this
  tree, with its own history and **no remote**. The desk that holds one
  names it with `NOW_CLASSIC_SKILLS_SOURCE`; the path is not written
  down here, because one desk's absolute paths are exactly what a
  public repository must not carry.
- **Source commit at extraction**: `9a89b8ebb219646d835f77249c495dd71d817655`
- **Working tree at extraction**: DIRTY — 9 paths modified or
  untracked, including three `SKILL.md` files. So this copy matches no
  commit of the source, and the sha above locates the neighbourhood
  rather than the content.
- **Content digest of this copy**: `0a4a5b456231a19198a71d7630aac98d859ee90db4c31aecf6c1a5ad7a35b576`
  (`find skills -type f | sort | xargs shasum -a 256 | shasum -a 256`)
- **Extracted**: 2026-08-19

## Why a copy rather than a submodule

The source has no remote, so a submodule would be unfetchable by anyone
who clones this repository — which is the whole audience. Vendoring makes
New Old World the published home of this material.

## What that costs, stated plainly

**There are now two copies of a versioned thing.** The parent project's
rule is that findings cross between children freely and code crosses only
by audited extraction; this is such an extraction, and the audit is this
file. The failure it invites is the ordinary one: somebody edits the
other copy, both stay plausible, and neither knows about the other.

**This copy also DIVERGES from the source on purpose, in six lines.**
The unvendored trees cite their evidence by absolute path — one desk's
`/Users/...` — and this repository is public, with a CI job whose whole
job is refusing exactly that (`ci.yml`, "No lab configuration in the
tree"). The citations here name the artifact relative to its root
instead: `toolchain/universal/CIncludes` in a Retro68 build rather than
the path on the machine that read it. The evidence is the same; the
desk is gone. A re-extraction will bring the paths back, so
`tools/sync-classic-skills` reporting those six lines as "changed" is
the expected answer, not a fix to apply.

Two things follow for whoever touches this next:

- **Edit here.** This copy is the one that ships in the application
  bundle and the one the chat harness reads. A fix made only in
  `~/Lab/Skills` reaches nobody.
- **Re-extract deliberately, not casually.** `tools/sync-classic-skills`
  copies the source over this directory and rewrites the digest above. It
  refuses to run silently: it prints what changed, because a sync that
  quietly overwrote local fixes is how the second copy becomes the wrong
  one.

## What the chat harness actually uses

Only `SKILL.md` — its front matter for the listing, its body when a
person loads the skill. The `references/` and `scripts/` directories
ship for a person reading them and for a workspace-lane runtime with file
tools; a model talking through the harness cannot open them, and nothing
here pretends otherwise.
