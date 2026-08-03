# The Mirror drive loop

**Read this file at the start of every run, before touching anything.**
It is short on purpose. It exists because the work kept failing the same
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
| **Sweep** | drive, observe, record findings with IDs (`D9.4`) | ~20 actions or one ladder pass, whichever comes first |
| **Triage** | rank: **blocking** / **broken** / **cosmetic** | — |
| **Patch** | fix the blockers, plus at most **two** others | gate green before restaging |
| **Verify** | next sweep RE-TESTS the claimed-fixed IDs first | before any new ground |

**Blocked mid-sweep**: keep sweeping whatever does not depend on the
block, record it as blocking, then break out into a patch session and
retry that rung. Do not abandon the rest of the sweep to chase it.

---

## 3. The ladder

Each rung is polished before the next. Every sweep re-runs the rungs
below it as regression.

| rung | target | done means |
|---|---|---|
| **1** | Frontmost window ops, on NOW's own window | hide, show, move, resize, zoom and close all work from the mirror |
| **2** | Desktop and the Finder | icons right, double-click opens, menus match the machine, Macintosh HD opens and renders |
| **3** | One application at a time, from the sample below | window and controls render, menus work, clicks land where they look |
| **4** | Control panels | several open; **text fields select and type** |
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

---

## 4. Recording

Findings go to `docs/local/mirror-drive-notes.md`, one section per
drive, each with an ID, what was seen, and what it is downstream of.
Screendumps beside the mirror screenshot for anything visual.

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
