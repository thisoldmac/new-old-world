# Retro68 Runtime and C++ Boundary

## Verified Startup Subset

Retro68's Carbon startup supplies a synthetic `argv` containing `./a.out`, registers global destructors through `atexit`, and exits with `main`'s result. Its target tests exercise reaching `main`, zero-initialized storage, basic stdio, global construction/destruction, exceptions, function-local static initialization, Pascal trap declarations, and GCC Pascal string literals.

Those tests support only the exercised facilities. Set C/C++ language standards explicitly; a modern compiler front end does not create modern OS services.

## Unsupported or Probe-Required Surfaces

The inspected libstdc++ configuration has neither gthreads nor TLS. Do not use `std::thread`, standard mutex/condition-variable facilities, or `thread_local` as a supported platform path.

Retro68's newlib shim is intentionally partial:

- open/read/write/close wrap classic File Manager calls with limited Unix semantics and incomplete `errno` behavior;
- file descriptors are offset Mac file reference numbers;
- stat, fstat, mkdir, rename, unlink, fcntl, fork, and exec are absent/failure paths;
- process identity is synthetic;
- entropy reports unavailable;
- time combines `GetDateTime` and `TickCount`, not a high-resolution monotonic clock;
- default console hooks fail unless the optional UI RetroConsole is linked.

Therefore treat `std::filesystem`, POSIX paths, process APIs, signals, environment variables, locale, `std::chrono`, `std::random_device`, and conventional stdin/stdout as unsupported or probe-required. Prefer the native Toolbox manager for each OS-facing job.

## Allocation

The inspected allocator uses `NewPtr`, `NewPtrClear`, `SetPtrSize`, and `DisposePtr`. Ordinary allocations exist, but verify:

- failure handling and exception policy;
- `calloc` multiplication overflow at project boundaries;
- realloc behavior when resizing fails;
- requested alignment above the platform's ordinary `NewPtr` alignment;
- peak heap usage and fragmentation under the declared `SIZE` partition.

Avoid over-aligned types unless a target probe and allocator path explicitly support them.

## Classification Rule

Classify a C++ facility as:

1. target-tested runtime subset;
2. pure language/template facility without OS backing, still subject to size and exception cost;
3. OS-backed facility requiring compile, link, and target-operation evidence.

Header presence is not evidence for category 3.
