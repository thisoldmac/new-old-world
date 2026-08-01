#include "act_cmds.h"

#include <Carbon.h>
#include <stdio.h>
#include <string.h>

#include "act_args.h"
#include "act_client.h"
#include "act_ref.h"
#include "axresolve.h"
#include "axtext.h"
#include "axwalk.h"
#include "cmd_line.h"
#include "json.h"
#include "now_act_guard.h"
#include "nowlog.h"
#include "peek_table.h"

/* The session's minted references. Static, and bounded by the table's
   own slot count: this is the only state the act plane keeps between
   commands, and every entry in it is something a caller observed. */
static NowActRefTable g_refs;

/* Big records stay off the stack - the same discipline the scene
   collector uses, and for the same reason. */
static NowActTarget   g_target;
static NowPeekActCell g_snap;

/* ---- replies ----------------------------------------------------------
 *
 * Every command in this table answers with output.<name> as an array of
 * [label, value] rows (the contract's x-rowArray). The act plane's rows
 * say what was DISPATCHED and, where a re-read was cheap, what the guest
 * itself then held - kept as separate rows so a reader can never mistake
 * the second for a consequence of the first. */

typedef struct {
    char rows[2048];
    long used;
    int  overflow;
} ActRows;

static void rows_reset(ActRows *r)
{
    r->rows[0] = '\0';
    r->used = 0;
    r->overflow = 0;
}

static void row_add(ActRows *r, const char *label, const char *value)
{
    char esc_label[64];
    char esc_value[512];
    int  n;

    if (r->overflow) {
        return;
    }
    now_json_escape(label, esc_label, (long)sizeof esc_label);
    now_json_escape(value, esc_value, (long)sizeof esc_value);
    n = snprintf(r->rows + r->used, (size_t)((long)sizeof r->rows - r->used),
                 "%s[\"%s\",\"%s\"]", r->used > 0 ? "," : "",
                 esc_label, esc_value);
    if (n < 0 || (long)n >= (long)sizeof r->rows - r->used) {
        r->overflow = 1;
        return;
    }
    r->used += n;
}

static void row_addf(ActRows *r, const char *label, const char *fmt, long v)
{
    char value[64];

    snprintf(value, sizeof value, fmt, v);
    row_add(r, label, value);
}

static void reply_rows(char *out, long cap, long id, const char *name,
                       const ActRows *r)
{
    snprintf(out, (size_t)cap,
             "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
             "\"output\":{\"%s\":[%s]}}", id, name, r->rows);
}

static void reply_error(char *out, long cap, long id, const char *code,
                        const char *message)
{
    char esc[512];

    now_json_escape(message, esc, (long)sizeof esc);
    snprintf(out, (size_t)cap,
             "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
             "\"error\":{\"code\":\"%s\",\"message\":\"%s\"}}",
             id, code, esc);
}

static void reply_status(char *out, long cap, long id, NowActStatus st)
{
    reply_error(out, cap, id, now_act_status_code(st),
                now_act_status_message(st));
}

/* The plane's own refusal, which names a condition the status vocabulary
   cannot: "that window is not in the target's list" is a different fact
   from "the target never served it". */
static void reply_plane_error(char *out, long cap, long id,
                              const NowPeekActCell *snap)
{
    reply_error(out, cap, id, now_act_error_code(snap->error),
                now_act_error_message(snap->error));
}

/* ---- arguments -------------------------------------------------------- */

/* Presence, for an integer argument. Two probes with different
   fallbacks: agreeing means the key was really there, and that
   distinction is the whole point of the geometry rule - a `left` that
   defaulted to 0 and a `left` the caller sent are different requests. */
static int arg_int(const char *json, const char *key, long *out)
{
    long a = now_json_find_int(json, key, -2147483647L);
    long b = now_json_find_int(json, key, 2147483646L);

    if (a != b) {
        return 0;
    }
    *out = a;
    return 1;
}

static int arg_str(const char *json, const char *key, char *out, long cap)
{
    out[0] = '\0';
    return now_json_find_string(json, key, out, cap) != 0 && out[0] != '\0';
}

/* ---- resolution and revalidation --------------------------------------
 *
 * A reference names an element this guest observed. Before ANY act, the
 * element is found again in the live process and required to still be
 * the same one - guest-side, by the side that owns the heap, because a
 * host-side match would be a stale observation wearing the clothes of a
 * live one. */

