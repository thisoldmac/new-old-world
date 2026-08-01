# A person at the guest cannot stop a download they started

Status: investigation + implementation notes. 2026-07-31.

## The defect

From a manual pass on a real machine: *"Files on the guest side: double click
downloads the file with no way of cancelling the transfer."*

`now_transfer_cancel` exists on the host's projection surface, so an **agent**
can cancel. The person sitting at the Macintosh — the only party who can see
the machine — cannot. That inverts rule 3.

## First question: does the transfer path pump the event loop?

**Yes.** A pull is asynchronous end to end; nothing blocks. Evidence, all
read from source:

| Step | Where | What it does |
| --- | --- | --- |
| double-click | `files/files_browser_view.c` `item_notify` → `open_row` | calls `now_wire_get_host` and **returns** |
| the ask | `core/wire.c:2012` `now_wire_get_host` | one `send_control` frame, sets `g_get.pending`, returns 0 |
| the bytes | `core/wire.c` `get_begin` / chunk path (`now_files_receive_chunk`, ~2651) | driven by inbound frames, one chunk per service pass |
| the pump | `main.c:403` | `while (g_running) { conn_service(); workshop_idle(); ...; WaitNextEvent(...) }` |
| service | `core/wire.c:4794` `conn_service` → `service_browse()`, `service_get()` | called at the top of **every** loop pass |

So `WaitNextEvent` is reached between every chunk. `mouseDown` is delivered
normally while a pull runs. A button in the Files pane **can** be clicked
mid-transfer — this is not the synchronous-probe shape that bit the repo
earlier today (a ~3 s call that never reached the event loop).

Corroborating evidence that the design already assumes this: `files_browser_idle()`
(`files_browser_view.c:417`) is documented as running "every event-loop pass
while a pull is running" and repaints a `Getting... N% of N K` note from
`now_wire_get_active()`. That progress display only works because the loop
turns during the transfer.

## Progress is already tracked guest-side

`Boolean now_wire_get_active(long *received, long *expected)` (`wire.h:147`,
`wire.c:1998`) is the single existing notion of "a pull is in flight":

- `pending` = asked, no bytes yet → `received` reported as 0
- `receiving` = `file.begin` seen, writing → `received` = `g_get.rx.received`
- `expected` = `bytes` from the host's `file.begin`, 0 when unknown

There is no second notion to add. The cancel UI reads this same call.

## What a cancel must leave behind

`get_cleanup(Boolean keep_file)` (`wire.c:1989`) is the one teardown, and it is
what every existing failure path already uses (timeout in `service_get`, a
`file.end` with `ok:false`, a downloads-folder failure). With `keep_file` false
it calls `now_files_receive_abort(&g_get.rx)`.

`now_files_receive_abort` (`fileshare.h:221`) closes the open forks and
**deletes the temp** unless the transfer is resumable. A pull is never
resumable — `get_begin` passes `resume_token = NULL, resume_offset = 0`
explicitly ("a pull starts at zero"), so `keep_partial` is false and the temp
is deleted. Bytes land under a temp name and are only renamed into place on
`now_files_receive_finish`, so **a cancelled pull leaves no partial file under
the real name**. Nothing half-written is left for a person to double-click.

That is the semantics a guest-side cancel must match: same `get_cleanup(false)`,
no new teardown path.

## What was built (2026-07-31)

Everything except the wire primitive, which lives in a file this thread does not
own.

| Piece | Where | What it is |
| --- | --- | --- |
| the pull's story | `now-guest-ppc/src/files/files_pull.{c,h}` | Toolbox-free: the phase machine, the wording, the percentage, the repaint gate, the arming rule |
| its test | `now-guest-ppc/tests/files_pull_test.c` | 43rd native test; ten mutations watched failing |
| the Stop button | `now-guest-ppc/src/files/files_module.c` | a push button at the right end of the path row, hidden unless a pull is live |
| starting a pull | `now-guest-ppc/src/files/files_browser_view.c` | `open_row` now says what it is doing before it asks |

### What the person sees, and when

| Moment | Line | Drawn |
| --- | --- | --- |
| double-click (or Return) | `Asking for Report.cwk...` | **directly, in that click** — `paint_transfer_now()` |
| the sender answers | `Getting Report.cwk - 42% of 812 K` | idle, once per whole percent |
| the sender gave no size | `Getting Report.cwk - 96 K so far` | idle, once per 4 K |
| Stop pressed | `Stopping Report.cwk...` | directly, before the wire is touched |
| after the stop | `Stopped getting Report.cwk - nothing was kept. Ready.` | directly |

The button and the first line are drawn rather than queued. Nothing blocks here —
a queued paint *would* land before the first byte, because the pull is
asynchronous — but a control that appears one pass after the click it belongs to
is a control a person has already decided is not there. That is the mirror of
the repaint trap this repo hit earlier the same day, where a synchronous 3 s
probe queued "Measuring…" and the paint landed with the answer.

No confirmation. A pull is never resumable, so stopping loses nothing that
existed; `confirm.c` is for the choices that cost something.

## Landed 2026-07-31: the primitive, the registration, the teardown

