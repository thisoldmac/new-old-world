#include "scene_collect.h"

#include <Processes.h>
#include <Quickdraw.h>

#include <string.h>

#include "peek_read.h"

/* The one file that sees both the reader's verdict enum and the scene's
   copy of it. peek_read.h cannot be included by scene.h - it pulls in
   Carbon, which is exactly what keeps assembly testable on the host - so
   the two enums are pinned HERE, at compile time. Break the
   correspondence and the guest build fails on a negative array size,
   which is the point: a silently reordered verdict would turn "this
   anchor is ambiguous" into "this process has no windows", and nothing
   would say so. */
typedef char now_scene_anchor_pin[
    (kNowSceneAnchorOk == (int)kNowPeekReadOk
     && kNowSceneAnchorNoPlane == (int)kNowPeekReadNoPlane
     && kNowSceneAnchorNotFound == (int)kNowPeekReadNoAnchor
     && kNowSceneAnchorNoWindows == (int)kNowPeekReadNoWindows
     && kNowSceneAnchorUnreadable == (int)kNowPeekReadUnreadable
     && kNowSceneAnchorStub == (int)kNowPeekReadStub
     && kNowSceneAnchorAmbiguous == (int)kNowPeekReadAmbiguous
     && kNowSceneAnchorMismatch == (int)kNowPeekReadMismatch) ? 1 : -1];

/* Mac epoch (1904-01-01) to Unix epoch (1970-01-01), in seconds. A fixed
   66-year offset including 17 leap days - the standard constant, and the
   only conversion between the two clocks. */
#define kMacToUnixEpochSeconds 2082844800.0

enum {
    kSceneCollectMaxPsns = kNowSceneMaxProcs
};

static double captured_at_now(void)
{
    unsigned long secs = 0;

    GetDateTime(&secs);
    /* What the MACHINE believes, not what it ought to believe. A
       PowerBook with a dead PRAM battery boots in 1904 and says so;
       silently correcting that would hide a real fact about the machine
       behind a plausible number. */
    return (double)secs - kMacToUnixEpochSeconds;
}

static void screen_size(short *w, short *h)
{
    GDHandle device = GetMainDevice();

    *w = 0;
    *h = 0;
    if (device != NULL) {
        Rect r = (**device).gdRect;

        *w = (short)(r.right - r.left);
        *h = (short)(r.bottom - r.top);
    }
}

/* One process's windows, appended under an already-added row. The
   reader's status decides whether anything may be appended at all;
   assembly enforces that independently (a refused verdict admits no
   window), so this is the collector asking rather than deciding. */
static void collect_windows(NowScene *s, int row,
                            const ProcessSerialNumber *psn)
{
    NowPeekWindowList list;
    short i;

    if (!now_scene_anchor_admits_windows(s->procs[row].anchor)) {
        return;
    }
    memset(&list, 0, sizeof list);
    if (now_peek_windows_for_psn(psn, &list) != kNowPeekReadOk) {
        return;
    }
    /* The stamp arrives WITH the walk, not before it - the reader
       reports when the anchor was captured alongside what it found - so
       the row's age is settled here rather than at add time. */
    now_scene_set_process_stamp(s, row, list.stamp_ticks);
    for (i = 0; i < list.count; ++i) {
        const NowPeekWindow *w = &list.windows[i];

        /* `visible` is true because the reader walks the Window
           Manager's window list, whose members are the windows the
           machine has; NOW cannot read the visible flag through the
           validated path yet, so this is the honest floor and is stated
           in docs/scene-producer.md rather than dressed up as measured. */
        (void)now_scene_add_window(s, row, w->title, w->top, w->left,
                                   w->bottom, w->right, 1);
    }
    if (list.more) {
        s->windows_truncated = 1;
    }
}

void now_scene_collect(NowScene *out, long seq,
                       unsigned long stale_after_ticks)
{
    ProcessSerialNumber psn = { 0, kNoProcess };
    ProcessSerialNumber front;
    ProcessSerialNumber psns[kSceneCollectMaxPsns];
    Boolean have_front;
    short w = 0, h = 0;
    unsigned long t_start = TickCount();
    int rows = 0;
    int i;
    int pass;

    if (out == NULL) {
        return;
    }
    screen_size(&w, &h);
    now_scene_begin(out, seq, captured_at_now(), "peek", w, h,
                    (unsigned long)TickCount(), stale_after_ticks);
    now_scene_set_plane(out, "peek anchors: processes + windows, no menus");

    have_front = GetFrontProcess(&front) == noErr;
    while (rows < kSceneCollectMaxPsns && GetNextProcess(&psn) == noErr) {
        ProcessInfoRec info;
        Str31 name;
        Boolean is_front = false;
        char cname[kNowSceneNameMax];
        short len;
        int row;
        NowPeekReadStatus st;
        short unused_count = 0;

        memset(&info, 0, sizeof info);
        info.processInfoLength = sizeof info;
        info.processName = name;
        info.processAppSpec = NULL;
        name[0] = 0;
        if (GetProcessInformation(&psn, &info) != noErr) {
            continue;
        }
        len = name[0];
        if (len > kNowSceneNameMax - 1) {
            len = kNowSceneNameMax - 1;
        }
        memcpy(cname, name + 1, (size_t)len);
        cname[len] = '\0';
        if (have_front) {
            (void)SameProcess(&psn, &front, &is_front);
        }
        /* The cheap variant: it runs the same resolve() - the same
           oracle verdict, the same validation - without reading titles,
           so a process whose anchor is refused costs one lookup and the
           scene still learns WHY. */
        st = now_peek_window_count(&psn, &unused_count);
        row = now_scene_add_process(out, psn.highLongOfPSN,
                                    (unsigned long)psn.lowLongOfPSN, cname,
                                    (unsigned long)info.processSignature,
                                    is_front ? 1 : 0, (NowSceneAnchor)st,
                                    0);
        if (row < 0) {
            break;                    /* assembly recorded the truncation */
        }
        psns[row] = psn;
        ++rows;
    }
    /* Windows front process first, then the rest in Process Manager
       order. Within a process the chain IS the stacking order and z says
       so; ACROSS processes only the front app's position is knowable
       from here, so that is the only cross-process claim the ordering
       makes. */
    for (pass = 0; pass < 2; ++pass) {
        for (i = 0; i < rows; ++i) {
            if ((pass == 0) == (out->procs[i].front != 0)) {
                collect_windows(out, i, &psns[i]);
            }
        }
    }
    out->latency_ms = (long)((TickCount() - t_start) * 1000UL / 60UL);
}
