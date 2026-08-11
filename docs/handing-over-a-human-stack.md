# Handing a stack to a person

A **human stack** is a host app and a guest VM that a *person* is going
to sit in front of and drive. It is not a lane's rig with a friendlier
label, and the difference is not cosmetic: a lane drives its guest over
a wire and never looks at it, while a person needs a screen, a pointer,
and a way out of whatever the machine puts in front of them.

This page is the checklist. It exists because on 2026-08-07 a lane was
asked to hand Michelle a stack, **followed its brief exactly**, and gave
her a VM booted `-display none`. A modal alert came up in Mail — *"Is
your computer set up for Internet access?"* — and she had no window to
click **No** in. The one remaining route, the act plane, was refusing
those buttons. The stack was, from her side, simply stuck.

Nothing was misconfigured. Headless is the correct default for a lane,
and no step in the brief said *"and give her a screen"*, because a
default nobody states is a default nobody checks.

## What a human stack requires

Four things, and the first is the one that gets forgotten:

1. **A display.** `NOW_SPIN_DISPLAY=1`. Without it there is no route to
   the guest that a person can use: QMP is an observation channel, not
   an input one on this rig (`mac99,via=pmu` has no ADB keyboard and no
   absolute pointer — see `tools/shutdown-guest.py`'s header), and the
   wire only reaches what the app already implements. A headless guest
   is drivable by a lane and by nobody else.
2. **Ports in the reserved human range**, 16720–16799. `tools/lane-ports`
   skips these in `allocate()`, so no lane can ever be handed them.
   Michelle's stack is block **591** — anchor `16728`, wire `16729`.
   `tools/lane-ports human` reports it read-only.
3. **Isolation suffixes**, both of them: `NOW_AGENT_SOCKET_SUFFIX` and
   `NOW_PREFS_SUFFIX`. A port block stops a lane *binding* her sockets;
   it does not stop a lane *driving* her app. There is one `now-agent`
   socket per user. `docs/arc-coordination.md` has the table of which
   knob covers what.
4. **A session-private run directory**, hers, that no lane reuses — and
   that nobody deletes without looking inside it first.

## The display is enforced, not remembered

`scripts/spin-up-ppc` decides this from the **ports**, which already know
whose machine it is:

- Anchor in the reserved human range → a window is the default, and the
  script says so on the way past.
- Anchor in that range **and** `NOW_SPIN_DISPLAY=0` → it **refuses**
  (exit 64) and names why, before it clones the image. "I explicitly
  passed 0" is not a reason to hand a person a machine they cannot see.
- `NOW_HUMAN_STACK=0` declares that this really is not a person's stack.
  That is a statement, not a knob — and it is the only way past.

The predicate is `tools/lane-ports human --is-human <port>`, silent and
exit-coded, so the range stays stated in exactly one place. A shell
script that restated 590–599 would be a second copy to drift.

Both halves are covered by `tools/mirror-gate-tests/test_lane_ports.py`,
and the display guard is tested by **running** `spin-up-ppc`, not by
reading it: a text assertion would survive an edit that moved the check
after the boot, which is where it would stop mattering.

## The lane that BUILDS it records it against its own block

A person's stack is booted by a lane, on the reserved ports — and
`spin-up-ppc` then calls `tools/lane-ports attach`, which files the VM's
QMP socket and run directory under **the building lane's** block, not
under 591. The ports are hers; the *claim* is the lane's.

So after handing over, `tools/lane-ports reclaim` on that lane — run by a
worktree sweep, or by the next session to inherit the branch — shuts down
**her machine**, correctly, from a record that says it is the lane's.
Nobody would be careless: the tool is doing exactly what the registry
says.

**Clear the two fields before you walk away** (`qmpSockets`, `runDirs` in
`/private/tmp/now-lanes/<block>.json`) and leave a note in their place
saying where the machine actually is. Her stack is not an unrecorded
orphan when you do — `tools/lane-ports whose --port 16729` finds it
through `lsof` and names the reserved range, which is the answer a person
looking for it wants anyway.

Observed 2026-08-07 while building the stack this page exists for: block
591's VM was filed under block 578.

## Replacing a running human stack

Order matters, and one step is not the order you would guess.

1. **Copy anything of hers out of the run directory first.** A session
   clone and its `provenance.json` / `staged.json` are the rig's; a file
   she put there is not.
2. **Quit the host app first, by path — never by port.** `lsof -ti
   tcp:<wire>` matches *QEMU itself* under user-mode networking, so
   killing by port kills the VM. Quitting the app first also frees the
   wire, which the next step needs to bind.
3. **Shut the guest down guest-clean**: `tools/shutdown-guest.py
   <qmp.sock> --port <anchor> --wire <wire>`. **Never QMP `quit`** —
   that is a power cut and it is the root of this project's dirty-image
   class. If the graceful route refuses, stop and report rather than
   power-cutting.
4. **Relaunch on the same ports, the same suffixes, and with a display.**
5. **Look at it.** Take a screendump before saying it is ready: desktop
   up, no Disk First Aid pass, no modal left over.

### A modal in the front application blocks the clean route

Step 3's primary route is the Finder's own **Special ▸ Shut Down**,
driven through the act plane, and it is the only route measured to leave
a clean volume. It needs the Finder to *be* the front application. When
Mail owned the menu bar behind that alert, the route reported

```
  the menu bar belongs to 'Mail', not the Finder
  the Finder route did not take; falling back to the applet
```

and fell back to the staged applet, which shut the machine down but is
known to leave the volume marked mounted. **That is acceptable for a
session clone and never for the shared stage image.** So: a stuck modal
on a human stack costs you the clean-shutdown route as well as the
stack, and the cure for the volume bit is that the clone is thrown away
— not a power cut.

## Related

- [`docs/lane-ports.md`](lane-ports.md) — the port scheme itself.
- [`docs/arc-coordination.md`](arc-coordination.md) — the reserved range,
  and the three isolation knobs it is not.
- [`docs/68k-metal-runbook.md`](68k-metal-runbook.md) — the same class of
  rule for real hardware, where the machine is shared and physical.
