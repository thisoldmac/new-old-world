# Target and UI Eras

## Contents

- Target declaration
- Executable profiles
- UI eras
- Boundary routing

## Target declaration

Treat “System 6 through Mac OS 9” as a research envelope, not one contract. Record CPU, executable format, lowest/highest OS, ROM or hardware family, addressing mode, MultiFinder/Process Manager state, optional extensions/shared libraries, screen/depth, memory partition, and artifact transport.

## Executable profiles

| Profile | Meaning | UI consequence |
|---|---|---|
| Classic 68000-compatible 68K | A5 world, jump table, `CODE` resources | Broadest 68K reach; avoid later-instruction assumptions |
| Later-CPU classic 68K | Explicit 68020/030/040/FPU floor | State the hardware floor; do not call it universal 68K |
| Native PowerPC CFM | PEF fragment plus `cfrg` and import libraries | Early PPC systems can still require System 7 presentation |
| Fat classic 68K/PPC | 68K `CODE` plus PPC PEF in one application | Share resources and interaction design; verify both launch paths |
| CFM-68K | CFM fragment on 68020+, System 7.1+, CFM-68K runtime | Advanced, component-gated, not the broad 68K default |

## UI eras

### U1: System 6 and monochrome baseline

- Design first in one-bit black and white.
- Fit compact built-in displays.
- Prefer ROM/system definitions and resources.
- Keep layouts sparse and conventional.
- Do not assume MultiFinder, `WaitNextEvent`, color, Appearance Manager, or later control variants.

### U2: System 7 classic

- Preserve the classic menu, window, dialog, alert, activation, and update model.
- Use enhanced Standard File only after capability detection.
- Treat Balloon Help, Apple events, Drag Manager, and other later managers as separate gates.
- Test cooperative activation, update regions, suspend/resume behavior, and compact screens.

### U3: Mac OS 8/9 Platinum without Carbon

- Check and register with Appearance Manager deliberately.
- Use standard Appearance-aware window/control definitions and theme drawing.
- Retain a classic fallback and do not assume systemwide Platinum mapping.
- Treat theme appearance as variable; layout remains stable.

Executable and UI profiles are orthogonal. A 68K application may use U3 on a later system; a native PPC application may need U2 on an early Power Macintosh.

## Boundary routing

- Route CarbonLib 1.x applications to `classic-mac-carbon-ui` and `classic-mac-carbon-platform`.
- Route event loops, managers, CFM, memory, builds, Rez, forks, and verification to `classic-mac-toolbox-platform`.
- Route INITs, trap patches, startup execution, and resident callbacks to `classic-mac-init-platform`.
- Treat drivers, desk accessories, control panels, XCMD/XFCN modules, ROM patches, and Mac OS X as separate scopes.
