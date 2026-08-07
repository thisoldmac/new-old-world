#include "scene_collect.h"

#include <Processes.h>
#include <Quickdraw.h>
#include <Timer.h>

#include <string.h>

#include "axprocess.h"
#include "axwalk.h"
#include "front_order.h"
#include "observe.h"
#include "obsref.h"
#include "peek_read.h"
#include "proc_roster.h"
#include "scene_phase.h"
#include "scene_self.h"
#include "scene_theme.h"
#include "scene_walk.h"
#include "semantic_client.h"

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
    kSceneCollectMaxPsns = kNowSceneMaxProcs,
    /* A window chain longer than this is cyclic or longer than a scene
       carries; either way what stands is a prefix and the scene says so
       rather than walking forever inside another process's heap. */
    kSceneCollectMaxWindowHops = 64
};

/* THE PHASE CLOCK, and the only place a Macintosh appears in the
   breakdown. scene_phase.c is Toolbox-free so its arithmetic can be
   tested by a host compiler; the machine's own microsecond counter is
   handed to it from here.

   `lo` alone is deliberate: the low word wraps about every 71 minutes,
   and every span the breakdown measures is a fraction of one scene, so
   unsigned subtraction across a wrap is exact. Carrying the high word
   would cost a 64-bit add per read to describe an hour nobody measures. */
static int g_phase_clock_installed;

/* THE LAYER LEDGER, and the only long-lived state in this file.
   front_order.h carries the whole argument for why cross-application
   depth has to be watched rather than read; this is the instance, and
   now_scene_note_front_process below is the one call that feeds it. */
static NowFrontOrder g_front_order;
static int g_front_order_ready;

void now_scene_note_front_process(void)
{
    ProcessSerialNumber front;

    if (!g_front_order_ready) {
        g_front_order_ready = 1;
        now_front_order_reset(&g_front_order);
    }
    /* THE PROCESSES FAMILY'S FRONT SAMPLE, not a second GetFrontProcess.
       This file also walks the roster, and a file that does both is
       exactly what `ProcessRosterSingleSourceTests` refuses - the pairing
       is how one reply comes to name two front processes. The rule holds
       here for a subtler reason than usual: this ledger and that walk
       must agree about who is in front, and two calls to the Toolbox
       seconds apart can disagree. One asker, one answer. */
    if (!now_proc_roster_front(&front)) {
        return;                       /* nothing observed, nothing claimed */
    }
    now_front_order_note(&g_front_order,
                         (unsigned long)front.highLongOfPSN,
                         (unsigned long)front.lowLongOfPSN);
}