enum { kActMaxWindowWalk = 64 };

/* Find the window this row names: front-first down the live window list,
   counting windows that share a title, bounded and cycle-refusing like
   every other walk in this project. */
static int find_window(NowActTarget *t, const NowActRefRow *row,
                       NowAxWindow *out)
{
    unsigned long address = t->ax.window_list;
    unsigned long seen[kActMaxWindowWalk];
    unsigned int  count = 0;
    unsigned int  matches = 0;

    while (address != 0 && count < kActMaxWindowWalk) {
        NowAxWindow   w;
        unsigned int  i;

        for (i = 0; i < count; i++) {
            if (seen[i] == address) {
                return 0;               /* a cycle proves nothing */
            }
        }
        seen[count++] = address;
        if (now_ax_read_window(&t->ax.memory, address, &w) != kNowAxOk) {
            return 0;
        }
        if ((size_t)w.title_len == row->title_len
            && memcmp(w.title, row->title, row->title_len) == 0) {
            if (matches++ == row->occurrence) {
                *out = w;
                return 1;
            }
        }
        address = w.next_window;
    }
    return 0;
}

/* The whole gate an act passes before anything is dispatched: the plane
   is usable, the reference is one we minted, the target binds, the
   element is still there, and it is still the SAME element. Any of
   those failing writes the reply and returns 0. */
static int resolve_for_act(const char *json, long id, char *out, long cap,
                           unsigned short kind, const NowActRefRow **row_out,
                           NowAxWindow *win_out)
{
    char                ref[kNowActRefMax];
    const NowActRefRow *row;
    NowActStatus        st;
    NowAxWindow         win;
    unsigned long       fingerprint;

    st = now_act_ready();
    if (st != kNowActOk) {
        reply_status(out, cap, id, st);
        return 0;
    }
    if (!arg_str(json, kind == kNowActRefWindow ? "window" : "element",
                 ref, (long)sizeof ref)
        || !now_act_ref_valid(kind, ref)) {
        reply_error(out, cap, id, "bad-request",
                    kind == kNowActRefWindow
                        ? "winact requires window: one opaque now-window- "
                          "reference from a current observation. This "
                          "surface cannot address a window any other way, "
                          "and deliberately has no \"frontmost\" form"
                        : "this command requires element: one opaque "
                          "now-element- reference minted by an observation "
                          "that saw the element");
        return 0;
    }
    row = now_act_ref_find(&g_refs, ref);
    if (row == NULL) {
        reply_error(out, cap, id, "element-not-found",
                    "this Mac did not mint that reference, or it has aged "
                    "out of the observation table. Observe again");
        return 0;
    }
    {
        /* The process the reference was minted against, never "the
           front one": an act that re-resolved to whatever is frontmost
           now would be the target-free form this plane refuses, arrived
           at by the back door. */
        ProcessSerialNumber psn;

        psn.highLongOfPSN = (long)row->psn_hi;
        psn.lowLongOfPSN = (unsigned long)row->psn_lo;
        st = now_act_open(&psn, &g_target);
    }
    if (st != kNowActOk) {
        reply_status(out, cap, id, st);
        return 0;
    }
    if (!find_window(&g_target, row, &win)) {
        reply_error(out, cap, id, "element-not-found",
                    "that window is no longer in the target's window list. "
                    "A reference for a window that has closed is refused, "
                    "never resolved to a neighbouring one");
        return 0;
    }
    /* THE REVALIDATION. Found by name; the fingerprint says whether it
       is the same thing behind the name. */
    fingerprint = now_ax_ref_fingerprint(row->psn_hi, row->psn_lo,
                                         win.address, row->control_handle);
    if (!now_act_ref_still_matches(row, win.address, row->control_handle,
                                   fingerprint)) {
        reply_error(out, cap, id, "element-stale",
                    "that element has moved since it was observed - the "
                    "title still resolves and the thing behind it is not "
                    "the one you named. Observe again");
        return 0;
    }
    *row_out = row;
    if (win_out != NULL) {
        *win_out = win;
    }
    return 1;
}

/* ---- elements: the observation that mints ----------------------------- */

