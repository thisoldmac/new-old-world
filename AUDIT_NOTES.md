# audit/buildstamp Lane Notes

> **HISTORICAL — the work below LANDED, and this page has decayed around
> it (reviewed 2026-08-06).** It is a session lane note that was never
> graduated; by AGENTS.md's rule it belongs under `docs/local/`, which is
> gitignored scratch, and it is kept at the root only because deleting
> another session's record is not this audit's call. Read it for the
> reasoning, not for the state. Three specific corrections:
>
> - **"Current State" describes the state BEFORE the change**, which is
>   the most misleading thing here. `build_stamp.c` returns
>   `NOW_SRC_HASH " " NOW_BUILT_AT` today, not `__DATE__`/`__TIME__`, and
>   `touch_build_stamp` no longer exists — `now-guest-ppc/CMakeLists.txt:285`
>   has `generate_buildstamp`, with the dependency at `:292`. The
>   "Changes Completed" section below is the accurate one.
> - **"Cannot execute: Retro68 PPC toolchain not installed" is undated
>   and describes one machine at one moment**, not this repository. The
>   PowerPC guest cross-builds in `scripts/test-all` stage 3 wherever
>   Retro68 is present, and the stage skips cleanly where it is not.
> - **Both `References` paths are dead.** `mirror/` is vendored INTO this
>   tree now, so the external absolute path is the wrong pointer, and the
>   `audit-buildstamp` worktree is gone.
>
> The one thing here still worth acting on is the verification status:
> the mutation and determinism tests in `BUILDSTAMP_TEST_PLAN.md` have
> not been recorded as run. A build proves only that the code compiles.

## Status
COMPLETE (Unverified due to missing Retro68 toolchain)

All changes ported from upstream. Static analysis passed.

## Current State *(as it was BEFORE this lane's change — see the banner)*
- NOW uses __DATE__/__TIME__ in `now-guest-ppc/src/core/build_stamp.c`
- CMake forces recompile via `touch_build_stamp` target (CMakeLists.txt:164-168)
- Problem: a change in unrelated file still ships old stamp if build_stamp.c wasn't edited
- Upstream fix at `/Users/michelle/Lab/Code/timbottu/mirror/guest/app/cmake/buildstamp.cmake` uses SHA-1 hash over all sources

## Changes Completed

### 1. Created buildstamp.cmake
- **Path**: `now-guest-ppc/cmake/buildstamp.cmake`
- **Logic**: Globs all src/*.{c,h,r} and src/*/*.{c,h,r}, sorts for stability, computes SHA-1 of accumulated hashes
- **Output**: Generates `build_stamp_gen.h` with NOW_SRC_HASH (12-char hex) and NOW_BUILT_AT (ISO8601Z)
- **Rationale**: Content-based identity, deterministic, only rewrites header when hash changes

### 2. Updated build_stamp.c
- **Was**: Returns `__DATE__ " " __TIME__`
- **Now**: Returns `NOW_SRC_HASH " " NOW_BUILT_AT`
- **Path**: `now-guest-ppc/src/core/build_stamp.c`
- **Include**: Added `#include "build_stamp_gen.h"` (generated file)

### 3. Updated CMakeLists.txt
- **Removed**: Old `touch_build_stamp` target that forced recompile on every build
- **Added**: 
  - Binary directory to include paths for `build_stamp_gen.h`
  - New `generate_buildstamp` target that runs buildstamp.cmake on every build
  - Dependency so now-guest-ppc waits for stamp generation
- **Path**: `now-guest-ppc/CMakeLists.txt`

## Verification Status

**Cannot execute**: Retro68 PPC toolchain not installed.

Would require:
1. `scripts/build-guests ppc` to succeed (test initial build)
2. Mutation test: touch a source, rebuild, verify stamp hash changes
3. Determinism test: rebuild unchanged tree, verify hash stays same

See `BUILDSTAMP_TEST_PLAN.md` for full test specification.

## Lanes Affected
- `now-guest-ppc` (PPC build)
- `now-guest-68k` (68K build, if any)

## References
- Upstream: `/Users/michelle/Lab/Code/timbottu/mirror/guest/app/cmake/buildstamp.cmake`
- NOW guest: `/Users/michelle/Lab/Code/timbottu/now/.claude/worktrees/audit-buildstamp/now-guest-ppc/`
