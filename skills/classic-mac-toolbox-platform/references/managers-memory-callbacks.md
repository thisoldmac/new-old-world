# Managers, Memory, and Callbacks

## Manager initialization

A normal non-Carbon application initializes the managers it uses. A common early sequence is `InitGraf`, `InitFonts`, `InitWindows`, `InitMenus`, `TEInit`, and `InitDialogs`, followed by application-specific managers and resources. Verify the exact target/header contract rather than copying a sequence blindly.

## Event loop

- Test whether `WaitNextEvent` is available.
- When available, pass a nonzero sleep, process null events for bounded idle work, and handle activation/update/cursor responsibilities.
- Without it, use `GetNextEvent` and call `SystemTask` regularly.
- Do not call `SystemTask` in addition to `WaitNextEvent`.
- Treat modal dialogs, menus, dragging, control tracking, Standard File, and Navigation Services as nested event loops with explicit liveness analysis.

## Handles and heap discipline

- Use Handles for movable application data.
- Assume an allocation or manager call can move or purge unlocked relocatable blocks.
- Do not retain `Ptr p = *handle` across such a call.
- Save Handle state, move/lock only when stable dereference is required, and restore state promptly.
- Avoid indiscriminate nonrelocatable blocks and long-lived locks; they fragment the heap.
- Call `MoreMasters` early enough from the main or never-unloaded segment.
- Check allocation results and `MemError`.
- Test under a deliberately constrained `SIZE` partition.

## A5 worlds and globals

Classic 68K application globals live relative to A5. Native PPC fragment globals use a different runtime model. Never assume a callback entered from the system has the application's global context unless the callback contract and glue establish it.

## Callbacks and UPPs

- Create callbacks using the matching UPP constructor where required.
- Preserve the callback and context for the full registration lifetime.
- Remove/dispose them in reverse ownership order.
- Keep callback code resident in multi-segment applications.
- Treat timer, VBL, deferred-task, completion, modal-filter, control-action, and Mixed Mode callbacks as different execution contexts.
- Do not allocate, load resources, compact memory, perform synchronous I/O, or call UI managers in interrupt context unless Apple explicitly permits it.

## Shared data and ABI

68K and PPC differ in alignment and calling conventions. For disk, resource, IPC, or network data:

- specify byte order and fixed field widths;
- decode into native structs rather than casting buffers;
- version the format;
- validate lengths and bounds;
- do not transmit pointers, Handles, Pascal-string storage, transition vectors, or native padding.