static void mint_window(NowActTarget *t, const NowAxWindow *w,
                        unsigned int occurrence, ActRows *rows)
{
    NowActRefRow  row;
    NowActRefRow *slot;
    char          value[512];

    memset(&row, 0, sizeof row);
    row.kind = kNowActRefWindow;
    row.psn_hi = (unsigned long)t->psn.highLongOfPSN;
    row.psn_lo = (unsigned long)t->psn.lowLongOfPSN;
    row.window_address = w->address;
    row.occurrence = occurrence;
    row.title_len = (size_t)w->title_len;
    memcpy(row.title, w->title, row.title_len);
    row.fingerprint = now_ax_ref_fingerprint(row.psn_hi, row.psn_lo,
                                             w->address, 0);
    slot = now_act_ref_remember(&g_refs, &row, (unsigned long)TickCount());
    if (slot == NULL) {
        return;
    }
    snprintf(value, sizeof value, "%s  %.*s", slot->ref,
             (int)w->title_len, w->title);
    row_add(rows, "Window", value);
}

static void mint_control(NowActTarget *t, const NowAxWindow *w,
                         const NowAxControl *c, unsigned int win_occurrence,
                         unsigned int occurrence, ActRows *rows)
{
    NowActRefRow  row;
    NowActRefRow *slot;
    char          value[512];

    memset(&row, 0, sizeof row);
    row.kind = kNowActRefElement;
    row.psn_hi = (unsigned long)t->psn.highLongOfPSN;
    row.psn_lo = (unsigned long)t->psn.lowLongOfPSN;
    row.window_address = w->address;
    row.control_handle = c->address;
    row.occurrence = win_occurrence;
    row.title_len = (size_t)w->title_len;
    memcpy(row.title, w->title, row.title_len);
    row.fingerprint = now_ax_ref_fingerprint(row.psn_hi, row.psn_lo,
                                             w->address, c->address);
    slot = now_act_ref_remember(&g_refs, &row, (unsigned long)TickCount());
    if (slot == NULL) {
        return;
    }
    snprintf(value, sizeof value, "%s  %.*s  #%u", slot->ref,
             (int)c->title_len, c->title, occurrence);
    row_add(rows, "Control", value);
}

/* A dialog's own live TextEdit record is the discoverable route to a
   real TEHandle: the caller names only the window, and the resident
   plane reports the handle it used. A document window's TEHandle is NOT
   discoverable from here and that gap is stated rather than papered
   over - such an element gets no reference and no row. */
static void mint_dialog_text(NowActTarget *t, const NowAxWindow *w,
                             unsigned int win_occurrence, ActRows *rows)
{
    NowAxText     text;
    NowActRefRow  row;
    NowActRefRow *slot;
    char          value[512];

    if (now_ax_read_dialog_text(&t->ax.memory, w->address, &text) != kNowAxOk) {
        return;
    }
    memset(&row, 0, sizeof row);
    row.kind = kNowActRefElement;
    row.text_kind = kNowActTextDialogTe;
    row.psn_hi = (unsigned long)t->psn.highLongOfPSN;
    row.psn_lo = (unsigned long)t->psn.lowLongOfPSN;
    row.window_address = w->address;
    row.occurrence = win_occurrence;
    row.title_len = (size_t)w->title_len;
    memcpy(row.title, w->title, row.title_len);
    row.fingerprint = now_ax_ref_fingerprint(row.psn_hi, row.psn_lo,
                                             w->address, 0);
    slot = now_act_ref_remember(&g_refs, &row, (unsigned long)TickCount());
    if (slot == NULL) {
        return;
    }
    snprintf(value, sizeof value, "%s  %u byte%s", slot->ref,
             text.length, text.length == 1 ? "" : "s");
    row_add(rows, "Text", value);
}

