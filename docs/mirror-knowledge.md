# Has Mirror already solved this?

**Read this before starting any work on perceiving or driving the
classic Mac.** It costs two minutes and has already been worth several
days.

`timbottu/mirror` is a parked, complete upstream project: a semantic
mirror of a Mac OS 9 desktop, with a guest application, resident
extensions and a Swift host. NOW has ported parts of it and inherits all
of its recorded knowledge. **Everything in it was paid for once
already.**

## Why this page exists

On 2026-07-31 an audit found NOW had re-derived two upstream answers in
a single day:

| What NOW re-derived | What upstream already had |
|---|---|
| A milestone declared **blocked** because the menu-list structure is in no header available here | The ported menu walker had carried the offsets all along — `now-guest-ppc/src/axwalk/axmenu.c` |
| A from-scratch INIT and reader, built to ask whether PowerPC QuickDraw can call a 68K bottleneck | Answered, in the **opposite direction** from what the spike braced for: **`NewQDxxxUPP` alone works, no `RoutineDescriptor` needed** |

Both cost real effort and produced nothing upstream did not have.

**The standing rule: check Mirror before deriving anything.** If a piece
of work begins with *"we need to find out whether…"*, the first place to
look is this page, and the second is the upstream repository.

## The pages

| Page | Covers |
|---|---|
| [mirror-perceive-plane.md](mirror-perceive-plane.md) | reading the desktop — the tree, references, menus, icon positions, the scene contract, wire behaviour |
| [mirror-act-plane.md](mirror-act-plane.md) | driving an application — in-process trap answering, the Toolbox facts underneath it, identity-not-position, input verbs |
| [mirror-content-plane.md](mirror-content-plane.md) | reading what an application draws — QuickDraw bottleneck capture, pixel islands, the Timbuktu prior art |
| [mirror-journaling.md](mirror-journaling.md) | the Event Manager journal: measured, and closed |
| [toolbox-and-gworld.md](toolbox-and-gworld.md) | the Toolbox measured — structure layouts, GWorld internals and lifetime, bottleneck dispatch, and how a composite is read from an offscreen port |
| [mirror-assets.md](mirror-assets.md) | extracting the guest's own fonts, icons, cursors and patterns |
| [cursor-follow.md](cursor-follow.md) | the guest's DRAWN cursor — why Inside Macintosh's redraw recipe does not work on Mac OS 9, which of three routes actually blits, and the measured fact that the cursor's **shape** already tracks a position the resident sets |
| [mirror-renders.md](mirror-renders.md) | rendered scenes, and what each proves — including the one before/after pair beside the machine's own screen |
| [mirror-measurement-method.md](mirror-measurement-method.md) | how to measure things here — **twenty-two** rules, each bought with a retraction. Rules 1–12 are upstream's inheritance; **13–22 are NOW's own**, all paid for on 2026-08-05/06, and they are why that file is no longer titled for Mirror alone. 19 is the one that bit the session that had just written it: the end of a shared append-only log is not your run. 20–22 are the ones about an instrument that *substitutes* rather than misses — one blocking call reported as two slownesses, a wedge mode named `modal` that never raised one, and heap arithmetic that failed in silence |
| [mirror-foldin-inventory.md](mirror-foldin-inventory.md) | what has crossed from upstream and what has not |

## What provenance means on these pages

Two rules, and they matter more here than on any other doc in this tree.

- **Upstream's measurements do not become NOW's measurements by being
  written down here.** They are evidence about a mechanism — strong
  evidence, and not the same thing as having measured it. Where NOW has
  ported the mechanism, they say what to expect; they do not say what NOW
  observed.
- **A measurement keeps the machine it was taken on.** Nearly everything
  upstream measured was on a QEMU `mac99` clone running Mac OS 9.1.
  Almost nothing touched real hardware, and the exceptions are labelled
  where they appear. **A mac99 number is a mac99 number in NOW too.**

## The index — questions that are already answered

### Mixed Mode and resident code

