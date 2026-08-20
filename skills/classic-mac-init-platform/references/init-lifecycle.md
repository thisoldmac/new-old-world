# INIT Lifecycle

## Loader contract

A conventional extension is a file with Finder type `INIT` and a locked `INIT` resource, normally ID 128. The Start Manager loads and invokes it during startup in a temporary environment, then closes its resource file.

System 6 installs the file directly in the System Folder. System 7 and later normally use the Extensions folder. Do not create or remove files in the folder currently being enumerated.

Treat load order as undefined. Apparent alphabetical order is not a dependency mechanism.

## Execution environment

At entry, assume:

- no application partition or application globals;
- no valid application A5 world;
- no application event loop;
- no guarantee that Process Manager, Finder, networking, printing, or CarbonLib is ready;
- limited startup UI and a user waiting for the machine to boot;
- a locked code resource, but not permanent ownership after the resource file closes.

Use local stack data for bounded installation work. Use explicit system-heap ownership for anything that outlives the call.

## Transient INIT

A transient INIT performs bounded installation or configuration and retains no code or data.

1. Relocate the code resource when required by the toolchain.
2. Initialize only the runtime facilities actually used.
3. Perform capability-gated work.
4. Release temporary globals and resources.
5. Return promptly.

For Retro68, the sample sequence is `RETRO68_RELOCATE()`, optional constructor initialization, bounded work, and `Retro68FreeGlobals()`. This is a transient pattern only.

## Resident INIT

A resident INIT installs code or state that survives after return.

1. Obtain the handle for each retained executable resource while its resource file is open.
2. Detach the resource from the resource map.
3. move it high when appropriate and lock it;
4. allocate retained state in the system heap;
5. initialize callback records completely;
6. install the callback only after code and state ownership are final;
7. do not free the globals used by retained code;
8. provide explicit shutdown or removal behavior where the manager supports it.

Do not point a callback into the transient INIT resource and then allow the file close to dispose that resource.

## Patching

Before patching a trap:

- prove that documented manager or callback mechanisms cannot solve the problem;
- save and chain the exact prior trap address;
- make installation idempotent;
- place patch code and state in retained, locked system-heap storage;
- preserve registers and calling convention exactly;
- avoid allocation, resource loading, and reentrant calls from the patch;
- document removal and conflict behavior.

Never infer that another extension owns the current trap merely from its address or filename.

## Startup presentation

Avoid alerts and modal dialogs. For a notification that can wait until normal interaction begins, install a Notification Manager record whose record, text, icon, sound, and response procedure all remain valid for the necessary lifetime.

A boot icon is diagnostic presentation, not evidence that resident behavior is safe.
