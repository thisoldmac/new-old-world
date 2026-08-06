# The visibility census, and what Mac OS 9's Finder will not tell us

**Status:** the census is repaired and returns every row the Finder can
see; it has not been watched settling an operation end to end. The
mutation it exists to confirm — `Hide`, `Hide Others`, `Show All` — is
**broken and cannot be repaired by the route it currently takes**: Mac
OS 9.1's Finder refuses to set `visible` at all. A visibility
postcondition also cannot yet reach `complete` for a second, independent
reason given below.

Everything on this page was measured on 2026-08-05 against a live guest
(QEMU mac99, Mac OS 9.1, guest build `a4a59d37d100`) by running the
production scripts verbatim. None of it is derived from the headers.

## What the census is for

The Mirror's process rows carry `visible`, and
`MirrorOperationPostcondition.processVisibility` settles **only** from a
census whose own coverage claim is `complete`. That rule is deliberate
and is not to be relaxed: a roster proves a process exists, and existing
is not the same as being visible, so a roster must never imply
`visible: true` (`mirror-drive-loop.md` §2j). A Hide that cannot be
confirmed must stay unconfirmed.

`NOWMirrorSource` gathers the census by asking the guest's Finder over
AppleScript, a page at a time, and `MirrorStateEngine.enrichVisibility`
joins it to the structural generation it describes — using names only as
a join key, so a duplicate or missing name keeps coverage `partial` and
therefore non-settling.

## Three things the OS 9.1 Finder actually does

**`visible` is readable and read-only.** Reading is fine: `set v to
visible of process "tbt-worker"` answers `false`. Every assignment is
refused, in all three forms the host used:

| script | error |
|---|---|
| `set visible of first application process whose frontmost is true to false` | `-10000 Finder got an error: Can't continue .` |
| `set visible of every application process to true` | `-10006 Can't set visible of every application process to true.` |
| `if not (frontmost of candidate) then set visible of candidate to false` | `-10006 Can't set visible of item 1 of every application process to false.` |

The census confirmed the machine was unchanged after each attempt. So
`Hide`, `Hide Others` and `Show All` have never been able to work by this
route, and the settlement rule was never what stopped them — it was
waiting on a dispatch that cannot happen.

**Reading `visible` inline into a concatenation does not yield the
boolean.** The Finder hands back an object specifier, and `&` refuses it:

    "x" & (visible of process "tbt-worker")
    -1700 Can't make visible of «class prcs» "tbt-worker"
          of application "Finder" into a string

Binding it first forces the specifier to resolve, and the bound value
coerces:

    set vis to visible of candidate
    ... & (vis as string) & ...

AppleScript fails a script **whole**, so the inline read aborted the
entire census before its first row. This is the same family as the
Finder art pass, which is split from the item pass for exactly this
reason.

**The Finder is absent from its own process list.** `count of (every
process whose name is "Finder")` is `0`, and `name of process "Finder"`
errors, while `name of every application process` returned the other
seven processes. The replica, built from the guest's own
`GetProcessInformation` walk, always carries the Finder.

## Why zero-of-eight looked like name ambiguity

Before the repair, `now_mirror_snapshot` showed `visible: null` on every
process and one coverage row:

    process-visibility partial
      "visibility census did not uniquely cover every application"

That reads as a join problem, and it sent one investigation at
`enrichVisibility`'s sequence guard — the theory being that the census
was arriving describing a superseded generation and being dropped. It
was not. **That coverage row can only be written by a census that has
already passed the sequence guard**, so its presence in the snapshot
ruled the race out before any machine was booted. The census was
arriving on the right generation and matching nothing, because it
contained nothing.

It contained nothing silently because a guest whose script raises still
replies `ok: true`, with an empty `output` row and its reason in
`osaErr`. `readingOutput` read `output` and never `osaErr`, so "the
Finder refused the question" and "the answer is empty" were one value.
That is now opt-in per call (`osaFailureIsAnError`), because one caller
is built on a script that is *expected* to raise; the two visibility
paths opt in, and the census notes the refusal by code.