| Question | Answer | Where |
|---|---|---|
| Can PowerPC QuickDraw call a 68K bottleneck procedure? | **Yes, with `NewQDxxxUPP` alone. No `RoutineDescriptor`.** (mac99) | [content plane](mirror-content-plane.md) |
| Is a draw-time hook stable enough to install and remove repeatedly? | Yes — 100× start/stop stable, install/uninstall 5/5 (mac99) | [content plane](mirror-content-plane.md) |
| Does a native PowerPC application's `DragWindow` reach a 68K trap patch? | Yes, demonstrated on this target | [journaling](mirror-journaling.md) |

### Reading state

| Question | Answer | Where |
|---|---|---|
| What is the menu-list structure? | Carried in the ported walker; the offsets are 6 / 6 / 14 | [perceive plane](mirror-perceive-plane.md) |
| Where does a self-scene put Help after the application menus? | At `MenuList.last_right`. Zero is the Apple slot's left edge and makes Help overwrite it. Measured in NOW's live Workshop on mac99, 2026-08-03 | `now-guest-ppc/src/scene/scene_self.c` |
| Why can't a process-list verb see foreign windows and menus? | The Window and Menu Managers keep their roots in **per-process A5 globals**. That is why the hook is an INIT | [perceive plane](mirror-perceive-plane.md) |
| Where does an icon in a Finder window really sit? | Ask the Finder for its live **bounds**, never the saved catalog field. `position` works for icon view but names a saved icon grid in list view; `bounds` is the drawn 32×32 or 16×16 box in all three measured views | [perceive plane](mirror-perceive-plane.md) |
| Can the QuickDraw stream tell us where Finder window icons are? | **Not from the WINDOW port** — the Finder composites offscreen and emits one opaque blit (confirmed three ways 2026-07-17, reproduced independently 2026-08-06). **YES from the OFFSCREEN port**: a resident found and hooked the Finder's GWorld from outside and read its icon LABELS as text ops at true pens ('Documents' [280,67], 'TimBotTu' [282,131]). Three Toolbox facts make it work and each defeats it alone — join on SHAPE (LockPixels relocates the PixMap record, so pointers, handles and baseAddr are all snapshots); MemTop is NOT the address-space ceiling, so a read guard bounded by it rejects every candidate; and the hook must be HELD across the repaint, since re-arming unhooks the world. Icons still arrive as identity-less bits — labels are semantic, images are not yet | [toolbox-and-gworld.md](toolbox-and-gworld.md) |
| Which AppleScript Finder terminology works on 9.1? | Generic `window` and `item of window`; the `Finder window` class and `target of window` both error | [perceive plane](mirror-perceive-plane.md) |
| Are menu rows a uniform height? | **No** — separators 6 px, items 16 px on mac99. Assuming 16 accumulated a 30 px error | [act plane](mirror-act-plane.md) |
| Is a menu item's `enabled` bit trustworthy? | **No.** Classic apps disable menus at rest. Never gate actuation on it | [act plane](mirror-act-plane.md) |
| Why do window ids change when you raise a window? | The id embeds the enumeration index, and that index **is** z-order | [perceive plane](mirror-perceive-plane.md) |

### Driving the machine

| Question | Answer | Where |
|---|---|---|
| Why can't posted events drive a control? | The application enters a tracking loop and spins; nothing else gets CPU. Answer the trap instead of injecting the input | [act plane](mirror-act-plane.md) |
| Can journaling reach inside a tracking loop? | **Yes** — and it still cannot drive a foreign app, because the flag is per-process | [journaling](mirror-journaling.md) |
| What are the scroll-bar control part codes? | 20 / 21 / 22 / 23 — **not** 10–13, which a comment once claimed | [act plane](mirror-act-plane.md) |
| Does `DragWindow` have `TrackControl`'s shape? | **No.** It is `pascal void` and does the move itself | [act plane](mirror-act-plane.md) |
| Why does a patch that "fires" do nothing? | A Pascal `Boolean` result lives in the **high byte** of a 2-byte slot. `move.w #1` writes FALSE | [act plane](mirror-act-plane.md) |
| Is a self-disarming patch a safety guard? | **No.** It says the patch fires once, not *whose* call it fires on. 18/20 hijacks until identity was checked | [act plane](mirror-act-plane.md) |
| Can one process's act fire a command in another? | **Unknown** — the test never reached the guard, because a background application does not arm at all (6/6 timeouts) | [act plane](mirror-act-plane.md) |
| Does a ⌘-shortcut need the character or the keycode? | The **keycode**. Char-only silently no-ops in the Finder | [act plane](mirror-act-plane.md) |

