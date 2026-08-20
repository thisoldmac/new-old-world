# Runtime Services and Concurrency

## Capability Gate Order

For optional or release-varying services:

1. verify the declaration and CarbonLib availability annotation in the selected headers;
2. identify the strong/weak import and backing shared library;
3. query the documented Gestalt selector/attribute where available;
4. use `GetSharedLibrary`/`FindSymbol` when symbol-level variation matters and no stronger selector exists;
5. initialize the service and handle its actual error;
6. exercise the operation and fallback on each required target row.

Do not infer availability from a non-null imported function pointer. CarbonLib glue and weak imports can exist while the backing service is absent.

Useful selector families include system/Carbon versions, Open Transport presence/version/load masks, file-system and HFS+ attributes, Resource Manager FS-call attributes, Thread Manager attributes, and MP callable-API attributes.

## Cooperative Baseline

The Process Manager schedules applications cooperatively. Yield through `WaitNextEvent`, `EventAvail`, or documented yielding Toolbox calls. Break parsing, transfers, network work, and retries into bounded units.

Do not assume a callback, Time Manager task, or network notifier creates general concurrency. Audit reentrancy whenever nested loops or callbacks pump application work.

## Thread Manager

Thread Manager threads are cooperative within one application task. They require explicit yields and still share the application's Toolbox and memory constraints.

Use only when stackful cooperative flows are clearer than event-driven state machines. Own the thread-entry UPP, define yield points, cancellation, shared-state rules, and event-loop responsiveness. A Thread Manager thread that does not yield blocks its peers.

## Multiprocessing Services

MP Services 2.0 arrived with Mac OS 8.6 but excludes several early Power Mac families; 2.1 is associated with Mac OS 9 and broader hardware support. CFM preparation does not prove MP usability. Check `MPLibraryIsLoaded`, version/hardware restrictions, and callable-API attributes.

An MP task is a restricted preemptive environment. Keep communication with the cooperative application narrow and documented. Do not call ordinary Toolbox APIs from an MP task without explicit Apple safety documentation.

## Open Transport

Gate OT presence, loaded state, TCP capability, and version independently. Design endpoints as asynchronous state machines with bounded notifier work, explicit completion ownership, cancellation/timeouts, and event-loop integration. Test connect, orderly close, abort, peer disappearance, partial I/O, DNS/address errors, and extension-disabled behavior.

Do not block the event loop around network operations merely because the host peer is fast during development.