The general lesson is the one this repository keeps re-paying for: a
total failure wore a partial failure's words. A coverage claim should
distinguish *nobody answered* from *the answer did not cover everyone*.

### The same defect was in the item roster, and cost more (2026-08-06)

Worth recording here rather than in a commit message, because it is the
identical mechanism one pass over and it produced this project's
longest-running wrong diagnosis.

The roster pass — the one that reads a container's items, and the one
`desktopItems` depends on — did not opt in. So a script that raised
answered `ok: true` with an empty output row, the empty answer fell
through to the roster guard, and **every** distinct failure (a raise, a
refusal, a Finder that could not name its own desktop) came back as the
one sentence `"incomplete or changing item roster"`. That sentence was
all the mirror ever said about why `desktopItems` was empty, and it was
read for a week as evidence the guest could not answer. It could: the
guest had been answering all along — three pages and a type pass, with
`osaErr` 0.

The pass now opts in and reports the guest's own refusal by code. Two
rules came out of it:

- **A refusal must carry the refuser's own words.** A caller that
  collapses distinct failures into one sentence has not simplified an
  error, it has deleted the evidence for the next diagnosis.
- **Opt-in was right, and incomplete is how opt-in fails.** The switch
  exists because one caller is built on a script that is *expected* to
  raise. But a default that hides failures means every new caller is
  wrong until someone remembers; the art pass still does not opt in,
  deliberately, and that is now a stated decision rather than an
  oversight.

## What is still open

A complete census is not reachable today. `enrichVisibility` requires
`matched == Set(replica.applications.keys)`, the replica always contains
the Finder, and the Finder cannot appear in its own census — so coverage
stays `partial` and a visibility postcondition still cannot settle even
with the script repaired.

`visible of application "Finder"` does answer a real boolean (`true`),
and it is the obvious candidate for the missing row. **Do not adopt it
until something has watched it go `false`.** It addresses the Finder
*application* rather than a process row — `visible of application "X"`
for any other X sends the event to X, which does not implement it — and
a value that never changes would settle mutations falsely, which is
precisely what §2j exists to prevent.

A working Hide needs a different mechanism entirely. The act plane
driving the Application menu is the candidate, because it is what a
person uses and the menu act is already proven against the Finder.

## Re-measuring this without disturbing anyone

The method matters, because the obvious setup silently measures the
wrong machine. Every QEMU guest sees this Mac as `10.0.2.2`, and a
guest with default preferences dials port 5250 — so if another session's
host already holds 5250, your guest connects to *theirs*, adding itself
to their session.

`tools/askguest.py` impersonates a host and asks a real guest verbs
directly, which needs no host app at all and so cannot collide over the
per-user agent endpoint (only one host may own it). Point the guest at a
port nothing else is dialling first. The dial port is at a fixed offset
in the preferences record — magic (4 bytes), format (2), then the port
as a big-endian `u16` — so it can be patched in place over the harness
without rewriting the file:

    tools/hc write "Macintosh HD:System Folder:Preferences:New Old World Prefs" \
        --data "55" --offset 6 --overwrite --port <harness>
    tools/askguest.py --port 13621 'script:source=<applescript>'

`"55"` is `0x3535` = 13621, chosen so both bytes are printable ASCII and
survive the JSON round trip. Patch the preferences **before** launching
the guest application: it auto-connects on launch, so a guest started
first has already dialled the wrong host.

Wrap a probe in `try ... on error m number n` to get the Finder's real
message; without it the reply carries only the `osaErr` code, and the
messages above are where the actual object-model facts came from.

## See also

- `docs/open-issues.md` — the dated ledger entry for the broken mutation.
- `docs/mirror-drive-loop.md` §2j — why a roster may not imply visibility.
- `docs/mirror-state-engine.md` — settlement and coverage claims generally.
