# Asset-pack parsers

These dependency-light Python modules decode the classic Mac resource types
used by [`tools/extract-assets-offline`](../extract-assets-offline): resource
forks, bitmap font strikes, icons, cursors, patterns, and the system 8-bit
colour lookup table.

They contain no transport and choose no output directory. That is deliberate:
stopped-volume extraction, future connected-guest extraction, and bounded
visual-oracle derivation are acquisition adapters for one asset-pack domain.
They must share decoding and the versioned manifest/provenance contract rather
than growing route-specific notions of an icon or font.

`fileicons.py` makes the acquisition seam executable rather than documentary:
`decode_custom_icon(finder_info_bytes, resource_fork_bytes)` accepts the same
two classic-file payloads from either stopped-volume or connected acquisition.
It alone owns `fdHasCustomIcon` and unambiguous-suite policy.

The currently supported bulk workflow reads a disk image without booting it
and writes a completed pack to the external asset store. Run:

```sh
tools/extract-assets-offline --help
```

The standalone Mirror project's live-pull orchestrator and its cached Apple
resource forks are retained in `archive/mirror-standalone-2026-08-09/` as
prior art for the connected adapter. The fork-bearing NOW `file.*` transport
already exists; product integration remains explicitly out of this parser
package and is tracked by plans 017 and 021.
Extracted Apple bitmaps remain private, regenerable runtime dependencies and
must not be committed or shipped as application resources.
