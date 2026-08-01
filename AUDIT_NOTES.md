# audit/buildstamp Lane Notes

## Status
Starting audit to replace date-based build stamps with hash-based ones.

## Current State
- NOW uses __DATE__/__TIME__ in `now-guest-ppc/src/core/build_stamp.c`
- CMake forces recompile via `touch_build_stamp` target (CMakeLists.txt:164-168)
- Problem: a change in unrelated file still ships old stamp if build_stamp.c wasn't edited
- Upstream fix at `/Users/michelle/Lab/Code/timbottu/mirror/guest/app/cmake/buildstamp.cmake` uses SHA-1 hash over all sources

## Plan
1. Port buildstamp.cmake to NOW
2. Create generated buildstamp header (e.g., `build_stamp_gen.h`)
3. Update build_stamp.c to use generated header
4. Remove `touch_build_stamp` target
5. Test with mutation: build, record stamp, touch source, rebuild, verify stamp changed

## Lanes Affected
- `now-guest-ppc` (PPC build)
- `now-guest-68k` (68K build, if any)

## References
- Upstream: `/Users/michelle/Lab/Code/timbottu/mirror/guest/app/cmake/buildstamp.cmake`
- NOW guest: `/Users/michelle/Lab/Code/timbottu/now/.claude/worktrees/audit-buildstamp/now-guest-ppc/`
