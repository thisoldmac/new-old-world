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
| **1** | Frontmost window ops, on NOW's own window | hide, show, move, resize, zoom and close all work from the mirror |
| **2** | Desktop and the Finder | icons right, double-click opens, menus match the machine, Macintosh HD opens and renders |
| **3** | One application at a time, from the sample below | window and controls render, menus work, clicks land where they look, and **anywhere it takes text, text goes in** |
| **4** | Control panels | several open, and their **forms** work — see §3.3 |
| **5** | Background applications | other apps' windows appear at all |

Rung 2 needs anchors for **the Finder specifically** — a narrower
problem than rung 5's general case, and fine to solve on its own.

### The application sample (rung 3)

Deliberately not trivial ones, and deliberately varied — the eventual
goal is to drive and render *any* application, so the sample has to
stress different things. One at a time; finish one before starting the
next.

| app | what it stresses |
|---|---|
| **Apple System Profiler** | tabbed panes, large list views, dense static text |
| **Sherlock 2** | icon toolbar, tabs, an editable search field, a results list |
| **Stickies** | many small windows at once, live text editing, window management |
| **Network Browser** | list/outline view, toolbar, progress |
| **QuickTime Player** | custom-drawn controls — deliberately the awkward one, where semantics run out and we learn what a NON-compliant application costs |

### Control panels (rung 4)

TCP/IP · Date & Time · Appearance · Monitors — between them: text
fields, popups, radio groups, checkboxes, tabs and sliders.

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

A person opens the mirror and operates the Macintosh: moves and closes
windows, opens disks and folders, launches an application, uses its
menus, clicks its controls, types into its fields — and what they see
matches what the machine is actually showing. Pixels and islands are
optional throughout; nothing may be load-bearing on them.

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
