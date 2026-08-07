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

/* --- title hygiene ----------------------------------------------------
 *
 * A title reaches this file having been read out of foreign memory at a
 * literal byte offset. When the offset is right the bytes are a Pascal
 * string; when the record is not what the walk believed it to be, the
 * SAME bytes are whatever else lives there - most often the high half of
 * a 68K address, because pointers are what fill a Toolbox record.
 *
 * Sweep A (docs/fidelity-sweep-2026-08-07-a.md) priced that: Memory 21,
 * Monitors 13, Mouse 12, General Controls 7, Date & Time 6, Set Time
 * Zone 5, and the application-switcher menu's own title arriving as
 * '\x01\x1f@"\xcf'. The host renders whatever it is handed, so eight
 * bytes of address became a label a person read.
 *
 * The rule, and it is deliberately one-way: a title the guest cannot
 * vouch for is OMITTED. An absent title says "this element has no name I
 * could read", which is true and which the host already draws as an
 * unnamed row. A present-but-wrong title is the confident wrong answer
 * plan 018 rule 1 forbids, and no consumer can detect it. */
int now_scene_title_is_publishable(const char *title)
{
    long i;

    if (title == NULL || title[0] == '\0') {
        return 1;                     /* absent is honest */
    }
    /* THE ONE DOCUMENTED EXCEPTION. The Apple menu's title in the system
       font is the single byte 0x14 - a Menu Manager convention, not
       corruption, and now_scene_fill_blank_system_apple() finds that menu
       by exactly this byte. Dropping it would take the Apple menu's
       identity with it. */
    if ((unsigned char)title[0] == 0x14 && title[1] == '\0') {
        return 1;
    }
    for (i = 0; title[i] != '\0'; ++i) {
        unsigned char c = (unsigned char)title[i];

        /* Control bytes and DEL are not text. Everything from 0x80 up
           IS: MacRoman spends that half on accented letters, the Apple
           glyph's siblings and the box-drawing characters, all of which
           appear in real Mac OS 9 labels.

           A menu title beginning 0x01 or 0x05 is the Menu Manager's
           icon-title convention rather than a string; it fails here for
           the same reason and with the same consequence - the title is
           omitted, and the menu is still addressable by id. */
        if (c < 0x20 || c == 0x7F) {
            return 0;
        }
    }
    return 1;
}

/* Titles go through here and nothing else does. copy_bounded still
   serves refs, provenance and values, which are minted by this side and
   are not foreign bytes. */
static void copy_title(char *out, long cap, const char *src)
{
    if (!now_scene_title_is_publishable(src)) {
        out[0] = '\0';
        return;
    }
    copy_bounded(out, cap, src);
}

/* --- rect hygiene -----------------------------------------------------
 *
 * The same corruption reaches the geometry: sweep A found l = 16584 and
 * l = 16504 in Energy Saver and eighteen out-of-port rects in Memory,
 * the 16xxx family being the top half of an address read as a short.
 *
 * kNowSceneCoordSane is stated once, here. Classic Mac OS QuickDraw is a
 * 16-bit coordinate space and a real control lives on a screen; the
 * largest display any of these machines drives is under 2048 pixels on
 * its long edge, so a coordinate past 4096 in either direction is not a
 * position, it is a misread. The bound is generous on purpose - this is
 * a lie detector, not a layout rule, and a control legitimately scrolled
 * out of view must survive it. */
enum { kNowSceneCoordSane = 4096 };

static int coord_sane(short v)
{
    return v > -kNowSceneCoordSane && v < kNowSceneCoordSane;
}

int now_scene_rect_is_sane(short t, short l, short b, short r)
{
    return coord_sane(t) && coord_sane(l) && coord_sane(b) && coord_sane(r)
        && t <= b && l <= r;
}

static short clamp_coord(short v, short lo, short hi)
{
    if (v < lo) {
        return lo;
    }
    if (v > hi) {
        return hi;
    }
    return v;
}

/* An insane rect is clamped into the box it claims to sit in, which
   makes it a degenerate rect at that box's edge: it draws as nothing and
   hit-tests as nothing. That is the honest reading of "we do not know
   where this is" in a wire that has no way to say so - and it is
   strictly better than shipping l = 16555, which hit-tests as somewhere.
   A rect that IS sane is passed through untouched; nothing here moves a
   control that was merely scrolled away. */
