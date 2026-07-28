# Screenshots

Empty on purpose, and tracked as a gap rather than left to be noticed.

A project whose entire subject is two Macintosh interfaces — one from
1993, one from now — and which shows neither of them is asking a reader
to take the interesting part on faith.

## What to capture

Two, minimum, both at their native size and unscaled:

1. **`workshop.png`** — the guest's Workshop window on the classic Mac.
   The Files page with a real listing showing is the most legible single
   frame: it is obviously a Mac OS 9 window, and it is obviously doing
   something. Capture on real hardware if possible — an emulator
   screenshot is honest but a photograph of the PowerBook says more about
   what this is for.
2. **`host.png`** — the host window on macOS, ideally the same session
   as the one above, so the two images are visibly the same connection
   from both ends.

Worth adding later: the live stream mid-frame, and the classic-side
console at a prompt.

## Rules

- **PNG, no scaling, no device frames, no drop shadows.** The pixels are
  the point. A 640×480 screen scaled to fit a README grid loses the
  thing worth seeing.
- **Nothing identifying in frame.** Check the file listing, the window
  titles, the process list and the clock before saving — a screenshot is
  the easiest way to undo the lab scrub.
- Keep them small enough to load. Crop rather than resample.

## Wiring them in

Drop the files here, then replace the Screenshots section of the
[README](../../README.md) with:

```markdown
| The Workshop, on the classic Mac | The host, on macOS |
|---|---|
| ![The Workshop on Mac OS 9](docs/images/workshop.png) | ![The NOW host on macOS](docs/images/host.png) |
```

And close the row in [open-issues.md](../open-issues.md).
