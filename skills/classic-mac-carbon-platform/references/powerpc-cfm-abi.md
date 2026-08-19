# PowerPC CFM ABI

Use Apple's *Mac OS Runtime Architectures for System 7 Through Mac OS 9* as the authority. Current Retro68 XCOFF/PEF emission follows these rules.

## Data Layout

- big-endian;
- 4-byte pointers, `int`, `long`, `size_t`, and `ptrdiff_t`;
- 2-byte `short` and `wchar_t` in the inspected compiler;
- 8-byte `long long` and `double`; `long double` has the same width as `double` in the inspected compiler;
- plain `char` is unsigned in the inspected compiler;
- scalar alignment is type-specific; PowerPC, 68K, packed, and natural structure embedding modes are not interchangeable.

Never copy a native structure onto a wire or persistent format. Serialize fixed-width fields explicitly and state byte order. Use balanced `#pragma pack(push, n)`/`pop` only at documented ABI boundaries; verify `sizeof` and `offsetof`.

## Calling Convention

- stack grows downward and remains 16-byte aligned;
- GPR1 is the stack pointer;
- the 24-byte linkage area stores back chain at `+0`, saved CR at `+4`, saved LR at `+8`, reserved words, and saved GPR2 at `+20`;
- caller supplies at least 32 bytes of parameter area;
- integer/pointer parameters use GPR3–GPR10; floating parameters use FPR1–FPR13;
- large/composite return values use a hidden result pointer;
- GPR13–GPR31, FPR14–FPR31, and CR2–CR4 are nonvolatile;
- leaf routines may use the 224-byte red zone below SP.

Varargs and composite arguments have additional ABI rules. Do not write cross-language callbacks or assembly from generic PowerPC assumptions.

## Transition Vectors and TOC

A PowerPC CFM function pointer addresses a transition vector:

- first word: instruction address;
- second word: fragment direct-data/TOC address.

GPR2 carries the direct-data/TOC base. Indirect cross-fragment calls use the transition vector and GPR12. Do not compare, persist, log, or symbolicate a function pointer as though it were a raw PC.

Retro68 `MakePEF` emits code, data, and loader sections. Its application entry is a transition vector in data pointing to startup code and the TOC.

## Callbacks and UPPs

Carbon source selects opaque UPP types. Create each callback with its matching `New...UPP` routine, retain the UPP for at least the registration lifetime, unregister before disposal, and dispose with the matching routine. Do not cast an ordinary function pointer to a UPP.

## Address Translation

For a known anchor function:

1. dereference its runtime transition vector's first word to obtain the runtime instruction address;
2. locate the anchor instruction symbol in the exact XCOFF;
3. translate a runtime PC with `link_pc = link_anchor + (runtime_pc - runtime_anchor)`.

This removes the need for target code to discover its loaded code-section base.
