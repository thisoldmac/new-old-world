# Build Stamp Mutation Test Plan

## Overview
The build stamp replacement changes the build identity from a clock-based `__DATE__ __TIME__` to a content-based SHA-1 hash. This document specifies the mutation test that would verify the replacement works correctly.

## Test Methodology

### Precondition
- Retro68 toolchain installed and configured in `.env.lab`
- `scripts/build-guests ppc` can execute successfully

### Test 1: Initial Build (Baseline)
1. Clean build: `rm -rf /tmp/now-guest-builds && scripts/build-guests ppc`
2. Extract build stamp from binary: run the built guest and capture `now_build_stamp()` output
3. Record both parts:
   - **Hash**: 12-character hex string (e.g., `a1b2c3d4e5f6`)
   - **Timestamp**: ISO 8601 format (e.g., `2026-08-01T12:34:56Z`)

**Expected result:**
- Build succeeds
- Stamp format is `{12-hex} {ISO8601Z}`
- Hash is deterministic (same tree → same hash)

### Test 2: Unrelated Change (Verify Stamp Changes)
1. Touch an unrelated source file: `touch now-guest-ppc/src/commands/cmd_help.c`
2. Rebuild: `scripts/build-guests ppc`
3. Extract new stamp
4. **Compare hashes**: Old hash ≠ New hash (critical requirement)
5. **Timestamp will differ**: Expected and fine (new build time)

**Expected result:**
- Rebuild detects the touched file (timestamp newer)
- SHA-1 hash CHANGES (proving content-based dependency)
- Timestamp updates
- This is the core mutation test: if the hash didn't change, the fix is incomplete

### Test 3: No Change Rebuild (Verify Determinism)
1. Rebuild without touching sources: `scripts/build-guests ppc`
2. Extract stamp
3. **Compare hash to Test 1 baseline**: Old hash = New hash

**Expected result:**
- Unchanged source tree produces identical hash
- Timestamp will differ (new build time)
- This proves the hash is truly content-based, not clock-based

### Test 4: Revert Change and Rebuild (Reproducibility)
1. Touch the file again: `touch now-guest-ppc/src/commands/cmd_help.c`
2. Rebuild and extract stamp (Record as Stamp B)
3. Revert the touch on the original: `touch -r now-guest-ppc/src/core/wire.c now-guest-ppc/src/commands/cmd_help.c`
4. Rebuild and extract stamp (Record as Stamp C)
5. **Compare Stamp B hash to Stamp C hash**: They should be identical

**Expected result:**
- Reverting to prior state reproduces prior hash
- Proves the hash depends only on file content, not modification time

## Test Failure Modes

### Failure: Hash doesn't change in Test 2
- **Diagnosis**: buildstamp.cmake is not detecting file changes
- **Possible causes**:
  - GLOB pattern doesn't include the touched file
  - SHA-1 computation is wrong
  - CMake caching issue (header not being regenerated)

### Failure: Hash differs between identicalTree builds
- **Diagnosis**: Non-determinism in the stamp computation
- **Possible causes**:
  - File ordering issue (SORT not working as expected)
  - Timestamp is somehow included in the hash (it shouldn't be — only in the context string)
  - Build timestamp or machine state bleeding into hash

## Current Status: UNVERIFIED (No Toolchain)

**Cannot run:** The Retro68 PPC toolchain is not installed on this machine.

This audit lane cannot execute the above tests. The code review shows:
- `buildstamp.cmake` logic is sound: stable glob, name-sort, SHA-1 hash
- `build_stamp.c` correctly includes and uses generated header
- `CMakeLists.txt` correctly sets up generation and dependencies
- Include paths are correct for all consumers

A developer with the Retro68 toolchain should run this test plan to fully verify the fix.

## Proof of Concept: Upstream Validation

The upstream codebase at `/Users/michelle/Lab/Code/timbottu/mirror/guest/app/cmake/buildstamp.cmake` 
has already proven this pattern works. The NOW implementation is a faithful port with:
- Same SHA-1 hashing strategy
- Same stable file ordering
- Same header-rewrite-only-on-change optimization
- Same qualified variable names (NOW_SRC_HASH, NOW_BUILT_AT)
