# Raising the unknown-creator modal, on demand

[Plan 018](plans/2026-08-06-018-feat-stable-honest-render-plan.md) lists
"unknown-creator / open-with modal renders nothing at all" as defect #7,
and [sweep A](fidelity-sweep-2026-08-07-a.md) could not score it either
way:

> not reproduced; I could not force one. Slice 3 needs a reliable way to
> raise it (a file with a garbage creator) before this can be scored
> either way.

This page is that way. It is a rig procedure, not a product feature: it
belongs to whoever is running a fidelity sweep or driving the Mirror, and
sweep B is expected to use it verbatim.

## The procedure

Two commands against a booted guest.

```sh
# 1. Put a document on the desktop that nothing on the volume owns.
NOW_ANCHOR_PORT=1740 tools/stage-orphan-doc.py

# 2. Open it the way a person would — a Finder open of a desktop item.
tools/askguest.py --port 5290 --wait 120 \
  'script:source=tell application "Finder" to open item "Orphan Document" of desktop'
```

Step 2 answers `timeout` — **that is the success case, not a failure.**
The Finder raises a modal alert and stops answering Apple Events, so the
guest's `script` verb hits its own deadline with the work done. The alert
is up from that moment.

What appears (verified by QMP screendump, emulator, 2026-08-07):

- A `dBoxProc` stop alert owned by the **Finder**, one OK button, no
  title: *"The document "Orphan Document" could not be opened, because
  the application program that created it could not be found."* with the
  second line *"Could not find a translation extension with appropriate
  translators."*
- If the Finder is not frontmost, the alert is drawn behind whatever is,
  and the **Notification Manager** puts up its own floating bar: *"The
  Finder needs your attention. Please select the Finder from the
  Application menu."* That bar is a separate window class from the alert
  and is worth capturing in its own right.

## Two things that decide whether it works at all

**Both the type and the creator must be orphans.** The Finder falls back
to the file TYPE when the creator is unknown, so a document typed `TEXT`
with a garbage creator opens in SimpleText and raises nothing. The tool
defaults both to `ZZZZ` and **refuses the run** if the guest reads the
staged file back with any other pair — a green stage that measured
nothing is the failure this check exists to prevent.

**The Finder must be able to see the file.** The anchor worker writes it
behind the Finder's back. Two ways to settle that:

- The AppleScript in step 2 resolves `item "Orphan Document" of desktop`
  through the Finder's own model, which reads the desktop folder from
  disk — so it works even when the desktop has not redrawn. That is why
  step 2 is an AppleScript open rather than a click, and it is the
  cheapest path.
- `tools/stage-orphan-doc.py --refresh-wire 5290` asks the Finder to
  `update` the desktop folder first, for a driver that wants the icon
  actually drawn. A cold reboot does the same and is never in doubt.

## Dismissing it

`ditemact` / `mirror_drive --gesture dialogItem` is the product path and
is the one a sweep should try first — sweep A dismissed Mail's modal that
way in 7.6 s.

Where that cannot be reached, **QMP `send-key` works on this machine**,
and that is worth writing down because the rig's own notes say it should
not: `scripts/spin-up-ppc` states that "QMP keyboard events do not arrive
on mac99 (`has-adb=false`, so no ADB keyboard and no power key)". That is
true of the *ADB* keyboard; the profile also attaches `-device usb-kbd`,
and a Return through it dismissed this alert on the first try, twice
(2026-08-07). So:

```sh
python3 - <<'PY'
import json, socket
s = socket.socket(socket.AF_UNIX); s.connect("/private/tmp/nowvm-<yours>/qmp.sock")
f = s.makefile("rw"); f.readline()
f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush(); f.readline()
f.write(json.dumps({"execute": "send-key",
                    "arguments": {"keys": [{"type": "qcode", "data": "ret"}]}}) + "\n")
f.flush(); print(f.readline())
PY
```

That is a **manual VM override** in the sense plan 018 authorises: record
that you used it. It presses the alert's default button and nothing else;
it is not a substitute for proving the Mirror can dismiss the window.

## Why it must be dismissed before anything else is measured

While the alert is up the Finder is inside `ModalDialog` and answers no
Apple Events. Everything the Mirror reads from the Finder by script — the
desktop item roster, a window's contents, a view switch — stalls until it
is cleared, and if the Finder is *frontmost* while blocked it starves
NOW's own event loop badly enough to drop the wire (watched: the guest's
Connection panel fell back to "Retry in 4 s" and a `scene.request` timed
out at 45 s). So: raise it with **NOW frontmost**, capture, dismiss,
and only then measure anything else.
