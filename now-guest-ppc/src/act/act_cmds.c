#include "act_cmds.h"

#include <Carbon.h>
#include <stdio.h>
#include <string.h>

#include "act_args.h"
#include "act_client.h"
#include "act_menu_probe.h"
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

static void settlement_rows(ActRows *rows)
{
    const NowActSettlementRecord *record = now_act_last_settlement();
    char correlation[40];

    if (record == NULL) {
        row_add(rows, "Settlement", "unknown");
        return;
    }
    row_add(rows, "Settlement",
            now_act_settlement_status_code(record->status));
    snprintf(correlation, sizeof correlation, "%08lX-%08lX",
             (unsigned long)record->spec.correlation_hi,
             (unsigned long)record->spec.correlation_lo);
    row_add(rows, "Correlation", correlation);
    row_addf(rows, "Resident stage", "%ld",
             (long)record->resident_stage);
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

/* Only after THIS command registered a correlation. Validation and resolve
   errors use reply_error above and can never inherit a previous action. */
static void reply_registered_error(char *out, long cap, long id,
                                   const char *code, const char *message)
{
    char esc[512];
    const NowActSettlementRecord *record = now_act_last_settlement();
    if (record == NULL) { reply_error(out, cap, id, code, message); return; }
    now_json_escape(message, esc, (long)sizeof esc);
    snprintf(out, (size_t)cap,
             "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
             "\"error\":{\"code\":\"%s\",\"message\":\"%s\","
             "\"correlation\":\"%08lX-%08lX\",\"settlement\":\"%s\"}}",
             id, code, esc,
             (unsigned long)record->spec.correlation_hi,
             (unsigned long)record->spec.correlation_lo,
             now_act_settlement_status_code(record->status));
}

static void reply_status(char *out, long cap, long id, NowActStatus st)
{
    reply_error(out, cap, id, now_act_status_code(st),
                now_act_status_message(st));
}

static void reply_registered_status(char *out, long cap, long id,
                                    NowActStatus st)
{
    reply_registered_error(out, cap, id, now_act_status_code(st),
                           now_act_status_message(st));
}

/* Did the request reach the machine at all?
 *
 * NOT simply `armed == ArmReady`, and the difference is a race this side
 * lost 8 times in 8. The resident arms in the target's context and
 * queues the press in the same pass; the application can dequeue it,
 * call the trap, and have the patch answer - which sets `fired` and
 * clears `armed` back to None - all before this side gets to look at the
 * snapshot. Reading `armed` alone then says "the target served the
 * request and did not arm" about a request that has ALREADY COMPLETED.
 *
 * Measured 2026-08-02 against the Finder, once the patches were being
 * installed per context: `menuact` created an `untitled folder` on the
 * Desktop 8 times out of 8 and reported `act-not-armed` 8 times out of
 * 8. A false negative in the worst direction - a caller that believes it
 * gets a second folder for every retry.
 *
 * So: armed OR already fired. Both mean the plane took it.
 */
static int act_reached_the_machine(const NowPeekActCell *snap)
{
    return snap->armed == (NowPeekU32)kNowPeekActArmReady || snap->fired;
}

/* The plane's own refusal, which names a condition the status vocabulary
   cannot: "that window is not in the target's list" is a different fact
   from "the target never served it". */
static void reply_plane_error(char *out, long cap, long id,
                              const NowPeekActCell *snap)
{
    reply_registered_error(out, cap, id, now_act_error_code(snap->error),
                           now_act_error_message(snap->error));
}

/* ---- arguments -------------------------------------------------------- */

/* Presence, for an integer argument. Two probes with different
   fallbacks: agreeing means the key was really there, and that
   distinction is the whole point of the geometry rule - a `left` that
   defaulted to 0 and a `left` the caller sent are different requests. */
/* Present AND readable. The two-fallback trick this replaced could tell
   absent from present and could not tell either from UNREADABLE: a
   quoted number stopped strtol at the quote, so both probes returned 0,
   agreed, and the caller was handed a confident zero. A host whose args
   are all strings therefore pressed part 0 and moved windows to (0,0)
   while every reply said `dispatched`. See now_json_read_int. */
static int arg_int(const char *json, const char *key, long *out)
{
    return now_json_read_int(json, key, out) == kNowJsonIntOk;
}

/* Present but unreadable, which is a CALLER's bug and deserves its own
   sentence rather than "missing". */
static int arg_int_malformed(const char *json, const char *key)
{
    return now_json_read_int(json, key, NULL) == kNowJsonIntUnreadable;
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
static int act_target_is_self(const ProcessSerialNumber *psn);
static NowActSelfMenuHandler g_self_menu_handler;
static NowActSelfWindowCloseHandler g_self_window_close_handler;

void now_act_set_self_menu_handler(NowActSelfMenuHandler handler)
{
    g_self_menu_handler = handler;
}

void now_act_set_self_window_close_handler(
    NowActSelfWindowCloseHandler handler)
{
    g_self_window_close_handler = handler;
}

static int resolve_for_act(const char *json, long id, char *out, long cap,
                           NowObsKind kind, NowObsHandle *handle,
                           char *ref_out, int self_direct)
{
    NowActStatus st;

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
    /* A self window can be acted on with this application's own Window
       Manager calls. Requiring the OPTIONAL resident plane before even
       resolving it made the direct self path below unreachable: Close,
       Move and Zoom all reported "extension not installed" despite
       owning the WindowRef in this process. Other self acts still need
       the plane because their APPLICATION event path owns the meaning. */
    if (self_direct && act_target_is_self(&handle->psn)) {
        return 1;
    }
    st = now_act_ready();
    if (st != kNowActOk) {
        reply_status(out, cap, id, st);
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


/* --- acting on THIS application's own window ----------------------------

   The act plane exists to reach into a FOREIGN process: it writes a cell,
   the resident trap patches read it in that process's context, and the
   application's own FindWindow answers. None of that is needed to move
   our own window. We are the application; the Window Manager will do it
   on the spot.

   This is not a shortcut around the plane, it is the absence of a reason
   to use it. Routing our own window through a trap patch would mean
   arming a plane, submitting a cell and waiting for our own event loop
   to answer a question we already know the answer to.

   Watched 2026-08-03: NOW's own window was the only thing on the screen
   and every act on it was refused, so a person could not move it out of
   the way to see the desktop behind it. */

static int act_target_is_self(const ProcessSerialNumber *psn)
{
    ProcessSerialNumber me;
    Boolean             same = false;

    if (psn == NULL || GetCurrentProcess(&me) != noErr) {
        return 0;
    }
    if (SameProcess((ProcessSerialNumber *)psn, &me, &same) != noErr) {
        return 0;
    }
    return same ? 1 : 0;
}

static void self_window_act(WindowRef window, const NowActWinArgs *args,
                            int zoom_dir, long id, char *out, long cap)
{
    ActRows rows;
    char    number[32];

    rows_reset(&rows);
    switch (args->action) {
    case kNowActWinMove:
        MoveWindow(window, (short)args->left, (short)args->top, false);
        break;
    case kNowActWinSelect:
        SelectWindow(window);
        break;
    case kNowActWinResize:
        SizeWindow(window, (short)args->width, (short)args->height, true);
        break;
    case kNowActWinZoom:
        ZoomWindow(window, (short)(zoom_dir == 1 ? inZoomOut : inZoomIn),
                   false);
        break;
    case kNowActWinClose:
        if (g_self_window_close_handler == NULL
            || !g_self_window_close_handler(window)) {
            reply_error(out, cap, id, "self-close-busy",
                        "the application's close command could not be "
                        "queued for its main event loop");
            return;
        }
        break;
    default:
        reply_error(out, cap, id, "bad-request",
                    "winact on this application's own window serves select, "
                    "move, resize, zoom and close");
        return;
    }
    row_add(&rows, "Window", "this application's own");
    snprintf(number, sizeof number, "0x%08lX", (unsigned long)window);
    row_add(&rows, "Ref", number);
    /* The action ran synchronously, but Dispatch is a shared wire
       vocabulary rather than a strength scale. `performed` was private to
       this branch; the typed host therefore rejected successful resize,
       zoom and close replies as outcome-unknown. Effect strength still
       comes from the later authoritative scene. */
    row_add(&rows, "Dispatch", "dispatched");
    row_add(&rows, "Mechanism",
                     args->action == kNowActWinClose
                         ? "the application's main-loop close path"
                         : "the Window Manager, called directly in this "
                           "process");
    reply_rows(out, cap, id, "winact", &rows);
}

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

    now_act_begin_command();
    memset(&args, 0, sizeof args);
    if (!arg_str(request_json, "action", action, (long)sizeof action)) {
        reply_error(out, cap, id, "bad-request",
                    "winact requires action: one of select, close, move, resize, "
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
                         &handle, ref, 1)) {
        return;
    }
    /* The window record the RESOLVER read, not a second read of our own:
       it is the one whose addresses were just proved to be the ones this
       reference was minted against, and reading it again here would open
       a window between the proof and the aim. */
    if (act_target_is_self(&handle.psn)) {
        self_window_act((WindowRef)handle.detail.window.address, &args,
                        zoom_dir, id, out, cap);
        return;
    }
    win = handle.detail.window;
    cell = now_act_cell();
    if (cell == NULL) {
        /* NULL is two answers: no usable plane, or another act already
           holds its single cell. now_act_why_no_cell() tells them apart -
           reporting "no extension" for a busy plane would send someone
           to reinstall software that is working. */
        reply_status(out, cap, id, now_act_why_no_cell());
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

    st = now_act_submit(&g_target, &g_snap);
    if (st == kNowActRefused) {
        reply_plane_error(out, cap, id, &g_snap);
        return;
    }
    if (st != kNowActOk) {
        reply_registered_status(out, cap, id, st);
        return;
    }

    /* Move is served outright in the target's context - MoveWindow has
       already run by the time the status flips, because DragWindow
       returns void and there is no question for a patch to answer. The
       other three need a click to make the application call FindWindow. */
    if (args.action != kNowActWinMove && args.action != kNowActWinSelect) {
        if (!act_reached_the_machine(&g_snap)) {
            now_act_withdraw();
            reply_registered_status(out, cap, id, kNowActNotArmed);
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
            reply_registered_error(out, cap, id, "act-not-taken", detail);
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
    row_add(&rows, "Mechanism", (args.action == kNowActWinMove
                                  || args.action == kNowActWinSelect)
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
    settlement_rows(&rows);
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

    now_act_begin_command();
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
                         &handle, ref, 0)) {
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
        /* NULL is two answers: no usable plane, or another act already
           holds its single cell. now_act_why_no_cell() tells them apart -
           reporting "no extension" for a busy plane would send someone
           to reinstall software that is working. */
        reply_status(out, cap, id, now_act_why_no_cell());
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

    st = now_act_submit(&g_target, &g_snap);
    if (st == kNowActRefused) {
        reply_plane_error(out, cap, id, &g_snap);
        return;
    }
    if (st != kNowActOk) {
        reply_registered_status(out, cap, id, st);
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
        settlement_rows(&rows);
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

    now_act_begin_command();
    if (arg_int_malformed(request_json, "part")) {
        /* Named separately because it is a CALLER's encoding bug, not a
           missing argument, and the two send someone looking in
           different places. A host whose args are all strings sends
           `"part": "21"`; this used to read as zero and press part 0. */
        reply_error(out, cap, id, "bad-request",
                    "ctlact's part is present but is not a number. Send a "
                    "JSON integer, not a quoted one: \"part\": 21, never "
                    "\"part\": \"21\"");
        return;
    }
    if (!arg_int(request_json, "part", &part) || part < 0 || part > 255) {
        reply_error(out, cap, id, "bad-request",
                    "ctlact requires part: a Control Manager part code. "
                    "The button parts are 10 and 11, the scroll bar's are "
                    "20 up, 21 down, 22 page-up, 23 page-down, and 129 is "
                    "the indicator");
        return;
    }
    if (!resolve_for_act(request_json, id, out, cap, kNowObsKindElement,
                         &handle, ref, 0)) {
        return;
    }
    if (handle.identity.control_handle == 0) {
        reply_error(out, cap, id, "bad-request",
                    "that reference names a text element, not a control");
        return;
    }
    /* NO SELF BRANCH HERE, and that is the correction. A control act has
       to make the APPLICATION respond - a checkbox toggles because the
       application's own click handler toggles it - and TrackControl
       called from outside that handler only hilites the part. Watched
       2026-08-03: the act reached "Compress on wire (PackBits)" and the
       checkbox did not move.
     *
       The plane already serves this correctly for our own process. Its
       trap patches are installed per context, `actselftest` proves the
       ABI holds in ours, and `now_act_open` binds us through the anchor
       plane like anyone else - so the application answers its own
       FindControl and does its own work. The window acts keep their
       direct path because MoveWindow IS the whole action there; a
       control's action belongs to the application. */
    cell = now_act_cell();
    if (cell == NULL) {
        /* NULL is two answers: no usable plane, or another act already
           holds its single cell. now_act_why_no_cell() tells them apart -
           reporting "no extension" for a busy plane would send someone
           to reinstall software that is working. */
        reply_status(out, cap, id, now_act_why_no_cell());
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

    st = now_act_submit(&g_target, &g_snap);
    if (st == kNowActRefused) {
        reply_plane_error(out, cap, id, &g_snap);
        return;
    }
    if (st != kNowActOk) {
        reply_registered_status(out, cap, id, st);
        return;
    }
    if (!act_reached_the_machine(&g_snap)) {
        now_act_withdraw();
        reply_registered_status(out, cap, id, kNowActNotArmed);
        return;
    }

    /* The resident plane queued the press when it armed. The
       application calls TrackControl from its own mouseDown handler, so
       it still needs one to get there - but where it lands decides
       nothing, because the patch answers with the part we named and
       refuses any control but this one. */
    st = now_act_await_fired(&g_snap);
    if (st != kNowActOk) {
        reply_registered_error(
            out, cap, id, "act-not-taken",
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
    settlement_rows(&rows);
    reply_rows(out, cap, id, "ctlact", &rows);
}

/* ---- ditemact --------------------------------------------------------- */

void now_act_run_ditemact(const char *request_json, long id,
                          char *out, long cap)
{
    NowObsHandle    handle;
    NowPeekActCell *cell;
    ActRows         rows;
    char            ref[kNowObsTokenMax];
    NowActStatus    st;
    long            item = 0;

    now_act_begin_command();
    if (arg_int_malformed(request_json, "item")) {
        reply_error(out, cap, id, "bad-request",
                    "ditemact's item is present but is not a JSON number");
        return;
    }
    if (!arg_int(request_json, "item", &item)
        || item < 1 || item > kNowAxDialogMaxItems) {
        reply_error(out, cap, id, "bad-request",
                    "ditemact requires item: a 1-based DITL number from 1 "
                    "through 96");
        return;
    }
    if (!resolve_for_act(request_json, id, out, cap, kNowObsKindElement,
                         &handle, ref, 0)) {
        return;
    }
    if (handle.identity.control_handle == 0) {
        reply_error(out, cap, id, "bad-request",
                    "ditemact requires the observation-minted reference "
                    "of a dialog control item");
        return;
    }
    cell = now_act_cell();
    if (cell == NULL) {
        /* NULL is two answers: no usable plane, or another act already
           holds its single cell. now_act_why_no_cell() tells them apart -
           reporting "no extension" for a busy plane would send someone
           to reinstall software that is working. */
        reply_status(out, cap, id, now_act_why_no_cell());
        return;
    }

    cell->op = kNowPeekActOpDialogItem;
    cell->control_handle = (NowPeekU32)handle.identity.control_handle;
    cell->text_window = (NowPeekU32)handle.identity.window_address;
    cell->text_item = (NowPeekI32)item;
    cell->text_item_type = 0;

    st = now_act_submit(&g_target, &g_snap);
    if (st == kNowActRefused) {
        reply_plane_error(out, cap, id, &g_snap);
        return;
    }
    if (st != kNowActOk) {
        reply_registered_status(out, cap, id, st);
        return;
    }
    if (!g_snap.fired) {
        /* Withdraw before returning. This was the one act path that left
           without it: harmless while the cell's only protection was that
           nothing else could reach it, and a latch leak now that the
           wait pumps - every later act would answer `act-busy`. */
        now_act_withdraw();
        reply_registered_error(
            out, cap, id, "act-not-taken",
            "the resident plane did not queue the dialog press");
        return;
    }
    now_act_withdraw();

    rows_reset(&rows);
    row_add(&rows, "Element", ref);
    row_addf(&rows, "Item", "%ld", item);
    row_add(&rows, "Dispatch", "dispatched");
    row_add(&rows, "Mechanism", "the application's Dialog Manager path");
    now_log(kLogInfo, "act", "#%ld ditemact item %ld dispatched", id,
            item);
    settlement_rows(&rows);
    reply_rows(out, cap, id, "ditemact", &rows);
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
    int                 visibility;
    NowActMenuProbe     probe;

    memset(&probe, 0, sizeof probe);
    now_act_begin_command();
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
    if (!arg_int(request_json, "serialHi", &hi)
        || !arg_int(request_json, "serialLo", &lo)) {
        reply_error(out, cap, id, "bad-request",
                    "menuact requires serialHi and serialLo from the scene's "
                    "front process. A menu bar belongs to that exact process; "
                    "falling back to whichever app is front now can invoke a "
                    "different application's item");
        return;
    }
    psn.highLongOfPSN = hi;
    psn.lowLongOfPSN = (unsigned long)lo;
    want = &psn;
    visibility = menu == -16489L && (item == 1L || item == 2L);
    if (!visibility && act_target_is_self(want)
        && g_self_menu_handler != NULL) {
        if (!g_self_menu_handler((menu << 16) | (item & 0xFFFFL))) {
            reply_error(out, cap, id, "self-menu-busy",
                        "the application's prior menu command is still "
                        "queued for its main event loop");
            return;
        }
        rows_reset(&rows);
        row_addf(&rows, "Menu", "%ld", menu);
        row_addf(&rows, "Item", "%ld", item);
        row_add(&rows, "Dispatch", "dispatched");
        row_add(&rows, "Mechanism", "the application's main-loop menu queue");
        now_log(kLogInfo, "act", "#%ld menuact %ld/%ld queued for main loop",
                id, menu, item);
        reply_rows(out, cap, id, "menuact", &rows);
        return;
    }
    /* READ THE ITEM BEFORE PRESSING IT. Not for tidiness: MenuSelect
       returns whatever we answer with, so a press on a DISABLED item
       reported `dispatched` and did nothing, forever - the Finder's
       `File > Print` with an empty selection, watched 2026-08-07. The
       probe refuses only on a POSITIVE reading; an unreadable menu list
       comes back Unknown and this dispatches as before, because "I could
       not look" is not "no".

       AFTER the two paths that do not go through a foreign MenuSelect,
       and the ordering is load-bearing. The visibility items are the
       Process Manager's, not any application's. And SELF is worse than
       useless here: axprocess.h says plainly that binding our own PSN
       "walks to nothing useful", because NOW is Carbon and its records
       are not at the classic offsets - so probing our own menu bar could
       refuse a legitimate act on the strength of a walk that was never
       looking at our menus. */
    if (!visibility) {
        now_act_menu_probe(want, menu, item, &probe);
        if (now_act_menu_probe_code(&probe) != NULL) {
            reply_error(out, cap, id, now_act_menu_probe_code(&probe),
                        now_act_menu_probe_message(&probe));
            return;
        }
    }
    st = now_act_ready();
    if (st != kNowActOk) {
        reply_status(out, cap, id, st);
        return;
    }
    st = now_act_open(want, &g_target);
    if (st != kNowActOk) {
        reply_status(out, cap, id, st);
        return;
    }
    cell = now_act_cell();
    if (cell == NULL) {
        /* NULL is two answers: no usable plane, or another act already
           holds its single cell. now_act_why_no_cell() tells them apart -
           reporting "no extension" for a busy plane would send someone
           to reinstall software that is working. */
        reply_status(out, cap, id, now_act_why_no_cell());
        return;
    }

    /* The menu bar is 20 px tall; aim at its middle. */
    h = (int)(title_left + 4);
    v = 10;
    cell->op = visibility ? kNowPeekActOpVisibility : kNowPeekActOpMenu;
    cell->menu_id = (NowPeekI32)menu;
    cell->item_index = visibility
        ? (NowPeekI32)(item == 1L ? kNowPeekActVisibilityHide
                                 : kNowPeekActVisibilityHideOthers)
        : (NowPeekI32)item;
    cell->arm_point_h = (NowPeekI32)h;
    cell->arm_point_v = (NowPeekI32)v;
    /* A MARKED MENU CAN CONFIRM ITSELF. Where the machine already marks
       one of this menu's items, the mark landing on the one pressed is
       the application saying its handler ran, and the act can reach
       `confirmed`. Where it does not, no postcondition is armed and the
       reply says the effect is unverifiable rather than leaving
       `dispatched-but-unconfirmed` to read like a pending answer. */
    now_act_clear_menu_postcondition();
    if (probe.marked_group && !probe.item_marked) {
        now_act_arm_menu_postcondition(menu, item);
    }

    st = now_act_submit(&g_target, &g_snap);
    if (st == kNowActRefused) {
        reply_plane_error(out, cap, id, &g_snap);
        return;
    }
    if (st != kNowActOk) {
        reply_registered_status(out, cap, id, st);
        return;
    }
    if (!act_reached_the_machine(&g_snap)) {
        now_act_withdraw();
        reply_registered_status(out, cap, id, kNowActNotArmed);
        return;
    }
    st = now_act_await_fired(&g_snap);
    if (st != kNowActOk) {
        reply_registered_error(
            out, cap, id, "act-not-taken",
            visibility
                ? "the target context did not accept the visibility key"
                : "armed, and the application never called MenuSelect");
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
    row_add(&rows, "Mechanism", visibility
        ? "the Process Manager's keyboard equivalent in the target context"
        : "the application's own MenuSelect");
    /* WHAT WOULD PROVE IT, said out loud. A caller reading
       `dispatched-but-unconfirmed` cannot otherwise tell "not yet" from
       "never, because nothing here can answer", and treating the second
       as the first is how a driving agent waits on a result that is not
       coming. */
    row_add(&rows, "Verification",
            visibility
                ? "none: the Process Manager's own action leaves no mark "
                  "this Mac can read back"
            : probe.verdict == kNowActMenuProbeUnknown
                ? "unavailable: this menu bar could not be read, so the "
                  "item was neither checked before nor can be checked after"
            : probe.marked_group && !probe.item_marked
                ? "the mark moving onto this item; a later scene settles it"
            : probe.marked_group && probe.item_marked
                ? "none: this item already carried the mark, so the mark "
                  "cannot say whether the press did anything"
                : "none available: this menu marks no item, so the machine "
                  "states nothing this act could be confirmed against");
    now_log(kLogInfo, "act", "#%ld menuact %ld/%ld dispatched", id, menu, item);
    settlement_rows(&rows);
    reply_rows(out, cap, id, "menuact", &rows);
}
