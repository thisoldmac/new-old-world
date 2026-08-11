---
title: Assets from the connected guest - Plan
type: feat
date: 2026-08-06
---

<!-- now-doc-provenance: generated reviewed=false -->

# Assets from the connected guest — Plan

Successor to the offline extraction route
([asset-extraction-offline.md](../asset-extraction-offline.md)), which
made the pack cheap to build but left it a DEPENDENCY. This removes the
dependency: **NOW extracts a machine's own assets from the machine it is
connected to.**

## Why this is the product answer, not just a nicer build step

Every route so far needs something beside the running system: a disk
image on the same Mac, or a pack somebody handed you. Both are fine for
this desk and neither is a product. A person who connects NOW to their
own Macintosh should get a faithful mirror of THAT machine, with no
image, no pack, no extraction step they have to know about.

It is also **more correct**, not merely more convenient:

- A pack extracted from one image is that image's System version, that
  image's applications, that image's theme. Pulling from the connected
  guest gives the art of the machine actually on screen.
- The 68K PowerBook and the emulated G4 have different Systems. One
  shared pack cannot be right for both; a per-machine pack is right for
  each by construction.
- A machine with applications nobody anticipated gets their icons
  anyway, because the roster names their creators.

## What is already true

- **The wire route is proven.** Upstream measured it: the whole System
  file's resource fork pulls in 24 s at ~330 KB/s, a font suitcase in
  0.1 s ([mirror-assets.md](../mirror-assets.md)). Slower than a
  filesystem read, and utterly acceptable for a one-time bootstrap.
- **NOW already pulls files with forks.** `files` is metal-verified for
  browse/pull/push, and `FilesModel` already reasons about `rsrcBytes`
  and MacBinary. Nothing new is needed on the wire.
- **The parsers exist — in Python.** `mirror/tools/extract-assets/`
  (`iconpack.py`, `cursors.py`, `clut.py`, `fonts.py`) and the offline
  extractor share them. That sharing is deliberate and must not be
  broken: two implementations of `icl8` would eventually disagree about
  what an icon is.

## The one real cost, stated up front

**The parsers must exist in Swift** for the host to do this itself, and
that is the bulk of the work. The Python stays as the offline route and
the reference; the two must be proven to agree rather than assumed to —
the same discipline that made the offline route trustworthy (its five
generic icons came out byte-identical to the wire route's).

A cross-checking test is therefore not optional: extract the same
resource both ways, compare bytes.

## The design

**Per-machine packs, keyed by the guest's machine id**, in Application
Support. A guest that has been seen before renders from its own pack
immediately; a new one bootstraps.

**Progressive, not all-or-nothing** — this is the part that makes 24 s
acceptable and 914 icons unnecessary:

1. **On first connect**, pull the System file's resource fork once. That
   is the generic icons, cursors and patterns — the art every window
   needs. One 24 s pull, in the background, while the mirror already
   works without it.
2. **Per-application icons LAZILY, driven by what is on screen.** The
   Finder roster and the process list already name creators and types.
   When the mirror needs `(creator, type)` it does not have, it queues
   that one application's fork. Ten visible applications is ten small
   pulls, not 186.
3. **Never block the mirror.** Extraction is background work; the
   renderer's procedural and generic fallbacks stay until real art
   arrives, and the UI should be able to SAY the pack is still filling
   rather than looking finished.

**Honesty rules, inherited and non-negotiable:**

- Absence is stated, never faked. A machine whose pack is empty draws
  fallbacks and says so; it never shows another machine's art as though
  it were this machine's.
- The pack stays private per the rule in mirror-assets.md — extracted
  from the user's own machine, kept on their own machine, never
  published or shipped.
- Pulls are read-only. Nothing is ever written into a guest System
  Folder.

## Slices

- **Q1 — the Swift resource fork reader.** Parse a MacBinary/AppleDouble
  or raw fork into typed resources. Gate it against the committed forks
  the offline route already reads, and against `macresources`' output
  for the same bytes.
- **Q2 — icons in Swift** (`icl8`/`ics8` with `ICN#`/`ics#` masks, the
  generated CLUT). The CLUT tail off-by-one that darkened one end of the
  grey ramp is a documented, already-paid-for bug — do not reintroduce
  it. Cross-check byte-for-byte against the Python pack.
- **Q3 — the bootstrap**: pull the System file on first connect, write a
  per-machine pack, renderer picks it up. Measure the real elapsed time
  against the guest and record it.
- **Q4 — lazy per-application icons**, driven by the roster's creators
  and types, bounded and cancellable.
- **Q5 — cursors, patterns, and the font strikes**, in that order of
  value. Fonts are the largest win for text fidelity and the largest
  parse (`NFNT` layout is spelled out in mirror-assets.md); they may
  deserve their own plan.

## What this does not do

- It does not replace `tools/extract-assets-offline`. That stays: it is
  faster, it works without a running guest, and it is the reference the
  Swift path is checked against.
- It does not make the pack shippable. Each user extracts from their own
  machine; that is the point.
- It does not touch composition or chrome.

## Stop condition

If the Swift and Python extractions ever disagree about a single icon's
bytes, stop and resolve THAT before adding a resource type. Two parsers
that quietly differ is a worse defect than a missing pack, because it
produces art that is wrong in a way nobody can see.