### Costs, measured on mac99

| Thing | Number |
|---|---|
| Semantic poll (accessibility tree) | ~2 ms; ~10 KB front scope; 13,980 B in 2.1 ms for a typical window |
| Full-window pixel island, 426×358, depth 16 | ~947 ms, fetched about once per four polls |
| A 613×538 capture inside the poll | ~150 ms |
| One Finder scripting round trip | 1–2 s — far too much per poll |
| Launch by name, first call | 327 directories, 0.45 s on the wire |
| Quit an application with a clean document | leaves the scene in 1.2 s |
| **Real hardware, for contrast — Quadra 950 over MacTCP** | ~32 ms per request; the same tree 307 ms median at front scope |

That last row is the only perceive measurement upstream took off the
emulator, and it is the useful one: **the mechanism is not the cost, the
transport is.**

## Traps that will cost you an afternoon

| Trap | Symptom |
|---|---|
| The guest serves **one connection**, serially | A second client resets the first, with a bare connection reset and no explanation on either side. Manufactured two separate wrong narratives upstream |
| A capability missing from the session's scope | Reads as a **refusal**, which looks nothing like the feature it breaks. One test battery reported an actuation bug that was pure configuration |
| Reading a result field without checking status | An honest `ok: false` reply becomes a client exception, then a "wedge" theory |
| An arming act **warps the pointer** | Rude to a human, and it corrupts measurements — it made a probe click the wrong thing and report a confident 0/2 |
| Two copies of a shared-memory header | They do not fail to build when they drift. They fail to **agree**, silently |
| A build stamp derived from a clock | Does not move when a source file changes. Hash the sources |
| A whole-disk Finder search | **Wedged a real machine for about twelve minutes.** Scope every script to a window already open |
| A journal device armed while falsifying ticks | Takes Open Transport down with it, because OT counts timeouts in ticks — so the wire disarm is unreachable in exactly the failure it exists for |
| Treating a session-private disk clone as automatically clean | The base may be clean and the clone still becomes dirty when staging ends with QMP `quit`. The next boot's Disk First Aid was manufactured by the harness, not inherited from the base |
| Assuming every bootstrap Worker grants `script` | The os91-runner Worker published `click`, `key`, `type`, and `launch`, but not `script`; Finder AppleScript shutdown was correctly refused. Session scope is evidence, not a constant |
| Selecting Finder's Shut Down with two posted clicks | Finder's MenuSelect owns a held tracking gesture. Separately posted clicks do not reproduce it, and QMP's relative pointer could not be closed-loop verified from framebuffer captures. Do not call this a clean-shutdown route. **SOLVED IN NOW 2026-08-06, by not posting a click at all:** the act plane's `menuact` answers the application's own `MenuSelect`, so the held gesture never has to be reproduced. Finder Special > Shut Down powered the guest off, QEMU exited on its own in under 10 s, and the volume came out cleanly unmounted. `menuact` requires `serialHi`/`serialLo` from the scene's front process, and omitting them is why an earlier NOW probe recorded this as impossible |
| Assuming a Shutdown Manager call proves a clean emulator stop | Staged 68K helpers using `ShutDwnStart`, `ShutDwnPower`, Finder Apple Events, and embedded OSA all failed to power off the scoped OS 9/mac99 guest. The 120-second observer left the VM intact; this investigation is deferred, not solved. **NOW re-measured this on 2026-08-06 and confirms the negative half with a sharper edge:** `ShutDwnPower` does not merely fail to power off, it fails to finish the UNMOUNT — three images preserved after it had the HFS volume still marked mounted, and `qemu-img check` passed all three because it validates the container. Ask `tools/volclean.py`. The positive route is the row above |

