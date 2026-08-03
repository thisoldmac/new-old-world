# The Mirror drive loop

**Read this file at the start of every CYCLE, before touching anything** —
not once per session. It is short on purpose so that re-reading it costs
nothing. It exists because the work kept failing the same
way: drilling into the first defect found, fixing it mid-drive, then
reporting a fix nobody had watched work.

The goal is not a list of closed findings. It is **a faithful,
functional, accurate mirror of the guest** — one a person can operate.

---

## 1. The rules, recited every pass

1. **Drive the mirror with computer use.** Never the wire, never NOW's
   own Console page, never QMP input, never a probe script. Test it the
   way a person would, because that is the only path that is real.
2. **QMP `screendump` is for LOOKING, never for doing.** The A-B
   reference must not come through the app under test; a defect shared
   by both halves is invisible otherwise.
2a. **Every assessment of the mirror is PAIRED with a screendump of the
   same moment.** Not "for anything visual" — every pass and every fail.
   A mirror screenshot on its own says what the mirror drew, never
   whether that is what the machine is showing, and the gap between
   those two is the entire product. Stated by Michelle on 2026-08-03,
   after I reported NOW's own Workshop window as rendering correctly on
   the strength of seeing seven buttons with titles in it. It was not
   rendering correctly, and one screendump would have said so
   immediately. `tools/mirror-gate row` refuses a pass or a fail without
   one, so this is not a thing to remember.
2b. **Compare the WHOLE frame, not the thing you just fixed.** A pairing
   is worthless if the comparison is not made. On 2026-08-03 I passed
   `controls-render` because three buttons had come out right, while the
   same dialog was missing its icon and both lines of its text, and
   passed `window-renders` on a window whose title was absent. Michelle:
   "buttons rendering doesnt mean its a pass". Judge the row against
   everything the machine draws — every dialog item, the window title,
   the static text, the icons — and score the row on the worst of it.
2c. **Wait for the guest before calling a null result.** It is
   cooperatively scheduled and an act can take tens of seconds to
   appear; a five-second look reports "nothing happened" for something
   that is happening. Three rows were failed wrongly this way in one
   session — an icon open, a disk open, and the click that actually did
   dismiss a modal alert. Wait for the scene to change, or for a
   generous timeout, and take the paired screendump after that.
2d. **Score FIDELITY separately, and never infer it from behaviour.** A
   control that is clickable is not a control that is drawn right, and a
   window whose every element is present can still not look like the
   window. Date & Time on 2026-08-03: the radio buttons worked, the text
   field took a keystroke, the machine recalculated — and the panel was
   a mess. Labels truncated mid-word and overlapping each other, group
   boxes as dashed rectangles instead of engraved frames, checkboxes and
   radios drawn as push buttons, every field value missing or drawn in
   the window's top-left corner. Michelle: "just because its rendering
   all the controls and fields doesnt mean its passing". Every rung
   carries a `fidelity` row, judged on the whole frame against the
   machine's, and it is scored even when everything else passed.
2e. **A null reading needs a positive control before you blame the
   instrument.** An empty log, a blank capture, a silent act: each has at
   least two causes — the instrument is wrong, or the thing never
   happened. On 2026-08-03 I added act logging, drove a drag, got an
   empty log, and immediately patched the logging on the assumption it
   was wired to the wrong path. I never checked whether the drag had
   moved the window. It had not — a later drag missed the title bar the
   same way and logged nothing for the correct reason. Michelle: "you
   got a silent result and jumped to patching the logging without sanity
   checking against whether or not the known good drag action actually
   completed". So: do the thing, confirm the EFFECT on the machine, and
   only then read the instrument. An instrument that reports nothing
   about an event that did not occur is working.
3. **If the mirror cannot do it, that IS the finding.** Record it. Do
   not reach past it to keep the run going.
4. **Record, don't fix, during a sweep.** No edits, no builds, no
   diagnosis beyond a screendump.
5. **Nothing is "fixed" until a later drive watched it work.** A claim
   made from code you wrote is not a result.
