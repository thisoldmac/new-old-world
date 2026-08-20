# Memory and Ownership

## Application Partition

Classic applications run inside an application partition whose preferred and minimum sizes come from `SIZE`. Launch may fail at the minimum boundary; normal execution can fail under fragmentation before nominal free bytes are exhausted. Measure realistic low-memory behavior on target.

## Pointers and Handles

- `Ptr` memory is nonrelocatable.
- `Handle` memory is relocatable; the handle remains stable while its dereferenced pointer may move during compaction.
- Lock a handle before retaining its dereferenced pointer across any call that may allocate, purge, compact, load a resource, open UI, or yield into code that can do so.
- Restore the prior lock state rather than unconditionally unlocking a caller-owned handle.
- Keep ownership explicit: creator, disposer, lock owner, and transfer point.

Do not keep raw pointers into resource data or movable blocks in long-lived C++ objects unless lifetime and lock state are mechanically guaranteed.

## Resource Manager Ownership

Loading a resource produces a relocatable handle managed by the Resource Manager. Distinguish:

- resource-file ownership;
- handle ownership and purgeability;
- changed-resource state;
- detach/release/dispose behavior;
- update/close ordering and error handling.

Resource IDs, types, and file selection are part of application behavior, not merely asset lookup.

## Asynchronous and Restricted Contexts

Interrupt, timer, exception, and MP-task code cannot call arbitrary Toolbox services. Before using an API in a restricted context, find Apple's explicit safety statement for that context.

For exception handlers:

- preallocate and lock all storage;
- do not allocate or trigger heap compaction/purging;
- do not touch unlocked handles;
- avoid UI, stdio, Resource Manager, file opening, and non-reentrant helpers;
- bound every copy and walk;
- restore or chain the previous handler.

Treat writing through a pre-opened raw File Manager refnum as probe-required until every declared target validates it.

## C++ Ownership Mapping

RAII is useful only when it models the actual Toolbox lifetime. Create narrow wrappers for one manager/type at a time. Encode nullability, ownership transfer, UPP registration lifetime, handle lock restoration, and `OSErr` handling explicitly. Do not hide a movable handle behind a wrapper that exposes a permanently stable `T*`.
