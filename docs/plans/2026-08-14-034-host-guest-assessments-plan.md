# 034 — Host & guest assessments: plan and tracker

Status: **research in progress** (swarm fanned out 2026-08-14). This file is
the master tracker; it will be rewritten into the real plan as research
lands. Raw per-unit research notes live in `docs/local/assessments-034/`
(gitignored scratch); anything load-bearing graduates into this doc.

Branch: `claude/host-guest-assessments-7b254f`, forked off
`refactor/mirror-continuity-split` @ 76f4dac6. Merges with that thread when
both are done.

## Item inventory

Classification: **locked** = straightforward, plan is decided and ready to
implement. **discussion** = open design question to workshop with Michelle.
Blank = research not yet landed.

### Host

| ID | Item | Unit | Class |
|----|------|------|-------|
| H1 | Web proxy: 127.0.0.1 unreachable from classic guest (should be 10.0.2.2); needs start-automatically toggle | U1 | |
| H2 | File browser sidebars: mixed theming; use native components | U4 | |
| H3 | Dump ROM opaque: needs modal (destination, format, name) + progress bar | U2 | |
| H4 | Update-guest-app-in-place sometimes fails to trash running app (hangs); needs progress + cancel | U2 | |
| H5 | Clicking already-open shelf should return it to its first tab module | U3 | |
| H6 | Spring-loaded drop needs spring-loaded animation | U3 | |
| H7 | Cannot spring-load into connections shelf (moves itself out of the way) | U3 | |
| H8 | Networking module immature: identity question; maybe host-machine shelf; add net diag/speed/latency (some exists in tbt) | U7 | |
| H9 | Development module: name and purpose unclear (build source on guest + classic dev project management; MCP surface, CLI later?) | U7 | |
| H10 | Files module host sidebar hover anim: chevron nudge → native subtle grow/bounce | U4 | |
| H11 | Chat needs sidebar for chats & projects | U6 | |
| H12 | Diagnostics module: earning its keep? add diags or remove | U7 | |
| H13 | Guest overview: storage should parse MB/GB/TB; processor should show type | U8 | |
| H14 | Connections: general cleanup/merge/reorg; machines list → right collapsible sidebar (own toggle, hover, best practices) | U5 | |
| H15 | Language pass: inconsistent/weird copy; use "This Mac" / "Guest" | U9 | |
| H16 | Shelf dropdown highlight: toggles on mouse-over, never un-highlights on leave | U3 | |
| H17 | Settings pass: move module controls into settings? or pill-tab settings + per-module settings button | U10 | |

### Guest

| ID | Item | Unit | Class |
|----|------|------|-------|
| G1 | General review of guest app as its own thing and as sibling to host; suggest improvements | U14 | |
| G2 | Development module: button label overflow; project registration + active project; build-job history (split list/detail); build/run buttons | U11 | |
| G3 | Chat: collapsible chats/projects list; transcript + prompt boxes white, not bg gray | U6 | |
| G4 | Networking: more useful than host side but identity/purpose crisis | U7 | |
| G5 | Diagnostics: same worth question as host | U7 | |
| G6 | Mirror: enable/disable/show-on-host only; toggles duplicated; merge into mirror+continuity control? screen shelf with screenshots? | U12 | |
| G7 | Files: messy; weird labels, unintuitive controls; take a pass | U12 | |
| G8 | Connection: send connect immediately after port/addr update; button reads "Disconnect" while connected | U5 | |
| G9 | Sibling semantic pass over guest app (with host's) | U9 | |
| G10 | Key (cmd-N?) to open Workshop; persist last open/close state | U13 | |
| G11 | File transfers to guest: native progress bar owned by rx (shows without Workshop); error handling; cancel | U13 | |

## Research units

| Unit | Scope | Tier | Status |
|------|-------|------|--------|
| U1 | Host web proxy | sonnet | pending |
| U2 | Host long-op UX (ROM dump, in-place update) | sonnet | pending |
| U3 | Shelf behaviors (open/return, spring-load, dropdown highlight) | sonnet | pending |
| U4 | Host files visuals (sidebar theming, hover anim) | sonnet | pending |
| U5 | Connections host+guest | sonnet | pending |
| U6 | Chat host+guest | sonnet | pending |
| U7 | Module identity: Networking / Development / Diagnostics, both sides | opus | pending |
| U8 | Guest overview formatting | sonnet | pending |
| U9 | Language/semantic pass, both apps | sonnet | pending |
| U10 | Settings inventory + restructure options | sonnet | pending |
| U11 | Guest development module | sonnet | pending |
| U12 | Guest files + mirror/screen restructure | sonnet | pending |
| U13 | Guest workshop shell + transfer progress | sonnet | pending |
| U14 | Guest app holistic/sibling review | opus | pending |

## Decisions log

(Empty — filled as items lock or discussions resolve.)