void now_act_run_elements(const char *request_json, long id,
                          char *out, long cap)
{
    ActRows             rows;
    NowActStatus        st;
    ProcessSerialNumber psn;
    ProcessSerialNumber *want = NULL;
    unsigned long       address;
    unsigned long       seen[kActMaxWindowWalk];
    unsigned int        count = 0;
    long                hi = 0;
    long                lo = 0;
    NowAxTitleEntry     titles[kActMaxWindowWalk];
    NowAxTitleCounter   counter;

    st = now_act_ready();
    if (st != kNowActOk) {
        reply_status(out, cap, id, st);
        return;
    }
    if (arg_int(request_json, "serialHi", &hi)
        && arg_int(request_json, "serialLo", &lo)) {
        psn.highLongOfPSN = hi;
        psn.lowLongOfPSN = (unsigned long)lo;
        want = &psn;
    }
    st = now_act_open(want, &g_target);
    if (st != kNowActOk) {
        reply_status(out, cap, id, st);
        return;
    }

    rows_reset(&rows);
    now_ax_title_counter_reset(&counter, titles, kActMaxWindowWalk);
    address = g_target.ax.window_list;
    while (address != 0 && count < kActMaxWindowWalk && !rows.overflow) {
        NowAxWindow   w;
        unsigned int  i;
        unsigned int  occurrence = 0;
        unsigned long ctl;
        unsigned int  ctl_count = 0;

        for (i = 0; i < count; i++) {
            if (seen[i] == address) {
                address = 0;
                break;
            }
        }
        if (address == 0) {
            break;
        }
        seen[count++] = address;
        if (now_ax_read_window(&g_target.ax.memory, address, &w) != kNowAxOk) {
            break;
        }
        (void)now_ax_title_counter_next(&counter, w.title,
                                        (size_t)w.title_len, &occurrence);
        mint_window(&g_target, &w, occurrence, &rows);
        mint_dialog_text(&g_target, &w, occurrence, &rows);

        ctl = w.control_list;
        while (ctl != 0 && ctl_count < kNowAxResolveMaxControls
               && !rows.overflow) {
            NowAxControl c;

            if (now_ax_read_control(&g_target.ax.memory, &w, ctl, &c)
                != kNowAxOk) {
                break;
            }
            mint_control(&g_target, &w, &c, occurrence, ctl_count, &rows);
            ctl_count++;
            ctl = c.next_control;
        }
        address = w.next_window;
    }

    if (rows.overflow) {
        /* An honest partial: a reader that cannot tell a short list from
           a clipped one has been told nothing useful. */
        row_add(&rows, "Truncated",
                "more elements existed than one reply can carry");
    }
    if (rows.used == 0) {
        row_add(&rows, "Elements", "none - that process has no windows a "
                                   "classic walk can read");
    }
    now_log(kLogInfo, "act", "#%ld elements a5=%lu", id, g_target.a5);
    reply_rows(out, cap, id, "elements", &rows);
}

/* ---- winact ----------------------------------------------------------- */

