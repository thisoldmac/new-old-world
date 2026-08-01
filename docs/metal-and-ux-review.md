# The review this slice is waiting on

Everything built between 2026-07-29 and 2026-07-31 is **tested and not
metal-verified**, with two exceptions noted below. This file is the list of what
a person has to do to change that, and it exists because the alternative is
twenty agent reports and nobody's memory.

Two audiences, one pass:

- **UX review** — a person looks at something and judges it. No measurement
  substitutes.
- **Metal test** — an agent or a suite drives a real Macintosh and something
  either happens or does not.

Read [68k-metal-runbook.md](68k-metal-runbook.md) before any metal work. Its
rules are not ceremony: they were written after a run nobody could attribute.

## Three questions that are one experiment

Added 2026-07-31, once it became clear they had converged. Three separate pieces
of this slice each owe **a number from the same machine**, and none of them is a
yes/no:

| # | The question | What the answer decides |
|---|---|---|
| 13 | Does a process's `LMGetCurStackBase()` fall inside its partition? | If not, **every** process reports `MISMATCH` and the Windows row reads "stale anchor" everywhere — a silent, total, *polite* refusal rather than a fault |
| 9 | Is a frame off an open bracket cheaper than a 0.5–0.6 s capture? | The streaming row's entire premise. If it is not clearly cheaper, the row's reason for existing is wrong and should be reported as such |
| — | What does a **semantic scene walk** cost on the 1400c? | Whether Mirror scenes reuse the bracket or stay one-shot ([streaming-a-scene.md](streaming-a-scene.md)). Above roughly 200 ms the bracket earns its keep |

They want the same setup — one machine, one connected session, a stopwatch on
the wire — so running them separately would be three setups for one afternoon's
answers. **The whole slice is being held for a single unified pass** rather than
verified piecemeal, which is also why nothing below has been struck off yet.

## Before anything

**Ask before each pass.** Per-action, not per-session. The machines are shared
with other agent sessions and with your own work.

**The environment**, proven on 2026-07-29 against the PB1400c:

```
NOW_METAL=1 NOW_METAL_PORT=5251 NOW_METAL_MACHINE=<addr>
```

- The guest dials out on a **30-second retry**, so budget half a minute before
  reading a quiet listener as a failure.
- **One `swift test` at a time on this Mac.** `HostAppStateWiringTests` binds a
  fixed port 52981; `HostLogTests` and `LoggingSpecTests` share
  `~/Library/Logs/now-logs`.
- **Quit the host app before running the suite**, and this is the bigger one —
  found 2026-07-31 after a wrong diagnosis. `AgentIntegrationUnixSocket` derives
  its path as `dev.newoldworld.now-agent-<uid>/host.sock`: **fixed per user, not
  per process.** A running `New Old World.app` holds it (confirmed with `lsof`),
  and it also holds a log file in `now-logs`. Any test that stands up an
  `AgentIntegrationLocalServer` is then competing with a live app for a resource
  only one process can have.
- **The failure does not name its cause.** It presents as socket-bound tests
  timing out — `AgentIntegrationLaunchTests`, `AgentIntegrationQuitTests`,
  `GuestIdentityTests` — with messages like *"timed out waiting for second guest
  connected"*. Those tests bind `port: 0` and read `boundPort`, so **the port in
  the message is never the problem**; the shared thing is the agent socket
  underneath. The count also moves run to run (6, then 12), which reads like
  flakiness and is not.

  **The list of three above is therefore too narrow.** It was written before this
  was understood, and "exactly those three failing means contention" is what sent
  the first diagnosis to machine load instead of a running app. If
  `AgentIntegration*` or `GuestIdentityTests` time out, check `lsof -nP -p $(pgrep
  -f 'New Old World')` before believing anything about the code.
- **Do not trust the version string to tell you which build answered.**
  `PRODUCT_VERSION` is `"0.1.0"` in current source *and* was on the stale build
  deployed to the 1400c. That cost a wrong diagnosis on 2026-07-29. `hello` now
  carries a build stamp; use it, and assert a capability only the build under
  test has.

## Already metal-verified — do not redo

| Thing | When | Evidence |
|---|---|---|
| `now_capture_screen`, end to end | 2026-07-29, PB1400c | 800×600, 4–5 pages of 8 KiB, whole call 0.5–0.6 s, digest chain proven by flipping a page byte |
| Addressing: answered / not-connected / session-ended / unaddressed | 2026-07-29, PB1400c | `MetalAddressingTests` |

Everything else below is unexercised.

---

# Part one — UX review

These need eyes. None of them has been looked at by a person.

## 1. The MCP module's resting state