6. **Do not restate a hypothesis as a fact.** "The arm lease was the
   root cause" was said twice before a drive proved it wrong.
7. **No regressions.** A pass that adds one feature and breaks three is
   worse than no pass. Rungs already polished are re-swept every drive.

---

## 2. The four phases

Collapsing Sweep into Patch is the failure this structure prevents.

| phase | what happens | hard limit |
|---|---|---|
| **Refresh** | re-read THIS file, then the last drive's notes | first action of every cycle, no exceptions |
| **Sweep** | drive, observe, record findings with IDs (`D9.4`) | ~20 actions or one ladder pass, whichever comes first |
| **Triage** | rank: **blocking** / **broken** / **cosmetic** | — |
| **Patch** | fix the blockers, plus at most **two** others | gate green before restaging |
| **Verify** | next sweep RE-TESTS the claimed-fixed IDs first | before any new ground |

**Blocked mid-sweep — a blocker does NOT mean stop.** It means: write it
down, step over it, and keep sweeping everything that does not depend on
it, INCLUDING rungs above the blocked one. Patching begins only when the
sweep budget is spent or the ladder pass is finished.

One failed test is not a sweep. A sweep attempts **every item on the
rung's checklist** and records each as pass / fail / blocked — and then
carries on up the ladder testing whatever the block does not prevent.

The temptation is always the same: the first failure is interesting, and
diagnosing it feels like progress. It is not; it is the drilling this
document exists to stop. Seen again on 2026-08-03 — one window drag
failed and the sweep ended there, with close, zoom, resize, the menus,
the desktop and the whole of rung 2 untested and a full patch session
started on the strength of a single observation.

**Why Refresh is a phase and not a preamble.** Drift happens INSIDE a
session, not between them. A patch session fills the working context
with header offsets, procIDs and build errors, and the rules quietly
stop being the thing in mind — which is how a run ends up on the wire,
or fixing mid-sweep, or reporting a fix nobody watched. Every one of
those happened on 2026-08-03 within a single session that started by
reading the rules once.

So each cycle re-reads the file itself, from disk, rather than
remembering it.

**That used to be self-reported, and the report was false.** Five drive
notes opened with `rules re-read`; two of those re-reads happened. The
audit line invented to catch the drift was itself the thing that drifted,
which is the argument against every honour-system guardrail here.

So the refresh is now a **consequence**, not a step. `tools/mirror-gate`
holds the cycle's checklist, a `Stop` hook runs `mirror-gate check`
before the turn can end, and the rejection it prints — which lands back
in context — carries the abbreviated rules with it. Refreshing is no
longer something to remember; it is what happens when the loop tries to
stop early. A `PreToolUse` hook on `Bash` refuses the console, the wire
and QMP input for the same reason.

    tools/mirror-gate begin 13 --rungs 1,2,3 --app "Sherlock 2"
    tools/mirror-gate row  r2.hd-contents fail "renders as an empty box"
    tools/mirror-gate finding "D13.4 icons fetch but never draw"
    tools/mirror-gate close          # ends the SWEEP, not the work

The checklist rows are generated from §3 below, so a cycle can fill one
in but never choose it, and `begin` refuses a third consecutive cycle at
the same reach — the ladder is meant to climb. Only two commands let a
turn end: `pause --reason` (something only Michelle can authorise) and
`done --evidence` (§5 is true).

---

## 3. The ladder

Each rung is polished before the next. Every sweep re-runs the rungs
below it as regression.

| rung | target | done means |
|---|---|---|
| **1** | Frontmost window ops | hide, show, move, resize, zoom and close all work from the mirror |
| **2** | Desktop and the Finder | icons right, double-click opens, menus match the machine, Macintosh HD opens and renders |
| **3** | **Control panels** — the compliance gate | several open at once, all drawn right, all drivable, and their **forms** work |
| **4** | **Modal alerts** — the sibling gate | the alert draws whole and can be answered |
| **5** | One application at a time, from the sample | the compliant ones match; the awkward one **degrades honestly** |
| **6** | Background applications | other apps' windows appear at all |

