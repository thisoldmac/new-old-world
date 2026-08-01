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
    copy_bounded(c->title, (long)sizeof c->title, title);
    c->rect.t = t;
    c->rect.l = l;
    c->rect.b = b;
    c->rect.r = r;
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
    copy_bounded(m->title, (long)sizeof m->title, title);
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
    copy_bounded(it->title, (long)sizeof it->title, title);
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

/* --- the desktop plane --------------------------------------------------- */

int now_scene_open_desktop_items(NowScene *s)
{
    if (s == NULL) {
        return 0;
    }
    s->desktop_items_present = 1;
    return 1;
}

int now_scene_add_desktop_item(NowScene *s, const char *name,
                               const char *kind, int has_type,
                               unsigned long file_type, unsigned long creator,
                               short x, short y, int alias, int invisible)
{
    NowSceneDesktopItem *d;

    if (s == NULL) {
        return 0;
    }
    /* The Finder does not draw an invisible item, so this scene does not
       report one either - refused independently of whatever the walk
       passed in, the same shape now_scene_add_window already uses for a
       disallowed anchor. Nothing is opened or counted for a refusal:
       an invisible item was never a candidate row, not a dropped one. */
    if (invisible) {
        return 0;
    }
    now_scene_open_desktop_items(s);
    if (s->desktop_item_count >= kNowSceneMaxDesktopItems) {
        s->desktop_items_truncated = 1;
        return 0;
    }
    d = &s->desktop_items[s->desktop_item_count];
    memset(d, 0, sizeof *d);
    copy_bounded(d->name, (long)sizeof d->name, name);
    copy_bounded(d->kind, (long)sizeof d->kind, kind);
    d->has_type = has_type ? 1 : 0;
    d->file_type = d->has_type ? file_type : 0;
    d->creator = d->has_type ? creator : 0;
    d->x = x;
    d->y = y;
    /* {0,0} means never placed - a Desktop Folder item the Finder has
       not laid out yet, or a volume this producer never places at all
       (the walk always passes 0,0 for one; see scene_desktop.c). */
    d->placed = !(x == 0 && y == 0);
    d->alias = alias ? 1 : 0;
    ++s->desktop_item_count;
    return 1;
}