*(Renamed 2026-07-31: the **Agent** pane is now **MCP**, and it also owns the
server's Start/Stop. Everything below still applies to its presence half.)*

**The single most important thing in this document.** On most machines, for most
of their lives, no companion has ever attached — so this is the sentence the
pane spends its existence saying, and it is the state most likely to read as
*broken* rather than as *idle*.

Open **MCP** in the sidebar on a host that has never run a companion. It
should say `No agent has attached`, explain that nothing is driving this Mac but
you, say there is nothing to switch on, and describe what *would* appear here.
It should show **no counters at all** — deliberately, because "0 companions,
0 calls, last seen never" is the visual shape of a thing that failed to load.

Judge: does it read as *nothing has happened yet*, or as *something is wrong*?

Then, if a companion has ever run: does presence decay honestly from active to
idle **while you watch and do nothing**? It re-derives on a 5-second tick
because that transition has no event behind it.

## 1a. The MCP server card — nobody has pressed either button

New on 2026-07-31 and **tested but never eyeballed**: the MCP pane's first card
is the server itself — a running dot, one line (`Running` / `Stopped` /
`Not started` / `Did not start`), one button (**Start** or **Stop**, never
both), and the socket path with its Copy button beside them.

What only a person can settle:

- **Stop, with a client connected.** There is deliberately no confirmation
  sheet: stopping is one click to undo and its consequence is the safe
  direction. Judge whether that is right *while a companion is mid-session* —
  if the answer is "that needed a warning", say so.
- **Start after a stop.** The path should come back the same, and a client
  should reconnect without the app being relaunched. Not verified: only the
  model transition is under test, not the socket actually reopening.
- **`Stopped` vs `Not started` vs `Did not start`** should read as three
  different situations, not three spellings of "off". The person reading them
  is usually the one whose client just failed to connect.
- Does the card belong at the **top** of the pane? It is the control; the rest
  is history. The alternative — history first, control last, where the endpoint
  card used to be — was rejected without a person looking at either.

Also worth one glance: a saved selection of the old `agent` id forwards to this
pane, so **a person who was last on the Agent page should land here on the next
launch**, not on Screenshots.
## 1b. The Connections page, which no eye has ever met

A whole new page, and a page is entirely a UX judgement — no test here settles
whether it *reads* right. It is not in the sidebar yet; wire it in first.

**The resting state, which is the same trap as section 1.** Open **Connections**
on a host that is listening with nothing dialled in. It should read as a waiting
room — what this side is doing, and that the classic Mac dials in — with no
counters, no red, and no empty table. Judge: *nothing has happened yet*, or
*something is wrong*? Then stop the listener and look again: "Not listening" is
a different resting state and must not read as a fault either. The only red on
this page should be a listener that actually failed (occupy port 1400 with
`nc -l 1400` and start it to see that one).

**One Mac, which is the common case.** With a single guest connected the page
should not read as a fleet: one card, no chooser, and nothing implying a choice
that is not there. If it reads as a list of one, it is the wrong page.

**Two Macs, which is what it exists for.** Needs a second guest on the same
listener (a QEMU guest dialling the same port will do). Judge:

- Can you tell **at a glance** which Mac the window is driving?
- **Drive This Mac** on the other row — does the whole window follow, and does
  every other page now show that machine rather than a mix?
- The three identities are labelled side by side (machine id, session id,
  address). Does a person reading the card understand they are three different
  things, or does it read as three spellings of one? This is the judgement the
  whole design rests on, and it cannot be tested.

**The addressing lines.** Every row says what an agent naming it would be told,
in the host's own sentence. With two Macs connected, run one MCP tool with
`guest:` set to the machine the host is *not* driving, and compare the refusal
you get to the line on that row. They should say the same thing; if the page's
wording sends you somewhere the agent's does not, the page is the one that is
wrong. Section 10 is the same case from the agent's side.

**Remembered machines.** Disconnect a guest and stay on the page. It should move
to *Remembered* by name, keep its ended session id, and say that a caller
holding it is told the session ended. Judge whether "remembered" reads as a
useful memory or as clutter after a week of reconnections.

**Naming a Mac.** Rename a connected guest from the page. Does the id change
everywhere it is shown? Does the live session id deliberately *not* change (it
must not), and is that confusing on screen? Try a name another machine already
holds and read the refusal — it names the other Mac so you know which one to go
and free.

**On an emulated guest** every row will carry *Id is a guess*, because loopback
cannot tell two Macs apart. Judge whether that badge reads as informative or as
alarming; it will be the normal state for every QEMU guest, forever.

## 2. The guest's icon on a real Finder

`now-icons.r` is adopted by the PPC guest. Everything asserted about it is
arithmetic on a resource fork — nobody has *seen* it.

Look at it in: the Finder's icon view, its list view (16×16), the application
menu, and the ⌘-Tab switcher. On a 1-bit or 4-bit display if you can reach one.

The pack's own README says the **1-bit checker** is the one whose read depends
on the actual display, and that an emulator screenshot does not fully stand in.

## 3. The menu bar glyph

Five states — empty, dot, half filled, filled, filled behind a bang — as an
18 pt template glyph.

Check it on a **light and a dark** menu bar, and **with the menu open** (macOS
inverts templates then). Check that the states are distinguishable at a glance
at real size, which is the only size that matters.

Also worth confirming: rename or remove the asset and the old text should come
back rather than the item disappearing.

## 4. The Diagnostics module

Three probes with different ISA availability — `vprobe` both, `shotdiag` 68K
only, `putstat` PPC only. Judge what a card says when the connected machine does
**not** serve that probe: it must not imply the machine is broken, and it must
not present a button that silently does nothing.

### 4a. `putstat` on a Mac that has received nothing (new 2026-07-31)

The Transfer Diagnostics card used to answer eleven rows of `0` on a Mac that
had received no file — the same visual shape §1 calls the worst defect this
product has. It now says so in words and shows only the three live counters
(`Rcv backlog`, `Rcv peak`, `Loop passes`), which are the evidence the probe
answered.

Eyeball, on a freshly launched guest, in this order:

1. **Run it before sending anything.** Does it read as *nothing has arrived
   yet* rather than *the probe failed*? The live counters are still on screen —
   do they help, or do three lone numbers under a sentence look like debris?
2. **Send a file, then run it again.** All eleven rows should come back as one
   table, in the guest's order, with nothing hidden.
3. The split is by label (`now-guest-ppc/src/commands/commands.c ::
   run_putstat`). If a guest build renames a row, an unrecognised label counts
   as a transfer counter — so a renamed live counter would show up as a card
   that never reaches the never-run state. Worth noticing if the wording ever
   looks wrong after a guest change.

Not settled by any test: whether the sentence is the *right* sentence, and
whether "Live on the connection right now" earns its caption.
## 4b. A control the attached Mac cannot serve — 68K, Screenshots

Added 2026-07-31 with `GuestCapabilityGate`. **Only a person with a real 68K
machine on the wire can judge this**, and it has never met one: nothing below
was reached by a build or a test.

Connect the 68K guest and open **Screenshots**. Press **Start Streaming** once.
That guest does not implement the stream family — it answers `not-implemented`
(`wire68.c :: send_error_reply`) — so what should happen is:

| | |
| --- | --- |
| Before the first press | The button is **live**, not grey. Nobody has asked this machine yet, and unproven is not a no. |
| After the refusal | The button goes **dark and stays there**, with a readable line beside it naming the machine and quoting its own words — and saying nothing is wrong with it. |
| Layout | **Unchanged.** The button is present in both states; nothing moves as the reason appears. |

Judge three things a test cannot:

1. **Is the sentence readable by someone who does not know the protocol?** It
   currently contains the wire name (`stream.start`) and the guest's own
   message. That is honest and it may be jargon.
2. **Does the dark button read as a difference between two Macs, or as
   damage?** If a person's next move is to check their network, the wording
   failed.
3. **How long does the page sit on "Waiting for the first frame…" first?** The
   bracket is opened optimistically and the refusal now asks to stop it, which
   the listener's unacknowledged-stop fallback clears after ~5 s. Time it. If
   that wait reads as a hang, the fix is in `GuestListener` routing stream ids
   in `recordGuestError` — see open-issues.

Also worth a glance on a **PowerPC** machine: hovering Start Streaming before
any stream has run shows "Nothing has established whether … serves stream.stop,
stream.refresh". True — neither is observable until used — but judge whether it
reads as a warning on a control that works perfectly.

## 4c. An action that does not apply to the item — Software, Processes, Diagnostics

**Wired 2026-07-31.** The three panes the mechanism was written for now route
through `GuestCapabilityGate` instead of deciding for themselves:

| Pane | Control | What changed |
| --- | --- | --- |
| Software | Launch | Was live on a system extension — `isLaunchable` is only "the machine named a path" — and the guest refused it after the round trip. Now dark on anything whose Finder type is not `APPL`, with the reason beside it. **Show in Finder is deliberately untouched and rule-free.** |
| Processes | Bring to Front | Was live on a faceless background process. Now dark on one, off the guest's own `modeOnlyBackground` classification. `isDrivable` / `isQuittable` are unchanged. |
| Diagnostics | Run | Was **absent** on a verb the Mac does not serve; now present and dark, so the cards no longer change height as machines connect and leave. |

What a person still has to judge, on metal, and a build cannot answer:

- **Are the two greyed states distinguishable *without hovering*?** An extension
  whose Launch is dark because it is not an application, versus a control dark
  because this Mac does not serve the verb. They lead to different next actions —
  one is answered by attaching a different Mac and the other never is — and the
  sentences are the only thing telling them apart. Both now draw beside the
  control rather than only in the tooltip; judge whether that reads, or whether
  it reads as clutter on a page of ordinary rows.
- **Does a dark control still read as damage?** That is the whole failure this
  guards against, and it is a judgement about the sentence, not about the state.
- **Does the Diagnostics page look better or worse for keeping the button?** The
  trade is a stable layout against a permanently dead control on a card. The
  argument for it is that a control which simply vanishes cannot explain itself;
  the argument against is only visible with the three cards in front of you.
- **Enabled-but-unproven.** `unsettled` leaves every one of these live on a Mac
  nobody has asked yet, on purpose. Judge whether clicking one and reading the
  machine's own refusal is a decent experience or a trap — it is the one case
  where the app deliberately lets a click fail.

The tests reach the views only by reading their source
(`GuestItemGateWiringTests`, through `GateSource`), which proves the call is
spelled and cannot prove the control is reachable. Seeing the buttons is this
section's job.

## 5. The Files page's new verbs

Move, trash, restore, mkdir, and download. The confirmation sheet and the
fifty-deep Undo are the human half of a destructive capability an agent can also
reach. Judge whether the wording makes it clear what will happen and to what.

### 5a. The path bar, on a volume that is actually deep (new 2026-07-31)

The Files browser used to show one crumb — the last component of the share
root — and an up button. It now shows the whole path, disk first, and every
component inside the share is a click. Unit-tested only; **no machine has drawn
this bar**, and the questions left are the ones a test cannot answer.

| What to do | What to judge |
|---|---|
| Connect a real guest and look at the bar before opening anything | Does the disk read as that machine's disk? The first crumb is the volume name with an `externaldrive` beside it, and the components between the disk and the shared folder are grey and unclickable on purpose. Does "grey" read as *context*, or as *broken*? |
| Navigate somewhere genuinely deep — `System Folder:Extensions` is only two, so go further: `Macintosh HD:Applications:Utilities:Network:…`, or point the share at the volume root and walk down | At **four or more** folders inside the share the middle folds into a `…` menu, keeping the disk, the shared folder, and the last two folders. Six elements maximum. Is the fold obvious enough to click, or does it read as the path having been *cut*? |
| Open the `…` menu | Everything folded is listed and every enterable one jumps. Confirm nothing is missing — the fold is meant to lose nothing. |
| Find a folder with a long name (HFS allows 31 characters — `System Folder Extensions (Disabled)` is over, but 31 is easy to hit) | Names are **never** truncated; that was deliberate, on the grounds that depth is unbounded and a name is not. On a narrow window does the bar stay on one line, or does the deliberate no-truncation choice push the actions off the right edge? That is the one thing the width ceiling was computed for and the one thing only a real window can settle. |
| Point the share at a whole volume (`Macintosh HD:`) | One crumb, which is both the disk and where browsing starts, and it is clickable. |
| Watch the bar **before** the first listing, and force a failure (share a folder, then delete it on the guest, then Refresh) | It never goes blank: "nothing listed yet" / "listing…" / a `not listed` warning that keeps the crumbs. Judge whether the failed state reads as *where you tried to be* rather than as *where you are*. |
| Switch between two guests mid-browse | Each machine's bar comes back to its own path. |

Names on a classic volume can contain `/`, `..` and high-MacRoman bytes; the
splitter is `contract/share_path.h`'s rule and those are pinned in tests, but a
volume with a folder actually named `..` is worth a look if one exists.

### 5b. Double-click: download to the share, then open (new 2026-07-31)

A double-click on a file now fetches it into the folder **this** Mac shares and
opens it here. Unit-tested against a fake guest; the seams a real machine
decides are these.

| What to do | What to judge |
|---|---|
| Double-click a plain `TEXT` file | It lands in the shared folder — the same one "Reveal Shared Folder" opens — and opens in TextEdit. Check the **converted** text is right, not just that something opened. |
| Double-click a **large** file (a few MB over this wire is slow on purpose) | The progress row says "*then opens here*" while it runs. Does that read as an explanation of the wait, or is the wait still long enough to feel broken? This is the judgement the row exists for. |
| Press **Cancel** during that transfer | Nothing opens, and nothing half-written is left in the shared folder. |
| Double-click a resource-only file or a 68K application | Nothing here can open it: it is revealed in the Finder and a grey (not red) notice says where it went. Judge whether "revealed + notice" reads as success — because it *is* one — or as a failure with the wrong colour. |
| Double-click the same file twice | The second copy is `name (2)`; the share is never overwritten. Is silently bumping right here, or should it ask? |
| Double-click a folder | It navigates, and 5a's bar is what confirms where it landed. |
| Double-click while another transfer runs | The footer says the wire is busy. Previously this did nothing at all. |

## 6. The Software page's sweep budget and its duplicate groups

Added 2026-07-31. The page used to re-run the guest's whole Applications sweep
every time it was opened, and again on every domain-picker flip. It now sweeps
**once per machine per domain per connection**, and the only thing that re-asks
a domain the Mac has already answered is the **Rescan** button. Duplicates
gather under a container row, by the guest's own `compute_groups` rule.

Tested on the host only — a scripted guest over loopback. **Nothing here has
met a real Mac**, and three of the four things worth judging are things a build
cannot answer:

- **Is once-per-connection the right budget on real hardware?** The saving is
  real (a ~4 s disk crawl per open, on a machine doing nothing else while it
  runs), but a listing now survives every visit to the page for the life of the
  connection. If a person installs something on the guest and comes back, the
  page is wrong until they press Rescan. Judge whether the footer's "as of
  14:02:11 (23 minutes ago)" is enough of a prompt, or whether the page should
  volunteer a rescan past some age.
- **Does the age phrase read as stale, or as broken?** The relative age is
  computed as the page draws, so it sharpens on the next interaction rather
  than ticking. Sitting on the page for ten minutes shows an age that does not
  move. The absolute time beside it is always right; the question is whether
  the frozen phrase reads as a bug.
- **The disclosure triangle is hand-drawn.** `Table` cannot draw a real outline
  before macOS 14 and this app ships to 13, so a group's chevron is a plain
  button in the Name cell and members are indented by a spacer. On a real disk
  with several SimpleTexts, judge whether it reads as an outline or as a row
  with a stray button — and whether clicking the chevron feels like disclosure
  when the row deliberately refuses to select (the guest refuses too).
- **The two surfaces have never been compared side by side.** The grouping rule
  is ported from the guest's source and pinned by tests, but nobody has put the
  host's Software page and the guest's Workshop Software page next to each
  other on the same disk and checked that they gather the same items into the
  same groups. That comparison is the only thing that proves the port, and it
  needs one real Mac with real duplicates on it.

One known divergence, stated rather than smoothed over: two names differing
only in the case of a **non-ASCII** Mac Roman letter (`é`/`É`) may group on the
guest and not here. Both surfaces sort under an ASCII fold, which does not
bring such a pair adjacent, so the guest only groups them when nothing sorts
between them. Not expected to occur on a real disk; worth a glance if one ever
does.

## 7. Contention, which nobody has ever seen happen

Added 2026-07-31 with `now_stream_screen`. **Two sentences a person reads only
when an agent is doing something to their Mac**, and neither has been in front
of anybody.

Drive it: open **Screenshots**, then have an agent call `now_stream_screen`
with `intention: start` while you watch.

- The live view turns on **without you clicking anything**, the Capture button
  greys out, and a line under the buttons should say an agent is streaming and
  that Stop Streaming ends it. Judge whether that reads as *somebody else is
  using this* or as *the app has done something odd*. Before the line existed,
  this state was indistinguishable from a fault.
- **Stop Streaming should end it**, and that is the whole of the person-wins
  decision: it is one explicit click, and Capture was deliberately NOT made to
  end an agent's stream as a side effect of being pressed. Judge whether one
  click is enough, or whether being unable to just take a screenshot is
  annoying enough to want the other design.
- The **MCP** page should carry the same fact as a standing state — an
  orange card naming the held lane — for someone who came to that page to ask
  what an agent is doing. Judge whether the two sentences say the same thing
  in the two places without contradicting each other.

Then the reverse: start a stream yourself and have an agent call `start`. It
should be refused with a sentence naming *you*, not a bare "busy". You cannot
see that one — it goes to the agent — but the wording is worth reading in the
tool's answer.

## 8. Platinum fidelity — deferred

Named here so it is not lost, but it belongs to the Mirror fold-in rather than
this slice. Whether the rendered desktop *looks* right is a human call and the
one thing no measurement replaces.

---

# Part two — metal test

## 9. The eleven capabilities that have never crossed a wire

**Exactly one capability has met a Macintosh: capture.** Addressing is verified
too, but addressing is a property of every call rather than a capability of its
own. Everything else in the twelve is unrun — including the three diagnostics
rows, which an earlier draft of this file left out of its own count.

Note the axis, because two documents look like they disagree and do not: a
**guest verb** being metal-verified is not its **host projection row** being
metal-verified. `vprobe` has run on the 180c; `now_framebuffer_probe` has never
crossed a wire. The verb is the machine's; the row is the surface's.

| Capability | Watch for |
|---|---|
| `now_hardware_census` | fourteen probes, both guests. A probe's own outcome must stay distinct from the call's — `absent` on a pre-PCI Mac is a **completed call carrying a finding**, not a failure |
| `now_machine_facts` | PPC only. Every group in one call, in the contract's order, snapshot first |
| `now_software_inventory` | the `apps` sweep is ~4 s. The 48-item ceiling and the `PBCatSearch` root-only fallback must reach you in the guest's own `note` |
| `now_catalog_search` | ~20 s per pass, and the second pass rides the first's cache. The 16-row bound is the guest's own |
| `now_guest_log_tail` | **the count travels on `line`, not `args`** — see the defect note below |
| `now_bring_to_front` | does a real switch land inside one round trip (`fronted`) or usually read `unconfirmed`? That number decides whether the answer is useful or merely honest |
| `now_reveal_item` | reports `asked`, never `revealed`. Confirm the Finder actually comes forward — the host cannot tell you |
| `now_guest_files_download` | 4 MiB ceiling refused *before* the wire, re-checked on arrival |
| `now_guest_files_mutate` | the `PBCatMove` rename-first path on a real volume; a Trash that must be created; whether `trashedAs` comes back |
| `now_transfer_cancel` | cancelling nothing must answer, not error |
| `now_framebuffer_probe` | both guests. The verb is metal-verified; this row is not |
| `now_capture_diagnostics` | 68K only — so the 180c, not the 1400c |
| `now_transfer_diagnostics` | PPC only. Three rows rather than one because these three do not co-occur on any guest, which is the thing to confirm on metal: each machine offers exactly the ones it serves |
| `now_stream_screen` | PPC only, and the one row whose metal question is not "does it work" — see below |

**`now_stream_screen` needs its own paragraph, because the question is a
number rather than a yes.** The row is built on the assumption that a frame
off an open bracket is *cheaper than a capture* — a capture measured 0.5–0.6 s
on the 1400c, and a stream has the machine capturing continuously, so a frame
should be waiting rather than starting. Nothing has measured that. Ask for
`intention: frame` several times over an open bracket and record the wall
time; if it is not clearly under a capture's, **the row's whole reason for
existing is wrong** and it should be reported as such rather than shipped as a
capability with an unmeasured premise.

Three more things only metal answers here:

- **What one frame costs the machine at the default 1000 ms pace**, in wire
  bytes and in how much slower everything else on that Mac gets. The default
  was chosen by argument, not measurement.
- **Whether `stream.refresh` actually produces a whole frame promptly** on a
  real 603e, or whether the guest's self-pacing makes the wait longer than the
  capture it replaces.
- **That the bracket ends.** Open one, kill the companion process, and confirm
  the PowerBook stops capturing within about five seconds — the liveness half
  of the ownership rule has only ever been exercised against an injected
  predicate. The lease half needs a minute of doing nothing and is the more
  likely of the two to be wrong in practice.

**Two known hazards while doing this:**

- **`guest_file_mutation` has a 2-second local receive window against a
  20-second guest-side change watchdog.** A slow `PBCatMove` can time out
  locally on a call the machine then completes. If you see that, it is this,
  not the machine.
- **A pre-`file.begin` download cannot be cancelled on the wire at all.** The
  host frees its lane while the guest may keep sending, holding its own. That is
  the exact wedge `cancel` exists to prevent, and the app's own Cancel button
  has it too.

## 10. Guest consent, which has never met a machine

The PPC guest's answer now comes from its preferences file, and the MCP page
of the Workshop sets it — so the ceiling is testable from the guest's own
screen rather than needing a build that answers differently.

- `disabled` → every tool refused, as a JSON-RPC error with code `-32010`, not
  as a capability being unavailable. **A caller must be able to tell those
  apart** — that distinction is the whole design.
- `read-only` → read rows allowed, the rest refused.
- An unrecognised token → everything refused.
- Silence → everything allowed (a recorded decision, revisited when the
  installer lands).

Confirm a refusal **emits an audit event** and appears in the MCP module.

### 9a. A tier changed WHILE connected (`agent.access`, never metal-verified)

The point of this one is that it takes effect on the link already up. Tested
on both sides and never watched on a real machine:

- With a Mac connected and an agent driving it at **Full Access**, set **Read
  Only** on the guest's MCP page. Without touching the connection, call a
  destructive tool. It must be **refused, by consent** (`-32010`, the same
  refusal shape as above) — not merely greyed, and not allowed. A refusal is
  the whole fix; anything else means the revision did not reach enforcement.
- Set it back to **Full Access** and confirm the same tool is permitted
  again. The field is the machine's position, not a budget it spends down.
- Watch the host's **MCP pane consent row** follow both changes without a
  reconnect, and the host log line (`… now says agent Read Only (was Full
  Access)`).
- On the guest page, the third line should read **"The Mac on the wire has
  been told."** It deliberately never says the host is *enforcing* it —
  nothing acknowledges `agent.access`, so that claim is not this Mac's to
  make. If it instead says "has not yet heard this", the announcement did not
  fit the control queue; that is the honest rare case and worth reporting
  with what was happening at the time (a transfer? a stream?).
- **Change the tier with nothing connected**, then connect. `hello` carries
  the new answer and the same line should appear. This is the path that
  worked before and must not have regressed.

**A tier changed mid-call is NOT handled, deliberately.** The earlier design
sketched warning the person that an agent operation is in flight ("Stop it
now / Let it finish / Never mind"). The guest cannot know that: nothing on
the wire tells it a projection call is running, and it would need a
host-to-guest bracket around agent activity — a new message pair and a real
design question about what "in flight" means for a call the host may have
already answered. Not built. What happens today is that the revision is
applied when it arrives, and a call that already passed the consent check
runs to completion at the old tier. Worth eyeballing what that feels like
during a long operation (a whole-volume software sweep is the easy one) so
the decision is made against something observed.

## 11. The fifth addressing case

`now-guest-not-addressed` means *connected but not driven*, which **one machine
cannot be**. It needs a second guest live on the same listener — a second real
Mac, or a QEMU guest dialling the same port. Everything else in that family is
already verified.

## 12. The agent audit line has never been read on a real run

Rule 3's whole point is that a person can see what an agent did. Drive one tool
against a real machine and then **read the line out of `~/Library/Logs/now-logs`
and out of the MCP module**. Nobody has done this end to end.

## 13. The anchor oracle's one unmeasured assumption

Added 2026-07-31 with the oracle (M1b). This is the highest-value single
observation in the metal half, because it is the one place in this slice where a
wrong guess degrades *silently into a refusal* rather than into an error.

The oracle decides an anchor slot is this process's by checking two roots
against the partition: `a5` and the new `stack_base`. The A5 half is unchanged
and proven. The stack-base half rests on one claim nothing here has measured:
**that `LMGetCurStackBase()` for a process falls inside `[processLocation,
processLocation + processSize]`**, the stack growing down from the top.

If that is wrong on real hardware, **every process reports Mismatch and the
Windows row reads "stale anchor" for all of them** — the feature does not error,
it politely declines, everywhere.

**What to do:** open the Processes module, select several apps in turn — a
foreground app, a background one, the Finder — and read the Windows row.

| What you see | What it means |
| --- | --- |
| Counts and titles, as before | The assumption holds. Say so; it becomes a measurement. |
| "stale anchor" on **every** process | The geometry claim is wrong. Not a crash — a false refusal. |
| "stale anchor" on **some** | More interesting than either: the check is working and those slots are genuinely debris. |
| "unclear (two matches)" | Two slots survived both checks. Worth capturing which app, since it is the case the oracle was written for and nobody has seen one. |

The check was written **loose on purpose** — it rejects only addresses outside
the partition entirely, and accepts `loc+size` exactly, because that is the
normal value and the strict readability test would reject it. Tightening it
(that the stack base sits above A5, say) wants this observation first; until
then it stays out as a phantom constraint.

## 14. Two machine-specific facts worth confirming

- **`vprobe` reported `CopyBits failed` on the 1400c**, and that failure does
  **not** reproduce through `capture.request` — two clean captures. The paths
  differ. Do not let one be read as evidence about the other.
- The 68K guest's `NOW68K_APP_VERSION` is hand-bumped with no build stamp, so
  on that machine you still cannot tell two builds apart.

---

# Part three — what a green pass would not prove

Stated so a clean run is not over-read.

**Six source-scanning gates were found not to prove what they claimed**
([source-text-gates.md](source-text-gates.md)) — including one where deleting a
view's Refresh button leaves the face-parity gate green, and one where an audit
sink that records nothing passes. Those are fixed or documented, but the lesson
generalises: **mutation-proving is only as strong as the mutation someone
thought to try**, and an author testing their own gate is the worst-placed
person to imagine the one that defeats it.

**The stream row's ownership rule has never met a real companion.** Both
halves are mutation-proven against injected values: the liveness check against
a set of pids a test controls, the lease against a clock a test moves. What
neither proves is that a real MCP companion's pid behaves the way the design
assumes — that it outlives a single call and dies with its client. If that
assumption is wrong, the liveness half is dead weight and the lease is doing
all the work. Section 8 says how to find out.

**`capture.request` and the census families read `unproven` in the capability
ledger by construction**, because the listener records no observation for them.
A guest that has served a capture will still report it unproven. That is honest
and it is not evidence of a problem.

`stream.start` **no longer does.** It was in that list for the same reason — the
bracket has no completion for `observing(_:)` to wrap, so nothing wrote the
answer down — and the listener now records it directly at the two moments that
settle it: a frame (served) and an `error` on the bracket's own id before any
frame (not served). `stream.stop` and `stream.refresh` are still unproven by
construction and stay in the paragraph above: they share the bracket's one id,
so a refusal naming it says only "one of the three", and the listener attributes
it to the open rather than guessing between them. What that leaves is a guest
that serves the start and refuses a stop, which reads as `unproven` for the stop
rather than as a wrong `notServed`.

**The MCP module's audit stream is per-launch and in memory.** The log
persists; the pane does not. Someone looking for last week's activity needs the
log.

## 15. The Mirror module, which no eye has ever met (new 2026-07-31)

A new page in the sidebar, between Processes and Console. It draws a guest
scene with the ported Platinum renderer. **Every line of it is a UX judgement**
— tests can say which state it selects and what words that state carries, and
nothing more.

**It renders replayed documents AND fetched ones** (updated 2026-07-31, was
"replayed only"). The wire learned to ask: *Look Now* sends `scene.request` and
draws what comes back, banner-marked as that Mac rather than as a recording.
*Open Scene…* still replays a file, and both go through the pane's one door.

**The page keeps itself up to date** (updated 2026-08-01, and this paragraph
is a retraction). It used to say a fetch happens *only* because a person
pressed something — not on appearance and not on a timer — on the argument
that a scene is a transfer on the one bulk lane screenshots and file transfers
share. The question it left for a person to judge was *"is a page that shows
nothing until asked worse than one that shows a stale scene by itself?"*, and
the answer is that both options were bad: a mirror that only updates when
pressed is a screenshot viewer, and a blind poll is what the lane argument was
actually against.

What runs now is neither. About twice a second the page asks `axsnap` — a
**control** message, which the contract names as the one call on that surface
safe to poll — and spends a bulk transfer only when the front process changed
or the drawing has aged past a five-second ceiling. *Look Now* still asks by
hand, and **Live/Paused** is a visible switch in the header.

What a person still has to judge here: whether the header makes it obvious
which of the two states it is in, whether "Scene from N ago" reads as honest
dating rather than as lag, and whether the back-off line ("the last ask
collided with something else on the Mac's one transfer lane") reads as the
system working rather than as a fault.

What only a person can settle:

- **The four resting states, in the order a real desk meets them.** No Mac
  connected → connected but nobody has asked → no NOW Extension → extension
  present, scene plane dormant. Each says what is true, why that is ordinary,
  and what would change it. **Judge each one the way §1 is judged: does it read
  as *nothing has happened yet*, or as *something is wrong*?** Only the
  unreadable-document state is drawn as a fault; if any of the other five
  reads like an error, that is the defect, not a nitpick.
  - **A live desk can leave *Not Looked Yet* now** (updated 2026-07-31): a
    scene that arrives is proof of both rungs at once and records them. What a
    person still has to judge is the pair the ask added — *Looking* while a
    walk is running, and *Not This Time* when the Mac declines. The second is
    **not** drawn as a fault, because the commonest reason is the Mac being
    busy with the other thing its one lane carries. Does it read that way?
  - *Not Looked Yet* remains the resting state on a fresh connection, because
    asking is a person's decision. Judge whether its new last line — "Look Now
    asks … to walk its screen" — makes that read as an invitation rather than
    as a page that failed to load.
- **The replay banner.** A recorded Finder window drawn full-size is
  indistinguishable from this Mac right now, except for one line in the header:
  *"Replayed from 07-….json — a recording, not this Mac now"*. Is one line, in
  the header's second row, loud enough? If not, say so — this is the page's
  worst possible failure and the cheapest to make worse by being tasteful.
- **A sparse scene is normal here, and must not look broken.** NOW's guest
  reports no QuickDraw content at all, so a window is drawn as empty chrome
  with a title and nothing inside. The footer line under the drawing is what is
  supposed to keep that legible ("2 windows · programs not reported · menus not
  reported"). Look at a real scene and judge whether the empty content reads as
  *this producer does not send content* or as *the renderer failed*.
- **"not reported" vs "none" in that footer.** The distinction is carried
  faithfully all the way from the guest (absent key) through the adapter to
  those words. Does a person reading them understand that they are different
  claims, or does it read as pedantry?
- **A scene with no screen size.** The producer can omit `screen`; the page then
  says so rather than drawing a canvas of an invented size. Confirm that reads
  as a limitation of the recording and not as a broken file.
- **Where it sits, and whether it belongs yet.** Placed after Processes on the
  argument that Processes is what is running and Mirror is what those programs
  have on screen. A person who does not have the extension installed will meet
  this page every time they scan the sidebar.

Not verified by anything here: that a scene the *real* guest produces renders
correctly. The fixtures that crossed with MirrorKit are upstream's, recorded
off a different producer; no NOW-produced scene has been drawn by this pane.

## Recording what you find

A metal measurement is recorded rather than narrated — `NOWBASE` lines carry
build, machine and port beside every number
([68k-metal-baseline.md](68k-metal-baseline.md)). A UX judgement belongs in
[open-issues.md](open-issues.md) under *unverified* becoming *verified*, or as
its own entry when the answer is "this reads wrong".

And per AGENTS.md: **builds / tested / metal-verified**, and never "works" for
the first two.
