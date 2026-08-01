#include "act_cmds.h"

#include <Carbon.h>
#include <stdio.h>
#include <string.h>

#include "act_args.h"
#include "act_client.h"
#include "axresolve.h"
#include "cmd_line.h"
#include "json.h"
#include "now_act_guard.h"
#include "nowlog.h"
#include "observe.h"
#include "peek_table.h"

/* THIS PLANE KEEPS NO REFERENCES. It used to: act_ref.c held a second
   registry, minting the same now-window-/now-element- token shape from a
   second walk with a second staleness rule. Two systems producing one
   token shape means a reference minted by one may not resolve in the
   other and a caller cannot tell which it holds - so the registry, the
   minting and the revalidation all live in src/observe/ now, and this
   file only asks. See observe.h. */

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

/* The verdict as an error slug. Five verdicts, five slugs, because
   "your reference is stale" and "nothing answers to it" send a caller to
   different repairs and a single code would collapse them. */
static const char *refusal_code(NowObsVerdict verdict)
{
    switch (verdict) {
    case kNowObsOk:        return "ok";
    case kNowObsStale:     return "element-stale";
    case kNowObsAmbiguous: return "element-ambiguous";
    case kNowObsMismatch:  return "element-mismatch";
    case kNowObsNotFound:  break;
    }
    return "element-not-found";
}

/* The whole gate an act passes before anything is dispatched: the plane
   is usable, the reference resolves to a live element that is still the
   SAME element, and the process it names opens. Any of those failing
   writes the reply and returns 0.

   The middle step is not ours. now_observe_resolve_* re-proves the
   reference from foreign memory - five verdicts, fifteen reasons, and
   the recycled-PSN check before the walk rather than after it - and the
   contract that comes with it is obeyed here without exception: any
   verdict other than kNowObsOk is a REFUSAL carrying that reason. Not a
   retry, not a re-derivation from the reference's titles, and never a
   fall back to whatever is frontmost.

   `ref_out` is the caller's own reference string, echoed back in the
   reply: a receipt names what was asked for. */
static int resolve_for_act(const char *json, long id, char *out, long cap,
                           NowObsKind kind, NowObsHandle *handle,
                           char *ref_out)
{
    NowActStatus st;

    st = now_act_ready();
    if (st != kNowActOk) {
        reply_status(out, cap, id, st);
        return 0;
    }
    if (!arg_str(json, kind == kNowObsKindWindow ? "window" : "element",
                 ref_out, (long)kNowObsTokenMax)) {
        reply_error(out, cap, id, "bad-request",
                    kind == kNowObsKindWindow
                        ? "winact requires window: one opaque now-window- "
                          "reference from a current observation. This "
                          "surface cannot address a window any other way, "
                          "and deliberately has no \"frontmost\" form"
                        : "this command requires element: one opaque "
                          "now-element- reference minted by an observation "
                          "that saw the element");
        return 0;
    }
    if (kind == kNowObsKindWindow) {
        now_observe_resolve_window(ref_out, 0, handle);
    } else {
        now_observe_resolve_element(ref_out, 0, handle);
    }
    if (handle->verdict != kNowObsOk) {
        /* A reference that is not even the right SHAPE is the caller's
           bug rather than a fact about the machine, and it gets the
           code that says so. Everything else is an answer about this
           Mac and carries the reference layer's own sentence. */
        if (handle->why == kNowObsWhyMalformed) {
            reply_error(out, cap, id, "bad-request",
                        kind == kNowObsKindWindow
                            ? "that is not a well-formed now-window- "
                              "reference. This surface cannot address a "
                              "window any other way"
                            : "that is not a well-formed now-element- "
                              "reference");
            return 0;
        }
        reply_error(out, cap, id, refusal_code(handle->verdict),
                    now_obs_why_text(handle->why));
        return 0;
    }
    /* The process the reference was minted against, never "the front
       one": an act that re-resolved to whatever is frontmost now would
       be the target-free form this plane refuses, arrived at by the back
       door. The reference layer read the PSN out of the reference; we
       open exactly that. */
    st = now_act_open(&handle->psn, &g_target);
    if (st != kNowActOk) {
        reply_status(out, cap, id, st);
        return 0;
    }
    return 1;
}

/* ---- where `elements` went --------------------------------------------
 *
 * The observation that MINTS the references these five verbs take is not
 * here any more; it is now_observe_elements_command, in src/observe/. It
 * moved because it was the second minter: it walked the same window list
 * and produced the same now-window-/now-element- token shape from its own
 * table with its own staleness rule, while the reference layer next door
 * did the same thing better - a token hashed over a per-session secret, a
 * recycled-PSN check before the walk, five verdicts instead of one
 * boolean. Two systems producing one token shape is a reference whose
 * provenance a caller cannot tell, so there is one now.
 *
 * `elements` is still a command and still means the same thing to a
 * caller. It is the reference layer's walk aimed by a process rather
 * than by a scope. */