void now_act_run_winact(const char *request_json, long id, char *out, long cap)
{
    const NowActRefRow *row = NULL;
    NowAxWindow         win;
    NowAxWindow         after;
    NowActWinArgs       args;
    NowPeekActCell     *cell;
    ActRows             rows;
    char                action[16];
    char                zoom[8];
    const char         *reason = NULL;
    NowActStatus        st;
    int                 zoom_dir = 0;
    int                 click_h;
    int                 click_v;

    memset(&args, 0, sizeof args);
    if (!arg_str(request_json, "action", action, (long)sizeof action)) {
        reply_error(out, cap, id, "bad-request",
                    "winact requires action: one of close, move, resize, "
                    "zoom");
        return;
    }
    args.action = now_act_win_action(action);
    args.has_left = arg_int(request_json, "left", &args.left);
    args.has_top = arg_int(request_json, "top", &args.top);
    args.has_width = arg_int(request_json, "width", &args.width);
    args.has_height = arg_int(request_json, "height", &args.height);
    if (!now_act_win_args_check(&args, &reason)) {
        reply_error(out, cap, id, "bad-request", reason);
        return;
    }
    if (args.action == kNowActWinZoom) {
        /* The direction is optional and defaults to out, because a zoom
           with no direction is the gesture a person means by "zoom". */
        if (arg_str(request_json, "zoom", zoom, (long)sizeof zoom)) {
            zoom_dir = now_act_zoom_direction(zoom);
            if (zoom_dir < 0) {
                reply_error(out, cap, id, "bad-request",
                            "zoom must be \"in\" or \"out\"");
                return;
            }
        } else {
            zoom_dir = 1;
        }
    }

    if (!resolve_for_act(request_json, id, out, cap, kNowActRefWindow,
                         &row, &win)) {
        return;
    }
    cell = now_act_cell();
    if (cell == NULL) {
        reply_status(out, cap, id, kNowActNoExtension);
        return;
    }

    /* The click goes at the CENTRE of the content region, and where it
       lands decides nothing: the FindWindow patch answers with the part
       the request names, so the grow box and the close box never have to
       be located. That is the whole reason FindWindow is patched at all
       - locating them means inventing a title-bar height and a corner
       size no guest structure reports, which is a phantom constant by
       another name.

       The centre is still the right place to aim, for two reasons that
       are not about correctness: it is certainly inside the window, so
       if the patch ever declines the click is harmless rather than
       landing on a neighbour; and the patch matches on these exact
       coordinates, so the point has to be one we can state. */
    click_h = (win.left + win.right) / 2;
    click_v = (win.top + win.bottom) / 2;

    cell->op = kNowPeekActOpWindow;
    cell->window_op = (NowPeekI32)args.action;
    cell->window_ptr = (NowPeekU32)win.address;
    cell->zoom_part = (NowPeekI32)(zoom_dir == 1 ? kNowPeekActInZoomOut
                                                 : kNowPeekActInZoomIn);
    cell->click_h = (NowPeekI32)click_h;
    cell->click_v = (NowPeekI32)click_v;
    if (args.action == kNowActWinMove) {
        cell->win_h = (NowPeekI32)args.left;
        cell->win_v = (NowPeekI32)args.top;
    } else {
        cell->win_h = (NowPeekI32)args.width;   /* GrowWindow's low word  */
        cell->win_v = (NowPeekI32)args.height;  /* GrowWindow's high word */
    }

    st = now_act_submit(g_target.a5, &g_snap);
    if (st == kNowActRefused) {
        reply_plane_error(out, cap, id, &g_snap);
        return;
    }
    if (st != kNowActOk) {
        reply_status(out, cap, id, st);
        return;
    }

    /* Move is served outright in the target's context - MoveWindow has
       already run by the time the status flips, because DragWindow
       returns void and there is no question for a patch to answer. The
       other three need a click to make the application call FindWindow. */
    if (args.action != kNowActWinMove) {
        if (g_snap.armed != kNowPeekActArmReady) {
            now_act_withdraw();
            reply_status(out, cap, id, kNowActNotArmed);
            return;
        }
        /* The press was queued by the resident plane, in the target's
           own context, at the moment it armed - see act_client.h for
           why it is not queued from here. */
        st = now_act_await_fired(&g_snap);
        if (st != kNowActOk) {
            char detail[320];

            /* The counters ARE the diagnostic. A guarded patch cannot
               answer, about itself, whether nothing happened because the
               trap was never called or because it was called and
               declined - and those are opposite repairs. */
            snprintf(detail, sizeof detail,
                     "%s (answers=%lu; this request saw find=%lu grow=%lu "
                     "box=%lu goaway=%lu; the machine saw find=%lu)",
                     g_snap.find_window_fired
                         ? "the application took the part code and did not "
                           "call the trap that goes with it"
                         : "the application never called FindWindow for "
                           "our click",
                     (unsigned long)g_snap.fw_answers,
                     (unsigned long)g_snap.trap_hits_target[0],
                     (unsigned long)g_snap.trap_hits_target[1],
                     (unsigned long)g_snap.trap_hits_target[2],
                     (unsigned long)g_snap.trap_hits_target[3],
                     (unsigned long)g_snap.trap_hits[0]);
            reply_error(out, cap, id, "act-not-taken", detail);
            return;
        }
    }
    now_act_withdraw();

    rows_reset(&rows);
    row_add(&rows, "Window", row->ref);
    row_add(&rows, "Action", action);
    /* The one word this surface is allowed to say. It means the event
       was handed to the addressed element's own application - not that
       the window moved. Whoever wants to know that reads it back. */
    row_add(&rows, "Dispatch", "dispatched");
    row_add(&rows, "Mechanism", args.action == kNowActWinMove
                                    ? "the window manager, in the "
                                      "application's own context"
                                    : "the application's own FindWindow");

    /* The oracle: the window's own rect, re-read out of the guest. A
       SEPARATE row and a separate claim - `dispatched` is not evidence,
       and this project has upstream's four retracted findings to show
       for treating it as such. A window that has gone is not a failure
       to re-read; for close it is the whole result. */
    if (now_act_open(&g_target.psn, &g_target) == kNowActOk) {
        if (find_window(&g_target, row, &after)) {
            char rect[96];

            snprintf(rect, sizeof rect, "%d, %d to %d, %d",
                     (int)after.left, (int)after.top,
                     (int)after.right, (int)after.bottom);
            row_add(&rows, "Re-read", rect);
        } else {
            row_add(&rows, "Re-read", "that window is no longer in the "
                                      "target's window list");
        }
    }
    now_log(kLogInfo, "act", "#%ld winact %s dispatched", id, action);
    reply_rows(out, cap, id, "winact", &rows);
}

