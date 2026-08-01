#ifndef NOW_CAPTURE_REGION_ARGS_H
#define NOW_CAPTURE_REGION_ARGS_H

/* capture.region's argument line, parsed and bounds-checked once.
   ------------------------------------------------------------------
   capture.region is the side-effect-free sibling of process.shot: it
   names a rect directly (no PSN, no SetFrontProcess) so the pixel-island
   fallback can fetch a window's CURRENT interior without disturbing
   which process is frontmost. wire.c's serve_capture_region owns the
   Toolbox half (capture_screen_rect); this is the half that has none, so
   the host cc can watch its bounds fail before a real device ever runs
   it (now-guest-ppc/tests/capture_region_args_test.c).

   left/top/right/bottom are taken as given here — the SCREEN-bounds
   clamp (a window may straddle an edge) happens inside
   capture_screen_rect, which already owns the GDevice. What this checks
   is shape: non-empty, and no side over kCaptureRegionMaxDim before a
   GWorld is ever allocated for it. */

/* Ported from timbottu/mirror's kCapMaxDim (mirrorverbs.c): a sanity
   bound on either side of a crop, protecting the per-row scratch and the
   GWorld allocation. Mirror ALSO refuses when the packed image would
   overrun its one 128 KB resident capture buffer — NOW's transfer is
   chunked and incremental rather than one resident buffer (wire.c's
   service_transfer), so that second check has no NOW analogue and is
   deliberately not ported; only the dimension cap is. */
enum { kCaptureRegionMaxDim = 1024 };

typedef struct {
    long left, top, right, bottom;   /* GLOBAL screen coords, as asked */
    short depth;                     /* 0 = caller's default (prefs) */
} CaptureRegionArgs;

/* Validates the rect and depth; on success fills `out` and returns 1. On
   failure returns 0 and writes a one-line, human-readable reason into
   `msg` (bounded by `cap`, NUL-terminated) — a refusal nobody can read
   is the same defect as a silent one. `depth_in` 0 means "no preference"
   and always passes; the caller applies its own default. */
int now_capture_region_parse(long left, long top, long right, long bottom,
                             long depth_in, CaptureRegionArgs *out,
                             char *msg, long cap);

#endif /* NOW_CAPTURE_REGION_ARGS_H */
