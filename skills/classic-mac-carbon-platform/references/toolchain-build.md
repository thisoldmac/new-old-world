# Retro68 Toolchain and Build Pipeline

## Fingerprint First

Record:

- Retro68 source commit and dirty state;
- `powerpc-apple-macos` GCC/G++ versions;
- CMake toolchain file and configured cache;
- `UNIVERSAL_INTERFACES_VERSION` and selected interface tree;
- hashes/inventory of Apple import inputs and generated import archives;
- configure options, compile flags, link flags, and language standards;
- versions/paths of `Rez`, `MakePEF`, `ResInfo`, `LaunchAPPL`, and GNU XCOFF tools.

Apple Universal Interfaces and libraries may be manually supplied, gitignored inputs. A Retro68 commit does not fingerprint them.

## Carbon Build Pipeline

Retro68 `add_application` performs this transformation:

1. compile `.r` with Retro68 Rez and `TARGET_API_MAC_CARBON=1`;
2. compile/link C/C++ into XCOFF;
3. convert XCOFF to PEF with `MakePEF`;
4. combine the PEF data fork, `RetroCarbonAPPL.r`, and project resources with Rez;
5. package native APPL, MacBinary, AppleDouble, and HFS image forms.

The generated Carbon application envelope contains a PowerPC `cfrg`, an empty `carb`, and a default `SIZE`. Project resource order can override `SIZE`; Rez input ordering is therefore runtime behavior.

## Link Model

- `-carbon` selects CarbonLib plus Retro68's Carbon startup/runtime.
- XCOFF is the linked representation and retains symbols/DWARF.
- PEF is the CFM-loadable code fragment in the application data fork.
- `MakeImport` turns PEF exports into XCOFF import descriptions; the archive is not the runtime shared library.
- CarbonLib import archives can contain strong and weak members. A weak import that permits launch still requires a runtime capability gate before use.

## Diagnose by Stage

Classify failures as configure, compile, link, MakePEF, Rez/resource composition, packaging, transfer, CFM launch, service initialization, or feature operation. Do not apply a remedy from a later stage to an earlier failure.

With newer GCC revisions, a historical `-Werror` policy may make new diagnostic families fatal. Record the exact diagnostic and compiler version. Prefer a source correction; for reproduction, demote only the newly fatal family rather than disabling warnings globally.

## Preserve Diagnostic Inputs

Archive together:

- shipped MacBinary or disk image;
- exact XCOFF with DWARF;
- link map (`ld -Map`) and cross-reference table when useful;
- toolchain fingerprint;
- source revision and dirty-state record;
- resources and build flags.

Do not strip or discard the only address-bearing intermediate after producing the smaller PEF.
