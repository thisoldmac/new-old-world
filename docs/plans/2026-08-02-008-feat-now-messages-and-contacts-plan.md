# Messages and Contacts: a 1993 Macintosh that texts

**Date:** 2026-08-02 · **Status:** plan only, nothing built ·
**Namespace:** `claude/`

A snapshot of intent, per [README](README.md). Where this and the code
disagree, the code is right; where this and
[open-issues.md](../open-issues.md) disagree, the ledger is right.

The pitch has been "a travel visa for Old World Macs" and the visa
office is [icloud.md](../icloud.md). Files, Photos and Contacts made
the old machine a *reader* of the modern world. Messages makes it a
**participant** — the first capability where the classic Mac does
something a person on the other end sees. It is also the first family
that carries live personal correspondence, which changes what the
honest defaults are.

## What v0 is, in one paragraph

While a guest is connected and the host person has switched Messages
on, the classic Mac can **send** an iMessage or SMS and **receive**
the ones that arrive. No backfill: the transcript begins when the
connection does. Recipients come from Contacts, so "message Ada" is
two clicks rather than a typed phone number, and an arriving message
says *Ada Lovelace*, not *+1 415 555 0142*. Plaintext on the wire, on
a desk-local LAN, stated rather than implied.

## The two halves are not symmetric, and that decides the design

**Sending has a supported door.** Messages.app takes Apple Events;
the `send` verb has worked since the Jaguar era and covers iMessage
and — when the person's iPhone forwards texts — SMS through the same
call. It needs the Automation TCC grant plus
`com.apple.security.automation.apple-events` in the entitlements file
(the hardened runtime denies it silently otherwise, exactly as it did
for Photos and Contacts on 2026-08-02; that trap is documented and
this plan inherits the fix).

**Receiving has no door at all.** There is no public API for inbound
messages. The workable route, and what every third-party tool does,
is reading `~/Library/Messages/chat.db` — SQLite, polled by a `ROWID`
watermark. That needs **Full Disk Access**, which has no entitlement
and cannot be requested programmatically: the person grants it in
System Settings or the feature does not run. Two consequences the
design must take seriously rather than paper over:

- the reader must degrade to an honest `no-access` with a sentence
  that says *where to go*, the way the Photos row already does;
- modern macOS often leaves `message.text` NULL and puts the body in
  `attributedBody`, an NSKeyedArchiver/typedstream blob. A decoder is
  required, and it is the single most fragile thing in this plan.

Because the halves differ, so do their failure modes: a send fails
loudly with Messages.app's own error, and a receive fails *quietly* by
never arriving. The UI must make the second visible — a Messages page
that cannot read says so at rest, not by looking idle.

## Where it lives

**Wire: a new `msg.*` family, not a cloud service.** The `cloud.*`
family is strictly ask/answer — guest asks, host answers — and
messages need the first **host-initiated push of live events** this
contract has carried. Bending ask/answer into push would cost the
property that makes the cloud family checkable.

**Consent: the existing cloud registry.** Messages reports itself as a
service (`serving` / `off` / `no-access` / `unavailable`) so the host's
iCloud page grows one more row with one more switch, and the guest's
service dropdown can say *why* Messages is missing. One consent
surface, already built, already understood.