Built as specified below, on `thread/p1-wire-cancel`. `now_pull_can_stop()` is
now true whenever a pull is live, because `files_create()` registers
`now_wire_get_cancel` as the canceller — that one line is the whole difference
between a Stop button that appears and one that does not.

Three things changed beyond the fifteen lines:

- **One teardown for a leaving link.** `enter_backoff()` and `conn_disconnect()`
  now both call `link_drop_transfers()`, which is the old five-call list plus
  `get_cleanup(false)` — the pull neither path used to drop. Two lists that
  must agree had already stopped agreeing; there is one now. `conn_disconnect()`
  calls it after the `bye` is flushed, since the queue drain is the last thing
  that link is asked to carry.
- **The wire says which half of a pull is in flight.** `now_wire_get_active()`
  takes a `WireGetPhase *` (`kWireGetNone` / `kWireGetAsked` /
  `kWireGetReceiving`), and `now_pull_observe()` takes the fact instead of
  inferring it from the counts. One caller; the inference is deleted rather
  than kept beside the fact it stood in for.
- **A source-level gate**, `now-guest-ppc/tests/get_cancel_source_test.py`, in
  the shape of `ot_connect_source_test.py`: `wire.c` does not compile on the
  host, so what a host can check is what the source says — `transfer` and not
  `id`, both halves in order, `send_control` not gating the teardown, one drop
  list. It strips comments before asserting, because the prose beside this code
  names every identifier it checks.

Eleven mutations watched failing; the cancelled-pull-leaves-nothing claim below
was re-read in `fileshare.c` rather than assumed (`resumable` false →
`keep_partial` false → `receive_release(rx, false)` → `FSpDelete(&rx->temp)`).
**Nothing here is tested on a machine.** All three targets cross-build and the
native suite is 49/49; neither says a person pressed Stop and a transfer stopped.

## The one thing missing: `now_wire_get_cancel`

`now_pull_can_stop()` is false until a canceller is registered, so **as merged,
the Files pane looks exactly as it did** — no dark button, no regression, and no
defect fixed either. The primitive is 15 lines inside `wire.c`, whose `g_get` is
private to it:

```c
/* wire.h, beside now_wire_get_active */
int now_wire_get_cancel(char *err, long cap);

/* wire.c, beside get_cleanup */
int now_wire_get_cancel(char *err, long cap)
{
    char json[64];

    if (!g_get.pending && !g_get.receiving) {
        snprintf(err, (size_t)cap, "Nothing is being transferred");
        return -1;
    }
    snprintf(json, sizeof json,
             "{\"type\":\"file.cancel\",\"transfer\":%ld}", g_get.id);
    (void)send_control(json);      /* best effort: the local half must
                                      happen even on a dead wire */
    now_log(kLogInfo, "get", "#%ld stopped at %ld bytes by the person",
            g_get.id, g_get.receiving ? g_get.rx.received : 0);
    get_cleanup(false);
    return 0;
}
```

and one registration line wherever the Files module is created:
`now_pull_set_canceller(now_wire_get_cancel);`

Three things that make it that and not something else:

- **`transfer`, not `id`.** `contract/asyncapi.yaml` `FileCancel` requires
  `{type, transfer}` with `additionalProperties: false`. (The guest's own inbound
  handler at `wire.c:4483` ignores the field entirely and aborts whatever is
  live, which is a separate looseness.)
- **Both halves, in that order.** Local-only teardown leaves the host pushing a
  file nobody is writing into a lane one transfer wide, for the rest of its
  length: the pane would look stopped and the machine would still be busy.
  Wire-only leaves an open temp fork. `send_control` is best-effort because a
  stop on a dead wire still has to free this side.
- **`get_cleanup(false)`, not a new teardown.** It is what the timeout, the
  refusal and the failed `file.end` already use.

The contract already says this is how it is meant to be — the `cancel` verb's
own text: *"the PowerPC guest reaches the same capability from its own UI and
from file.cancel, and declares no verb."* That sentence has been describing
something that did not exist.

## Two things noticed in passing, both fixed 2026-07-31 (see above)

- **`conn_disconnect()` does not clean up a pull.** `enter_backoff()` calls
  `xfer_cleanup / offer_cleanup / stream_drop / shot_drop / put_drop`, and
  `conn_disconnect()` calls none of them. Disconnecting mid-pull therefore leaves
  `g_get.receiving` true with an open temp fork and no path back to
  `now_files_receive_abort`. It is also why "just disconnect" is not an
  acceptable stand-in for a cancel.
- **`now_wire_get_active()` cannot distinguish *asked* from *receiving nothing
  yet*.** Both report through one boolean, and a sender that has neither given a
  size nor delivered a byte is indistinguishable from a question with no answer.
  The pane copes (it knows it asked, and both states arm Stop and say a fetch is
  underway), but a `PullPhase` out-parameter would be more honest than the
  inference.

## corpus_impact

`corpus_impact: none` — this thread's durable claim (the pull path pumps, so a
Stop button can be pressed) is already the finding recorded in the first commit
above; the work since is implementation against it and changes no corpus claim.