/* ---- textget / textset ------------------------------------------------ */

static void text_rows(ActRows *rows, const NowPeekActCell *snap)
{
    char text[kNowPeekActTextMax + 1];
    long take = snap->text_buf_length;

    if (take < 0) {
        take = 0;
    }
    if (take > (long)kNowPeekActTextMax) {
        take = (long)kNowPeekActTextMax;
    }
    memcpy(text, snap->text_buf, (size_t)take);
    text[take] = '\0';

    row_add(rows, "Text", text);
    row_addf(rows, "Length", "%ld", (long)snap->text_length);
    row_addf(rows, "Returned", "%ld", take);
    /* Truncation is a fact about the READING, not about the element: an
       absent flag would leave a caller unable to tell a short field from
       a clipped one. */
    row_add(rows, "Truncated",
            snap->text_length > snap->text_buf_length ? "yes" : "no");
}

static void text_exchange(const char *request_json, long id, char *out,
                          long cap, int is_set)
{
    const NowActRefRow *row = NULL;
    NowPeekActCell     *cell;
    ActRows             rows;
    char                body[kNowPeekActTextMax + 1];
    NowActStatus        st;
    long                body_len = 0;

    if (is_set) {
        if (!now_json_find_text(request_json, "text", body,
                                (long)sizeof body)) {
            reply_error(out, cap, id, "bad-request",
                        "textset requires text: the element's whole new "
                        "contents. There is no offset and no append form - "
                        "an offset into text the caller has not read is a "
                        "write it cannot predict");
            return;
        }
        body_len = (long)strlen(body);
    }
    if (!resolve_for_act(request_json, id, out, cap, kNowActRefElement,
                         &row, NULL)) {
        return;
    }
    if (row->text_kind == kNowActTextNone) {
        reply_error(out, cap, id, "not-text",
                    "that reference names a control, not a text element");
        return;
    }
    cell = now_act_cell();
    if (cell == NULL) {
        reply_status(out, cap, id, kNowActNoExtension);
        return;
    }

    cell->op = (NowPeekU32)(is_set ? kNowPeekActOpTextSet
                                   : kNowPeekActOpTextGet);
    cell->text_kind = (NowPeekU32)row->text_kind;
    cell->text_window = (NowPeekU32)row->window_address;
    cell->text_handle = (NowPeekU32)row->te_handle;
    cell->text_item = (NowPeekI32)row->dialog_item;
    /* Clamped to what the RESIDENT half allocated, not to what this
       build was compiled against: the two can differ across a version
       and the memory that exists is the one that matters. */
    body_len = now_act_text_take(body_len, (long)kNowPeekActTextMax);
    cell->text_length = (NowPeekI32)body_len;
    cell->text_buf_length = 0;
    if (body_len > 0) {
        memcpy(cell->text_buf, body, (size_t)body_len);
    }

    st = now_act_submit(g_target.a5, &g_snap);
    if (st == kNowActRefused) {
        reply_plane_error(out, cap, id, &g_snap);
        return;
    }
    if (st != kNowActOk) {
        reply_status(out, cap, id, st);
        return;
    }
    now_act_withdraw();

    rows_reset(&rows);
    row_add(&rows, "Element", row->ref);
    text_rows(&rows, &g_snap);
    if (is_set) {
        row_addf(&rows, "Requested scalars", "%ld", body_len);
        /* Dispatched, and no more. The application may refuse the new
           text, reformat it, or be modal elsewhere; the rows above are
           the object read back at the moment of the write, which is a
           different claim from "the element now holds this". */
        row_add(&rows, "Dispatch", "dispatched");
    } else {
        row_addf(&rows, "Observed at", "tick %ld",
                 (long)g_snap.served_ticks);
    }
    now_log(kLogInfo, "act", "#%ld text%s %ld bytes", id,
            is_set ? "set" : "get", (long)g_snap.text_buf_length);
    reply_rows(out, cap, id, is_set ? "textset" : "textget", &rows);
}