Rung 2 needs anchors for **the Finder specifically** — a narrower
problem than rung 6's general case, and fine to solve on its own.

**Why first-party comes before applications.** Rungs 3 and 4 used to sit
above "one application", which meant meeting a third-party app before
we had proved we could draw a compliant one. That is backwards. A
control panel and a system alert are **Apple's own**, built to Apple's
own guidelines, so a gap in one is OUR defect with no "that app is
strange" left to hide behind. They are the gate, and the bar is
**perfect**.

Rung 5 keeps a deliberately non-compliant application for the opposite
reason, and its bar is different: **degrade honestly**. A mirror that
cannot render a custom-drawn control must say so rather than draw
something plausible. Polishing only against compliant software is how
you get a mirror that lies about the software that isn't.

### Control panels (rung 3)

TCP/IP · Date & Time · Appearance · Monitors — between them: text
fields, popups, radio groups, checkboxes, tabs, sliders, a scrolling
list and colour swatches, which is most of the Toolbox's control classes
in four windows that open in seconds.

Three properties make them the gate rather than merely a good sample:

- **Stateful.** You can toggle a thing and see it stick, which is the
  difference between "drew a checkbox" and "the checkbox works".
- **Several at once.** Open four and the rung also tests z-order,
  switching by clicking a background window, switching through the
  Application menu, and hide/show.
- **Identical on every OS 9 machine.** A captured control-panel scene is
  a permanent regression fixture in a way "whatever was open that day"
  never is.

### Modal alerts (rung 4)

A sibling of rung 3, not a subset: an alert is chrome-less by design,
is answered rather than operated, and blocks its own application while
the rest of the machine carries on. Every one of those is a distinct
thing to get wrong, and on 2026-08-03 the mirror got all of them wrong
at once — three unlabelled scroll-bar tracks where the buttons were.

**Raise one by double-clicking Mail on the desktop.** It asks whether
the computer is set up for Internet access, every time, on a fresh boot
— which makes it the one reliably reproducible alert on this machine.
Answering "Yes" opens the Internet Setup Assistant, itself a useful
target: a *titled* dialog, the case that proved chrome cannot be decided
from `windowKind` alone.

What the rung asks: the alert draws its icon and all of its text, not
just its buttons; the buttons carry their titles and the default ring
sits on the right one; a click on a button actually answers it; Return
actuates the default; and while the alert is up the rest of the screen
still mirrors faithfully.

### The application sample (rung 5)

Reached only once rungs 3 and 4 are green, because these are where the
mirror stops being able to blame the application. Deliberately varied —
the eventual goal is to drive and render *any* application. One at a
time; finish one before starting the next.

| app | what it stresses |
|---|---|
| **Apple System Profiler** | tabbed panes, large list views, dense static text |
| **Sherlock 2** | icon toolbar, tabs, an editable search field, a results list |
| **Stickies** | many small windows at once, live text editing, window management |
| **Network Browser** | list/outline view, toolbar, progress |
| **QuickTime Player** | custom-drawn controls — deliberately the awkward one, where semantics run out and we learn what a NON-compliant application costs |

The first four are held to the rung-3 bar. **QuickTime Player is held to
the honesty bar instead**: what it cannot draw it must decline to draw,
and what it cannot drive it must refuse by name. A plausible-looking
guess there is worse than a blank.

### 3.3 Text input is its own test, everywhere it appears

Not a footnote on one rung. Anywhere a person can type, test it, and
test the whole interaction rather than the keystroke alone:

- **click to place the caret** in a field that already has text
- **drag to select** a range, and select-all
- **type** — the characters arrive, in order, in the right field
- **delete and edit** an existing value, not only append to an empty one
- **tab between fields** in a form, where the app supports it
- **commit** — Return/Enter where the form expects it

Two shapes, and both must work:

| shape | where | why it differs |
|---|---|---|
| **single-line form fields** | TCP/IP addresses, Date & Time, Sherlock's search field | short, validated, often tab-linked; a wrong caret lands in the wrong field |
| **multi-line text areas** | Stickies, a SimpleText-style document, any editable body | wrapping, scrolling, caret across lines; selection spans lines |

