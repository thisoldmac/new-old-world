# Mirror ↔ MCP parity — what an agent can drive, and what only a hand can

**Status:** inventory taken 2026-08-04 against `7b3eceb`. Derived from the
source, not remembered — the commands that produce it are at the bottom.

This is the Mirror's version of [command-parity.md](command-parity.md).
That rule says every guest capability must be reachable from both the
console and the wire, with one implementation behind them, because
`process.list` shipped wire-only and nothing noticed. The Mirror has the
same two faces and the same exposure: a **person driving the Mirror
window**, and an **agent calling MCP**. They do not currently agree, and
worse, where they overlap they do not share an implementation.

## The two addressing worlds

This is the finding that matters more than any individual missing row.

| | Mirror window | MCP act rows |
|---|---|---|
| addresses | scene objects the state engine published — a window, a menu item, a desktop icon by name | opaque `now-element-…` refs minted by `now_observe_elements` |
| routes through | `MirrorActionExecutor` → `InteractionPlan` → broker → typed settlement | `AgentIntegrationActControl` straight to the guest's command dispatch |
| settles by | a later scene observation confirming a typed postcondition | nothing — a dispatch is all any row may claim |
| measured by | `MirrorActClocks` (`NOWBASE act`) | not measured |

So the two faces are not one capability with two doors; they are two
mechanisms that happen to move the same machine. An agent benchmarking
through MCP today measures a path **no person can take**, and a person's
gesture is invisible to every MCP reader. Closing this is worth more than
adding rows: rows added on the current MCP side would deepen the split.

## Read

| Mirror shows | MCP row | Drift |
|---|---|---|
| scene: windows, menus, processes | `now_mirror_snapshot` | — |
| snapshot identity, generations, coverage, freshness | `now_mirror_status` | — |
| find an element | `now_mirror_find` | — |
| wait for a newer snapshot | `now_mirror_wait` | — |
| **plane policy** (P1–P4 on/off, capability/requested/active bits) | none | **missing** |
| **resident identity** (lifecycle, build fingerprint) | none | **missing** — this is the one that cost a boot cycle on the PowerBook 1400c on 2026-08-04 |
| **act clocks** (wait/dispatch/settle/total, queue depth) | none | **missing** — added 2026-08-04, host-side only |
| **scene cycle clocks** (idle/request/decode, walk kind) | none | **missing** — same |
| **operation journal** (P4: every attempt and its outcome) | none | **missing** |

## Mutate

Every `InteractionPlan` case, against the MCP row that comes closest.

| Mirror plan | MCP row | Drift |
|---|---|---|
| `controlPart` | `now_control_act` | different ref grammar; no scene control is addressable (`Scene.Control.ref` is `""` from NOW's producer) |
| `windowAct` | `now_window_act` | different ref grammar |
| `menuCommand` | `now_menu_act` | closest to parity; identity check is a coordinate |
| `setText` | `now_text_set` | different ref grammar |
| `activateApp` | `now_bring_to_front` | approximate |
| `activateWindow` | — | **missing** as one operation |
| `dialogItem` | none | **missing** |
| `keystroke` | none | **missing** |
| `typeText` | none | **missing** |
| `applicationVisibility` (Hide / Hide Others / Show All) | none | **missing** |
| `openAppleMenuItem` | none | **missing** |
| `finderSelect` / `finderOpen` | `now_reveal_item` is adjacent, not equivalent | **missing** |
| `finderDeselect` | none | **missing** |

Mirror-window controls with no MCP equivalent at all: opening and closing
the Mirror, its scale, and the four plane switches.

## What to close, in order

1. **One executor behind both faces.** An MCP act should build an
   `Interaction`, go through `MirrorActionExecutor` and the broker, and
   settle from a scene observation — the same path a click takes. That
   makes the missing rows below mostly mechanical, and it makes an
   agent's measurement describe the product rather than a side door.
2. **Scene-object addressing for agents**, so a row can name what the
   snapshot already published instead of a second ref minted elsewhere.
3. The missing mutate rows, cheapest first once (1) exists.
4. The missing read rows — planes, resident identity, the two clock
   families, the journal. These are pure additions and unblock a
   headless benchmark today.

Two are worth calling out as **drift the Mirror itself should close**,
found while taking this inventory rather than added for MCP's sake:

- `Scene.Control.ref` is empty from NOW's producer, so no rendered
  control can be addressed by reference by either face. The Mirror hides
  this behind positional resolution; an agent cannot. **Measured
  2026-08-05** over the headless surface, against the guest's own
  Workshop window: **6 of 54 items carry an addressable ref**. The other
  48 — 30 static texts, 13 icons, the placards, the panel, the
  separator, the selection band — are drawn and unnameable. Slice 3 of
  [the plan](plans/2026-08-04-009-feat-now-headless-mirror-mcp-plan.md)
  cannot be complete until the producer mints them.
- The act clocks and the operation journal are visible in NOW's Mirror
  page but nowhere else, so an agent cannot tell a queued act from a slow
  one — the exact ambiguity the clocks were built to remove.

## Deriving this again

    grep -n "capability = HostCapabilityID" \
        now-host/Sources/NOWAgentIntegration/Projection/*.swift
    grep -n "case " \
        mirror/host/MirrorKit/Sources/MirrorKit/InteractionPolicy.swift
    grep -n "requiresTypedSettlement" -A 20 \
        now-host/Sources/Host/MirrorActionExecutor.swift

Do not hand-edit a row from memory; `docs/contract-coverage.md` carries
the same rule and the same reason.