## What upstream never answered

Do not read this page as "Mirror solved everything." These are open, and
a NOW thread that takes one on is doing new work, not repeating old
work.

| Open | Note |
|---|---|
| **Real hardware, for all three planes** | Essentially nothing upstream built for perceive-and-act ran on metal. No per-operation metal-safety review exists for the act plane |
| **Cross-process blast radius** | The guard was never reached |
| **Finder list and small-icon views** | **Answered in NOW 2026-08-08:** `view of window` reports `name` and `small icon`; item `bounds` carries the drawn row/icon box and the host renders names semantically. Column metadata beyond name remains unmeasured |
| Should Finder interiors come from P3 drawing replay? | **No on this product boundary.** P3 tracing crashed/restarted Finder on the PB1400c and Finder is now permanently refused at both host and guest arm boundaries. NOW renders desktop and open-folder interiors from semantic path, view, order, live bounds and selection; applications may still use P3. This is Tested, not yet re-run on metal after consolidation | [open issues](open-issues.md) |
| Does bounded semantic Finder mean share-root-only browsing? | There are now **two boundaries**. Guest-follow mode may mirror a Finder window anywhere Finder opened it and reads only that displayed directory. Optional **Emulate Finder Windows** does not open guest Finder windows at all; it browses through the Files contract, so its root is the configured guest share (the whole disk when **Share entire boot volume** is enabled). Neither mode recursively enumerates the volume | [open issues](open-issues.md) |
| Can Finder folder windows be useful without waiting for Finder state? | **Tested host-side, not metal-verified.** With **Emulate Finder Windows** enabled, NOW owns folder-window lifecycle, geometry, view, sort, selection and scroll, and obtains entries through bounded `file.list` pages. Opening a folder emits no guest command/Finder-open request. The ordinary guest-follow semantic mode remains available when the toggle is off | [open issues](open-issues.md) |
| **An application's own document text** | The door exists; discovering a private text handle is not implemented, and no documented route to it was found |
| **Precise control kind** | Button versus checkbox versus radio — the definition procedure's id is not in the record |
| **True cross-app z-order** | Reconstructed, not read, and there is nothing to read: `WindowList` is a per-process low-memory global, so no application's chain reaches another's. Since 2026-08-07 the reconstruction is the order applications were last WATCHED coming to the front (`front_order.h`) rather than Process Manager enumeration, which is launch order |
| **Scale** | All folder-item trials used one folder, in one window, with fifteen items |
| **Content-plane record mode** | Only counting was built; the ring and the text records were never reached |
| **A fixture for the content plane** | Its contract was frozen on design and live use, not on captured evidence |

## What crossed, and what was left behind

Fourteen upstream documents were read for these pages. Their disposition:

| Upstream document | Disposition |
|---|---|
| `QUICKDRAW-CONTENT-PLANE.md`, `QDPEEK-SPEC.md`, `TIMBUKTU-QD-FINDINGS.md`, `TIMBUKTU-TEARDOWN.md` | merged into one content-plane page; the patent teardown is summarised as prior art rather than transplanted |
| `CONTROL-SURFACE.md`, `FOLDER-ITEMS.md`, `IR-V1.md` | split by subject across the perceive and act pages |
| `PORTAL-PLAN.md` | findings extracted; the plan itself left behind — NOW is not going to execute upstream's milestone sequence |
| `JOURNALING.md` | crossed close to whole; it is a completed investigation, not a plan |
| `ASSET-EXTRACTION.md` | crossed as findings; the deliverable layout and the extractor's design were left behind |
| `HANDOFF.md`, `MIRRORKIT-PLAN.md`, `PROTOTYPE-NOTES.md` | mechanisms and gotchas extracted; the module inventories, phase tables and run commands left behind — they describe a tree NOW does not have |
| `STATUS.md` (55 KB) | mined; the milestone narration discarded, the findings redistributed by subject. The method page is mostly from here |

Left behind entirely, and why: upstream's milestone tables, effort
estimates, sequencing, module listings, run commands and repository
paths. They describe a project that is parked. **The findings are the
inheritance; the plan is not.**
