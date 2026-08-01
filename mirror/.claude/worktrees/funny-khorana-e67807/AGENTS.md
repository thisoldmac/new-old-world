# Working conventions for Mirror

Read this before writing code or docs here. It applies to **everyone —
human or agent**. Mirror renders and drives a real Mac OS 9.1 desktop from
semantic state; these rules are what the prototype proved, not aspirations
([the plan](docs/MIRRORKIT-PLAN.md), [the control
surface](docs/CONTROL-SURFACE.md)).

## The lab and its children

Mirror is a **nested repository inside the TimBotTu lab checkout**
(`timbottu/mirror`), gitignored by the parent exactly like `codekitten/`,
`now/`, and `qemu/`, carrying its own full history. Know the family before
you reach across any boundary:

- **TimBotTu is the lab** — the parent: a large, deliberately messy
  research world of emulators, corpus, and instruments, where hard-won
  platform lessons are *found*. It is not a dependency.
- **CodeKitten and NOW are siblings** — a Carbon IDE and a native cockpit
  for a Mac OS 9 guest. They share this repo's *lineage*, not its code.

The doctrine is symmetric and non-negotiable: **every child of the lab is
its own world.** A child inherits the lab's *findings and culture* — never
runtime code, and never a sibling's code either.

- **Shared — corpus and culture.** Mirror mines the parent's
  `data/findings` for the platform lessons it depends on (the OT listener
  wedge, the MacTCP poll-sleep transport numbers, AXPeek's metal gates)
  and holds the same disciplines: contract-first, the verification ladder,
  the human-first stance.
- **Not shared — a single line of code.** The AX layer, the wire, and the
  Open Transport path here began as clean copies of the lab's
  `harness/src` and **are expected to diverge**. When the lab's copy fixes
  a bug ours also has, a human ports the *fact* and we write our own
  patch. A finding crosses the boundary; a function never does.

### TimBotTu is the lab, not a dependency

The lab's instruments — the emulator (`tools/launch`), `tools/hc`,
`classicfmt`, `mcp-classic` — live in the parent checkout at `..`. They
**drive tests and deploys only; nothing from there ships.** Instruments,
not organs. Mirror must build and run with the parent checkout absent
except when standing up an emulator.

Two divergences are named debt, not accidents, and both are load-bearing
to understand:

1. **The AX guest layer.** `guest/app` carries a clean copy of the lab's
   `ax*.c` walk/ref/menu/resolve/text/binding library and the AX verb
   handlers. In the lab those handlers live inside a 309 KB `verbs.c`
   behind `#ifdef TBT_MORDOR` — a *toolkit* build the Runner refuses to
   lease, which is why AX was always hand-deployed there. Here they are a
   first-class app, which is the structural fix.
2. **The host package.** The lab still builds its pre-extraction
   `MirrorKit` for the workshop and the `service.mirror` managed service,
   frozen at extraction. Do not try to keep the two in sync.

## Semantic state, not pixels

The whole project rests on one bet: what the guest already knows about its
own UI is richer than its framebuffer, and cheaper to move.

1. **The renderer never sees the wire.** `WireClient` is the only
   wire-touching code in the host. Scene construction, hit-testing, and
   action dispatch live in the headless core, where they are testable
   without a window.
2. **Every rendered element carries `ref` and `rect`.** This symmetry is
   what makes perceive and act the same surface: anything you can see, you
   can name, and anything you can name, you can hit. A drawn element
   without a ref is a defect.
3. **Passive observation only, on the guest.** The extension copies roots;
   it never dereferences a foreign tree. The app walks **only** the
   regions an AXPeek sample and a SysZone validation have proven, bounded
   by tick budget and record caps, and reports `bytesScanned=0` when the
   oracle carried it. An unbounded walk is a wedge waiting for metal.
4. **Stale beats guessed.** A sample older than its freshness window fails
   loudly (`ax_oracle_not_found`, an age field) rather than rendering a
   plausible lie. Unknowns are absent keys.

## Emulator-only is a type, not a footnote

`mac99` is the bench and the gate. But some mechanisms exist only there —
QMP mouse injection (which beats cooperative tracking-loop starvation) and
the closed-loop `mouseloc` convergence it needs.

- Anything emulator-only is **typed** emulator-only in the action model
  and per-target action availability, and **degrades honestly** on a real
  machine — never silently, never by pretending it worked.
- Metal drag needs a VBL mouse-walker; until one exists, drag is an
  emulator capability and the host must say so.
- **Never gate a design on an emulator-only mechanism.** The bench may
  flatter you.

## The scene IR

Version-stamped from day one, and **unstable until the parity gate**.

- The fixture corpus in `host/MirrorKit/Tests/MirrorKitTests/Fixtures/` is
  a regression test during maturation, and hardens into the contract gate
  at the **IR v1 freeze** — freezing is the ritual that opens the parity
  phase, not a thing that happens quietly.
- Fixtures are captured off a **live guest**, garbage and all: the corpus
  deliberately includes a real garbage menu, `ax_oracle_not_found` rows,
  and stale samples. A corpus of only healthy scenes tests nothing.
- The Python generator that produced the first corpus is **retired** —
  Swift is the only implementation. Re-capture through the app.

## Verification

- **A clean build proves nothing; run the artifact.** A guest binary that
  compiles has not been tested.
- **A test is trusted only after it has been watched to fail** by
  mutation — and commit before mutating, so the mutation can never ride
  along into the tree.
- **Render-screenshot, not host capture.** The app rasterizes its own
  drawn canvas offscreen. That is explicitly *not* the guest framebuffer
  (a separate plane) and *not* the host screen. It makes the renderer
  agent-verifiable; comparing a render-shot against a guest snap is a free
  cross-check, never the mechanism. A human still judges Platinum
  *fidelity*.
- **The emulator gate comes before metal, always**, and a real machine is
  attended. Some above-the-line verbs still wedge real hardware.

## Emulator discipline

- **Test on a session-private clone**, never a shared base image. The
  parent's `tools/launch` clones by default; on APFS this is free.
- **Stop QEMU with QMP `quit`**, never `pkill` — a hard kill raises the
  macOS crash dialog that needs manual dismissal.
- **INITs load at boot only.** Installing the extension means a cold
  reboot; OS 9 ignores QMP `system_powerdown`, so hard-quit and relaunch
  without `-loadvm`.
- Spinning up your own VM is expected work, not a privileged act. Never
  block on a human to free one, and never borrow another session's.

## Docs

- Markdown. Short sections and tables over walls of prose.
- State **verified** facts as facts and mark hypotheses as hypotheses.
- Convert relative dates to absolute (YYYY-MM-DD).

## Provenance

The extension and the guest walk read live Toolbox structures whose
layouts come from published Apple documentation and Universal Interfaces
(`P-DOC`), cross-checked against our own probes (`P-OBS`). Keep it that
way: **no phantom constants** — every offset and magic number cites a
header, a document, or a measurement, or is explicitly marked a guess
awaiting evidence. A named `TODO` beats a plausible fill.

## Git

- Branch per thread, off the head; `main` lands by merge or
  fast-forward. Commit only when the human asks.
