# Memory and Callback Ownership

## System heap

Code and data that outlive INIT execution belong in the system heap. Use `NewPtrSys`, `NewPtrSysClear`, `NewHandleSys`, or their documented equivalents. Check `MemError` and fail closed if installation memory is unavailable.

Do not switch zones casually, retain pointers into relocatable handles, inspect master-pointer layout, or assume the system heap is growable before System 7.

## Handles and resources

- Lock executable resources before relocation or callback installation.
- Detach any resource that must survive closure of its resource file.
- Keep notification icons and sounds nonpurgeable for their required lifetime.
- Reacquire dereferenced handle pointers after any call that may move memory.
- Do not unlock resident code while callbacks remain installed.

Resource attributes are not ownership. A `locked` attribute ensures loading behavior but does not by itself detach the resource from a file that will close.

## A5 and globals

An INIT has no normal application A5 world. A callback invoked later may run with another process's A5 value or no useful A5 setup.

Use one deliberate model:

- position-independent code with no mutable globals;
- a retained state block reached through a documented callback record or stable pointer;
- a separately established private globals base whose save and restore protocol is proven for every entry point.

Never access another application's QuickDraw globals through an assumed A5 layout. At startup, create temporary QuickDraw globals only when a documented drawing technique requires them.

## Retro68 relocation lifetime

Retro68 flat code resources allocate BSS during `Retro68Relocate()`. The current runtime chooses system-heap allocation when the code is outside an application zone and falls back to 24-bit address stripping when the newer trap is unavailable.

`Retro68FreeGlobals()` disposes that BSS and marks it unavailable. Therefore:

- call it for a one-shot INIT that retains no code requiring those globals;
- do not call it while any retained entry point can reference the relocated BSS;
- retain and lock the executable resource separately because the runtime does not automatically recover and own its resource handle;
- audit the installed Retro68 revision rather than assuming this behavior is unchanged.

## Interrupt and completion contexts

Assume interrupt-time code cannot:

- allocate, dispose, resize, compact, or purge memory;
- load resources;
- perform synchronous file or network I/O;
- call most UI managers;
- depend on the current application or its globals;
- run unbounded work.

Preallocate fixed records and buffers. Copy minimal data, set a flag, or enqueue documented deferred work. A deferred task is still an interrupt task; it is not application context.

## Failure atomicity

Install in this order:

1. allocate and validate state;
2. acquire, detach, and lock code/resources;
3. initialize records;
4. install callbacks or patches last.

On failure, unwind only resources already owned. Never leave a callback installed after freeing its code or state.