void now_act_run_textget(const char *request_json, long id, char *out, long cap)
{
    text_exchange(request_json, id, out, cap, 0);
}

void now_act_run_textset(const char *request_json, long id, char *out, long cap)
{
    text_exchange(request_json, id, out, cap, 1);
}

/* ---- ctlact ----------------------------------------------------------- */

void now_act_run_ctlact(const char *request_json, long id, char *out, long cap)
{
    const NowActRefRow *row = NULL;
    NowAxWindow         win;
    NowPeekActCell     *cell;
    ActRows             rows;
    NowActStatus        st;
    long                part = 0;

    if (!arg_int(request_json, "part", &part) || part < 0 || part > 255) {
        reply_error(out, cap, id, "bad-request",
                    "ctlact requires part: a Control Manager part code. "
                    "The button parts are 10 and 11, the scroll bar's are "
                    "20 up, 21 down, 22 page-up, 23 page-down, and 129 is "
                    "the indicator");
        return;
    }
    if (!resolve_for_act(request_json, id, out, cap, kNowActRefElement,
                         &row, &win)) {
        return;
    }
    if (row->control_handle == 0) {
        reply_error(out, cap, id, "bad-request",
                    "that reference names a text element, not a control");
        return;
    }
    cell = now_act_cell();
    if (cell == NULL) {
        reply_status(out, cap, id, kNowActNoExtension);
        return;
    }

    cell->op = kNowPeekActOpControl;
    /* THE IDENTITY CHECK, carried in the request: the patch answers only
       for THIS handle. It is the clause that measured 0/20 upstream
       while the menu patch without its equivalent measured 18/20. */
    cell->control_handle = (NowPeekU32)row->control_handle;
    cell->part_code = (NowPeekI32)part;
    /* Where the resident plane will press. The centre of the control if
       we can read it, else the centre of its window - and either way it
       decides nothing, because the patch answers for the handle the
       request names and declines every other. It only has to be
       somewhere the application will route to a mouseDown handler. */
    {
        NowAxControl c;

        cell->click_h = (NowPeekI32)((win.left + win.right) / 2);
        cell->click_v = (NowPeekI32)((win.top + win.bottom) / 2);
        if (now_ax_read_control(&g_target.ax.memory, &win,
                                row->control_handle, &c) == kNowAxOk) {
            cell->click_h = (NowPeekI32)((c.left + c.right) / 2);
            cell->click_v = (NowPeekI32)((c.top + c.bottom) / 2);
        }
    }

    st = now_act_submit(g_target.a5, &g_snap);
    if (st == kNowActRefused) {
        reply_plane_error(out, cap, id, &g_snap);
        return;
    }
    if (st != kNowActOk) {
        reply_status(out, cap, id, st);
        return;
    }
    if (g_snap.armed != kNowPeekActArmReady) {
        now_act_withdraw();
        reply_status(out, cap, id, kNowActNotArmed);
        return;
    }

    /* The resident plane queued the press when it armed. The
       application calls TrackControl from its own mouseDown handler, so
       it still needs one to get there - but where it lands decides
       nothing, because the patch answers with the part we named and
       refuses any control but this one. */
    st = now_act_await_fired(&g_snap);
    if (st != kNowActOk) {
        reply_error(out, cap, id, "act-not-taken",
                    "armed, and the application never called TrackControl");
        return;
    }
    now_act_withdraw();

    rows_reset(&rows);
    row_add(&rows, "Element", row->ref);
    row_addf(&rows, "Part", "%ld", part);
    row_add(&rows, "Dispatch", "dispatched");
    row_add(&rows, "Mechanism", "the application's own TrackControl");
    /* A control with a live range publishes its position, so for those
       the guest itself can be quoted. A push button has no such range
       and this proves nothing about it - its effect is whatever its own
       handler did, which only the caller can name and check. The
       stronger claim is made exactly where the guest supports it. */
    if (now_act_open(&g_target.psn, &g_target) == kNowActOk
        && find_window(&g_target, row, &win)) {
        NowAxControl c;

        if (now_ax_read_control(&g_target.ax.memory, &win,
                                row->control_handle, &c) == kNowAxOk) {
            if (c.max > c.min) {
                row_addf(&rows, "Re-read value", "%ld", (long)c.value);
            } else {
                row_add(&rows, "Re-read value",
                        "this control has no range, so its position "
                        "answers nothing about the act");
            }
        }
    }
    now_log(kLogInfo, "act", "#%ld ctlact part %ld dispatched", id, part);
    reply_rows(out, cap, id, "ctlact", &rows);
}

