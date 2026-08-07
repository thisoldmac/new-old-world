# Every lane's own ports

A **lane** is one agent or human working in one git worktree. On a busy
day there are a dozen of them on this Mac, each wanting a guest VM and a
host app, and each of those wants two TCP ports: an *anchor* (the QEMU
hostfwd to the guest's worker on 1400) and a *wire* (the host listener
the guest dials at `10.0.2.2:<wire>`).

    tools/lane-ports                    # what are my ports?
    eval "$(tools/lane-ports --env)"    # …as NOW_ANCHOR_PORT / NOW_WIRE_PORT
    tools/lane-ports whose --port 17649 # whose port is this?
    tools/lane-ports list               # every lane, and what is running
    tools/lane-ports reclaim            # take my own block back
    tools/lane-ports gc                 # drop claims whose worktree is gone

`scripts/spin-up-ppc` already does this for you. You only need the tool
directly to answer a question or to clean up.

## What this replaces, and what it cost

Until 2026-08-07 the ports were assigned **by hand**, by whichever
session was coordinating: 1700/5250, 1710/5260, 1720/5270, up to
1890/5440. That is not a scheme, it is one session holding a dozen
allocations in its head, and on 2026-08-06 it failed three ways in a
single day:

- **A lane lost its run to an orphan.** Port 1840 was held by a VM
  orphaned by a host crash — a machine nobody owned any more, and which
  no lane had standing to stop.
- **`HostMachineGuardTests` went red for lane after lane** because a
  *different* lane's QEMU was up. Under user-mode networking the guest's
  outbound connection belongs to the `qemu` process, so `lsof` on a wire
  port names QEMU itself; the guard could say a port was busy and
  nothing more.
- **An agent then re-diagnosed that three separate ways**, because a busy
  machine looks exactly like a defect in your own change.

All three are one missing fact: *which lane does this port belong to?*
Make that answerable and each of them becomes a sentence instead of an
investigation.

## The scheme

**A lane is its git worktree root** — an absolute path, unique by
construction (two lanes cannot share a worktree), stable for the lane's
life, and knowable from inside the lane with no coordinator. Not the
branch name: branches get renamed, get checked out in two places, and are
empty in a detached HEAD.

That path **hashes to a block of 8 consecutive ports** in 12000–19999:

| offset | name       | what it is                                   |
|--------|------------|----------------------------------------------|
| +0     | `anchor`   | QEMU hostfwd to the guest's anchor worker    |
| +1     | `wire`     | the host listener the guest dials            |
| +2     | `anchor_b` | a second VM in the same lane — A/B drives    |
| +3     | `wire_b`   | that second VM's wire                        |
| +4     | `metal`    | `NOW_METAL_PORT` for this lane               |
| +5..+7 | `spare0-2` |                                              |

Then a **claim file** (`/private/tmp/now-lanes/<block>.json`, created
`O_EXCL`) makes it exact, and a taken block is probed past
deterministically.

### Why both, and not either alone

A hash needs no cleanup and has no liveness; a registry has liveness and
can say who owns what, but goes stale. Both were considered on their own
and neither is enough:

- **Hash alone collides.** 1000 blocks and fifteen lanes is a ~10% chance
  that two of them land together — and "usually collision-free" is
  precisely what the hand-assigned scheme already was.
- **Registry alone goes stale**, exactly the way the `/private/tmp/nowvm-*`
  run directories did: 11 GB of them outliving their VMs on the same day.
  A lane whose claim was swept would move, and a moved lane can no longer
  find its own running VM.

Used together, the hash is the primary and the registry is the
correction. **Wipe the registry entirely and every lane lands back on the
block it had** (`test_a_wiped_registry_does_not_move_a_lane`), because the
hash did not change. And a stale claim is *harmless*: a block is only
ever asked for by the one lane that hashes to it, which is the block's
owner anyway.

### Why 12000–19999

It is defined by what it has to avoid, in both directions:

