# Verification Strategy

## Evidence Layers

Use separate gates:

1. host-only pure logic tests;
2. compiler/header probes;
3. link/import and MakePEF success;
4. resource/package inspection;
5. emulator launch and functional probes;
6. representative physical-hardware validation.

A success at one layer does not waive the next layer when the claim depends on it.

## Capability Probe Contract

A reusable target probe should emit a versioned machine-readable record plus human text containing:

- OS, CarbonLib, probe, and build-fingerprint versions;
- relevant Gestalt values and actual operation results separately;
- File Manager/FSRef/Unicode behavior on the current volume format;
- Resource Manager FS and named-fork behavior;
- TEC version/features and representative conversions;
- Thread Manager presence and cooperative-yield behavior;
- optional MP Services availability;
- only project-requested newlib/libstdc++ surfaces such as alignment, clocks, entropy, locale, filesystem, and stdio.

Keep deliberate Exception Manager faults in a separate binary so the general reporter cannot be destroyed by its own probe. Never call a weak optional symbol before its gate.

The bundled `assets/target-probe/` is a compile-verified baseline reporter for system, CarbonLib, file-system, Resource Manager, and Thread Manager Gestalt values. Copy it before modification. It deliberately does not claim operational support from those selector values; add manager-specific operations only for capabilities the project needs, and preserve selector and operation results separately.

## Compatibility Rows

At minimum exercise:

- Mac OS 8.6 plus CarbonLib 1.6;
- Mac OS 9.0.x plus CarbonLib 1.6;
- Mac OS 9.1 plus CarbonLib 1.6;
- Mac OS 9.2.2 plus CarbonLib 1.6.

An emulator gives repeatability, not hardware equivalence. Physical hardware owns timing, drivers, extension conflicts, networking behavior, memory pressure, disk/volume reality, and transfer behavior.

## Release Evidence

Archive:

- source revision and dirty state;
- toolchain fingerprint;
- XCOFF/DWARF and link map;
- complete packaged artifact and hashes;
- artifact inspection output before and after deployment;
- target probe output per OS/hardware row;
- functional test results, timeouts, and failure logs;
- known untested/probe-required capabilities.

Do not report “works on OS 9” when only one point release, emulator, or artifact build was observed.