/* ---- menuact ---------------------------------------------------------- */

void now_act_run_menuact(const char *request_json, long id, char *out, long cap)
{
    NowPeekActCell     *cell;
    ActRows             rows;
    ProcessSerialNumber psn;
    ProcessSerialNumber *want = NULL;
    NowActStatus        st;
    long                menu = 0;
    long                item = 0;
    long                title_left = 0;
    long                hi = 0;
    long                lo = 0;
    int                 h;
    int                 v;

    st = now_act_ready();
    if (st != kNowActOk) {
        reply_status(out, cap, id, st);
        return;
    }
    if (!arg_int(request_json, "menu", &menu)
        || !arg_int(request_json, "item", &item) || item < 1) {
        reply_error(out, cap, id, "bad-request",
                    "menuact requires menu (the menu's id) and item (its "
                    "1-based position in that menu)");
        return;
    }
    /* THE PRESS IS THE IDENTITY, so the caller has to state where it
       will be. A menu press carries no handle to name, and the scene's
       menu bar is where a caller gets this number; without it there is
       no way to tell our own press from the user's, which is exactly
       the 18/20 defect. */
    if (!arg_int(request_json, "titleLeft", &title_left)
        || title_left < 0 || title_left > 32767L) {
        reply_error(out, cap, id, "bad-request",
                    "menuact requires titleLeft: the x of that menu's "
                    "title in the menu bar. The press is this act's "
                    "identity check - a menu carries no handle to name - "
                    "so the point has to be one we can state");
        return;
    }
    if (arg_int(request_json, "serialHi", &hi)
        && arg_int(request_json, "serialLo", &lo)) {
        psn.highLongOfPSN = hi;
        psn.lowLongOfPSN = (unsigned long)lo;
        want = &psn;
    }
    st = now_act_open(want, &g_target);
    if (st != kNowActOk) {
        reply_status(out, cap, id, st);
        return;
    }
    cell = now_act_cell();
    if (cell == NULL) {
        reply_status(out, cap, id, kNowActNoExtension);
        return;
    }

    /* The menu bar is 20 px tall; aim at its middle. */
    h = (int)(title_left + 4);
    v = 10;
    cell->op = kNowPeekActOpMenu;
    cell->menu_id = (NowPeekI32)menu;
    cell->item_index = (NowPeekI32)item;
    cell->arm_point_h = (NowPeekI32)h;
    cell->arm_point_v = (NowPeekI32)v;

    st = now_act_submit(g_target.a5, &g_snap);
    if (st == kNowActRefused) {
        reply_plane_error(out, cap, id, &g_snap);
        return;
    }
    if (st != kNowActOk) {
        reply_status(out, cap, id, st);
        return;
    }
    if (g_snap.armed != kNowPeekActArmReady) {
        now_act_withdraw();
        reply_status(out, cap, id, kNowActNotArmed);
        return;
    }
    st = now_act_await_fired(&g_snap);
    if (st != kNowActOk) {
        reply_error(out, cap, id, "act-not-taken",
                    "armed, and the application never called MenuSelect");
        return;
    }
    now_act_withdraw();

    rows_reset(&rows);
    row_addf(&rows, "Menu", "%ld", menu);
    row_addf(&rows, "Item", "%ld", item);
    /* Dispatched, and nothing more. What the application's own command
       handler then did is the caller's to verify against guest state -
       reporting the stronger claim is how an ABI bug stayed invisible
       upstream for an afternoon. */
    row_add(&rows, "Dispatch", "dispatched");
    row_add(&rows, "Mechanism", "the application's own MenuSelect");
    now_log(kLogInfo, "act", "#%ld menuact %ld/%ld dispatched", id, menu, item);
    reply_rows(out, cap, id, "menuact", &rows);
}
