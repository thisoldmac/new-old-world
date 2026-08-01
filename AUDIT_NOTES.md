# audit/buildstamp Lane Notes

## Status
COMPLETE (Unverified due to missing Retro68 toolchain)

All changes ported from upstream. Static analysis passed.

## Current State
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
