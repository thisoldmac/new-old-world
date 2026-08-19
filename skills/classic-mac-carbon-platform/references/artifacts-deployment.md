# Artifacts and Deployment

## Representation Matrix

| Artifact | Meaning | Use | Hazard |
|---|---|---|---|
| XCOFF | linked image with symbols/DWARF | archive and diagnosis | not launchable |
| PEF | CFM fragment/data fork | packaging intermediate | lacks resource fork and Finder metadata |
| native APPL | macOS file with xattrs/forks | local preserving filesystem | ordinary tools can drop metadata |
| MacBinary II | self-contained encoded classic file | canonical portable single-file transfer and LaunchAPPL input | receiver must decode correctly |
| AppleDouble pair | data plus metadata/resource sidecar | shared-folder convention | both members and naming convention required |
| HFS disk image | preserved classic volume | emulator/hardware delivery | mount/image layout is part of the artifact |

Use `scripts/inspect_artifact.py` before claiming an artifact is complete.

## Preservation Rule

Archive format alone is not a guarantee. Verify the exact encoder, decoder, host OS, filesystem, and reconstructed result.

A current-host experiment found:

- default `cp`, `ditto`, and that host's BSD `tar` preserved a native APPL locally;
- `cp -X` and plain `zip`/`unzip` dropped FinderInfo/resource-fork data;
- a ditto-sequestered ZIP reconstructed correctly with `ditto`;
- plain `unzip` exposed the AppleDouble sidecar but did not reconstruct metadata.

Do not generalize those results to other hosts or implementations. Run `scripts/verify_preservation.py` on both endpoints.

## LaunchAPPL

Retro68 LaunchAPPL can support classic/Carbon launch through configured emulator, serial, TCP, SSH, or shared-folder backends. Enumerate configured backends rather than assuming one exists. Package creation is not target execution evidence.

- use MacBinary when the backend expects it;
- set bounded timeouts and validate target output;
- keep the unauthenticated TCP execution backend on an isolated trusted lab network;
- do not offer `--make-executable` as a PowerPC repair path unless current tool evidence says it is implemented.

## Deployment Checklist

1. Inspect source package structure and record hashes.
2. Transfer through the actual path.
3. Reconstruct on the receiving side with the intended decoder/convention.
4. Reinspect forks, Finder metadata, resources, and data hash.
5. Launch on the declared OS row.
6. Record target output and runtime capability results.

For a raw HFS deployment disk, build to an artifact path that no VM currently
mounts. QEMU or the host can leave a mounted output as a same-sized all-zero
file while the build still appears to succeed. Attach a session-private copy,
not the build output. Before deploy, verify the expected image length and the
HFS Master Directory Block signature `BD` at byte offset 1024; after the guest
releases the copy, rebuild and re-run the artifact inspection.

Prefer MacBinary for portable application delivery and an HFS image when volume-level preservation matters.
