#include "scene.h"

#include <stdio.h>
#include <string.h>

/* Scene assembly: rows in, a scene out, no Toolbox and no I/O. Every
   rule this file encodes is a claim the scene makes about the machine,
   so every one of them is testable natively (tests/scene_build_test.c). */

static void copy_bounded(char *out, long cap, const char *src)
{
    long n = 0;

    if (src != NULL) {
        while (src[n] != '\0' && n < cap - 1) {
            out[n] = src[n];
            ++n;
        }
    }
    out[n] = '\0';
}

const char *now_scene_anchor_error(NowSceneAnchor a)
{
    switch (a) {
    case kNowSceneAnchorOk:
    case kNowSceneAnchorNoWindows:
        /* Neither is an error. "This process has no windows" is a real
           answer about the machine, not a failure to find out. */
        return NULL;
    case kNowSceneAnchorNotFound:
        return "ax_oracle_not_found";
    case kNowSceneAnchorAmbiguous:
        return "ax_oracle_ambiguous";
    case kNowSceneAnchorMismatch:
        return "ax_oracle_mismatch";
    case kNowSceneAnchorUnreadable:
        return "ax_read";
    case kNowSceneAnchorNoPlane:
        return "now_no_plane";
    case kNowSceneAnchorStub:
        return "now_not_walked";
    }
    return "now_unknown_verdict";
}

const char *now_scene_stale_error(void)
{
    return "ax_oracle_stale";
}

int now_scene_anchor_admits_windows(NowSceneAnchor a)
{
    return a == kNowSceneAnchorOk || a == kNowSceneAnchorNoWindows;
}

const char *now_scene_proc_error(const NowSceneProc *p)
{
    const char *err;

    if (p == NULL) {
        return NULL;
    }
    err = now_scene_anchor_error(p->anchor);
    if (err != NULL) {
        return err;
    }
    /* Clean, but older than the caller's window. Reported beside the data
       rather than instead of it - the data is exactly as good as its
       stamp says, and a consumer that knows the age can decide. */
    return p->stale ? now_scene_stale_error() : NULL;
}

void now_scene_begin(NowScene *s, long seq, double captured_at,
                     const char *source, short screen_w, short screen_h,
                     unsigned long now_ticks, unsigned long stale_after_ticks)
{
    if (s == NULL) {
        return;
    }
    memset(s, 0, sizeof *s);
    s->version = NOW_SCENE_IR_VERSION;
    s->seq = seq;
    s->captured_at = captured_at;
    copy_bounded(s->source, (long)sizeof s->source, source);
    s->screen_w = screen_w;
    s->screen_h = screen_h;
    s->latency_ms = -1;               /* absent until measured */
    s->now_ticks = now_ticks;
    s->stale_after_ticks = stale_after_ticks;
}

int now_scene_add_process(NowScene *s, long psn_hi, unsigned long psn_lo,
                          const char *name, unsigned long signature,
                          int front, NowSceneAnchor anchor,
                          unsigned long stamp_ticks)
{
    NowSceneProc *p;

    if (s == NULL) {
        return -1;
    }
    if (s->proc_count >= kNowSceneMaxProcs) {
        s->procs_truncated = 1;
        return -1;
    }
    p = &s->procs[s->proc_count];
    memset(p, 0, sizeof *p);
    p->psn.hi = psn_hi;
    p->psn.lo = psn_lo;
    copy_bounded(p->name, (long)sizeof p->name, name);
    p->signature = signature;
    p->front = front ? 1 : 0;
    p->anchor = anchor;
    p->stamp_ticks = stamp_ticks;
    /* Staleness is derived, not passed: the reader runs with no age gate
       (peek_read.c states why), so an old anchor arrives as Ok with an
       old stamp and this is the only place the age is looked at. A zero
       window disables it; a stamp in the future - a clock that moved
       backwards - is not stale, it is zero-aged. */
    if (s->stale_after_ticks != 0 && now_scene_anchor_admits_windows(anchor)
        && s->now_ticks > stamp_ticks
        && s->now_ticks - stamp_ticks > s->stale_after_ticks) {
        p->stale = 1;
    }
    return s->proc_count++;
}

int now_scene_add_window(NowScene *s, int proc, const char *title,
                         short t, short l, short b, short r, int visible)
{
    NowSceneProc *p;
    NowSceneWindow *w;

    if (s == NULL || proc < 0 || proc >= s->proc_count) {
        return 0;
    }
    p = &s->procs[proc];
    /* A window under a refused anchor is the coin-flip walk the
       validation layer exists to refuse. Admitting it here would deliver
       a guess as a fact, one layer above the code that declined to
       guess. */
    if (!now_scene_anchor_admits_windows(p->anchor)) {
        return 0;
    }
    if (s->window_count >= kNowSceneMaxWindows) {
        s->windows_truncated = 1;
        return 0;
    }
    w = &s->windows[s->window_count];
    memset(w, 0, sizeof *w);
    w->proc = (short)proc;
    copy_bounded(w->title, (long)sizeof w->title, title);
    w->rect.t = t;
    w->rect.l = l;
    w->rect.b = b;
    w->rect.r = r;
    w->visible = visible ? 1 : 0;
    w->z = p->window_count;
    /* Upstream's rule, unchanged: the front window is the frontmost
       window of the front process, and nothing else is front. */
    w->front = (p->front && w->z == 0) ? 1 : 0;
    /* "<psn>/<title>#<idx>" - upstream's own id form (SceneBuilder), so
       an id minted here means the same thing as one minted there. */
    snprintf(w->id, sizeof w->id, "%ld.%lu/%s#%d", p->psn.hi, p->psn.lo,
             w->title, (int)w->z);
    ++p->window_count;
    ++s->window_count;
    return 1;
}