static unsigned long phase_clock_us(void)
{
    UnsignedWide t;

    Microseconds(&t);
    return t.lo;
}

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
                            const ProcessSerialNumber *psn, Boolean is_self,
                            NowObsWalk *refs)
{
    NowPeekWindowList list;
    NowAxContext ctx;
    int bound;
    short i;
    int windows_truncated_before = s->windows_truncated;

    now_scene_set_windows_coverage(s, row, kNowSceneCoverageUnavailable);

    /* THE BIND COMES FIRST, and it used to come after a gate that
       returned before it.
     *
     * The gate was peek_read's verdict, taken in the enumeration loop by
     * now_peek_window_count. When that answered NoWindows - which is not
     * an error and so publishes no token - this function returned
     * immediately: no bind, no windows, no controls, and nothing said.
     *
     * Measured 2026-08-02, Finder in front: `axsnap` reported the Finder
     * bind=ok with hasWindows=true, `observe` returned its Desktop
     * window with a minted ref, and the scene of the same machine at the
     * same moment contained one window - NOW's own. Two readers in one
     * binary disagreeing about one process, with the scene taking the
     * answer from the reader that could not see it.
     *
     * So the bind is asked first, and a process that BINDS is walked
     * from its own context regardless of what the other reader thought.
     * peek_read's verdict stays - as a report, which is what it is good
     * at - but it no longer decides whether the walk happens. */
    now_scene_phase_enter(kNowScenePhaseBind);
    bound = !is_self
        && now_ax_bind_process(psn, &ctx) == kNowPeekReadOk;
    now_scene_phase_leave(kNowScenePhaseBind);

    /* SELF IS DESCRIBED, NOT WALKED. NOW is Carbon, so its own records
       are not at the classic offsets the walk reads - but an application
       does not need to walk memory to know its own interface, it asks
       the Toolbox. Skipping self left the largest window on most screens
       mirrored as an empty box with no close box and no content, which
       is what a person sees first. See scene_self.c. */
    if (is_self) {
        now_scene_collect_self(s, row, psn, refs);
        now_scene_set_windows_coverage(
            s, row, s->windows_truncated != windows_truncated_before
                ? kNowSceneCoveragePartial : kNowSceneCoverageComplete);
        return;
    }
    if (!bound && !now_scene_anchor_admits_windows(s->procs[row].anchor)) {
        now_scene_set_windows_coverage(s, row,
                                       kNowSceneCoverageUnavailable);
        return;
    }
    if (bound) {
        /* Every process is still joined against retained semantic facts, but
           only the front process may spend the single resident request cell.
           When an app loses focus its last guest-provided facts become
           expected-stale instead of competing with the app a person is using. */
        now_semantic_client_aim(ctx.a5, s->procs[row].front != 0);
        /* The minting seam is aimed at THIS process before anything is
           read from it, because a reference names its own target: the
           chain it counts occurrences along and the fingerprint it is
           minted against both belong to this partition and to no
           other. */
        now_observe_walk_aim(refs, psn, &ctx);
    }

    /* A BOUND PROCESS IS WALKED FROM ITS OWN CHAIN - the same source
       `observe` reads, which is the one that could see the Finder when
       the scene could not. The rect here is the CONTENT region's box,
       where peek_read reported the STRUCTURE region's; axwalk.h states
       that difference and it is two fields for two questions, not a
       disagreement. A consumer drawing a frame wants the structure box,
       and closing that is its own change - having the windows at all
       comes first. */
    now_scene_phase_enter(kNowScenePhaseWindows);
    if (bound && ctx.window_list != 0) {
        unsigned long addr = ctx.window_list;
        int hops;
        int partial = 0;

        now_scene_set_process_stamp(s, row, ctx.stamp_ticks);
        for (hops = 0; addr != 0 && hops < kSceneCollectMaxWindowHops;
             ++hops) {
            NowAxWindow win;

            if (now_ax_read_window(&ctx.memory, addr, &win)
                    != kNowAxOk) {
                /* The chain left the readable zones or failed a check.
                   What stands is a PREFIX, and saying so is the
                   difference between a short list and a wrong one. */
                s->windows_truncated = 1;
                partial = 1;
                break;
            }
            /* THE BOX, not the content region - and this is now the
               ONLY place in the guest that derives one from the other.
               now_ax_read_window returns both regions; IR v1's
               `windows[].rect` is the content region grown up by a title
               bar, and its consumer recovers the content origin by
               adding the same constant back. Handing over the content
               region makes every control in the window twenty pixels out
               on the consumer's screen; see kNowSceneIRTitleBarHeight for
               the measurement that caught it, and for why the true
               structure region is the wrong answer HERE despite being
               the more faithful one. */
            if (now_scene_add_window(s, row, win.title,
                                     (short)(win.top
                                             - kNowSceneIRTitleBarHeight),
                                     win.left,
                                     win.bottom, win.right,
                                     win.visible ? 1 : 0)) {
                now_scene_set_window_addr(s, now_scene_last_window(s),
                                          (unsigned long)win.address);
                now_scene_walk_window(s, now_scene_last_window(s),
                                      &ctx.memory, win.address, refs);
            }
            addr = win.next_window;
        }
        if (addr != 0) {
            s->windows_truncated = 1;   /* longer than a scene carries */
            partial = 1;
        }
        now_scene_set_windows_coverage(
            s, row, s->procs[row].stale ? kNowSceneCoverageStale
                    : partial ? kNowSceneCoveragePartial
                    : kNowSceneCoverageComplete);
    } else if (bound) {
        /* A validated empty chain is a complete observation of no windows. */
        now_scene_set_windows_coverage(
            s, row, s->procs[row].stale
                ? kNowSceneCoverageStale : kNowSceneCoverageComplete);
    } else if ((memset(&list, 0, sizeof list), 1)
               && now_peek_windows_for_psn(psn, &list) == kNowPeekReadOk) {
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
            /* THE SAME DERIVATION, from this reader's content region -
               which it did not use to return. It published the STRUCTURE
               region here, so an unbound process's windows arrived in a
               different coordinate convention from a bound one's, in the
               same scene, under the same field name. Nothing declared
               which a row held and no consumer could have asked. */
            if (!now_scene_add_window(s, row, w->title,
                                      (short)(w->cont_top
                                              - kNowSceneIRTitleBarHeight),
                                      w->cont_left,
                                      w->cont_bottom, w->cont_right, 1)) {
                continue;
            }
            /* The fallback path is self (Carbon, no record address) or
               an unbound process, so there is no chain to walk into. */
        }
        if (list.more) {
            s->windows_truncated = 1;
        }
        now_scene_set_windows_coverage(
            s, row, s->procs[row].stale ? kNowSceneCoverageStale
                    : list.more ? kNowSceneCoveragePartial
                    : kNowSceneCoverageComplete);
    } else if (s->procs[row].anchor == kNowSceneAnchorNoWindows) {
        now_scene_set_windows_coverage(s, row, kNowSceneCoverageComplete);
    } else {
        now_scene_set_windows_coverage(s, row, kNowSceneCoverageFailed);
    }
    now_scene_phase_leave(kNowScenePhaseWindows);
    /* One menu bar per machine, and it is the front process's. A back
       process's MenuList is real but is not what the screen shows, so
       reporting it as `menubar` would be a true fact filed under a false
       name. */
    now_scene_phase_enter(kNowScenePhaseMenubar);
    if (bound && s->procs[row].front) {
        now_scene_walk_menubar(s, row, &ctx.memory, ctx.menu_list);
    } else if (bound) {
        /* A background process's whole menu bar is not the one on screen,
           so it is never filed as `menubar`. Its validated system Apple
           rows may, however, complete the front Carbon app's exact blank
           shell. The bridge admits only the measured two-NUL system rows
           and preserves the front menu's own IDs and action indices. */
        (void)now_scene_fill_blank_system_apple(
            s, &ctx.memory, ctx.menu_list);
    }
    now_scene_phase_leave(kNowScenePhaseMenubar);
}