/* ---- winact ----------------------------------------------------------- */

void now_act_run_winact(const char *request_json, long id, char *out, long cap)
{
    NowObsHandle        handle;
    NowObsHandle        after;
    NowAxWindow         win;
    char                ref[kNowObsTokenMax];
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

    if (!resolve_for_act(request_json, id, out, cap, kNowObsKindWindow,
                         &handle, ref)) {
        return;
    }
    /* The window record the RESOLVER read, not a second read of our own:
       it is the one whose addresses were just proved to be the ones this
       reference was minted against, and reading it again here would open
       a window between the proof and the aim. */
    win = handle.detail.window;
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
        /* Now the press, queued by the resident half on a pass running
           in THIS application's own process - see act_client.h for the
           measurement that moved it out of the target's. */
        st = now_act_post_click();
        if (st != kNowActOk) {
            char why[192];

            now_act_withdraw();
            /* The counters, not just the verdict: "nobody posted it" and
               "somebody tried and the queue said no" are opposite
               repairs, and this plane has already spent two passes
               naming the wrong one. */
            snprintf(why, sizeof why, "%s (act passes while waiting=%lu, "
                     "last pumping A5=0x%08lX, target A5=0x%08lX)",
                     now_act_status_message(st),
                     now_act_click_passes(), now_act_click_last_a5(),
                     g_target.a5);
            reply_error(out, cap, id, now_act_status_code(st), why);
            return;
        }
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
    row_add(&rows, "Window", ref);
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
    now_observe_resolve_window(ref, 0, &after);
    if (after.verdict == kNowObsOk) {
        char rect[96];

        snprintf(rect, sizeof rect, "%d, %d to %d, %d",
                 (int)after.detail.window.left, (int)after.detail.window.top,
                 (int)after.detail.window.right,
                 (int)after.detail.window.bottom);
        row_add(&rows, "Re-read", rect);
    } else {
        /* The reference layer's own sentence, not a guess of ours: after
           a close it says the window is gone, after a stale resolve it
           says the addresses moved, and those are different facts a
           reader should not have to squint at one word to tell apart. */
        row_add(&rows, "Re-read", now_obs_why_text(after.why));
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
    NowObsHandle          handle;
    const NowObsIdentity *named;
    NowPeekActCell       *cell;
    ActRows               rows;
    char                  ref[kNowObsTokenMax];
    char                  body[kNowPeekActTextMax + 1];
    NowActStatus          st;
    long                  body_len = 0;

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
    if (!resolve_for_act(request_json, id, out, cap, kNowObsKindElement,
                         &handle, ref)) {
        return;
    }
    /* WHAT THE MINT KNEW, and not a fresh opinion about it. The route to
       a text element - which record, which item - was decided by the
       observation that saw it; deciding it again here would be the
       second decider this plane was unified to remove. */
    named = &handle.identity;
    if (named->text_kind == kNowObsTextNone) {
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
    cell->text_kind = (NowPeekU32)named->text_kind;
    cell->text_window = (NowPeekU32)named->window_address;
    cell->text_handle = (NowPeekU32)named->te_handle;
    cell->text_item = (NowPeekI32)named->dialog_item;
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
    row_add(&rows, "Element", ref);
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
    NowObsHandle        handle;
    NowObsHandle        after;
    NowPeekActCell     *cell;
    ActRows             rows;
    char                ref[kNowObsTokenMax];
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
    if (!resolve_for_act(request_json, id, out, cap, kNowObsKindElement,
                         &handle, ref)) {
        return;
    }
    if (handle.identity.control_handle == 0) {
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
    cell->control_handle = (NowPeekU32)handle.identity.control_handle;
    cell->part_code = (NowPeekI32)part;
    /* Where the resident plane will press: the centre of the control the
       RESOLVER read, which is the one whose addresses it just proved.
       Where it lands decides nothing - the patch answers for the handle
       the request names and declines every other - so this only has to
       be somewhere the application will route to a mouseDown handler. */
    cell->click_h = (NowPeekI32)((handle.detail.control.left
                                  + handle.detail.control.right) / 2);
    cell->click_v = (NowPeekI32)((handle.detail.control.top
                                  + handle.detail.control.bottom) / 2);

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

    /* Now the press. The application calls TrackControl from its own
       mouseDown handler, so it still needs one to get there - but where
       it lands decides nothing, because the patch answers with the part
       we named and refuses any control but this one. */
    st = now_act_post_click();
    if (st != kNowActOk) {
        now_act_withdraw();
        reply_status(out, cap, id, st);
        return;
    }
    st = now_act_await_fired(&g_snap);
    if (st != kNowActOk) {
        reply_error(out, cap, id, "act-not-taken",
                    "armed, and the application never called TrackControl");
        return;
    }
    now_act_withdraw();

    rows_reset(&rows);
    row_add(&rows, "Element", ref);
    row_addf(&rows, "Part", "%ld", part);
    row_add(&rows, "Dispatch", "dispatched");
    row_add(&rows, "Mechanism", "the application's own TrackControl");
    /* A control with a live range publishes its position, so for those
       the guest itself can be quoted. A push button has no such range
       and this proves nothing about it - its effect is whatever its own
       handler did, which only the caller can name and check. The
       stronger claim is made exactly where the guest supports it. */
    now_observe_resolve_element(ref, 0, &after);
    if (after.verdict == kNowObsOk) {
        if (after.detail.control.max > after.detail.control.min) {
            row_addf(&rows, "Re-read value", "%ld",
                     (long)after.detail.control.value);
        } else {
            row_add(&rows, "Re-read value",
                    "this control has no range, so its position "
                    "answers nothing about the act");
        }
    } else {
        row_add(&rows, "Re-read value", now_obs_why_text(after.why));
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
    st = now_act_post_click();
    if (st != kNowActOk) {
        now_act_withdraw();
        reply_status(out, cap, id, st);
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

/* ---- menugeom ----------------------------------------------------------
 *
 * Served outright (V2, kNowPeekActOpMenuGeom): unlike menuact, nothing is
 * armed and no click is queued, because there is no trap to answer - the
 * extension reads the menu's own MDEF in the target's context and the
 * reply carries what it found. Same submit-and-withdraw shape as textget/
 * textset, not menuact/ctlact/winact's arm-then-await. */
void now_act_run_menugeom(const char *request_json, long id, char *out,
                          long cap)
{
    NowPeekActCell     *cell;
    ActRows             rows;
    ProcessSerialNumber psn;
    ProcessSerialNumber *want = NULL;
    NowActStatus        st;
    long                menu = 0;
    long                hi = 0;
    long                lo = 0;
    long                count;
    long                i;

    st = now_act_ready();
    if (st != kNowActOk) {
        reply_status(out, cap, id, st);
        return;
    }
    if (!arg_int(request_json, "menu", &menu)) {
        reply_error(out, cap, id, "bad-request",
                    "menugeom requires menu: the menu's id, as the scene "
                    "reports it");
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

    cell->op = kNowPeekActOpMenuGeom;
    cell->menu_id = (NowPeekI32)menu;

    st = now_act_submit(g_target.a5, &g_snap);
    if (st == kNowActRefused) {
        reply_plane_error(out, cap, id, &g_snap);
        return;
    }
    if (st != kNowActOk) {
        reply_status(out, cap, id, st);
        return;
    }
    /* Served outright, like textget/textset: the reply is already
       complete by the time status flipped to done, so this withdraws
       rather than waiting for a patch that was never armed. */
    now_act_withdraw();

    rows_reset(&rows);
    row_addf(&rows, "Menu", "%ld", menu);
    count = (long)g_snap.menu_item_count;
    row_addf(&rows, "Items", "%ld", count);
    row_addf(&rows, "Width", "%ld", (long)g_snap.menu_width);
    row_addf(&rows, "Height", "%ld", (long)g_snap.menu_height);
    /* One row per item, "top,left,bottom,right" - the same field order
       the MDEF filled and the table stores, so nothing here reorders a
       QuickDraw Rect into a caller's own convention. Separators come
       back a real 6px-ish sliver against a 16px-ish item, the whole
       reason this verb exists instead of an assumed uniform row. */
    for (i = 0; i < count && i < (long)kNowPeekActMenuItemMax; i++) {
        char label[24];
        char rect[64];
        const NowPeekActMenuRect *r = &g_snap.menu_item_rects[i];

        snprintf(label, sizeof label, "Item %ld", i + 1);
        snprintf(rect, sizeof rect, "%d, %d, %d, %d",
                 (int)r->top, (int)r->left, (int)r->bottom, (int)r->right);
        row_add(&rows, label, rect);
    }
    now_log(kLogInfo, "act", "#%ld menugeom %ld: %ld item(s)", id, menu, count);
    reply_rows(out, cap, id, "menugeom", &rows);
}
