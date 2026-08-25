<!-- now-doc-provenance: generated reviewed=false -->

# Third-party notices

New Old World is MIT-licensed (see [LICENSE](LICENSE)) and carries no
external package dependencies. The material below is the complete list of
third-party-derived content in the tree; each item also carries its
attribution inline at the point of use.

## machfs 1.3

`now-host/Sources/Host/HFSStandardVolume.swift` includes Apple's HFS
case-insensitive relative-ordering table (byte-indexed over MacRoman),
taken from machfs 1.3 rather than from GPL-licensed alternatives.

machfs is MIT License, Copyright (c) Elliot Nunn:
<https://github.com/elliotnunn/machfs>

## Runtime and toolchain dependencies (not distributed here)

The repository distributes no Apple software. CarbonLib is a runtime
dependency arranged on the classic Mac itself; release assembly may fetch
Apple's own checksum-pinned installer through an external descriptor, with
its license material carried alongside — see the
[distribution standard](docs/developer-guide/reference/distribution-standard.md).
[Retro68](https://github.com/autc04/Retro68) is a build-time
cross-compiler installed separately by contributors; none of its code or
headers is tracked in this tree.
