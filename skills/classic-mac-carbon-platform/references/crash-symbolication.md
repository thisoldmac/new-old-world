# Crash Capture and Symbolication

## Exception Manager Constraints

`InstallExceptionHandler` is annotated CarbonLib 1.1+. In Carbon source, create the opaque `ExceptionHandlerUPP`, retain the previous handler, install for the intended context, and restore/dispose on teardown.

The exception information includes kind, PC, LR, CTR, CR, XER, MSR, GPRs including SP, FPU state, and memory-fault information. Returning `noErr` resumes from the supplied machine state; a nonzero result continues unhandled-exception processing.

The handler executes on the faulting stack with asynchronous constraints:

- no allocation, purge, or compaction;
- no unlocked handles;
- no UI, stdio, Resource Manager, file opening, or context-sensitive Toolbox work;
- reentrant/bounded code only;
- `DebugStr` is an interactive debugger path, not persistence, and can recurse without a debugger.

Preallocate and lock a fixed buffer before installation. Treat writing through a pre-opened File Manager refnum as target-probe-required.

## Version 1 Crash Record

Use an explicitly serialized 160-byte big-endian record, not a packed C structure:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 4 | magic `C9CR` |
| 4 | 2 | version `1` |
| 6 | 2 | record size `160` |
| 8 | 4 | flags |
| 12 | 4 | exception kind |
| 16 | 32 | SHA-256 of exact archived XCOFF |
| 48 | 4 | runtime anchor instruction address |
| 52 | 4 each | PC, LR, SP, fault address, CTR, CR, XER, MSR |
| 84 | 2 | frame count, maximum 8 |
| 86 | 2 | frame capacity `8` |
| 88 | 8 | reserved zero |
| 96 | 64 | eight `(SP, saved LR)` pairs |

Store instruction addresses. If target code begins with a function pointer, dereference the transition vector's first word before recording the anchor.

## Offline Translation

Require the exact XCOFF whose SHA-256 matches the record. Locate the anchor instruction symbol, then compute:

`link_address = link_anchor + (runtime_address - runtime_anchor)`

Resolve nearest symbols from XCOFF `nm` output and source lines from `objdump --dwarf=decodedline`. The installed `addr2line` may provide incomplete function/line results; do not make it the only path.

Use `scripts/symbolicate_crash.py` for the version 1 record. It rejects mismatched builds and allows an explicit link-time anchor address when symbol naming is ambiguous.

## Stack Evidence

The ABI back chain points from a frame's SP to its caller SP. The current function's saved LR is at caller-SP `+8` under the ordinary prolog. Validate 16-byte alignment, monotonic addresses, readable range, loops, and maximum depth before copying.

Leaf routines, tail calls, optimized prologs, and corruption can omit or invalidate frames. Always report PC and LR independently and label recovered frames best effort.
