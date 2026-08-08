# Four defects to clear before the merge

**Reported by Michelle, 2026-08-08, metal session.** Filed, not fixed.
Two new here; two already have their own pages and are cross-referenced
because the evidence overlaps.

## 1. The host Files module is completely broken

**Not agent-introduced.** Michelle's own account, recorded because
provenance matters when someone later goes looking for the commit that
did it:

> this was my fault, not yours, i merged changes to this pane without
> fully tested and you inherited when you pulled main

So the search starts at the merge that brought the pane in from `main`,
not in this arc's lanes.

**The guest logs already show it, in every session that ran long enough.**
From the four PowerBook logs of 2026-08-08:

```
01:00:50  files ? #31   refused: not-found (no such item in the share)
01:06:05  files ? #148  refused: not-found (no such item in the share)
01:39:13  files ? #12   refused: not-found (no such item in the share)
```

That is `wire.c:2511`. The guest is answering honestly — it looked in the
share and the item is not there. The defect is on the host side of the
request.

### This corrects something said earlier tonight

Reading these logs, I told Michelle that two of the four sessions "die
immediately after the files refusal", and offered that as a lead. **That
evidence is much weaker than I made it sound.** The refusal appears in
every session that reached the software sweep — three of four — and one
of those sessions survives it and keeps running for another twelve
minutes. A line that appears in nearly every log is not explained by the
two logs it happens to end.

The proximity was real; the inference was not. Recorded because it is the
second time tonight the same mistake was made — taking a true observation
and promoting it to a cause because it sat near the thing being looked
for.

## 2. The guest Mirror module redraws about every 700 ms

Reported from the machine. On a 117 MHz 603e this is not free, and the
Mirror page is static text — lifecycle, resident version, plane bits,
build, and five plane rows. Nothing on it changes at that rate.

Where to look: `now-guest-ppc/src/mirror/mirror_show.c` draws the page and
contains **no cadence of its own** — no tick comparison, no idle
handling. So the repaint is being driven from outside it, by the
Workshop module's idle hook or by a poll that invalidates the page
whether or not anything changed.

The rule this breaks is the one every Workshop module is meant to keep: a
page redraws when its content changes, not when a timer fires. The fix is
to make the repaint conditional on the plane facts actually differing
from what is on screen, which is the same shadow-and-delta shape
`now_content.c` already uses for port state.

Worth measuring rather than assuming: 700 ms is suspiciously close to a
poll interval, and naming which one is most of the fix.

## 3. Stopping the Mirror pauses instead of disconnecting

Its own page: [mirror-stop-should-disconnect.md](mirror-stop-should-disconnect.md).
Stop should end the session; pause should be a separate explicit control;
module switching already pauses and that case is correct.

## 4. Mirror crashes NOW on the PowerBook

Its own page: [mirror-crashes-now-on-metal.md](mirror-crashes-now-on-metal.md).

**The logs add one thing to that page, and it is the important one: the
Mirror path writes no log line at all.** There is no `mirror`, `peek`,
`plane`, `scene` or `content` log tag anywhere in `now-guest-ppc/src`. So
the four logs from the crashing session cannot show the crash — only what
NOW was doing when it stopped.

That is why six mechanisms could be read out of the source and none
falsified. **Giving the Mirror path a log tag is worth more than any
further reading**, because it is the difference between the next metal
attempt producing evidence and producing another theory.

What the logs do localize, precisely, is the app-switcher death:

```
01:27:52  mach #1245 activate 0.8781826 [fronted] Finder   ← last line
```

Written at `mach_activate.c:151`, immediately before
`now_mach_reply_rows`. NOW fronted the Finder, logged the success, and
died composing the reply.

## Status

All four filed, none fixed, none reproduced by a test.
