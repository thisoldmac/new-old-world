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
