# Events and Cooperative Liveness

Classic Mac OS is cooperatively scheduled. A visually correct UI that starves networking, progress, or the host protocol during Toolbox tracking is not correct.

## Preferred Structure

- For new CarbonLib 1.6 UI, prefer Carbon Events, standard application and window handlers, command IDs, and `RunApplicationEventLoop`.
- Install standard handlers before specialized handlers.
- When adapting a mature `WaitNextEvent` application, move one ownership boundary at a time; do not run two competing top-level loops.
- Follow [redraw-and-damage.md](redraw-and-damage.md). Select standard `kEventWindowDrawContent` ownership or deliberate manual `kEventWindowUpdate` ownership per window; never mix them.
- Keep ordinary drawing in the selected draw/update owner and model mutation in commands or services. Commands, timers, bounds handlers, and I/O completion invalidate damage rather than paint it.

## Nested-Loop Inventory

Review every use of:

- `ModalDialog`, `StandardAlert`, and custom modal filters;
- `NavGetFile`, `NavPutFile`, `NavChooseFolder`, and other Navigation Services calls;
- `TrackControl`, menu tracking, window dragging or resizing, and scroll tracking;
- synchronous file, compression, screenshot, clipboard, or network work.

Use the API's idle, event, or action callback to perform a bounded pump where available. Apple's NavSample demonstrates `NewNavEventUPP`, `kNavCBEvent`, version checks with `NavLibraryVersion`, and disposal of UPPs and replies.

## Pump Contract

Each pump tick should:

1. do a bounded amount of nonblocking I/O;
2. advance timers and retry state without sleeping;
3. update model state;
4. invalidate the old and new bounds of what changed;
5. return promptly.

Guard against reentrancy. A pumped callback must not open another modal dialog, recursively track a control, dispose the object that owns the callback, or synchronously wait for the peer. Give the host protocol deadlines and bounded buffering because some classic tracking loops cannot be fully interrupted.

A control-action or tracking callback may draw immediate feedback when the tracked interaction requires it. Clip that drawing to the owned content, keep it bounded, and leave coherent model state so the next ordinary update reconstructs the same result.

## Ownership

Create UPPs with the matching `New...UPP`, keep them alive for the owning Toolbox object's lifetime, and dispose them at teardown. Dispose Navigation replies, Data Browser callbacks and state, timers, controls, regions, handles, and `IconRef`s according to their documented ownership.