void now_scene_collect(NowScene *out, long seq,
                       unsigned long stale_after_ticks)
{
    ProcessSerialNumber psns[kSceneCollectMaxPsns];
    Boolean selves[kSceneCollectMaxPsns];
    /* THE PROCESS FAMILY'S ROW, not a sixth private walk (proc_roster.h).
       The kind, the front sample and the admission rule are the ones
       `process.list` and `ps` serve, so the scene can no longer say
       `ax_oracle_not_found` about a process the processes family calls
       `background` at the same instant. The anchor verdict rides as an
       ADDITIONAL column on that row - it is what this plane knows and
       the others do not. */
    NowProcRosterIter it;
    NowProcRosterRow proc;
    NowObsWalk refs;
    short w = 0, h = 0;
    unsigned long t_start = TickCount();
    int rows = 0;
    int i;

    if (out == NULL) {
        return;
    }
    /* Installed here rather than at startup so that every path which
       produces a scene - the wire, the console, a test harness - gets a
       measured one without having to remember. set_clock discards the
       calibration, so it is done once. */
    if (!g_phase_clock_installed) {
        g_phase_clock_installed = 1;
        now_scene_phase_set_clock(phase_clock_us);
        now_scene_phase_calibrate();
    }
    now_scene_phase_reset();
    screen_size(&w, &h);
    /* ONE epoch for the whole scene, not one per process. What it bounds
       is how much of a SCENE stays addressable, and a scene is what the
       person is looking at when they click; a per-process epoch would
       let the last application walked evict the first one's buttons. */
    now_observe_walk_begin(&refs);
    now_scene_begin(out, seq, captured_at_now(), "peek", w, h,
                    (unsigned long)TickCount(), stale_after_ticks);
    now_scene_set_plane(out, "peek anchors: processes, windows, controls, "
                        "dialog text, and the front app's menu bar");
    /* Asked once per scene, beside the screen size and for the same
       reason: both describe the surface the consumer is redrawing, and a
       theme can be switched while this guest runs. Four Toolbox calls
       against a walk that already costs tens of milliseconds. */
    {
        NowSceneTheme theme;

        now_scene_theme_ask(&theme);
        now_scene_set_theme(out, &theme);
    }
    /* And the desktop, for the same reason and in the same breath: it is
       the largest rectangle the consumer redraws, and until this line the
       only thing that could say what was on it was an offline pack's
       record of a disk image. Two GetTheme collections per sweep rather
       than one is the cost; the alternative was a renderer confidently
       drawing last week's desktop. */
    {
        NowDesktopFacts desktop;

        now_desktop_facts_ask(&desktop);
        now_scene_set_desktop(out, &desktop);
    }
    now_semantic_client_begin((unsigned long)seq);

    now_proc_roster_begin(&it);
    now_scene_phase_enter(kNowScenePhaseEnumerate);
    while (rows < kSceneCollectMaxPsns && now_proc_roster_next(&it, &proc)) {
        char cname[kNowSceneNameMax];
        int row;
        NowPeekReadStatus st;
        short unused_count = 0;

        /* The roster skipped and counted the unreadable rows, so the
           scene's `partial` coverage is derived from ITS number rather
           than from a flag this walk sets for itself. */
        memcpy(cname, proc.name, sizeof cname - 1);
        cname[sizeof cname - 1] = '\0';
        /* The cheap variant: it runs the same resolve() - the same
           oracle verdict, the same validation - without reading titles,
           so a process whose anchor is refused costs one lookup and the
           scene still learns WHY. */
        st = now_peek_window_count(&proc.psn, &unused_count);
        if (proc.is_self) {
            /* The reader's verdict is about a walk this row will not
               take. Self answers from its own Toolbox, so the row is
               admissible on its own authority - otherwise add_window
               refuses it and the description never lands. */
            st = (NowPeekReadStatus)kNowPeekReadOk;
        }
        row = now_scene_add_process(out, proc.psn.highLongOfPSN,
                                    (unsigned long)proc.psn.lowLongOfPSN,
                                    cname, proc.creator,
                                    proc.is_front ? 1 : 0, (NowSceneAnchor)st,
                                    0);
        if (row < 0) {
            break;                    /* assembly recorded the truncation */
        }
        /* THE PROCESS'S OWN DECLARATION, carried on the roster row -
           the SAME kind `process.list` and `ps` serve, not a private
           re-read of the bit. It is the process answering, not us
           inferring, and there is deliberately no path from the walk
           result to this field: inferring it from "we saw no windows"
           is the mistake that made six healthy processes read as
           errors. The Finder is a kind of its own on that row and is
           not background-only, which is why this asks the enum rather
           than the bit. */
        now_scene_set_process_background_only(
            out, row, proc.kind == kNowProcKindBackground);
        now_scene_set_process_incarnation(
            out, row,
            now_obs_process_fingerprint(
                (unsigned long)proc.psn.highLongOfPSN,
                (unsigned long)proc.psn.lowLongOfPSN,
                proc.creator, proc.launch_date, proc.location,
                proc.process_size, proc.pname));
        psns[row] = proc.psn;
        selves[row] = proc.is_self;
        ++rows;
    }
    now_scene_phase_leave(kNowScenePhaseEnumerate);
    now_scene_set_processes_coverage(
        out, (it.unreadable > 0 || rows >= kSceneCollectMaxPsns
              || out->procs_truncated)
            ? kNowSceneCoveragePartial : kNowSceneCoverageComplete);
    /* THE KIND WAS READ FOR EVERY ROW THAT EXISTS. It comes from the same
       ProcessInfoRec as the name, so a row is in this scene exactly when
       its kind was established - and the only way to fall short is a
       GetProcessInformation that failed, which is already counted. Said
       out loud rather than left implicit, because this claim is what
       tells a consumer that an absent `backgroundOnly` means "has a
       face" rather than "this producer does not report kinds". */
    now_scene_set_process_kind_coverage(
        out, it.unreadable > 0 ? kNowSceneCoveragePartial
                               : kNowSceneCoverageComplete);
    /* WINDOWS IN LAYER ORDER, FRONT FIRST - and the array's order is the
       only place a scene has ever carried cross-application stacking.
     *
       Within a process the chain IS the stacking order and z says so.
       Across processes there is nothing to read: WindowList is a
       per-process low-memory global, so no application's chain reaches
       another's. This used to fall back to Process Manager enumeration
       after the front process, which is LAUNCH order - right often
       enough to look right, and watched wrong on 2026-08-07 when the
       render put NOW's sidebar over a Finder window the guest's own
       screendump shows in front of it.
     *
       So the rest are ordered by when they were last seen coming to the
       front, which on a machine that layers by application IS their
       layer order (front_order.h carries the argument). A process this
       ledger has never seen fronted has NO rank; those go behind
       everything ranked, in Process Manager order, and the `depth`
       coverage claim below says the order among them is a fallback
       rather than a claim.
     *
       A selection sort over at most kNowSceneMaxProcs rows, not a
       precomputed permutation: `collect_process` must be called in
       emission order, and rows is small enough that the quadratic is
       cheaper than the array it would otherwise need. */
    {
        Boolean done[kSceneCollectMaxPsns];
        int emitted;
        int ranked = 0;
        int unranked = 0;

        for (i = 0; i < rows; ++i) {
            done[i] = false;
        }
        for (emitted = 0; emitted < rows; ++emitted) {
            int best = -1;
            unsigned long best_seq = 0;

            for (i = 0; i < rows; ++i) {
                unsigned long seq;

                if (done[i]) {
                    continue;
                }
                /* The front process outranks every ledger entry. It is
                   read from the machine at this instant; the ledger is a
                   memory of transitions, and where the two could ever
                   disagree the machine wins. */
                if (out->procs[i].front) {
                    best = i;
                    break;
                }
                seq = now_front_order_seq(&g_front_order,
                                          (unsigned long)psns[i].highLongOfPSN,
                                          (unsigned long)psns[i].lowLongOfPSN);
                if (seq > best_seq) {
                    best_seq = seq;
                    best = i;
                }
            }
            if (best < 0) {
                /* Everything left is unranked. Process Manager order for
                   the remainder, which is what this walk did for every
                   row before the ledger existed. */
                for (i = 0; i < rows; ++i) {
                    if (!done[i]) {
                        best = i;
                        break;
                    }
                }
            }
            if (best < 0) {
                break;                /* cannot happen; not worth looping */
            }
            done[best] = true;
            if (out->procs[best].front
                || now_front_order_seq(
                       &g_front_order,
                       (unsigned long)psns[best].highLongOfPSN,
                       (unsigned long)psns[best].lowLongOfPSN) != 0) {
                ++ranked;
            } else if (!out->procs[best].background_only) {
                /* A faceless background application contributes nothing
                   to the picture, so not knowing where it would sit is
                   not a gap in the ORDER. Counting it would make every
                   scene on every machine read `partial` forever, which
                   is a coverage claim that has stopped saying anything.
                   Read from `background_only`, which enumeration filled
                   above, and NOT from a window count - collect_process
                   has not run for this row yet, so the count is still
                   zero and every process would look faceless. */
                ++unranked;
            }
            collect_process(out, best, &psns[best], selves[best], &refs);
        }
        (void)ranked;
        now_scene_set_depth_coverage(
            out, unranked > 0 ? kNowSceneCoveragePartial
                              : kNowSceneCoverageComplete);
        /* The ledger's own count of what it had to forget. It was already
           kept (front_order.h says why); this is the line that lets a
           consumer read it. Without it a machine that has run more than
           32 applications reports a forgotten process as never-observed,
           which is the empty/unknown conflation in the one plane whose
           subject is order. */
        now_scene_set_depth_evicted(out, g_front_order.evictions);
    }
    now_semantic_client_end();
    now_observe_walk_end(&refs);
    out->latency_ms = (long)((TickCount() - t_start) * 1000UL / 60UL);
}
