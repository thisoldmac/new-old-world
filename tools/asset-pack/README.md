<!-- now-doc-provenance: generated reviewed=false -->

# Asset-pack parsers

These dependency-light Python modules decode the classic Mac resource types
used by [`tools/extract-assets-offline`](../extract-assets-offline): resource
forks, bitmap font strikes, icons, cursors, patterns, and the system 8-bit
colour lookup table.

They contain no transport and choose no output directory. The supported NOW
workflow reads a disk image without booting it and writes a completed pack to
the external asset store. Run:

```sh
tools/extract-assets-offline --help
```

The standalone Mirror project's live-pull orchestrator and its cached Apple
resource forks are retained only in `archive/mirror-standalone-2026-08-09/`.
Extracted Apple bitmaps remain private, regenerable runtime dependencies and
must not be committed or shipped as application resources.