static void sanitize_rect(NowSceneRect *rect, short height, short width)
{
    if (now_scene_rect_is_sane(rect->t, rect->l, rect->b, rect->r)) {
        return;
    }
    if (height < 0) {
        height = 0;
    }
    if (width < 0) {
        width = 0;
    }
    rect->t = clamp_coord(rect->t, 0, height);
    rect->b = clamp_coord(rect->b, 0, height);
    rect->l = clamp_coord(rect->l, 0, width);
    rect->r = clamp_coord(rect->r, 0, width);
    if (rect->b < rect->t) {
        rect->b = rect->t;
    }
    if (rect->r < rect->l) {
        rect->r = rect->l;
    }
}

/* The content box a content-relative rect must live in, derived from the
   window row the scene already holds. */
static void window_extent(const NowSceneWindow *w, short *height,
                          short *width)
{
    long h = (long)w->rect.b - (long)w->rect.t;
    long v = (long)w->rect.r - (long)w->rect.l;

    if (h < 0 || h > kNowSceneCoordSane) {
        h = 0;
    }
    if (v < 0 || v > kNowSceneCoordSane) {
        v = 0;
    }
    *height = (short)h;
    *width = (short)v;
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
    /* AN ERROR WORD FOR A NORMAL CONDITION IS STILL A WRONG ANSWER.
       `ax_oracle_not_found` means "we expected an anchor for this
       process and there was none" - a failure to see. A process that
       declared `modeOnlyBackground` has no user interface by design, so
       there is nothing for an anchor to point at and its absence is the
       EXPECTED state, not a defect. Six healthy processes on a good boot
       (Control Strip Extension, DVD AutoLauncher, FBC Indexing
       Scheduler, Folder Actions, tbt-appe, tbt-worker) reported that
       token, and it is the same defect class as a confident wrong pixel:
       an assertion of failure where the honest answer is "this process
       has no UI by design", which `backgroundOnly` now states directly.

       ONLY that one pair is suppressed. Ambiguous, Mismatch, Unreadable
       and NoPlane are real failures whether or not the process has a
       face - NoPlane in particular says we could not look at ANY process
       - and a faceless process is owed those verdicts as much as any
       other. */
    if (p->background_only && p->anchor == kNowSceneAnchorNotFound) {
        return p->stale ? now_scene_stale_error() : NULL;
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

/* Staleness is DERIVED, not passed: the reader runs with no age gate
   (peek_read.c states why), so an old anchor arrives as Ok with an old
   stamp and this is the only place the age is looked at. A zero window
   disables it; a stamp in the future - a clock that moved backwards - is
   not stale, it is zero-aged. */
static void derive_stale(const NowScene *s, NowSceneProc *p)
{
    p->stale = (s->stale_after_ticks != 0
                && now_scene_anchor_admits_windows(p->anchor)
                && s->now_ticks > p->stamp_ticks
                && s->now_ticks - p->stamp_ticks > s->stale_after_ticks)
        ? 1 : 0;
}

void now_scene_begin(NowScene *s, long seq, double captured_at,
                     const char *source, short screen_w, short screen_h,
                     unsigned long now_ticks, unsigned long stale_after_ticks)
{
    if (s == NULL) {
        return;
    }
    memset(s, 0, sizeof *s);
    s->menubar_proc = -1;             /* memset would say "process 0" */
    s->version = NOW_SCENE_IR_VERSION;
    s->seq = seq;
    s->captured_at = captured_at;
    copy_bounded(s->source, (long)sizeof s->source, source);
    s->screen_w = screen_w;
    s->screen_h = screen_h;
    s->latency_ms = -1;               /* absent until measured */
    /* memset gave these 0, which is BLACK - a legal colour, and so the
       one value that cannot double as "not asked". */
    s->theme.dialog_background = -1;
    s->theme.alert_background = -1;
    s->theme.document_background = -1;
    s->theme.highlight = -1;
    s->theme.depth = -1;
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
    derive_stale(s, p);
    return s->proc_count++;
}

void now_scene_set_processes_coverage(NowScene *s,
                                      NowSceneCoverage coverage)
{
    if (s != NULL) {
        s->processes_coverage = coverage;
    }
}

void now_scene_set_process_incarnation(NowScene *s, int proc,
                                       unsigned long incarnation)
{
    if (s == NULL || proc < 0 || proc >= s->proc_count) {
        return;
    }
    s->procs[proc].incarnation = incarnation;
}

void now_scene_set_windows_coverage(NowScene *s, int proc,
                                    NowSceneCoverage coverage)
{
    if (s == NULL || proc < 0 || proc >= s->proc_count) {
        return;
    }
    s->procs[proc].windows_coverage = coverage;
}

void now_scene_set_process_kind_coverage(NowScene *s,
                                         NowSceneCoverage coverage)
{
    if (s != NULL) {
        s->process_kind_coverage = coverage;
    }
}

void now_scene_set_depth_coverage(NowScene *s, NowSceneCoverage coverage)
{
    if (s != NULL) {
        s->depth_coverage = coverage;
    }
}

void now_scene_set_depth_evicted(NowScene *s, unsigned long evicted)
{
    if (s != NULL) {
        s->depth_evicted = evicted;
    }
}

void now_scene_set_process_background_only(NowScene *s, int proc,
                                           int background_only)
{
    if (s == NULL || proc < 0 || proc >= s->proc_count) {
        return;
    }
    s->procs[proc].background_only = background_only ? 1 : 0;
}

void now_scene_set_process_stamp(NowScene *s, int proc,
                                 unsigned long stamp_ticks)
{
    if (s == NULL || proc < 0 || proc >= s->proc_count) {
        return;
    }
    s->procs[proc].stamp_ticks = stamp_ticks;
    derive_stale(s, &s->procs[proc]);
}

void now_scene_set_plane(NowScene *s, const char *plane)
{
    if (s != NULL) {
        copy_bounded(s->plane, (long)sizeof s->plane, plane);
    }
}

/* One channel's worth of sanity. An RGBColor is 16 bits per channel on
   this machine and the caller narrows it; anything that arrives outside
   the 24-bit range did not come from that narrowing, so it is rejected
   rather than masked - a masked colour is indistinguishable from a
   measured one, which is the whole defect this field exists to end. */
static long theme_channel(long v)
{
    return (v >= 0 && v <= 0xFFFFFFL) ? v : -1;
}

void now_scene_set_theme(NowScene *s, const NowSceneTheme *theme)
{
    if (s == NULL) {
        return;
    }
    if (theme == NULL) {
        return;
    }
    s->theme.dialog_background = theme_channel(theme->dialog_background);
    s->theme.alert_background = theme_channel(theme->alert_background);
    s->theme.document_background = theme_channel(theme->document_background);
    s->theme.highlight = theme_channel(theme->highlight);
    s->theme.depth = theme->depth;
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
    w->text = -1;                     /* memset would say "text row 0" */
    w->proc = (short)proc;
    copy_title(w->title, (long)sizeof w->title, title);
    w->rect.t = t;
    w->rect.l = l;
    w->rect.b = b;
    w->rect.r = r;
    w->visible = visible ? 1 : 0;
    w->z = p->window_count;
    /* Front means the frontmost VISIBLE window of the front process. An
       invisible utility window can precede the application's visible one in
       WindowList; using z==0 made Key Caps own the menu bar while its only
       visible window drew inactive chrome. */
    w->front = 0;
    if (p->front && w->visible) {
        short i;
        int visible_before = 0;

        for (i = 0; i < s->window_count; ++i) {
            if (s->windows[i].proc == proc && s->windows[i].visible) {
                visible_before = 1;
                break;
            }
        }
        w->front = visible_before ? 0 : 1;
    }
    /* "<psn>/<title>#<idx>" - upstream's own id form (SceneBuilder), so
       an id minted here means the same thing as one minted there.
       Formatted through a local: writing into w->id while reading
       w->title is one object's fields feeding snprintf's restrict-
       qualified destination, and Retro68's GCC rejects it outright
       (-Wrestrict, -Werror) - correctly, since the two do overlap as far
       as the compiler can prove. */
    {
        char id[kNowSceneIdMax];

        snprintf(id, sizeof id, "%ld.%lu/%s#%d", p->psn.hi, p->psn.lo,
                 w->title, (int)w->z);
        copy_bounded(w->id, (long)sizeof w->id, id);
    }
    ++p->window_count;
    ++s->window_count;
    return 1;
}

/* --- the walked sub-planes --------------------------------------------- */

void now_scene_set_window_addr(NowScene *s, int index, unsigned long addr)
{
    if (s == NULL || index < 0 || index >= s->window_count) {
        return;
    }
    s->windows[index].addr = addr;
}

int now_scene_last_window(const NowScene *s)
{
    if (s == NULL || s->window_count <= 0) {
        return -1;
    }
    return s->window_count - 1;
}

static NowSceneWindow *window_at(NowScene *s, int window)
{
    if (s == NULL || window < 0 || window >= s->window_count) {
        return NULL;
    }
    return &s->windows[window];
}

void now_scene_set_window_kind(NowScene *s, int window, short kind)
{
    NowSceneWindow *w = window_at(s, window);

    if (w != NULL) {
        w->kind = kind;
        w->kind_known = 1;
    }
}

int now_scene_open_controls(NowScene *s, int window)
{
    NowSceneWindow *w = window_at(s, window);

    if (w == NULL) {
        return 0;
    }
    if (!w->controls_present) {
        w->controls_present = 1;
        w->first_control = s->control_count;
        w->control_count = 0;
    }
    return 1;
}

/* The pool is filled one owner at a time, so an owner's block is always
   the tail while it is being filled. Anything else means two owners are
   interleaving, and an entry appended then would silently belong to the
   wrong one - which is a misattribution, not an overflow, so it is
   refused rather than flagged. */
static int block_is_tail(short first, short count, short total)
{
    return (int)first + (int)count == (int)total;
}

int now_scene_add_control(NowScene *s, int window, const char *title,
                          short t, short l, short b, short r,
                          int enabled, int visible,
                          short value, short min, short max)
{
    NowSceneWindow *w = window_at(s, window);
    NowSceneControl *c;

    if (w == NULL || !now_scene_open_controls(s, window)) {
        return 0;
    }
    if (!block_is_tail(w->first_control, w->control_count, s->control_count)) {
        return 0;
    }
    if (s->control_count >= kNowSceneMaxControls) {
        s->controls_truncated = 1;
        return 0;
    }
    c = &s->controls[s->control_count];
    memset(c, 0, sizeof *c);
    copy_title(c->title, (long)sizeof c->title, title);
    c->rect.t = t;
    c->rect.l = l;
    c->rect.b = b;
    c->rect.r = r;
    {
        short height, width;

        window_extent(w, &height, &width);
        sanitize_rect(&c->rect, height, width);
    }
    c->enabled = enabled ? 1 : 0;
    c->visible = visible ? 1 : 0;
    c->value = value;
    c->min = min;
    c->max = max;
    ++w->control_count;
    ++s->control_count;
    return 1;
}

/* A reference is copied whole or not at all. `copy_bounded` truncates,
   which is right for a title a person reads and catastrophic for a
   token: a shortened reference is still well formed to every shape check
   on both sides of the wire and resolves to nothing, so it would present
   as "this element went away" rather than as a producer bug. */
static void copy_ref(char *dst, long cap, const char *ref)
{
    long len;

    dst[0] = '\0';
    if (ref == NULL) {
        return;
    }
    len = (long)strlen(ref);
    if (len == 0 || len >= cap) {
        return;
    }
    memcpy(dst, ref, (size_t)len + 1);
}

void now_scene_set_window_ref(NowScene *s, int window, const char *ref)
{
    NowSceneWindow *w = window_at(s, window);

    if (w != NULL) {
        copy_ref(w->ref, (long)sizeof w->ref, ref);
    }
}

int now_scene_last_control(const NowScene *s, int window)
{
    const NowSceneWindow *w;

    if (s == NULL || window < 0 || window >= s->window_count) {
        return -1;
    }
    w = &s->windows[window];
    return (w->control_count > 0) ? (int)w->control_count - 1 : -1;
}

void now_scene_set_control_role(NowScene *s, int window, int index,
                                const char *role)
{
    NowSceneWindow *w = window_at(s, window);
    NowSceneControl *c;

    if (w == NULL || !w->controls_present) {
        return;
    }
    if (index < 0 || index >= (int)w->control_count) {
        return;
    }
    c = &s->controls[w->first_control + index];
    c->role[0] = '\0';
    if (role != NULL && role[0] != '\0') {
        strncpy(c->role, role, sizeof c->role - 1);
        c->role[sizeof c->role - 1] = '\0';
    }
}

void now_scene_set_control_definition(NowScene *s, int window, int index,
                                      short origin)
{
    NowSceneWindow *w = window_at(s, window);

    if (w == NULL || !w->controls_present) {
        return;
    }
    if (index < 0 || index >= (int)w->control_count) {
        return;
    }
    s->controls[w->first_control + index].definition = origin;
}

void now_scene_set_control_cdef(NowScene *s, int window, int index,
                                short state, short id, short variant)
{
    NowSceneWindow *w = window_at(s, window);
    NowSceneControl *c;

    if (w == NULL || !w->controls_present) {
        return;
    }
    if (index < 0 || index >= (int)w->control_count) {
        return;
    }
    c = &s->controls[w->first_control + index];
    c->cdef_state = state;
    c->cdef_id = id;
    c->cdef_variant = variant;
}

void now_scene_set_control_semantic_value(NowScene *s, int window, int index,
                                          const char *value)
{
    NowSceneWindow *w = window_at(s, window);
    NowSceneControl *c;

    if (w == NULL || !w->controls_present
        || index < 0 || index >= (int)w->control_count) {
        return;
    }
    c = &s->controls[w->first_control + index];
    c->semantic_value_known = value != NULL ? 1 : 0;
    copy_bounded(c->semantic_value, (long)sizeof c->semantic_value,
                 value != NULL ? value : "");
}

void now_scene_begin_control_list(NowScene *s, int window, int index,
                                  unsigned short total_count, int complete)
{
    NowSceneWindow *w = window_at(s, window);
    NowSceneControl *c;

    if (w == NULL || !w->controls_present
        || index < 0 || index >= (int)w->control_count) {
        return;
    }
    c = &s->controls[w->first_control + index];
    c->list_cells_present = 1;
    c->first_list_cell = s->list_cell_count;
    c->list_cell_count = 0;
    c->list_total_count = total_count;
    c->list_cells_complete = complete ? 1 : 0;
}

int now_scene_add_control_list_cell(NowScene *s, int window, int index,
                                    short row, short column,
                                    const char *text, int selected)
{
    NowSceneWindow *w = window_at(s, window);
    NowSceneControl *c;
    NowSceneListCell *cell;

    if (w == NULL || !w->controls_present
        || index < 0 || index >= (int)w->control_count) {
        return 0;
    }
    c = &s->controls[w->first_control + index];
    if (!c->list_cells_present
        || !block_is_tail(c->first_list_cell, c->list_cell_count,
                          s->list_cell_count)) {
        return 0;
    }
    if (s->list_cell_count >= kNowSceneMaxListCells) {
        s->list_cells_truncated = 1;
        c->list_cells_complete = 0;
        return 0;
    }
    cell = &s->list_cells[s->list_cell_count];
    memset(cell, 0, sizeof *cell);
    cell->row = row;
    cell->column = column;
    cell->selected = selected ? 1 : 0;
    copy_title(cell->text, (long)sizeof cell->text, text);
    ++c->list_cell_count;
    ++s->list_cell_count;
    return 1;
}

void now_scene_set_control_ref(NowScene *s, int window, int index,
                               const char *ref)
{
    NowSceneWindow *w = window_at(s, window);

    if (w == NULL || !w->controls_present) {
        return;
    }
    if (index < 0 || index >= (int)w->control_count) {
        return;
    }
    copy_ref(s->controls[w->first_control + index].ref,
             (long)sizeof s->controls[0].ref, ref);
}

void now_scene_set_control_handle(NowScene *s, int window, int index,
                                  unsigned long handle)
{
    NowSceneWindow *w = window_at(s, window);

    if (w == NULL || !w->controls_present
        || index < 0 || index >= (int)w->control_count) {
        return;
    }
    s->controls[w->first_control + index].handle = handle;
}

void now_scene_retract_controls(NowScene *s, int window)
{
    NowSceneWindow *w = window_at(s, window);

    if (w == NULL || !w->controls_present) {
        return;
    }
    if (!block_is_tail(w->first_control, w->control_count, s->control_count)) {
        return;
    }
    s->control_count = w->first_control;
    w->controls_present = 0;
    w->control_count = 0;
    w->first_control = 0;
    s->controls_truncated = 1;        /* never a silent drop */
    /* ...and never an ANONYMOUS one. The scene-wide flag above says a
       window lost its controls; this says which. Set here rather than at
       the call sites so a new one cannot forget it. */
    w->walk_verdict = w->walk_verdict == kNowSceneWalkDialogItemsRetracted
                    ? kNowSceneWalkControlsAndItemsRetracted
                    : kNowSceneWalkControlsRetracted;
}

void now_scene_set_walk_verdict(NowScene *s, int window, short verdict)
{
    NowSceneWindow *w = window_at(s, window);

    if (w != NULL && w->walk_verdict != kNowSceneWalkOk) {
        w->walk_verdict = verdict;
    }
}

void now_scene_set_control_chain_len(NowScene *s, int window, short len,
                                     int exact)
{
    NowSceneWindow *w = window_at(s, window);

    if (w != NULL && len >= 0) {
        w->control_chain_len = len;
        w->control_chain_len_exact = exact ? 1 : 0;
    }
}

void now_scene_note_window_unreadable(NowScene *s, int window)
{
    NowSceneWindow *w = window_at(s, window);

    if (w != NULL) {
        w->walk_verdict = kNowSceneWalkRecordUnreadable;
    }
}

int now_scene_open_dialog_items(NowScene *s, int window)
{
    NowSceneWindow *w = window_at(s, window);

    if (w == NULL) {
        return 0;
    }
    if (!w->dialog_items_present) {
        w->dialog_items_present = 1;
        w->first_dialog_item = s->dialog_item_count;
        w->dialog_item_count = 0;
    }
    return 1;
}

int now_scene_add_dialog_item(NowScene *s, int window, short number,
                              short kind, const char *title,
                              short t, short l, short b, short r,
                              int enabled, int visible)
{
    NowSceneWindow *w = window_at(s, window);
    NowSceneDialogItem *item;

    if (w == NULL || !now_scene_open_dialog_items(s, window)) {
        return 0;
    }
    if (!block_is_tail(w->first_dialog_item, w->dialog_item_count,
                       s->dialog_item_count)) {
        return 0;
    }
    if (s->dialog_item_count >= kNowSceneMaxDialogItems) {
        s->dialog_items_truncated = 1;
        return 0;
    }
    item = &s->dialog_items[s->dialog_item_count];
    memset(item, 0, sizeof *item);
    item->number = number;
    item->kind = kind;
    copy_title(item->title, (long)sizeof item->title, title);
    item->rect.t = t;
    item->rect.l = l;
    item->rect.b = b;
    item->rect.r = r;
    {
        short height, width;

        window_extent(w, &height, &width);
        sanitize_rect(&item->rect, height, width);
    }
    item->enabled = enabled ? 1 : 0;
    item->visible = visible ? 1 : 0;
    copy_bounded(item->provenance, (long)sizeof item->provenance,
                 "guest-ditl");
    ++w->dialog_item_count;
    ++s->dialog_item_count;
    return 1;
}

void now_scene_set_dialog_item_provenance(NowScene *s, int window, int index,
                                          const char *provenance)
{
    NowSceneWindow *w = window_at(s, window);

    if (w == NULL || !w->dialog_items_present
        || index < 0 || index >= (int)w->dialog_item_count) {
        return;
    }
    copy_bounded(s->dialog_items[w->first_dialog_item + index].provenance,
                 (long)sizeof s->dialog_items[0].provenance,
                 provenance != NULL ? provenance : "");
}

void now_scene_retract_dialog_items(NowScene *s, int window)
{
    NowSceneWindow *w = window_at(s, window);

    if (w == NULL || !w->dialog_items_present) {
        return;
    }
    if (!block_is_tail(w->first_dialog_item, w->dialog_item_count,
                       s->dialog_item_count)) {
        return;
    }
    s->dialog_item_count = w->first_dialog_item;
    w->dialog_items_present = 0;
    w->dialog_item_count = 0;
    w->first_dialog_item = 0;
    s->dialog_items_truncated = 1;
    w->walk_verdict = w->walk_verdict == kNowSceneWalkControlsRetracted
                    ? kNowSceneWalkControlsAndItemsRetracted
                    : kNowSceneWalkDialogItemsRetracted;
}

void now_scene_set_window_text(NowScene *s, int window, const char *content,
                               int active, int truncated)
{
    NowSceneWindow *w = window_at(s, window);
    NowSceneText *x;
    long len;

    if (w == NULL || w->text >= 0) {
        return;
    }
    if (s->text_count >= kNowSceneMaxTexts) {
        s->texts_truncated = 1;
        return;
    }
    x = &s->texts[s->text_count];
    memset(x, 0, sizeof *x);
    copy_bounded(x->content, (long)sizeof x->content, content);
    x->active = active ? 1 : 0;
    /* Truncated is the OR of two clips: the reader's own (the TERec was
       longer than it carries) and this one. Either way the consumer is
       told the text is a prefix. */
    len = (content != NULL) ? (long)strlen(content) : 0;
    x->truncated = (truncated || len >= (long)sizeof x->content) ? 1 : 0;
    w->text = s->text_count;
    ++s->text_count;
}

int now_scene_open_menubar(NowScene *s, int proc)
{
    if (s == NULL || proc < 0 || proc >= s->proc_count) {
        return 0;
    }
    /* The same independent refusal the window rule makes. A menu bar
       read under a refused anchor is the coin-flip walk the validation
       layer exists to decline. */
    if (!now_scene_anchor_admits_windows(s->procs[proc].anchor)) {
        return 0;
    }
    s->menubar_present = 1;
    s->menubar_proc = (short)proc;
    return 1;
}

void now_scene_retract_menubar(NowScene *s)
{
    if (s == NULL || !s->menubar_present) {
        return;
    }
    s->menubar_refused = 1;           /* never a silent drop */
    s->menubar_present = 0;
    s->menubar_proc = -1;
    s->menu_count = 0;
    s->menu_item_count = 0;
}

int now_scene_add_menu(NowScene *s, const char *title, short id, short left)
{
    NowSceneMenu *m;

    if (s == NULL || !s->menubar_present) {
        return -1;
    }
    if (s->menu_count >= kNowSceneMaxMenus) {
        s->menus_truncated = 1;
        return -1;
    }
    m = &s->menus[s->menu_count];
    memset(m, 0, sizeof *m);
    copy_title(m->title, (long)sizeof m->title, title);
    m->id = id;
    m->left = left;
    m->first_item = s->menu_item_count;
    return s->menu_count++;
}

int now_scene_add_menu_item(NowScene *s, int menu, const char *title,
                            short index, int separator, int enabled,
                            int mark, char cmd)
{
    NowSceneMenu *m;
    NowSceneMenuItem *it;

    if (s == NULL || menu < 0 || menu >= s->menu_count) {
        return 0;
    }
    m = &s->menus[menu];
    if (!m->items_present) {
        m->items_present = 1;
        m->first_item = s->menu_item_count;
        m->item_count = 0;
    }
    if (!block_is_tail(m->first_item, m->item_count, s->menu_item_count)) {
        return 0;
    }
    if (s->menu_item_count >= kNowSceneMaxMenuItems) {
        s->menu_items_truncated = 1;
        return 0;
    }
    it = &s->menu_items[s->menu_item_count];
    memset(it, 0, sizeof *it);
    copy_title(it->title, (long)sizeof it->title, title);
    it->index = index;
    it->separator = separator ? 1 : 0;
    it->enabled = enabled ? 1 : 0;
    it->mark = mark ? 1 : 0;
    it->cmd = cmd;
    ++m->item_count;
    ++s->menu_item_count;
    return 1;
}

void now_scene_retract_menu_items(NowScene *s, int menu)
{
    NowSceneMenu *m;

    if (s == NULL || menu < 0 || menu >= s->menu_count) {
        return;
    }
    m = &s->menus[menu];
    if (!m->items_present
        || !block_is_tail(m->first_item, m->item_count, s->menu_item_count)) {
        return;
    }
    s->menu_item_count = m->first_item;
    m->items_present = 0;
    m->item_count = 0;
    m->first_item = 0;
    s->menu_items_truncated = 1;      /* never a silent drop */
}