- **Below 20000**, because `HostAppStateTestSupport.testListenPort` draws
  from 20000–40000 keyed on the pid, and macOS draws every ephemeral port
  from 49152–65535. A lane range inside either would be taken from the
  lane by its own test process.
- **Above everything this project spells by hand**: 1400 (the guest-side
  anchor worker), 1700+ (the hand-assigned hostfwds), 5250–5253 (the
  product's wire and the metal harnesses). Those keep working untouched,
  which is what lets a lane already in flight on a hand-assigned pair
  finish undisturbed.

Both are gated (`RegionTests`), because a region is the kind of constant
that drifts quietly and is discovered by a collision.

## Orphans

**A block belongs to one lane, deterministically.** So a VM orphaned
inside a block can only ever be in *that lane's* way, and the lane that
finds it in the way is guaranteed to be the lane that started it. There
is no "whose is this?" left to ask, and no human needed to decide.

`tools/lane-ports reclaim` therefore acts on **your own block** by
default, and refuses another lane's without `--force` — you should never
need theirs.

It stops a machine **through QMP by socket path**, recorded at boot by
`spin-up-ppc`'s `attach` call, *before* the boot so that a run which dies
halfway still leaves a handle. In order:

1. `tools/shutdown-guest.py` — the guest-clean route: the staged applet
   calls the Shutdown Manager from inside the Macintosh and the volume is
   marked clean.
2. If that fails, the VM is **left running** and you are told to look at
   it. `--power-cut` accepts a QMP `quit` instead, and prints what that
   costs: the next boot of that image spends its first minutes in Disk
   First Aid.

It **never** kills by port. `lsof -ti tcp:<wire>` matches QEMU itself, so
killing what holds a wire port kills the whole machine — done by accident
2026-08-03. That is gated: `test_reclamation_goes_through_qmp_by_socket_path_never_by_port`
parses the reclaim path through `ast` and fails on `kill`, `pkill`,
`lsof` or a signal.

Three liveness states, and only one of them is reclaimable by `gc`:

| state    | meaning                                        | `gc` |
|----------|------------------------------------------------|------|
| `busy`   | a port is held, or a QMP socket answers        | left |
| `idle`   | worktree still there, nothing running          | left |
| `orphan` | worktree **gone** and nothing running          | reaped, with its run dirs |

A busy block whose worktree is gone stays `busy`. Stopping a machine is
`reclaim`'s decision and it is made by the owner, not by a garbage
collector.

## What the machine guards now say

`HostMachineGuardTests` and `MetalMachineGuard` still **fail** on a held
port — knowing whose it is does not make it safe to measure a machine
somebody is using. What changed is that they now say *which of three
situations this is*, and each has a different next step:

- **Your own block.** "Whatever holds it was started by this lane — most
  likely a VM orphaned by a crashed session. `tools/lane-ports reclaim`."
- **Another lane's block.** Names the branch and worktree, and does *not*
  suggest reclaiming it — that is the collision the scheme removes.
  Points you at your own ports instead.
- **No lane claims it.** Says plainly that the holder cannot be
  attributed from here, which is the honest answer for a hand-assigned
  port and the exact state that cost 2026-08-06.

`HostMachineGuardTests` also prints this lane's block and anything
running in it. Deliberately a report and not an assertion: a lane's VM
holding the lane's own anchor and wire is a *working* spin-up, and
`swift test` binds neither. Failing for it would be a guard that stops
honest work, which is how a guard gets routed around.

## Adopting it

Nothing is required. The scheme is additive in three places, all gated by
`AdditiveTests`:

- an explicitly-passed `NOW_ANCHOR_PORT` / `NOW_WIRE_PORT` still wins,
  and is read *before* the derivation runs, because `--env` sets those
  same names;
- `spin-up-ppc` falls back to the old 1700/5250 defaults when the tool is
  absent;
- a machine already booted is untouched — this changes what a *new* boot
  chooses.

`NOW_LANE_REGISTRY` and `NOW_LANE_PORT_BASE` move the registry and the
region, which is how the tests run without touching the real one.
