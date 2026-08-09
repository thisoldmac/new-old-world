#include "act_cmds.h"

#include <Carbon.h>
#include <stdio.h>
#include <string.h>

#include "act_args.h"
#include "act_client.h"
#include "act_menu_probe.h"
#include "axresolve.h"
#include "cmd_line.h"
#include "ctlact_line.h"
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
        /* TERMINAL here, unlike ctlact: this arm ends the act on the
           expiry and the counters below are the whole account of it, so
           the settlement's terminal word is the right one. */
        st = now_act_await_fired(&g_snap, 1);
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

/* How long part 0 will watch the control it pressed. Ticks.
 *
 * DELIBERATELY SHORTER THAN kNowActDeadlineTicks (300). That deadline is
 * how long a target may take to PUMP, and it is generous because a busy
 * application may be slow to reach its event loop. This one starts after
 * the target has already served the request and queued the press in its
 * own context, so the only thing still outstanding is the application
 * dequeuing one click - and it returns the moment the control moves, so
 * the number is only what an unmoved control costs. Two seconds against
 * an Appearance tab that redraws in well under one. */
enum { kCtlactSettleTicks = 120 };

/* What the control said about the act, as a reason rather than a flag -
   because `not confirmed` has three causes and they send a reader to
   three different places. */
typedef enum {
    kCtlMoved = 0,      /* re-read, and its value differs from before   */
    kCtlUnmoved,        /* re-read, and it is exactly where it was      */
    kCtlNoRange,        /* re-read, but min == max: nothing to observe  */
    kCtlUnreadable      /* the re-read itself failed; `after.why` says  */
} NowCtlSettled;

/* Watch ONE control for `ticks`, stopping the moment it moves.
 *
 * This is `part 11`'s settlement check written for the form that has no
 * patch to wait on: part 11 waits for the application to answer a trap,
 * part 0 waits for the application to move the control. Both wait for
 * the APPLICATION to do something observable, and both stop as soon as
 * it does. `ticks` of 0 takes a single reading, which is what a named
 * part wants - its settlement already happened.
 *
 * It re-resolves rather than re-reading a cached record: the reference
 * layer re-proves the control from foreign memory every time, so a
 * control that went away during the act is reported as gone rather than
 * as unmoved. */
static NowCtlSettled await_control_moved(const char *ref, long before,
                                         NowObsHandle *after,
                                         unsigned long ticks)
{
    unsigned long deadline = (unsigned long)TickCount() + ticks;

    for (;;) {
        now_observe_resolve_element(ref, 0, after);
        if (after->verdict != kNowObsOk) {
            return kCtlUnreadable;
        }
        if (after->detail.control.max <= after->detail.control.min) {
            return kCtlNoRange;
        }
        if ((long)after->detail.control.value != before) {
            return kCtlMoved;
        }
        if ((unsigned long)TickCount() >= deadline) {
            return kCtlUnmoved;
        }
        now_act_yield_once();
    }
}

