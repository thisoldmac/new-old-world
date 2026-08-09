# Mirror — the capability inventory

**Date:** 2026-08-01 · **Status:** current at `9536ca2`. Every functional
capability the project has shipped, mined from the history (~190 commits,
spike to the Phase-1/2 merges) rather than from memory — each row carries the
commit that proves it, so provenance is one `git show` away. Rates quoted are
the row's own measured numbers; the oracles and methods behind them are in
[ARCHITECTURE.md](ARCHITECTURE.md) and [STATUS.md](STATUS.md).

A row belongs here only if it ran against a live guest with its own oracle.
What is built but *not* yet verified that way is listed in STATUS's "Not yet
done" — not here.
Added 2026-08-01 after Michelle read Part 4: *"I need a more exhaustive list
than that. We did a lot more work than that."* She is right — Part 4's six rows
are the acceptance floor, not the product. This part is the full functional
inventory of the upstream worktree, mined from its history (~190 commits, spike
to `9536ca2`), each row with its commit so provenance is one `git show` away.
**This is the list to check the port against, row by row.**

## 1. Rendering — what the mirror looks like

| Capability | Provenance |
|---|---|
| Platinum renderer with the guest's OWN assets: Tier-2 bitmap fonts, desktop pattern, extracted from the guest over the wire | `9552d9d`, `a9882eb` |
| Real OS 9 generic icons (desktop + Finder items) | `45ffa43` |
| Real per-app icons — the vanilla+ set dug out of the guest's resources | `c7c90d8` |
| Control-panel icons (sweep APPC, not just cdev) | `dbe836f` |
| System CLUT off-by-one found and fixed — every icon re-extracted | `d0228ec` |
| MacRoman text, real menu rendering, window widgets (close/zoom/collapse boxes) | `a902b99` |
| One chrome-geometry model shared by renderer and hit-tester — drawn pixels and click targets cannot drift (the close-box seam) | `b4d4bdc` |
| Every open app's windows render, with correct front attribution | `4053e11` |
| Renders at the guest's real resolution, auto-detected | `a9d1e01` |
| Guest-aspect window with fit transform; drag outline during window drags | `9d274d6` |
| Window content via QuickDraw replay — a document's text renders semantically | `8fe8b8d` |
| Pixel islands where no semantic source exists: capture, composite, and a MoveBits scroll fast-path | `040144a`, `1c4c181`, `526292c` |
| Island focus retention — a blurred window KEEPS its last interior (hold-on-blur, Michelle's rule) | `2002f4b` |
| First-sight capture when unoccluded; occlusion decides whether a held frame shows | `1db904f` |
| Folder windows draw named items from the Finder's live positions — the island became the fallback | `f81a4f8` |

## 2. The desktop

| Capability | Provenance |
|---|---|
| Desktop icons from the semantic plane (`list` verb — the desktop was empty because a verb was missing) | `5166fa0`, `f46861e` |
| Volumes appear on the desktop (`volumes` verb; icon keys off `kind:"disk"`) | `90517b9`, `3b76f79` |
| Icons hit by NAME; click at icon centre; label strip part of the target; unplaced/invisible excluded; a window over an icon wins the point | `89e8b84` |
| Selection is INVERT-style — multiply through the icon's pixels, black label, white text (box-behind was rejected) | `3b76f79` |
| Single click selects, double click opens | `7eab579` |

## 3. Menus

| Capability | Provenance |
|---|---|
| First-class selectable menus in the pane: hover highlight, open dropdown, identity dispatch | `b90e155` |
| Per-item geometry from the app's own MDEF (`menugeom`, `mCalcItemMsg`) — separators 6px vs items 16px, the 30px miss | `a7499e1`, `186c012` |
| Shortcut-less items perform via `menuinvoke` — the app's own MenuSelect answered, 20/20 by effect | `186c012` |
| ⌘ items go as keystrokes, matched on CODE not char (char alone silently no-ops in Finder) | `ff7b303` |
| The resting enable bit is NOT authoritative for app menus — actuation bug found and fixed | `cab8646` |
| The Application menu (app switcher): switchableApps predicate, rows keyed by psn, click → activate | `65fc7c7` |
| Apple-menu items addressable by title (leading-NUL strip + `titleNulPrefix`) | `79e867b` |
| The no-hijack click guard: armed point ±2px, user's press on another menu chains through | `739c42b` |

## 4. Windows

| Capability | Provenance |
|---|---|
| Raise by click, with correct z-order | `5d2bbcb` |
| Move/resize/zoom/close via answered traps (`winact`) — 20/20 each, no QMP, re-verified on the merged build | `01ce214`, `8366b66`, `bd830b3` |
| Title-bar drag → move; drag outline while dragging | `9d274d6` |
| Close on a dirty document surfaces the app's own save alert (measured, not suppressed) | `baa1f70` |
| FindWindow answers at either of its two stages | `6f3c228` |

## 5. Controls and text

| Capability | Provenance |
|---|---|
| Scrollbar actuation from the pane — the mirror drives a real scrollbar | `cd6c2d1` |
| `axdo` — act on a control by reference, honest `not_actionable` for hidden/disabled | `b1c96bc` |
| `ctlinvoke` — both halves of TrackControl: buttons by return value, scrollbars via the action proc; part codes 20–23 | `8ab7d05`, `bb25a3b` |
| All four scroll parts move the bar as named (618→602→106→122→618) | `8ab7d05` |
| `textget`/`textset` — dialog item, dialog TERec, or caller TEHandle; 20/20 each; the app agrees (8/8 files on disk named what we wrote); TEHandle bounded before dereference | `26c6fd8`, `0dbe07f`, `544ecf7` |
| Typing: `key` with rates (20/20 plain, 20/20 ⌘, 45 consecutive Returns); a modified keystroke needs a beat between its halves; keyUp's `evtNotEnb` is normal | `f5cf256`, `f4b4742`, `eca8198` |
| Precise clicks, double-click synthesis | `7eab579` |

## 6. App lifecycle and files

| Capability | Provenance |
|---|---|
| `launch` by path or name (LaunchApplication; bounded catalog walk from FindFolder; `ambiguous` on two matches) | `0733e5f` |
| `quit` via the `apple-event` verb, incl. the dirty-document case | `1415ee6` |
| `activate` / `observe` / process list with signatures | spike era |
| `script` — AppleScript through OSA (the folder-position source; 1–2 s per call) | `1212671` |
| Folder items addressable: `find {kind:"windowItem"}`, `act.open {windowItem}`, 40/40 by the Finder's own selection | `d232131` |
| `list`/`stat`/volumes — the desktop/file read plane | `5166fa0` |

## 7. The agent surface (MCP)

| Capability | Provenance |
|---|---|
| Fifteen element-first methods over unix socket, 0.7 framing; sessions with plane grants (semantic/tracking) | `0cd25a2` |
| A full agent session drives the guest 7/7 through the surface alone | `8049686` |
| `irVersion` beside the payload on scene AND attach; IR frozen at v1 behind a mutation-proven parity gate; known-wrong fields excluded, additive re-entry path | `36c8ff6`, `8e45d88` |
| `mirror.app op=list` — actionable rows, background excluded by default (don't hand an agent the process it talks through) | `36c8ff6` |
| Plane enforcement on ops that bypassed it | `d2ae8f0` |
| Unknown parameters refused on every mutating method, error names what it accepts; envelope keys derived from code | `156b8ce`, `7dca17d` |
| Contract corrected where it lied: `scope`, `allowDrag`, `windowItem`, launch/quit gaps | lab `f4175054` |

## 8. The rig and the method (they found every bug above)

| Capability | Provenance |
|---|---|
| One-command headed spin-up: clone, stage over the anchor, cold-reboot for INITs, print ports | `5c822b0` |
| Staging hardened: FlushVol for staged writes, collision-safe ports, verify-by-fork-size past the −43 quirk, INITs that survive cold reboot | `f42cb09`, `a82cc8f` |
| Build stamp = hash over sources (a `__DATE__` stamp measured the old binary with confidence once) | `3754750` |
| `trials.py`: N=20 independent trials, state reset, preconditions enforced, persistent connection, `ok:false` is a reply | `ce6c84a` |
| `nohijack-probe.py`: six cases incl. disarm sweep and cross-process attempt | `d76be02`+ |
| The retraction record: 9-per-boot ceiling, axdo wedge, watchdog theory, WNE mask, held-button, fdLocation — each formally withdrawn with the bug that manufactured it | `f5cf256`, `b1c96bc`, `a6aea99` |
