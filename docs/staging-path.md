# Installing the NOW Extension, and what the guest then said

Status: **ran on a mac99 emulator, 2026-08-01.** Nothing here has executed
on physical hardware, and no claim below extends past the emulated machine
it was measured on.

## The gap

`scripts/build-guests` has compiled `ext/` since 2026-07-31 and, until this
work, nothing in the repository installed it. `tools/` held `fakeguest.py`
and `mb_rename.py`; `scripts/deploy-68k` puts a 68K *application* on a real
Mac over FTP and never mentions the Extensions folder; there was no PowerPC
deploy path at all.

Three of NOW's four planes live in that INIT — P1 anchors, P3 content, P4
act — so the consequence was not "the extension is untested" but "the
extension has never been resident on any machine, anywhere". `qdtrace`
answered `content-plane-absent` everywhere and `actselftest`, which
[emu-readiness.md](emu-readiness.md) makes a hard precondition *because a
wrong trap ABI does not crash, it lies*, could not be run at all.

## The path

    scripts/build-guests            # builds ext/ and now-guest-ppc
    scripts/spin-up-ppc             # one command, emulator only

| Piece | What it does |
| --- | --- |
| `tools/stage-ext.py` | Pushes `NowExt.bin` into `System Folder:Extensions` and the app beside it, through the lab's baked anchor worker. Verifies **by fork size and Finder type**, read back off the guest. |
| `scripts/spin-up-ppc` | Fresh session-private clone → stage → **guest-clean shutdown and relaunch** → re-verify → launch NOW → interrogate. |
| `tools/guest-shutdown` | A 68K applet whose whole body is `ShutDwnPower()`. Staged like the extension; it is how the Macintosh is asked to shut ITSELF down. |
| `tools/shutdown-guest.py` | Quits the front application, launches that applet through the worker, waits for QEMU to exit. Never `quit`. |
| `tools/askguest.py` | Listens as a NOW host, takes the dialling guest, asks verbs, prints answers verbatim. `fakeguest.py`'s mirror image. |

Ported from `archive/mirror-standalone-2026-08-09/tools/` (upstream `5c822b0`, `f42cb09`, `a82cc8f`),
keeping every rule that hardening encodes: an INIT loads at boot **only**
and OS 9 ignores a soft power-down, so the machine has to be reboot**ed**
rather than resumed; let the post-reboot `stat` be the guardrail; verify by
fork size, never by exit code; tolerate exactly `catalog dates err -43` (a
measured anchor quirk) and still require the verify to pass; walk `mkdir`'s
chain because it is `FSpDirCreate`; probe ports free rather than assume
them; clone the base image, never boot it.

**One rule was later found to be wrong, and it was this one.** The ported
reboot was a QMP `quit`, which is a power cut: it sets the volume's
unclean bit, so every cycle began with a Disk First Aid pass on the disk
it was about to measure. Asking the guest instead needs a route into a
machine whose human interface nothing outside can reach — no QMP key
event arrives, there is no absolute pointer, a posted click cannot select
from a menu, and the canonical anchor worker has no `script` verb. So NOW
stages an applet that calls the Shutdown Manager. Measured 2026-08-05:
launch to QEMU exit, 6 s; the next boot reached the anchor in 42 s with no
Disk First Aid, against 161 s for a boot after a power cut.
[open-issues.md](open-issues.md) carries what else that ruled out.

**One thing could not be ported.** NOW's wire runs *guest → host*: the guest
dials, defaulting to `10.0.2.2:5250` (`prefs.c` `set_defaults`,
`kNowDefaultHostPort`), which under QEMU user-mode networking is the host
Mac's loopback. So an unconfigured guest finds a listener with no
preferences file and no port forward — and the mirror's client-side
verifier had to become a listener.

## What the guest said

Verbatim, from a clean run (fresh clone, cold reboot, `exit 0`):

    hello: {"side":"guest","version":"0.1.0","build":"Aug  1 2026 02:21:36",
            "name":"Power Mac G4","os":"9","chunk":8192}

    qdtrace op=status  ->  ok
      "plane": {"format": 1, "length": 65676, "ringCap": 65536}
      ring/ops/loss/lifecycle counters all present and zero

    actselftest  ->  ok
      Process     New Old World
      A5          0x1F21CB40
      Verdict     abi-agreed
      Answered    0x03E70007
      Read back   0x03E70007
      Mechanism   a real MenuSelect at (0,0), made and answered inside
                  the target process

**Why the `qdtrace` answer is proof and "the file is in the folder" is
not.** The plane block is allocated and published by the extension at boot,
and reached only through Gestalt selector `'NWex'`. With no INIT resident,
`qdtrace_json.c` answers `content-plane-absent`. A block with a real
`format`, `length` and `ringCap` cannot be produced by an application that
found nothing.

`actselftest`'s verdict is the stronger one and also the narrower: the
patch answered `0x03E70007` and the application read back exactly
`0x03E70007`, so **the trap calling convention holds in that process, on
that emulated machine**. It says nothing about any other process and
nothing whatever about metal.

## The one failure worth keeping

The **first** `actselftest` after the launch answered
`no-such-process`, and `axsnap` at the same moment reported the front
process bound `"no-plane"`. Seconds later the identical call answered
`abi-agreed`. The extension anchors a process when that process first pumps
an event, so a freshly launched application is briefly invisible to the
anchor plane.

This is a settle window, not a defect — but it is a *dangerous* one,
because reporting that first answer means reporting a failure of the trap
ABI that did not happen, which is the exact class of lie `actselftest`
exists to catch. `spin-up-ppc` therefore retries, and `askguest.py`'s
`--retries` carries the reason in a comment rather than leaving a bare
sleep for someone to tidy away.

## What this does not do

- It does not touch metal, and is not a route to doing so. `deploy-68k` is
  the metal path and it is attended.
- It does not *uninstall*. Recovery from a bad extension is a shift-boot,
  which on an emulator is why the clone is disposable and on metal is why
  [emu-readiness.md](emu-readiness.md) asks for it to be rehearsed first.
- It does not arm the content plane. `qdtrace status` shows the ring at
  `mode: "off"` with zero ops — the plane is *present and discoverable*,
  which is a different claim from *exercised*.