void now_act_run_ctlact(const char *request_json, long id, char *out, long cap)
{
    NowCtlSettled       moved;
    NowObsHandle        handle;
    NowObsHandle        after;
    NowPeekActCell     *cell;
    ActRows             rows;
    char                ref[kNowObsTokenMax];
    NowActStatus        st;
    long                part = 0;
    long                point_h = 0, point_v = 0;
    int                 has_point = 0;
    /* Did the patch answer? Only ever reported as an absence, never as a
       verdict - see the `part != 0` arm. Starts 1 because part 0 asks no
       patch at all, and its receipt must not claim one was silent. */
    int                 track_answered = 1;
    char                line[kNowCtlactLineMax];
    char                rebuilt[kNowCtlactLineMax];

    now_act_begin_command();
    /* THE CONSOLE FACE, and it is first because a console line supplies
       every argument at once. A typed caller's named args win where both
       arrive, which is the rule cmd_line.h states for every verb. */
    if (now_cmd_line(request_json, line, (long)sizeof line) && line[0] != '\0') {
        char line_ref[kNowObsTokenMax];
        long line_part = 0, line_h = 0, line_v = 0;
        int  line_has_point = 0, half = 0;

        if (!now_ctlact_parse_line(line, line_ref, (long)sizeof line_ref,
                                   &line_part, &line_has_point,
                                   &line_h, &line_v, &half)) {
            reply_error(out, cap, id, "bad-request",
                        half ? "ctlact's point needs both numbers: "
                               "ctlact <element> <part> <h> <v>, in global "
                               "screen coordinates"
                             : "ctlact <element> <part> [h v]. The element "
                               "is one now-element- reference, which "
                               "`elements` prints; the part is a Control "
                               "Manager part code, and 0 means let the "
                               "application's own tracking decide from "
                               "where the click landed");
            return;
        }
        /* Rebuilt as the typed request this command already serves, so
           there is ONE implementation below and the console is not a
           second path through it. */
        if (!now_ctlact_line_request(line_ref, line_part, line_has_point,
                                     line_h, line_v,
                                     rebuilt, (long)sizeof rebuilt)) {
            reply_error(out, cap, id, "bad-request",
                        "that element reference is too long to be one this "
                        "Mac minted");
            return;
        }
        request_json = rebuilt;
    }
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
    /* THE POINT, and it is all-or-nothing. A caller that sent one
       coordinate meant to aim; taking the centre in the other axis would
       be an act landing somewhere nobody asked for, and the reply would
       still say `dispatched`. */
    if (arg_int_malformed(request_json, "h")
        || arg_int_malformed(request_json, "v")) {
        reply_error(out, cap, id, "bad-request",
                    "ctlact's h and v are present but not numbers. Send "
                    "JSON integers, not quoted ones");
        return;
    }
    {
        int have_h = arg_int(request_json, "h", &point_h);
        int have_v = arg_int(request_json, "v", &point_v);

        if (have_h != have_v) {
            reply_error(out, cap, id, "bad-request",
                        "ctlact's point needs both h and v, in global "
                        "screen coordinates. One alone would silently mean "
                        "\"the centre\" in the other axis");
            return;
        }
        has_point = have_h;
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
    if (has_point) {
        /* WHERE IS NOW PART OF THE REQUEST for the two controls whose
           identity is not enough: a tab strip is one control and eight
           tabs, a list box is one control and every row. For those the
           part code decides nothing and the point decides everything.
         *
           It is CHECKED against the rect the resolver just proved, in
           the same global frame, and refused rather than clamped. A
           clamp would turn "I aimed at the wrong thing" into "I pressed
           the edge of the right thing", and the reply would say
           dispatched either way. */
        if (point_h < handle.detail.control.left
            || point_h >= handle.detail.control.right
            || point_v < handle.detail.control.top
            || point_v >= handle.detail.control.bottom) {
            now_act_withdraw();
            reply_error(out, cap, id, "bad-request",
                        "that point is outside the control this reference "
                        "names. Send a point inside its rect, in the same "
                        "global coordinates the observation reported");
            return;
        }
        cell->click_h = (NowPeekI32)point_h;
        cell->click_v = (NowPeekI32)point_v;
    } else {
        cell->click_h = (NowPeekI32)((handle.detail.control.left
                                      + handle.detail.control.right) / 2);
        cell->click_v = (NowPeekI32)((handle.detail.control.top
                                      + handle.detail.control.bottom) / 2);
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

    /* WHAT EACH FORM OF THIS VERB MAY BE JUDGED BY, and the two forms do
     * not have the same answer. Getting that wrong cost the verb its
     * verdict in both directions, and the second cost was not free.
     *
     * A NAMED PART asks the patch to answer, so the patch answering IS
     * the settlement: the application called TrackControl, and one that
     * never did did not take the click. Unchanged below.
     *
     * PART 0 ASKS FOR NO PATCH. It posts a real click and lets the
     * application's own tracking decide - and an Appearance-era tab is
     * handled by the Appearance Manager's own click path, where no patch
     * is ever consulted. Waiting for one was wrong twice over, measured
     * on the emulator 2026-08-07 with the tab confirmed switched in the
     * guest's own pixels (value 4 -> 1, 1949 of 9320 strip pixels):
     *
     *   - THE VERDICT WAS A LIE. The reply read `Settlement: timed-out`
     *     on the press that WORKED - word for word the same reply a
     *     press that did nothing produced. A verb that cannot tell its
     *     two outcomes apart cannot be believed about either.
     *   - THE WAIT ITSELF DID THE DAMAGE. Burning the full 300-tick
     *     deadline took every part-0 press to 5.1 s, a hundred times a
     *     part-23 scroll, and outran the 180-tick writer lease - so the
     *     anchor plane went dark mid-act and `Re-read value`, the only
     *     evidence this form has, came back "the anchor plane is absent
     *     or not armed". (act_client.c :: act_yield now renews that
     *     lease; not asking for the extra seconds is the other half.)
     *
     * So part 0 waits for THE CONTROL - the thing it aimed at - and
     * stops the moment the control moves. */
    if (part != 0) {
        /* The resident plane queued the press when it armed. The
           application calls TrackControl from its own mouseDown handler,
           so it still needs one to get there - but where it lands
           decides nothing, because the patch answers with the part we
           named and refuses any control but this one. */
        st = now_act_await_fired(&g_snap, 0);
        if (st == kNowActNotTaken) {
            /* THE ABSENCE OF ONE TRAP CALL IS NOT A FACT ABOUT THE
             * MACHINE, and this arm phrased it as one for a day.
             *
             * It answered `act-not-taken` - "armed, and the application
             * never called TrackControl" - which reads as a conclusion
             * that nothing happened. It is an INFERENCE from a single
             * missing observation, and fidelity sweep D caught it being
             * wrong (SEQ-A step 4): the Appearance panel's help "?"
             * button, pressed with `part: 11`, answered exactly that
             * while the guest's own screendumps show no Help Viewer
             * before and Mac Help frontmost, having searched
             * "Appearance", after. A Carbon control actuated by any
             * other route - and a Help button on CarbonLib is a prime
             * candidate - lands without TrackControl ever being called.
             *
             * WHY IT IS WORSE THAN A WRONG WORD. An agent that believes
             * a refusal presses again, and the second press lands too.
             * A false negative in an act plane produces DUPLICATED
             * actions; on a destructive verb that is worse than a crash.
             *
             * WHETHER THE TWO CASES CAN BE TOLD APART - and the honest
             * answer is NO, which is why the weaker verdict is now given
             * every time. Sweep C scored this identical message as a
             * clean refusal, and it may well have been one; nothing in
             * the reply distinguished them then and nothing can now.
             * Everything that COULD establish "nothing happened" is
             * already checked above and returns its own status: the
             * plane refusing (`reply_plane_error`), the request never
             * reaching the machine (`act_reached_the_machine` answering
             * no, one branch above), the reference not resolving. Past
             * those, the press was queued inside the target's own
             * context and this application cannot see what the target
             * did with it. So there is no positive evidence of absence
             * left to gather, and `act-not-taken` has nothing to be
             * reserved FOR on this path - it is removed rather than
             * narrowed.
             *
             * What remains is `dispatched-but-unconfirmed`, which this
             * verb's part-0 form already answers and which is the honest
             * shape: it went, and this side cannot prove what it did.
             * The control watch below can still upgrade it to
             * `confirmed` on a control that publishes a position - so a
             * press that moved something is still reported as landing,
             * and only a press whose effect is invisible from here stays
             * unconfirmed. */
            track_answered = 0;
        } else if (st != kNowActOk) {
            /* Not a timeout: the plane itself went away between arming
               and waiting. That is a plane-health status with its own
               vocabulary, and reporting it as a verdict about the act
               would send a reader to the wrong half of the system. */
            reply_registered_status(out, cap, id, st);
            return;
        }
    }
    /* THE SAME WATCH FOR BOTH FORMS, and it costs a named part nothing:
       a control with no range answers on the first reading, and one that
       moved answers on the first reading too. Only a control that CAN
       move and did not pays the budget - which is exactly the case worth
       being sure about before saying so. */
    moved = await_control_moved(ref, (long)handle.detail.control.value,
                                &after, kCtlactSettleTicks);
    now_act_withdraw();
    now_act_note_observed(moved == kCtlMoved);

    rows_reset(&rows);
    row_add(&rows, "Element", ref);
    row_addf(&rows, "Part", "%ld", part);
    /* THE VERDICT ROW, and it is the settlement vocabulary rather than a
       word of this verb's own. `click posted` described the DISPATCH and
       was read as the effect - which is the exact failure slice 8 exists
       to remove, and it read identically over a machine that did
       nothing. `dispatched-but-unconfirmed` is already what the plane
       says elsewhere for "it went and I cannot prove what it did"; a
       second vocabulary here would only be a second thing to learn. */
    row_add(&rows, "Dispatch",
            moved == kCtlMoved ? "confirmed - the control moved"
                               : "dispatched-but-unconfirmed");
    if (part == 0) {
        row_add(&rows, "Mechanism",
                "a real click at the point; this form asks no patch to "
                "answer, so the control's own position is the evidence");
    } else if (track_answered) {
        row_add(&rows, "Mechanism", "the application's own TrackControl");
    } else {
        /* NAMED AS AN ABSENCE, not as an outcome. The receipt has to say
           which witness was silent, or `dispatched-but-unconfirmed`
           here is indistinguishable from the same words after a patch
           that answered and a control with no range. */
        row_add(&rows, "Mechanism",
                "armed for the application's own TrackControl, which it "
                "did not call before the deadline. That is the absence "
                "of one trap call and nothing more - a control actuated "
                "by another route lands without it - so it is not "
                "evidence the act was not taken");
    }
    if (has_point) {
        char point[64];

        snprintf(point, sizeof point, "%ld,%ld (global, as sent)",
                 point_h, point_v);
        row_add(&rows, "Point", point);
    } else {
        row_add(&rows, "Point", "the centre of the control this reference "
                                "names");
    }
    /* A control with a live range publishes its position, so for those
       the guest itself can be quoted. A push button has no such range
       and this proves nothing about it - its effect is whatever its own
       handler did, which only the caller can name and check. The
       stronger claim is made exactly where the guest supports it.

       WHY the verdict above cannot be recovered from these rows alone:
       `unconfirmed` has three causes and they send a reader to three
       different places - the control never moved, the control has no
       position to move, or the re-read itself failed. Each says which. */
    switch (moved) {
    case kCtlMoved:
    case kCtlUnmoved:
        /* BESIDE the value the resolver read BEFORE the act, because a
           number on its own cannot say whether anything moved - and for
           part 0, that pair is the only evidence there is. Both are the
           guest's own reads of the same control, either side of one
           request. */
        row_addf(&rows, "Value before", "%ld",
                 (long)handle.detail.control.value);
        row_addf(&rows, "Re-read value", "%ld",
                 (long)after.detail.control.value);
        break;
    case kCtlNoRange:
        row_add(&rows, "Re-read value",
                "this control has no range, so its position "
                "answers nothing about the act");
        break;
    default:
        row_add(&rows, "Re-read value", now_obs_why_text(after.why));
        break;
    }
    now_log(kLogInfo, "act", "#%ld ctlact part %ld %s", id, part,
            moved == kCtlMoved ? "confirmed" : "dispatched-but-unconfirmed");
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
    long                arm_left = 0;
    long                hi = 0;
    long                lo = 0;
    int                 h;
    int                 v;
    int                 visibility;
    NowActMenuProbe     probe;
    NowActMenuIdentity  identity = kNowActMenuIdentityUnchecked;

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
    /* Until the machine is asked, the caller's number is all there is.
       The probe below replaces it with the menu bar's own where it can
       read one, and refuses where the two disagree. */
    arm_left = title_left;
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
        /* No press is armed on this path - the command goes to NOW's own
           event loop - so there is no coordinate to be anyone's and
           nothing for the identity check to be about. Stated rather than
           omitted: a missing Identity row would read as unchecked. */
        row_add(&rows, "Identity",
                "not applicable: NOW's own menu command, dispatched "
                "through its event loop rather than by arming a press");
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
        /* AND THE SAME WALK ANSWERS THE IDENTITY CHECK. The coordinate
           IS the safety property here, so it is checked against the
           machine rather than trusted - act_menu_probe.h states the two
           ways a well-behaved caller's number goes wrong. Before the
           plane is opened and before anything is armed: a press that
           does not belong to the menu it names must never reach the
           cell, because once armed it will answer somebody's press. */
        identity = now_act_menu_identity(&probe, title_left, &arm_left);
        if (identity == kNowActMenuIdentityMoved) {
            reply_error(out, cap, id, "menu-title-moved",
                        "titleLeft is not where this application's own "
                        "menu bar puts that menu's title, so arming there "
                        "would answer a press that is not this act's - "
                        "read the menu bar again and send the x it "
                        "reports now");
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
    h = (int)(arm_left + 4);
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
    st = now_act_await_fired(&g_snap, 1);
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
    /* WHICH OF THE TWO THIS CALLER GOT, said out loud on the success
       path as well as the refusing one. Where two paths must remain,
       publish which is which: `checked` and `unchecked` are different
       safety claims, and a reply that named neither left a driving agent
       unable to tell a verified press from a trusted one. The visibility
       items are the Process Manager's and go nowhere near a menu bar
       press, so they have no identity to check rather than an unchecked
       one. */
    if (!visibility) {
        row_add(&rows, "Identity", now_act_menu_identity_note(identity));
    }
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

/* P8 cursor-only adjunct. The opaque window reference supplies the owning
   process/A5 world and bounds the point; the operation changes no selection,
   front order, or Finder state. */
void now_act_run_cursoract(const char *request_json, long id,
                           char *out, long cap)
{
    NowObsHandle handle;
    NowPeekActCell *cell;
    ActRows rows;
    char ref[kNowObsTokenMax];
    NowActStatus st;
    long h = 0;
    long v = 0;
    const NowAxWindow *w;

    now_act_begin_command();
    if (arg_int_malformed(request_json, "h")
        || arg_int_malformed(request_json, "v")
        || !arg_int(request_json, "h", &h)
        || !arg_int(request_json, "v", &v)) {
        reply_error(out, cap, id, "bad-request",
                    "cursoract requires numeric h and v");
        return;
    }
    if (!resolve_for_act(request_json, id, out, cap, kNowObsKindWindow,
                         &handle, ref, 1)) {
        return;
    }
    w = &handle.detail.window;
    if (w->right <= w->left || w->bottom <= w->top
        || h < w->left || h >= w->right
        || v < w->top || v >= w->bottom) {
        reply_error(out, cap, id, "bad-request",
                    "cursoract's point must be inside the window named by "
                    "its observation reference");
        return;
    }
    cell = now_act_cell();
    if (cell == NULL) {
        reply_status(out, cap, id, now_act_why_no_cell());
        return;
    }
    cell->op = kNowPeekActOpCursorPlace;
    cell->window_ptr = (NowPeekU32)handle.detail.window.address;
    cell->click_h = (NowPeekI32)h;
    cell->click_v = (NowPeekI32)v;
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
        now_act_withdraw();
        reply_registered_error(out, cap, id, "act-not-taken",
                               "the resident did not place the cursor");
        return;
    }
    now_act_withdraw();
    rows_reset(&rows);
    row_add(&rows, "Window", ref);
    row_addf(&rows, "At h", "%ld", h);
    row_addf(&rows, "At v", "%ld", v);
    row_add(&rows, "Dispatch", "placed");
    row_add(&rows, "Mechanism", "resident P8 cursor plane");
    settlement_rows(&rows);
    reply_rows(out, cap, id, "cursoract", &rows);
}

/* ---- dragpress / dragmove / dragrelease (P7) ---------------------------
 *
 * THREE VERBS FOR ONE GESTURE, and the asymmetry between them is the
 * plane's central fact rather than an interface wart.
 *
 * `dragpress` is an act request. It resolves an element, opens its
 * process, and submits through the same cell every other act uses,
 * because the press needs the target's own context, its identity check
 * and its A5 world.
 *
 * `dragmove` and `dragrelease` are NOT act requests and could not be.
 * The instant the button is down the target is inside DragGrayRgn or
 * TrackControl and has stopped calling GetNextEvent, so the jGNE filter
 * that serves act requests is never entered again until the gesture
 * ends. They write the drag cell and return; the resident's Time Manager
 * task is what reads them.
 *
 * WHAT THEY PROMISE. `dragpress` promises the button was put down.
 * `dragmove` promises a want was published. `dragrelease` promises the
 * resident was ASKED - never that it released, because the resident's
 * own deadline may have got there first and the honest answer to "did my
 * release happen" is a re-read of end_reason. That is lane D's rule
 * (an act that cannot verify itself says so) applied to a plane where
 * the verifying party is a Time Manager task. */

static void drag_state_rows(ActRows *rows, const NowPeekDragCell *drag)
{
    const char *state = "unknown";
    const char *reason = NULL;

    switch (drag->state) {
    case kNowPeekDragStateIdle:  state = "idle"; break;
    case kNowPeekDragStateHeld:  state = "held"; break;
    case kNowPeekDragStateEnded: state = "ended"; break;
    default: break;
    }
    row_add(rows, "State", state);
    row_addf(rows, "Session", "%ld", (long)drag->session);
    row_addf(rows, "At h", "%ld", (long)drag->at_h);
    row_addf(rows, "At v", "%ld", (long)drag->at_v);
    row_add(rows, "Button", drag->button_down ? "down" : "up");
    /* Evidence the vehicle RAN, in the shape liveness_ticks is: a count,
       not a timestamp, because a stopped clock and a stopped task look
       identical in a timestamp. Zero ticks with the button down is the
       one reading that says the Time Manager task never fired - which is
       exactly the failure this plane cannot otherwise distinguish from a
       Finder that ignores the writes. */
    row_addf(rows, "Vehicle ticks", "%ld", (long)drag->ticks_served);
    row_addf(rows, "Moves applied", "%ld", (long)drag->moves_applied);
    /* The clamped deadlines actually in force. Reported because a clamp
       nobody can observe is indistinguishable from a caller being right. */
    row_addf(rows, "Idle deadline", "%ld", (long)drag->idle_in_force);
    row_addf(rows, "Gesture cap", "%ld", (long)drag->cap_in_force);

    switch (drag->end_reason) {
    case kNowPeekDragEndNone: break;
    case kNowPeekDragEndReleased: reason = "released-as-asked"; break;
    /* The two dead-man codes stay separate all the way out to the
       caller. An idle expiry says the host stopped talking; a cap expiry
       says it never stopped and never finished. Collapsing them into
       "timed out" would throw away which repair to make. */
    case kNowPeekDragEndDeadManIdle: reason = "dead-man-idle"; break;
    case kNowPeekDragEndDeadManCap: reason = "dead-man-cap"; break;
    case kNowPeekDragEndSessionLost: reason = "session-lost"; break;
    default: reason = "unknown"; break;
    }
    if (reason != NULL) {
        row_add(rows, "Ended", reason);
    }
}

void now_act_run_dragpress(const char *request_json, long id,
                           char *out, long cap)
{
    NowObsHandle     handle;
    NowPeekActCell  *cell;
    NowPeekDragCell *drag;
    ActRows          rows;
    char             ref[kNowObsTokenMax];
    NowActStatus     st;
    NowPeekU32       session;
    long             idle = 0;
    long             gcap = 0;
    long             h = 0;
    long             v = 0;
    long             to_h = 0;
    long             to_v = 0;
    int              have_point;
    int              have_to;
    int              by_window;
    char             probe[kNowObsTokenMax];

    now_act_begin_command();
    if (arg_int_malformed(request_json, "idle")
        || arg_int_malformed(request_json, "cap")
        || arg_int_malformed(request_json, "h")
        || arg_int_malformed(request_json, "v")
        || arg_int_malformed(request_json, "toH")
        || arg_int_malformed(request_json, "toV")) {
        reply_error(out, cap, id, "bad-request",
                    "dragpress's idle, cap, h, v, toH and toV are present "
                    "but are not JSON numbers");
        return;
    }
    (void)arg_int(request_json, "idle", &idle);
    (void)arg_int(request_json, "cap", &gcap);
    have_point = arg_int(request_json, "h", &h)
              && arg_int(request_json, "v", &v);
    /* THE DESTINATION, AND WHY IT IS ON THE PRESS.
       Once this returns the target is inside its own tracking loop and
       this application stops being scheduled, so a dragmove sent after
       the press cannot be read until the gesture is already over
       (docs/open-issues.md, break 4). A caller that wants an item to
       MOVE has exactly this one chance to say where. */
    have_to = arg_int(request_json, "toH", &to_h);
    if (have_to != arg_int(request_json, "toV", &to_v)) {
        /* The same rule ctlact's h/v pair has, for the same reason: a
           half-specified destination would silently mean "stay where you
           are" in one axis, which is a drag to somewhere nobody asked
           for. */
        reply_error(out, cap, id, "bad-request",
                    "toH and toV go together: a destination with one axis "
                    "missing is a drag to a point nobody named");
        return;
    }

    /* EXACTLY ONE NAME FOR THE TARGET, and the second one exists because
       the first cannot reach a Finder icon.

       An icon on the desktop or in a folder window is not a Control
       Manager object: the Finder lays it out in its own structures, so
       the element walk cannot see it and no observation ever minted an
       element reference for it. Every item drag a person made therefore
       had nothing to name (docs/open-issues.md, 2026-08-07).

       What made a second form defensible rather than a loophole is what
       this verb actually does with the reference, which is less than it
       looks. ctlact's trap patch answers for the ControlHandle the
       request names, so its reference bounds the act. A drag press does
       not act through the named thing at all: the resident puts the
       button down at the caller's point and carries the session nonce in
       the field a handle would have used (ext/src/now_ext_act.c). The
       reference's job here is to name the PROCESS whose context the
       press runs in.

       So the window form names the CONTAINER, and the point is checked
       against it below. A window reference with a point anywhere on the
       screen would have been "a coordinate is a reference" arriving by
       the back door, which obsref.h asks reviewers to refuse. */
    by_window = arg_str(request_json, "window", probe,
                        (long)kNowObsTokenMax);
    if (by_window == arg_str(request_json, "element", probe,
                             (long)kNowObsTokenMax)) {
        reply_error(out, cap, id, "bad-request",
                    by_window
                        ? "dragpress takes element OR window and this "
                          "names both. They mean different targets and "
                          "nothing here gets to pick one"
                        : "dragpress requires element or window: one "
                          "opaque reference minted by an observation. "
                          "element names the thing pressed; window names "
                          "the container a press happens inside, which is "
                          "how a Finder icon is reached");
        return;
    }
    if (by_window && !have_point) {
        /* A window is a container, not a point. There is no rectangle to
           centre on that would mean anything, and the fallback below is
           deliberately not reused: pressing at the middle of a Finder
           window would pick up whatever happened to be there. */
        reply_error(out, cap, id, "bad-request",
                    "the window form of dragpress requires h and v: a "
                    "window is a container rather than a point, and this "
                    "verb does not press at a guessed one");
        return;
    }

    if (!resolve_for_act(request_json, id, out, cap,
                         by_window ? kNowObsKindWindow : kNowObsKindElement,
                         &handle, ref, 0)) {
        return;
    }
    if (by_window) {
        /* The bound that makes the reference do real work. detail.window
           is the CONTENT region's bounding box in global coordinates
           (axwalk.c reads contRgn and leaves it global), which is the
           same space h and v are in - so this is a comparison and not a
           conversion, and there is no second frame of reference to get
           wrong. */
        const NowAxWindow *w = &handle.detail.window;

        if (w->right <= w->left || w->bottom <= w->top) {
            reply_error(out, cap, id, "unsupported",
                        "this window resolves to no rectangle, so there is "
                        "nothing to check the press point against");
            return;
        }
        if (h < w->left || h >= w->right || v < w->top || v >= w->bottom) {
            reply_error(out, cap, id, "bad-request",
                        "that point is outside the window it names. The "
                        "window form presses INSIDE its container - a "
                        "reference that did not bound the point would be a "
                        "coordinate wearing a reference's clothes");
            return;
        }
    }
    /* Refuse BEFORE pressing, never after. A resident with a cell but no
       vehicle would take the press and never let go of it, which is the
       one outcome this whole plane exists to make impossible. */
    if (!now_act_drag_available()) {
        reply_error(out, cap, id, "unsupported",
                    "this resident has no drag vehicle, so a button it "
                    "pressed could never be released");
        return;
    }
    drag = now_act_drag_cell();
    if (drag->state == (NowPeekU32)kNowPeekDragStateHeld) {
        reply_error(out, cap, id, "conflict",
                    "a drag is already holding the mouse button down, and "
                    "there is only one");
        return;
    }
    cell = now_act_cell();
    if (cell == NULL) {
        reply_status(out, cap, id, now_act_why_no_cell());
        return;
    }

    if (!have_point) {
        /* ELEMENT FORM ONLY: the window form was refused above without a
           point, so this branch cannot be reached with a container.

           Fall back to the resolver's own rectangle for the element -
           but only if it HAS one. Found by driving: the resolver leaves
           detail.control zeroed for controls the scene walk reports with
           real bounds, so this silently pressed at 0,0.

           For ctlact that would be harmless, because its patch answers
           for the HANDLE the request names and where the click landed
           decides nothing. For a drag the point is the entire operation.
           So this refuses rather than guesses - the same rule that says
           an item whose home we cannot trust must not be dragged at
           all. A caller that knows the point passes h and v. */
        h = (handle.detail.control.left + handle.detail.control.right) / 2;
        v = (handle.detail.control.top + handle.detail.control.bottom) / 2;
        if (handle.detail.control.right <= handle.detail.control.left
            || handle.detail.control.bottom <= handle.detail.control.top) {
            reply_error(out, cap, id, "unsupported",
                        "this element resolves to no rectangle, so there "
                        "is no trustworthy point to press. Pass h and v "
                        "from an observation that does know where it is");
            return;
        }
    }

    session = now_act_drag_next_session();
    cell->op = kNowPeekActOpDragPress;
    /* The session nonce and the two deadlines ride in existing 32-bit
       fields with no meaning for this op - the accretive rule asking for
       reuse rather than three new ones. The RESIDENT clamps the
       deadlines regardless of what arrives here. */
    cell->control_handle = session;
    cell->win_h = (NowPeekI32)idle;
    cell->win_v = (NowPeekI32)gcap;
    cell->click_h = (NowPeekI32)h;
    cell->click_v = (NowPeekI32)v;
    /* The destination in the menu guard's point pair, flagged by
       zoom_part - three more fields with no meaning for this op, which
       is what the accretive rule asks for. peek_table.h states the
       reuse where both compilers read it. */
    cell->zoom_part = have_to ? 1 : 0;
    cell->arm_point_h = (NowPeekI32)to_h;
    cell->arm_point_v = (NowPeekI32)to_v;

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
        now_act_withdraw();
        reply_registered_error(out, cap, id, "act-not-taken",
                               "the resident plane did not begin the drag");
        return;
    }
    now_act_withdraw();

    rows_reset(&rows);
    /* Which form was used, said in the label rather than left for a
       reader to infer from the token's prefix. A receipt names what was
       asked for, and the two forms promise different things about where
       the press could have landed. */
    row_add(&rows, by_window ? "Window" : "Element", ref);
    row_add(&rows, "Dispatch", "pressed");
    row_add(&rows, "Point from", have_point ? "the caller" : "the resolver");
    if (have_to) {
        row_addf(&rows, "To h", "%ld", to_h);
        row_addf(&rows, "To v", "%ld", to_v);
    } else {
        row_add(&rows, "To", "nowhere - no toH/toV, so no item moves");
    }
    /* THE PAIR THAT SEPARATES A SLOW RESIDENT FROM A STARVED
       APPLICATION. Both look like "the press took four seconds" and the
       repairs are opposite ones. Reported on every press rather than
       behind a flag, because the number that matters is the one from the
       run somebody is already looking at. */
    row_addf(&rows, "Submit ticks", "%ld",
             (long)now_act_last_submit_ticks());
    row_addf(&rows, "Submit yields", "%ld",
             (long)now_act_last_submit_yields());
    drag_state_rows(&rows, drag);
    now_log(kLogInfo, "act", "#%ld dragpress session %ld", id,
            (long)session);
    settlement_rows(&rows);
    reply_rows(out, cap, id, "dragpress", &rows);
}

void now_act_run_dragmove(const char *request_json, long id,
                          char *out, long cap)
{
    NowPeekDragCell *drag;
    ActRows          rows;
    long             h = 0;
    long             v = 0;
    long             session = 0;

    now_act_begin_command();
    if (arg_int_malformed(request_json, "h")
        || arg_int_malformed(request_json, "v")
        || arg_int_malformed(request_json, "session")) {
        reply_error(out, cap, id, "bad-request",
                    "dragmove's h, v and session are present but are not "
                    "JSON numbers");
        return;
    }
    if (!arg_int(request_json, "h", &h) || !arg_int(request_json, "v", &v)
        || !arg_int(request_json, "session", &session)) {
        reply_error(out, cap, id, "bad-request",
                    "dragmove requires session, h and v: the nonce "
                    "dragpress returned, and a global point");
        return;
    }
    drag = now_act_drag_cell();
    if (drag == NULL) {
        reply_error(out, cap, id, "unsupported",
                    "this resident has no drag vehicle");
        return;
    }
    if (!now_act_drag_move((NowPeekU32)session, h, v)) {
        /* One refusal for three conditions, and they are one condition
           from the caller's side: the session it named is not the one
           holding the button. Which of the three it is, is a fact about
           the cell, and the rows below carry it. */
        rows_reset(&rows);
        drag_state_rows(&rows, drag);
        reply_error(out, cap, id, "conflict",
                    "no drag is holding the button under that session - "
                    "it may have ended, and end_reason says how");
        return;
    }
    rows_reset(&rows);
    row_add(&rows, "Dispatch", "want-published");
    row_addf(&rows, "Want h", "%ld", h);
    row_addf(&rows, "Want v", "%ld", v);
    drag_state_rows(&rows, drag);
    now_log(kLogInfo, "act", "#%ld dragmove %ld,%ld", id, h, v);
    reply_rows(out, cap, id, "dragmove", &rows);
}

void now_act_run_dragrelease(const char *request_json, long id,
                             char *out, long cap)
{
    NowPeekDragCell *drag;
    ActRows          rows;
    long             session = 0;

    now_act_begin_command();
    if (arg_int_malformed(request_json, "session")) {
        reply_error(out, cap, id, "bad-request",
                    "dragrelease's session is present but is not a JSON "
                    "number");
        return;
    }
    if (!arg_int(request_json, "session", &session)) {
        reply_error(out, cap, id, "bad-request",
                    "dragrelease requires session: the nonce dragpress "
                    "returned");
        return;
    }
    drag = now_act_drag_cell();
    if (drag == NULL) {
        reply_error(out, cap, id, "unsupported",
                    "this resident has no drag vehicle");
        return;
    }
    if (!now_act_drag_release((NowPeekU32)session)) {
        rows_reset(&rows);
        drag_state_rows(&rows, drag);
        reply_error(out, cap, id, "conflict",
                    "no drag is holding the button under that session - "
                    "the resident's own deadline may have released it "
                    "already, and end_reason says so");
        return;
    }
    rows_reset(&rows);
    /* "asked", not "released". The resident performs it on its next
       tick, through the same path its dead-man uses - and that path may
       already have fired. A verb that answered "released" here would be
       asserting an outcome it did not observe. */
    row_add(&rows, "Dispatch", "release-asked");
    drag_state_rows(&rows, drag);
    now_log(kLogInfo, "act", "#%ld dragrelease session %ld", id, session);
    reply_rows(out, cap, id, "dragrelease", &rows);
}