**Type with keystrokes, not by setting the value.** The guest can write
an element's text directly (`textset`) and that is the easy path and the
wrong one to prove with: it skips focus, skips the caret, skips
validation and skips everything an application does while a person
types. `textset` is a fallback for a field that answers nothing else,
and when it is used the note says so.

---

## 4. Recording

Pass/fail per row lives in `mirror-gate`; prose findings go to
`docs/local/mirror-drive-notes.md`, one section per drive, headed by the
cycle number: an ID, what was seen, and what it is downstream of.
Screendumps beside the mirror screenshot for anything visual.

The note no longer opens with `rules re-read`. That line could only ever
be self-reported, and it has a record of being false; the gate firing is
the evidence now.

A finding is closed only by a later drive that watched it work, and the
note says which drive closed it.

---

## 5. What "done" looks like

**The target, in one line: a high-fidelity emulator whose state is
provided by the guest and whose state mutations are driven by the
mirror.** Michelle, 2026-08-03. Everything below is a consequence of it,
and it is worth reading before scoring anything.

An emulator does not get to draw the interesting parts and leave the
rest blank. It shows what the machine shows — the static text, the
icons, the pictures, the list rows, the group boxes, the greyed-out
label nobody clicks — because a person reads a screen, not a control
tree. So:

- **"The controls rendered" is never a pass.** A window whose buttons
  are perfect and whose body is blank or garbled is a failure of the
  thing this is for. Score the row on the worst part of the frame
  (rule 2b), and if in doubt, look at the two pictures side by side.
- **A structural check can VETO a pass. It can never grant one.** The
  oracle, the diff, the row count, any harness: they are fast ways to
  find a defect, and none of them is evidence of fidelity. Only pixels
  compared against the machine's pixels, plus a person looking, grant.
- **Pixels are the gate, not a bonus.** The old line here said "pixels
  and islands are optional throughout" — that was about not making the
  *mechanism* depend on a pixel plane, and it is still true of the
  mechanism. It was never a licence to stop short of what the machine
  displays, and it has been read that way.

So the definition: a person opens the mirror and operates the Macintosh
— moves and closes windows, opens disks and folders, launches an
application, uses its menus, clicks its controls, types into its fields
— and what they see **matches what the machine is showing**, checked
against the machine's own framebuffer rather than against our idea of
what mattered.

Stop when that is true, not when the findings list is empty.

---

## 6. This is a loop, not a checklist

The phases are a **cycle**. Finishing Verify means starting the next
Sweep, immediately, in the same session. Every limit in this document
bounds one PASS; none of them ends the work.

**These are not stopping conditions.** Each has ended a session before,
and each is wrong:

- the sweep budget was reached — that ends the *sweep*, and triage
  begins
- the patch limit was reached — the rest of the findings wait for the
  next cycle, which starts now
- findings were recorded and written up — recording is not fixing
- a rung went green — the next rung starts
- an application was polished — the next application starts
- `scripts/test-all` passed — a green gate is not a working mirror
- the session has gone on a long time, or a lot was accomplished
- there is a good report to give — **give it and keep going**
- **"I am running out of context"** — checked on 2026-08-03 while it was
  being claimed for the third time: 65%. The session also compacts
  rather than ending, so running out is not a terminal condition; at
  worst the work continues with a summary. This one slipped past the
  list above because it reads as a constraint imposed from outside
  rather than a choice, which is precisely why it is named here.
  `mirror-gate pause` now refuses it.

**The only real stops** are: the §5 definition is met; something needs
authorisation that only Michelle can give (metal, a destructive act,
landing on `main`); or the tooling is broken in a way that cannot be
fixed from here — and then say so plainly, with the evidence, rather
than trailing off.

**Whatever the reason for a pause, leave it working.** The VM up, the
app running and connected, the mirror open, the tree clean and the gate
green. A pause with a broken mirror is worse than no pause, and "one new
feature and three new regressions" is the outcome this whole document
exists to prevent.

Report progress as often as is useful. Reporting is not stopping.