**Guest: its own Workshop page (#13), not a page in iCloud.** A
transcript with a compose field is not a browser; forcing it into the
list/detail shell would fight every rule that shell keeps. The iCloud
page's Contacts view gains a **Message** button that switches to it —
which is the whole contacts integration, in one gesture.

## The wire

Four messages, additive, no revision bump (the `agent.access`
precedent: an older peer ignores what it cannot decode).

| Message | Direction | Carries |
|---|---|---|
| `msg.listen` | guest → host | `{id, on}` — start/stop the live feed. The host pushes **only** to a guest that asked, so a page nobody has open costs nothing |
| `msg.send` | guest → host | `{id, to, text}` — `to` is a handle (phone or email), never a display name |
| `msg.result` | host → guest | `{id, ok, code, reason}` — the send's outcome, carrying Messages.app's own failure text when it fails |
| `msg.incoming` | host → guest | `{handle, name, text, when, service}` — pushed while listening |

Notes that belong in the contract prose, not in a commit message:

- **`name` is resolved host-side.** The host has Contacts access; the
  guest must not need it, and must not have to join two services to
  draw one line. An unknown handle sends `name` absent, and the guest
  draws the handle — never a guessed name.
- **`when` is classic seconds**, unsigned, per the correction of
  2026-08-02. Anything else repeats a bug we have already paid for.
- **`service` is `imessage` or `sms`**, because a person cares which
  one carried it, and because SMS silently absent is a different
  problem from SMS failing.
- **Text is converted host-side** to MacRoman-expressible, composed,
  the way every other human-readable string in this project is.
  Emoji become `?` and that is honest; the alternative is mojibake on
  a machine that cannot draw them.
- **No attachments in v0.** An `attachments: n` count may ride
  `msg.incoming` so the transcript can say *[2 attachments]* rather
  than pretending a photo message was empty.

## Slices

Each is separately verifiable and separately abandonable. The order is
chosen so the **riskiest unknown is settled first**, before any
contract is written around it.

### Slice 0 — probe, before anything else

A throwaway spike under `spikes/messages-read/`: open `chat.db`
read-only, read the last few rows, decode one `attributedBody`, and
send one message to the developer's own number via Apple Events.
Deliverables are **findings, not code**: does the schema look as
documented on *this* macOS, does the typedstream decoder handle real
blobs, does the send need any prompt beyond the first grant. Nothing
downstream starts until this reports. Cost: an hour. Value: it decides
whether Slice 3 is a week or a month.

### Slice 1 — contract

The four messages, the `messages` entry in `x-cloud`'s service
registry, and the prose above. Contract-first, as always.

### Slice 2 — host: sending

Apple Events send, the entitlement, the service row and its switch on
the iCloud page, and `msg.result` mapping Messages.app's errors into
the contract's codes. Testable without a grant by unit-testing the
script construction and the error mapping; the send itself is
`probe-required` until a human clicks the Automation prompt.

### Slice 3 — host: receiving

The `chat.db` watcher: watermark by `ROWID`, poll on a timer while at
least one guest is listening, decode `text` or `attributedBody`,
resolve the handle through Contacts, convert, push. **Tested against a
fixture database** built in-test with the real schema — that is the
whole reason this slice is testable at all without the grant, and the
fixture is what proves paging, watermarks, and the NULL-text path.
Full Disk Access absent reports `no-access` with the System Settings
sentence.

### Slice 4 — guest: the Messages page

Workshop module #13. A transcript (the Console page's scrollback is
the pattern — hand-drawn canvas plus a scroll bar, already proven
three times), a recipient field, a text field, Send. Incoming lines
append and scroll. Everything decidable — line wrapping, the
transcript ring, the send-enable rule — is Toolbox-free and natively
tested, per the house split.

### Slice 5 — Contacts joins Messages

The contacts card gains **Message**, which switches to the Messages
page with the recipient filled in. A contact with several handles gets
a small chooser; a contact with one skips it. This is the slice that
makes the feature feel like it belongs to the machine rather than
sitting beside it, and it is deliberately last: it is worth nothing
until both halves work.

### Slice 6 — arrival, when the page is not open

A Notification Manager mark or a sidebar badge, so "your iPhone
buzzed a System 7 machine" does not require staring at the page. The
demo is the moment, and the moment is worthless if it is invisible.

## What v0 excludes, deliberately

Backfill, attachments, group threads (read-only at best; sending to a
group is not v0), read receipts, typing indicators, editing or
unsending, and **encryption on the wire**. Each is a decision, not an
oversight, and each belongs in the ledger the day the slice lands.

## The risks, ranked

1. **`attributedBody` decoding.** The one place where Apple can break
   us without warning. Mitigation: a message whose body cannot be
   decoded is delivered as `[unreadable]` with its metadata intact —
   the transcript stays honest and the failure is visible rather than
   silent. Slice 0 tells us how bad this really is.
2. **Full Disk Access.** Heaviest grant in the project. Mitigation is
   honesty, not cleverness: the row says exactly what is missing and
   where the switch lives, and every other service keeps working
   without it.
3. **Volume.** A busy account can produce more traffic than a 1993
   machine wants. The push is bounded — a cap per poll, and a
   transcript ring that drops the oldest — and both bounds are stated
   in the UI rather than silently swallowed.
4. **Plaintext.** The wire is a desk-local LAN, which is the standing
   threat model ([SECURITY.md](../../SECURITY.md)). But this is
   personal correspondence, and it is the family that should force the
   encryption conversation. It goes in the ledger the day Slice 3
   lands, phrased as a decision with a date, not a someday.
5. **Never send unbidden.** NOW composes nothing and sends nothing on
   its own. A message leaves this machine because a person at the
   classic Mac typed it and pressed Send. Worth stating in the code,
   not only here.

## Privacy rules this feature introduces

- **Message bodies are never written to disk by NOW** — not to
  `now-logs`, not to the host's log, not to a cache. The transcript is
  in memory and dies with the page.
- **The host log records that a message arrived, never what it said.**
- **The guest's own log follows the same rule**, which is the one a
  future contributor will break first, because the guest logs
  liberally everywhere else.

## What would make this stop

- Slice 0 finds `attributedBody` unreadable without private frameworks
  → the receive half is not viable as designed, and the honest product
  is send-only, said out loud.
- The Automation grant proves unreliable across macOS versions → the
  same, in the other direction.
- Either half needs a private API → stop. The project has refused one
  private API already this week (the photos byte-size KVC) and the
  reasoning holds here with more force, not less.
