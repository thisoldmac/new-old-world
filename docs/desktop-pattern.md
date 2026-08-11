<!-- now-doc-provenance: generated reviewed=false -->

# The desktop, asked of the machine

**Date:** 2026-08-07 · **Status:** emulator-verified · [plan 018](plans/2026-08-06-018-feat-stable-honest-render-plan.md) slice 5

The renderer used to tile the System file's `ppat` 16 unconditionally.
Under Appearance the desktop is chosen elsewhere, so that resource sits
at its factory value forever — purple Mac faces beside whatever the
person actually picked. That is a **confident wrong answer**, which
plan 018's first rule forbids outright.

This is the live route, what it actually returns, and what a renderer
can do with it.

## The two routes that do not exist

Both were checked before the one below was built, and both are worth
recording because they are the obvious first guesses.

- **`LMGetDeskCPat` / `SetDeskCPat` are not in Carbon.** The low-memory
  desk-pattern accessors did not survive the transition and have no
  Carbon replacement that hands back the bits. This is also why the
  eventual 68K answer cannot share an implementation with this one: on
  System 7.1 the low-memory route is the *only* route, and there is no
  Appearance Manager to ask instead.
- **`ppat` 16 is a shipped default, not a setting.** Reading it answers
  a question nobody asked. It is unchanged on a machine whose desktop
  has been changed a dozen times.

## The route that does exist

`GetTheme(Collection)` — Appearance Manager, `Appearance.h`, declared
`CarbonLib 1.0 and later`. It fills a Collection Manager collection; the
desktop tags live in it, in the header's **second** tag group, which the
header itself marks as Mac OS 9 only. Every tag is therefore read as
may-be-absent rather than assumed present, and the absences turned out
to matter (below).

The guest serves it as the `desktop` command — `now-guest-ppc/src/machine/desktop.h`
and its two implementation files, split the way `census` is: the
serializer is Toolbox-free and natively tested, the Toolbox call decides
nothing the report cannot show.

## What a real machine answered

Measured 2026-08-07 on the OS 9.1 runner image
(`os91-runner.qcow2`), guest build `98e93c5d9f3c`, over the wire on port
5330 and again through the guest's own console. Both faces returned the
same rows.

```
getTheme        0                       (noErr)
tags            19
tagList.0       coll dpal dpan hcol lgsf patn patt sbar sbth smoo
                smos smsf smsk snds sndt thme
tagList.1       varn vfnt vfsz
theme           <absent>
appearanceFile  Apple platinum
patternName     Lollipop 7
patternBytes    16790
pattern.0       00010000001c0000004e00000000000000000000aa55aa55aa55aa55
                0c91db208080000000000080
pattern.40      0080000400000000000000480000004800000000000800010008
                000000000000404e000000000908
pictureName     <absent>
pictureAlign    5
pictureAlias    154
```

typed beside the rows: `source: picture`, `hasPattern: true`,
`hasPicture: true`, `patternBytes: 16790`, `patternCarried: 200`.

### Three things in that answer are not what you would guess

**`kThemeNameTag` ('name') is ABSENT.** The theme's name is not in the
collection at all; `kThemeAppearanceFileNameTag` ('thme') carries
`Apple platinum` instead. A reader that asks only for `name` learns
nothing about the theme on a machine that plainly has one.

**`kThemeDesktopPictureNameTag` ('dpnm') is ABSENT while a picture is on
the screen.** The screendump for this run shows a full-screen blue
picture; the name tag is not there, and `kThemeDesktopPictureAliasTag`
('dpal', 154 bytes) plus `kThemeDesktopPictureAlignmentTag` ('dpan', 5)
are. **The alias is the signal, not the name.** The first version of the
guest verb keyed on the name and reported `source: pattern` for a machine
showing a picture — precisely the failure this lane exists to remove, and
caught only because the answer was checked against the guest's own
pixels rather than read for plausibility.

**A picture does not replace the pattern.** `patternName` and
`patternBytes` are both present and real on this machine. The pattern is
the layer under the picture, and it is what shows wherever the picture
does not reach. Both facts are reported and `source` says which one a
person is looking at.

## The pattern is 16790 bytes, and that is the interesting number

The flattened `kThemeDesktopPatternTag` value decodes cleanly as a
QuickDraw **`PixPat`**, and the 200 carried bytes are enough to read the
whole header:

| field | value |
|---|---|
| `patType` | 1 — full-colour pattern |
| `patMap` / `patData` | offsets 28 / 78 |
| `pat1Data` | `aa55aa55aa55aa55` — the 1-bit fallback, a 50% checkerboard |
| bounds | 0,0,128,128 |
| `rowBytes` | 128, PixMap bit set |
| `pixelSize` | 8 (indexed), `cmpCount` 1, `cmpSize` 8 |
| resolution | 72.0 × 72.0 |

The arithmetic closes exactly: 78 header + (128 × 128) pixels + 328
bytes of colour table (8-byte header + 40 × 8-byte `ColorSpec`) = 16790.
So "Lollipop 7" is a **128×128 8-bit indexed pattern with 40 colours** —
not the 8×8 `PAT` the word "pattern" suggests, and not tileable from
eight bytes.

**16790 bytes cannot cross a `command.result`**, which caps at 3072.
That is a fact about the transport, not a defect in the verb: the answer
carries the pattern's *identity* and its first 200 bytes as evidence, and
anything wanting the bits needs a different route.

## What a renderer can do with this

Three rungs, in the order plan 018's ladder would take them:

1. **By identity.** `patternName` is a real, stable string
   (`Lollipop 7`) and the asset pack holds the same art under the same
   names. Matching on the name is exact and costs nothing.
2. **By the fallback.** `pat1Data` is always eight bytes and is always
   present in a `PixPat` — a legitimate 1-bit rendering of the same
   pattern, and the one the machine itself falls back to at low depth.
   It is a poor likeness of a 40-colour image but it is not a guess.
3. **The marked unknown.** `source: unknown`, or a `patternName` that
   matches nothing. Never a default `ppat`.

And the picture case, which is out of scope for rendering but still
answers a question: when `hasPicture` is true the pattern layer is
mostly or entirely **invisible**, so effort spent matching the pattern
buys nothing on that machine. `pictureAlign` is a bare `UInt32` — this
toolchain's headers declare no constants for it, so its 5 is recorded
raw and not interpreted. Alignment is what would say whether a picture
covers the screen; until someone finds the constants, "a picture is set"
is as far as this answer goes, and it is deliberately not stretched
further.

## What is not known

- **Whether the pattern is reachable in full.** 16790 bytes needs a
  transfer or a paged verb; neither was built. If a renderer ever wants
  the real bits rather than a name match, that is the work.
- **What `pictureAlignment`'s values mean.** No named constants in
  Universal Interfaces 3.4.1. Five is five.
- **Whether `patternName` is stable across localised systems.** It was
  read once, on one English image.
- **Any of this on metal.** Emulator-verified only.
- **NOW-68K** does not serve it and would have to answer through the
  opposite mechanism — see
  [contract-coverage.md](contract-coverage.md).
