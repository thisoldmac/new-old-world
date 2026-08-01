#include "scene_collect.h"

#include <Processes.h>
#include <Quickdraw.h>

#include <string.h>

#include "axprocess.h"
#include "peek_read.h"
#include "scene_walk.h"

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

/* One process's windows and their sub-planes, appended under an
   already-added row. The reader's status decides whether anything may be
   appended at all; assembly enforces that independently (a refused
   verdict admits no window), so this is the collector asking rather than
   deciding.

   TWO READERS, ONE CHAIN, MATCHED BY ADDRESS. peek_read.c produces the
   window rows (its rect is the STRUCTURE region - the frame a person
   sees) and reports each row's WindowRecord address; the ported walk
   then returns to that exact record for the controls, the kind and the
   dialog text. Matching by address rather than by position is what makes
   the pairing exact: peek_read.c skips a window whose bounds are insane
   and the ax walk would not, so counting along both chains would misfile
   every control after the first such skip. */
static void collect_process(NowScene *s, int row,
                            const ProcessSerialNumber *psn, Boolean is_self)
{
    NowPeekWindowList list;
    NowAxContext ctx;
    int bound;
    short i;

    if (!now_scene_anchor_admits_windows(s->procs[row].anchor)) {
        return;
    }
    /* Self is never walked, and that is a stated limit rather than an
       oversight: NOW is Carbon, so its own window and menu records do
       not sit at the classic offsets the walk reads (axprocess.h says
       the same). Its windows come from the Window Manager and carry no
       record address; its sub-planes stay absent. */
    bound = !is_self
        && now_ax_bind_process(psn, &ctx) == kNowPeekReadOk;

    memset(&list, 0, sizeof list);
    if (now_peek_windows_for_psn(psn, &list) == kNowPeekReadOk) {
        /* The stamp arrives WITH the walk, not before it - the reader
           reports when the anchor was captured alongside what it
           found - so the row's age is settled here rather than at add
           time. */
        now_scene_set_process_stamp(s, row, list.stamp_ticks);
        for (i = 0; i < list.count; ++i) {
            const NowPeekWindow *w = &list.windows[i];

            /* `visible` is true because the reader walks the Window
               Manager's window list, whose members are the windows the
               machine has; NOW cannot read the visible flag through the
               validated path yet, so this is the honest floor and is
               stated in docs/scene-producer.md rather than dressed up as
               measured. */
            if (!now_scene_add_window(s, row, w->title, w->top, w->left,
                                      w->bottom, w->right, 1)) {
                continue;
            }
            if (bound && w->address != 0) {
                now_scene_walk_window(s, now_scene_last_window(s),
                                      &ctx.memory, w->address);
            }
        }
        if (list.more) {
            s->windows_truncated = 1;
        }
    }
    /* One menu bar per machine, and it is the front process's. A back
       process's MenuList is real but is not what the screen shows, so
       reporting it as `menubar` would be a true fact filed under a false
       name. */
    if (bound && s->procs[row].front) {
        now_scene_walk_menubar(s, row, &ctx.memory, ctx.menu_list);
    }
}

void now_scene_collect(NowScene *out, long seq,
                       unsigned long stale_after_ticks)
{
    ProcessSerialNumber psn = { 0, kNoProcess };
    ProcessSerialNumber front;
    ProcessSerialNumber psns[kSceneCollectMaxPsns];
    ProcessSerialNumber self;
    Boolean selves[kSceneCollectMaxPsns];
    Boolean have_self;
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
    now_scene_set_plane(out, "peek anchors: processes, windows, controls, "
                        "dialog text, and the front app's menu bar");

    have_front = GetFrontProcess(&front) == noErr;
    have_self = GetCurrentProcess(&self) == noErr;
    while (rows < kSceneCollectMaxPsns && GetNextProcess(&psn) == noErr) {
        ProcessInfoRec info;
        Str31 name;
        Boolean is_front = false;
        Boolean is_self = false;
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
        if (have_self) {
            (void)SameProcess(&psn, &self, &is_self);
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
        selves[row] = is_self;
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
                collect_process(out, i, &psns[i], selves[i]);
            }
        }
    }
    out->latency_ms = (long)((TickCount() - t_start) * 1000UL / 60UL);
}
