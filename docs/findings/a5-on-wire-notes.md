# A5-on-wire audit notes (audit/a5-on-wire)

Lane: make a target application's A5 world reachable from the wire, so the
content plane's mandatory `arm_a5` (P3, qdtrace) is no longer an unarmable
dead end.

## Step 1 — confirming the finding

Confirmed against source, all three legs:

- `now-guest-ppc/src/content/qdtrace_cmd.c:215-227` — `qdtrace start` calls
  `now_qdtrace_arm_plan`, and on `kNowQDArmNoTarget` refuses with code
  `no-target` and exactly the "no arm-everything" message quoted in the
  brief. Confirmed verbatim.
- `contract/content_table.h` — the `arm_a5` field (declared at line 157,
  doc comment running 157-163, preceded by the commit-order block comment
  at 151-156) is documented as "the ONLY A5 world we will hook... a bound
  on count or duration is not a bound on scope." Confirmed: it is the
  target application's A5 world, mandatory.
- Grep for `"a5"` (the wire key) across `now-guest-ppc/src` turns up only
  `qdtrace_cmd.c:204` (parsing the caller's own input) and the echo at
  `qdtrace_cmd.c:256`. `qdtrace_json.c` echoes the armed/active a5 the same
  way (status echo of what was already sent/armed), not a fresh source.
  No verb anywhere else in the PPC guest emits an `a5` a caller could have
  obtained first. Confirmed: closed loop.

## Step 2 — where NOW already knows a process's A5

- `contract/peek_table.h` — anchor slot carries `a5` as field 1 in V1/V2/V3
  (unchanged across formats, per the file's own history comments).
- `now-guest-ppc/src/peek/peek_oracle.c` + `peek_oracle.h` — the anchor
  oracle (`now_peek_anchor_match`) resolves a process's partition to at
  most one anchor slot and answers with one of five verdicts:
  `kNowPeekAnchorOk`, `NotFound`, `Mismatch`, `Ambiguous`, `Stale`. Only
  `Ok` and `Stale` fill the match fields (including `a5`); the other three
  leave them zeroed "on purpose - there is no honest value to put in
  them."
- `now-guest-ppc/src/act/act_client.c:now_act_open` already calls the
  oracle a second time (deliberately, per its own comment: "the oracle is
  asked again here rather than a second answer being invented") to obtain
  `out->a5` for the act plane's internal use — but that value never
  reaches the wire; `now_act_open`'s only caller inside `act_cmds.c` uses
  it purely to submit into `now_act_submit`.
- `now-guest-ppc/src/axwalk/axprocess.c:now_ax_bind_process` also calls
  the oracle (its own comment says explicitly: "does not publish A5") and
  captures `window_list`, `menu_list`, `stamp_ticks` — but drops `a5` on
  the floor. `NowAxContext` (`axprocess.h`) carries `verdict` "carried
  through" from the oracle, so the raw 5-way verdict IS available to
  callers of this context, just not `a5` itself.
- `now-guest-ppc/src/observe/observe.c:emit_process_head` is the ONE JSON
  emitter shared by `observe`, `axtree`, `elements` and `axsnap` (all four
  wire commands funnel through `walk_reply` / this function per the "ONE
  MINTER, ONE WALK, ONE EMITTER" block comment at observe.c:604-616). It
  already emits `bind` (the collapsed `NowObsBindStatus`, which folds
  `Ok` and `Stale` into one "ok" word) but not the raw a5.

## Plan

1. `now-guest-ppc/src/axwalk/axprocess.h` — add `a5` to `NowAxContext`.
2. `now-guest-ppc/src/axwalk/axprocess.c` — capture `match.a5` into
   `out->a5` in `now_ax_bind_process`, in the same place `window_list`/
   `menu_list` are already captured (only reachable when the collapsed
   verdict is Ok, i.e. exactly when `match`'s fields are filled).
3. `now-guest-ppc/src/observe/observe.c:emit_process_head` — emit `"a5"`
   as a hex string (`"0x%08lx"`, matching qdtrace's own echo format) ONLY
   when `target->context.verdict == kNowPeekAnchorOk` — strictly Ok, not
   Stale, not any of the other three. Absence (field omitted from the
   JSON object), never `0`, on every other verdict.
4. `contract/asyncapi.yaml` — document the new field on both row shapes
   that share `emit_process_head`'s output: `x-axTree.processes[]` (used
   by observe/axtree/elements) and `axsnap.front`.
5. Tests: drive expected-absence from `peek_oracle.h`'s verdict enum, not
   from the code under test.

## Why Stale is excluded even though the oracle "vouches" for it

`peek_oracle.h` says Stale's fields (including `a5`) are "filled exactly
as for Ok" — the oracle does vouch for the VALUE. But the brief's
instruction (bullet 4) is explicit: not-found, mismatch, ambiguous, OR
STALE all mean absent. That's a stricter policy than "the oracle marked
these fields non-zero" — it's specifically about whether a caller should
be handed an A5 to go ARM something with. A stale anchor names a process
that has not pumped its event loop since the plane was armed; handing a
caller that A5 to feed into `qdtrace start`'s `arm_a5` would let them arm
tracing against a snapshot that might already describe a dead partition.
Freshness is a precondition for arming, not merely for observing, so this
lane draws the line at strict `Ok` — narrower than what the oracle's
"vouching" alone would justify, and stated here rather than left
implicit in a boolean.
