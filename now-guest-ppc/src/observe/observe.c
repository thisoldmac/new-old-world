/* The impure half of the reference layer: obtaining, never deciding.
   See observe.h. */

#include "observe.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "axprocess.h"
#include "axtext.h"
#include "json.h"
#include "obsref.h"
#include "peek.h"
#include "proc_roster.h"

enum {
    /* Bounds on one answer. They are about the FRAME, not about the
       machine: a reply that will not fit is a reply nobody receives, so
       the walk stops and says it stopped. */
    kObsMaxProcs = 24,
    kObsMaxWindows = 12,
    kObsMaxControls = 24,
    /* Leave room for the tail object; below this the emitter stops
       adding rows rather than writing a truncated one. */
    kObsTailSlack = 512
};

static NowObsRegistry g_registry;
static int            g_armed;

/* --- the session secret ------------------------------------------------ */

/* There is no CSPRNG on this machine, and pretending otherwise would be
   worse than saying what this is: a mix of the values available at
   startup that an outside caller cannot observe together - the tick
   count, the microsecond clock, the Toolbox's own Random(), the date,
   and the address of a stack frame. It is enough for the property that
   matters (a caller cannot COMPUTE a token from what it can see about an
   element) and it is not claimed to be enough for anything else.

   It is deliberately not derived from anything on the wire. */
void now_observe_init(void)
{
    UnsignedWide  micro;
    unsigned long here = 0;
    unsigned long seed_hi;
    unsigned long seed_lo;
    unsigned long now_seconds = 0;

    if (g_armed) {
        return;
    }
    micro.hi = 0;
    micro.lo = 0;
    Microseconds(&micro);
    GetDateTime(&now_seconds);
    here = (unsigned long)(&micro);
    seed_hi = ((unsigned long)micro.lo)
              ^ ((unsigned long)TickCount() << 11)
              ^ here;
    seed_lo = ((unsigned long)micro.hi << 7)
              ^ ((unsigned long)(unsigned short)Random() << 16)
              ^ ((unsigned long)(unsigned short)Random())
              ^ now_seconds;
    now_obs_registry_init(&g_registry, seed_hi, seed_lo);
    g_armed = 1;
}

/* --- the plane this walk reads through ---------------------------------
 *
 * **THE WALK ARMS ITS OWN PLANE, and until 2026-08-07 it armed nothing.**
 *
 * Every foreign read below goes through the anchor plane, and this file
 * never claimed it. It worked only when somebody ELSE happened to be
 * holding the plane up — the scene, whose owner lease is ten seconds
 * (`peek.c :: kNowPeekOwnerLeaseTicks`) and is renewed by host traffic
 * only once a `scene.request` has been served on the link, or the
 * Processes page, which claims while it is the visible module.
 *
 * Two consequences, and the second is the one that was reported:
 *
 *   - A headless caller that never asks for a scene — an MCP client
 *     calling `now_observe_elements` — had NO claim at all, and every
 *     walk answered `no-plane` for every foreign process, for ever.
 *   - A caller with a Mirror polling beside it got an INTERMITTENT
 *     answer: `no-plane` seconds after a `reveal`, `ok` on a later poll,
 *     depending on where the walk fell against somebody else's poll
 *     cadence and that ten-second lease. An intermittent false negative
 *     is the worse of the two — it teaches a caller to retry blindly and
 *     makes every result downstream of it probabilistic.
 *
 * So: claim, then WAIT briefly for the resident's echo, which is the
 * scene's own pattern and for its own reason (`wire.c :: serve_scene`).
 * A claim is a request; the resident echoes it into `arm_active` on its
 * next pass, and a walk that reads before the echo gates itself off and
 * reports "I could not look" for the whole machine. `now_peek_settle`
 * returns as soon as the echo lands (~15 ms measured) and gives up after
 * half a second; the walk proceeds either way, because a walk that says
 * "not observed" is still the honest answer when the plane genuinely is
 * not armed.
 *
 * The lease is the claim's, not this call's: ten seconds, held across
 * requests. That is the number a caller acting at HUMAN speed needs —
 * an agent that observes, decides and acts is inside it, and an agent
 * that has stopped for ten seconds is one whose next answer should be
 * re-armed rather than served off a plane nobody wanted. It is not
 * released at the end of the walk on purpose: releasing would drop the
 * plane between two calls of a caller who is plainly still using it,
 * which is the flap this whole comment is about.
 *
 * The tree bit rides along because the walk emits controls and menus. */
enum { kNowObsArmSettleTicks = 30 };   /* half a second, the scene's bound */

static void arm_anchor_plane(void)
{
    now_peek_claim(kNowPeekOwnerObserve,
                   (unsigned long)(kNowPeekCapAnchors | kNowPeekCapTree));
    (void)now_peek_settle((unsigned long)kNowPeekCapAnchors,
                          kNowObsArmSettleTicks);
}

/* --- binding one process ----------------------------------------------- */

typedef struct {
    ProcessSerialNumber psn;
    Str31               name;
    OSType              signature;
    unsigned long       process_fingerprint;
    NowAxContext        context;
    NowObsBindStatus    bind;
    Boolean             is_front;
} NowObsTarget;

/* peek_read.c's vocabulary in this layer's words. One plane, two
   spellings, and the translation lives here so the pure resolver never
   has to include a Carbon-flavoured header. */
static NowObsBindStatus bind_status(NowPeekReadStatus status)
{
    switch (status) {
    case kNowPeekReadOk:         return kNowObsBindOk;
    case kNowPeekReadNoPlane:    return kNowObsBindNoPlane;
    case kNowPeekReadNoAnchor:   return kNowObsBindNoAnchor;
    case kNowPeekReadAmbiguous:  return kNowObsBindAmbiguous;
    case kNowPeekReadMismatch:   return kNowObsBindMismatch;
    case kNowPeekReadUnreadable: return kNowObsBindUnreadable;
    case kNowPeekReadNoWindows:
    case kNowPeekReadStub:
    default:                     break;
    }
    return kNowObsBindUnreadable;
}

/* Bind one process the ROSTER already described. `front` comes off that
   row, which means it comes off the walk's ONE sample - this function
   used to call GetFrontProcess itself, once per process, so a Cmd-Tab
   mid-walk could produce a reply in which two rows carried
   `front: true`, or none did. A snapshot that contradicts itself is
   worse than a stale one, because a caller cannot tell. Everything else
   in this guest samples the front once before its loop; now this does
   too, and it does it by not having the call at all. */
static int bind_target_row(const NowProcRosterRow *row, NowObsTarget *out)
{
    NowPeekReadStatus status;

    memset(out, 0, sizeof(*out));
    out->psn = row->psn;
    out->bind = kNowObsBindNoProcess;
    BlockMoveData(row->pname, out->name, (long)row->pname[0] + 1);
    out->signature = (OSType)row->creator;
    /* The launch date is the discriminator a PSN is not: it is the one
       field a relaunch into a recycled serial number cannot inherit.
       See now_obs_process_fingerprint. */
    out->process_fingerprint = now_obs_process_fingerprint(
        (unsigned long)row->psn.highLongOfPSN,
        (unsigned long)row->psn.lowLongOfPSN,
        row->creator, row->launch_date, row->location, row->process_size,
        row->pname);
    out->is_front = row->is_front;
    status = now_ax_bind_process(&out->psn, &out->context);
    out->bind = bind_status(status);
    return 1;
}

/* One process, named rather than walked. A single-row answer is a single
   moment by construction, so this is the one place the front may be
   sampled for one process - and it is the roster's sample, not a fourth
   private read. */
static int bind_target(const ProcessSerialNumber *psn, NowObsTarget *out)
{
    NowProcRosterRow row;

    if (!now_proc_roster_read(psn, &row)) {
        memset(out, 0, sizeof(*out));
        out->psn = *psn;
        out->bind = kNowObsBindNoProcess;
        return 0;
    }
    return bind_target_row(&row, out);
}

static void live_from(const NowObsTarget *target, NowObsLive *live)
{
    memset(live, 0, sizeof(*live));
    live->bind = target->bind;
    live->process_fingerprint = target->process_fingerprint;
    live->window_list = target->context.window_list;
    live->memory = &target->context.memory;
}

/* --- the scene walk's door onto this registry --------------------------- */

void now_observe_walk_begin(NowObsWalk *walk)
{
    now_observe_init();
    now_obs_walk_begin(walk, &g_registry);
}

/* Aim a walk at THIS process. Same fingerprint tuple as the foreign
   path - a reference minted under one and re-proved under another is
   refused as a recycled process - but no memory reader, because nothing
   here reads memory. */
void now_observe_walk_aim_self(NowObsWalk *walk,
                               const ProcessSerialNumber *psn)
{
    NowProcRosterRow row;
    unsigned long    fingerprint = 0;

    if (walk == NULL || psn == NULL) {
        return;
    }
    if (now_proc_roster_read(psn, &row)) {
        fingerprint = now_obs_process_fingerprint(
            (unsigned long)psn->highLongOfPSN,
            (unsigned long)psn->lowLongOfPSN,
            row.creator, row.launch_date, row.location, row.process_size,
            row.pname);
    }
    /* NULL memory reader: nothing here reads memory. The window list is
       our own, from the Window Manager. */
    now_obs_walk_aim(walk, NULL, (unsigned long)GetWindowList(),
                     (unsigned long)psn->highLongOfPSN,
                     (unsigned long)psn->lowLongOfPSN, fingerprint,
                     (unsigned long)TickCount());
}

void now_observe_walk_aim(NowObsWalk *walk, const ProcessSerialNumber *psn,
                          const NowAxContext *context)
{
    NowProcRosterRow row;
    unsigned long    fingerprint = 0;

    if (walk == NULL || psn == NULL || context == NULL) {
        return;
    }
    /* The SAME tuple bind_target computes, and it has to be: a reference
       minted against one fingerprint and re-proved against another is
       refused as a recycled process, which would make every scene
       reference fail with the most alarming verdict this layer has. It
       is the same tuple because it is now read from the same row. A
       process the Process Manager will not describe gets a zero
       fingerprint, and every reference for it will fail that check - so
       it is aimed with a seam it cannot mint through instead. */
    if (!now_proc_roster_read(psn, &row)) {
        now_obs_walk_aim(walk, NULL, 0, 0, 0, 0, 0);
        return;
    }
    fingerprint = now_obs_process_fingerprint(
        (unsigned long)psn->highLongOfPSN, (unsigned long)psn->lowLongOfPSN,
        row.creator, row.launch_date, row.location, row.process_size,
        row.pname);
    now_obs_walk_aim(walk, &context->memory, context->window_list,
                     (unsigned long)psn->highLongOfPSN,
                     (unsigned long)psn->lowLongOfPSN, fingerprint,
                     (unsigned long)TickCount());
}

void now_observe_walk_end(NowObsWalk *walk)
{
    now_obs_walk_end(walk);
}

/* --- resolution, for the act plane ------------------------------------- */


/* --- this application's own elements ------------------------------------

   A reference minted against OUR OWN process cannot be resolved the way
   every other one is. `bind_target` aims a foreign A5 world and the
   walk reads a WindowRecord out of it; for self there is no foreign
   world to aim and no reason to read memory at all - the Toolbox will
   answer directly, in this process, about windows this application
   made.

   The validation is not weaker for that, it is stronger: a self
   reference is live exactly when the WindowRef is still in this
   application's own window list, which is the same question the
   fingerprint check asks a foreign one and is answered here without a
   guess. */

static int psn_is_self(const ProcessSerialNumber *psn)
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

static int window_is_ours(WindowRef window)
{
    WindowRef it = GetWindowList();
    int       hops = 0;

    if (window == NULL) {
        return 0;
    }
    for (; it != NULL && hops < 64; it = GetNextWindow(it), ++hops) {
        if (it == window) {
            return 1;
        }
    }
    return 0;
}

/* `detail` for one of OUR OWN windows, and for the control in it.
 *
 * THIS USED TO BE LEFT ZEROED, and the verdict said Ok over it. The
 * foreign path fills `detail` from `now_ax_resolve_ref`, which reads the
 * other process's ControlRecord; the self path has no foreign memory to
 * read and simply did not fill it, so every consumer of a self reference
 * was handed a control with an empty title, invisible, disabled, value 0
 * and the rectangle {0,0,0,0} — beside `"resolved": true`.
 *
 * Two consequences, one of them silent for months:
 *
 * - The `handle` verb described every control of this application that
 *   way. A confidently wrong answer, which is the defect class plan 018
 *   exists to remove.
 * - `ctlact` computes its press point from this rectangle, so the press
 *   landed at 0,0. HARMLESS THERE, and that is why nobody noticed: the
 *   act plane's patch answers for the control HANDLE the request names
 *   and declines every other, so where the press landed decided nothing.
 *   It stops being harmless the moment a caller needs the point itself —
 *   which a drag does, and the drag lane hit it on 2026-08-07.
 *
 * GLOBAL COORDINATES, because that is what `detail.control` already
 * means: `now_ax_read_control` adds the window's content origin to the
 * local rect it reads (`axwalk.c`, "Local to global"). `GetControlBounds`
 * answers in the owner window's LOCAL coordinates, so the same origin is
 * added here. Two producers of one field must agree about its space, and
 * the field's space was decided by whoever wrote first.
 *
 * Note this is deliberately NOT `scene_self.c`'s convention, which keeps
 * a control's rect content-relative because IR v1 says a control's rect
 * is content-relative. Those are two different fields with two different
 * contracts, and the disagreement the drag lane found was between this
 * one and its own foreign twin — not between the scene and the handle.
 */
static void fill_self_control_detail(ControlRef control, WindowRef owner,
                                     NowAxControl *detail)
{
    Rect   box;
    Rect   content;
    Str255 title;
    short  dh = 0;
    short  dv = 0;

    if (GetWindowBounds(owner, kWindowContentRgn, &content) == noErr) {
        dh = content.left;
        dv = content.top;
    }
    GetControlBounds(control, &box);
    detail->address = (unsigned long)control;
    detail->top = (short)(box.top + dv);
    detail->left = (short)(box.left + dh);
    detail->bottom = (short)(box.bottom + dv);
    detail->right = (short)(box.right + dh);
    detail->visible = IsControlVisible(control) ? 1 : 0;
    detail->enabled = IsControlActive(control) ? 1 : 0;
    detail->value = GetControlValue(control);
    detail->min = GetControlMinimum(control);
    detail->max = GetControlMaximum(control);
    title[0] = 0;
    GetControlTitle(control, title);
    detail->title_len = title[0];
    if (title[0] != 0) {
        memcpy(detail->title, title + 1, title[0]);
    }
    detail->title[title[0]] = '\0';
}

static void fill_self_window_detail(WindowRef window, NowAxWindow *detail)
{
    Rect   box;
    Str255 title;

    if (GetWindowBounds(window, kWindowStructureRgn, &box) == noErr) {
        detail->left = box.left;
        detail->top = box.top;
        detail->right = box.right;
        detail->bottom = box.bottom;
    }
    detail->address = (unsigned long)window;
    detail->visible = IsWindowVisible(window) ? 1 : 0;
    /* The title travelled as an empty string too, for the same reason and
       with the same `resolved: true` over it. */
    title[0] = 0;
    GetWTitle(window, title);
    detail->title_len = title[0];
    if (title[0] != 0) {
        memcpy(detail->title, title + 1, title[0]);
    }
    detail->title[title[0]] = '\0';
}

static void resolve_self(NowObsKind kind, const NowObsEntry *entry,
                         NowObsHandle *out)
{
    WindowRef window = (WindowRef)entry->identity.window_address;

    if (kind == kNowObsKindElement) {
        ControlRef control = (ControlRef)entry->identity.control_handle;

        /* A control is live when the window that owns it still is. */
        if (control == NULL
                || !window_is_ours(GetControlOwner(control))) {
            out->verdict = kNowObsNotFound;
            out->why = kNowObsWhyElementGone;
            return;
        }
        out->control = control;
        out->window = GetControlOwner(control);
        out->verdict = kNowObsOk;
        out->identity = entry->identity;
        fill_self_control_detail(control, out->window, &out->detail.control);
        fill_self_window_detail(out->window, &out->detail.window);
        return;
    }

    if (!window_is_ours(window)) {
        out->verdict = kNowObsNotFound;
        out->why = kNowObsWhyElementGone;
        return;
    }
    out->window = window;
    out->verdict = kNowObsOk;
    out->identity = entry->identity;
    fill_self_window_detail(window, &out->detail.window);
}

static void resolve_kind(NowObsKind kind, const char *reference, long len,
                         NowObsHandle *out)
{
    const NowObsEntry *entry;
    NowObsTarget       target;
    NowObsLive         live;
    NowObsResolution   resolution;
    size_t             length;

    if (out == NULL) {
        return;
    }
    memset(out, 0, sizeof(*out));
    out->verdict = kNowObsNotFound;
    out->why = kNowObsWhyMalformed;
    if (reference == NULL) {
        return;
    }
    length = (len > 0) ? (size_t)len : strlen(reference);
    now_observe_init();

    /* Which process to bind is read OUT of the reference, never off the
       machine. That is the whole point: a reference names its own
       target, so there is no path here that consults the front process
       and no argument that could ask it to. */
    entry = now_obs_lookup(&g_registry, kind, reference, length);
    if (entry == NULL) {
        out->why = now_obs_token_valid(kind, reference, length)
                   ? kNowObsWhyUnminted : kNowObsWhyMalformed;
        return;
    }
    out->psn.highLongOfPSN = (long)entry->identity.psn_hi;
    out->psn.lowLongOfPSN = (long)entry->identity.psn_lo;
    if (psn_is_self(&out->psn)) {
        resolve_self(kind, entry, out);
        return;
    }
    if (!bind_target(&out->psn, &target)) {
        out->verdict = kNowObsNotFound;
        out->why = kNowObsWhyNoProcess;
        return;
    }
    live_from(&target, &live);
    now_obs_resolve(&g_registry, kind, reference, length, &live, &resolution);
    out->verdict = resolution.verdict;
    out->why = resolution.why;
    if (resolution.verdict != kNowObsOk) {
        return;
    }
    out->detail = resolution.resolved;
    out->window = (WindowPtr)resolution.resolved.window_address;
    out->control = (ControlHandle)resolution.resolved.control_handle;
    /* What the mint knew, handed back whole. The act plane needs the
       text route (which of a dialog's items this reference names, and
       how to reach it) and it must not re-derive that from the machine:
       re-deriving is a second thing deciding what an element is, which
       is the defect this layer was unified to remove. */
    out->identity = entry->identity;
}

void now_observe_resolve_window(const char *reference, long len,
                                NowObsHandle *out)
{
    resolve_kind(kNowObsKindWindow, reference, len, out);
}

void now_observe_resolve_element(const char *reference, long len,
                                 NowObsHandle *out)
{
    resolve_kind(kNowObsKindElement, reference, len, out);
}

/* --- emitting ---------------------------------------------------------- */

static int append(char *out, long cap, long *used, const char *fmt, ...)
    __attribute__((format(printf, 4, 5)));

static int append(char *out, long cap, long *used, const char *fmt, ...)
{
    va_list args;
    int     n;

    if (*used >= cap) {
        return 0;
    }
    va_start(args, fmt);
    n = vsnprintf(out + *used, (size_t)(cap - *used), fmt, args);
    va_end(args);
    if (n < 0 || n >= cap - *used) {
        out[*used] = '\0';
        return 0;
    }
    *used += n;
    return 1;
}

static void escape_pstr(const unsigned char *pstr, char *out, long cap)
{
    char plain[64];
    long n = (long)pstr[0];

    if (n > (long)sizeof(plain) - 1) {
        n = (long)sizeof(plain) - 1;
    }
    memcpy(plain, pstr + 1, (size_t)n);
    plain[n] = '\0';
    now_json_escape(plain, out, cap);
}

static void ostype_text(OSType type, char *out)
{
    out[0] = (char)((type >> 24) & 0xFF);
    out[1] = (char)((type >> 16) & 0xFF);
    out[2] = (char)((type >> 8) & 0xFF);
    out[3] = (char)(type & 0xFF);
    out[4] = '\0';
}

/* The bind status as a word, so a caller can see WHY a process
   contributed no tree instead of seeing an empty array. */
static const char *bind_name(NowObsBindStatus bind)
{
    switch (bind) {
    case kNowObsBindOk:         return "ok";
    case kNowObsBindNoProcess:  return "no-process";
    case kNowObsBindNoPlane:    return "no-plane";
    case kNowObsBindNoAnchor:   return "no-anchor";
    case kNowObsBindAmbiguous:  return "ambiguous";
    case kNowObsBindMismatch:   return "mismatch";
    case kNowObsBindUnreadable: return "unreadable";
    }
    return "unreadable";
}

static int emit_process_head(char *out, long cap, long *used,
                             const NowObsTarget *target)
{
    char name[128];
    char sig[8];
    char sig_esc[32];
    int  ok;

    escape_pstr(target->name, name, sizeof(name));
    ostype_text(target->signature, sig);
    now_json_escape(sig, sig_esc, sizeof(sig_esc));
    ok = append(out, cap, used,
                "{\"name\":\"%s\",\"signature\":\"%s\","
                "\"serialHi\":%lu,\"serialLo\":%lu,\"front\":%s,"
                "\"bind\":\"%s\",\"stampTicks\":%lu",
                name, sig_esc,
                (unsigned long)target->psn.highLongOfPSN,
                (unsigned long)target->psn.lowLongOfPSN,
                target->is_front ? "true" : "false",
                bind_name(target->bind),
                (unsigned long)target->context.stamp_ticks);
    if (!ok) {
        return 0;
    }
    /* a5 is the target application's A5 world - the one thing
       `qdtrace start`'s mandatory `arm_a5` needs and no verb used to
       emit. It rides on THIS row rather than a new one because the
       oracle read that fills it is the same read that fills `bind`.

       Strictly `kNowPeekAnchorOk`, not the collapsed `bind` word: `bind`
       reads "ok" for both the oracle's Ok and Stale verdicts (see
       axprocess.c's verdict_status), but a Stale anchor names a process
       that has not pumped its event loop since the plane was armed, and
       handing that A5 to a caller who will feed it straight into an ARM
       call is a different risk than handing it to a caller who is only
       looking. Absence, not zero, on every other verdict - zero is a
       legal (if impossible in practice) A5 value and would read as a
       real answer instead of "cannot tell". The decision itself is not
      made here: now_peek_anchor_a5_arm_trusted is the one place that
      says which verdict earns a caller the right to arm with this
      value, and it is host-tested against peek_oracle.h's own verdict
      enum (peek_oracle_test.c) since this file has no host test of its
      own. */
    if (now_peek_anchor_a5_arm_trusted(target->context.verdict)) {
        return append(out, cap, used, ",\"a5\":\"0x%08lx\"",
                      target->context.a5);
    }
    return 1;
}

/* A window's own editable text, and the element reference that names it.

   THE ONE ELEMENT THAT IS NOT A CONTROL. A dialog's live TextEdit record
   is the discoverable route to a real text field: the walk reads it out
   of the window, so the reference can be minted for it like any other.
   A document window's TEHandle is NOT discoverable from a foreign walk,
   and that gap is stated rather than papered over - such a window gets
   no text reference and no `text` object, which is the honest shape.

   It mints from a COPY of the window's identity: the caller reuses that
   struct for the controls that follow, and a text route left set on it
   would make every control in the window claim to be a text field.

   Absent text is not a failure. It writes nothing and returns 1, because
   a window with no TextEdit record is an answer about the window. */
static int emit_window_text(char *out, long cap, long *used,
                            NowObsTarget *target, const NowAxWindow *window,
                            const NowObsIdentity *base)
{
    /* A kilobyte of text off the stack, for the reason the title tables
       next door are static: one cooperative thread, one walk at a time. */
    static NowAxText text;
    NowObsIdentity    id;
    char              token[kNowObsTokenMax];

    if (now_ax_read_dialog_text(&target->context.memory, window->address,
                                &text) != kNowAxOk) {
        return 1;
    }
    id = *base;
    id.control_handle = 0;
    id.text_kind = kNowObsTextDialogTe;
    id.te_handle = 0;
    id.dialog_item = 0;
    id.minted_ticks = (unsigned long)TickCount();
    /* The same fingerprint the window reference carries - a zero control
       handle - because this element IS reached through the window, and
       resolution walks it the same way. */
    id.node_fingerprint = now_ax_ref_fingerprint(id.psn_hi, id.psn_lo,
                                                 window->address, 0UL);
    id.ref.node_fingerprint = id.node_fingerprint;
    id.ref.control_title[0] = 0;
    id.ref.control_title_len = 0;
    id.ref.control_occurrence = 0;
    token[0] = '\0';
    if (!now_obs_mint(&g_registry, kNowObsKindElement, &id, token,
                      sizeof(token))) {
        return 1;
    }
    return append(out, cap, used, ",\"text\":{\"ref\":\"%s\",\"length\":%u}",
                  token, text.length);
}

/* One process's windows and controls, with a reference minted for each.

   MINTING IS THE SIDE EFFECT THIS FUNCTION EXISTS FOR. Every row it
   emits is also a row in the registry, and the token in the JSON is the
   only copy of it a caller will ever get - there is no "look up the
   reference for the window called Save" call, deliberately, because that
   would be a way to name an element without observing it. */
static int emit_tree(char *out, long cap, long *used, NowObsTarget *target,
                     int *truncated)
{
    /* Static, not automatic: NowAxTitleEntry carries a 255-byte title, so
       these two tables are ten kilobytes of stack in a function that runs
       inside a classic application's modest one. Nothing here is
       reentrant - one cooperative thread, one walk at a time - which is
       what makes that safe rather than merely cheaper. */
    static NowAxTitleEntry window_titles[kObsMaxWindows];
    static NowAxTitleEntry control_titles[kObsMaxControls];
    NowAxTitleCounter window_counter;
    NowAxTitleCounter control_counter;
    unsigned long     seen_windows[kObsMaxWindows];
    unsigned long     address;
    int               window_count = 0;
    int               first_window = 1;

    if (!append(out, cap, used, ",\"windows\":[")) {
        return 0;
    }
    if (target->bind != kNowObsBindOk) {
        return append(out, cap, used, "]");
    }
    now_ax_title_counter_reset(&window_counter, window_titles,
                               kObsMaxWindows);
    address = target->context.window_list;
    while (address != 0 && window_count < kObsMaxWindows) {
        NowAxWindow    window;
        NowObsIdentity id;
        char           token[kNowObsTokenMax];
        char           title[512];
        unsigned int   occurrence = 0;
        unsigned long  control;
        int            control_count = 0;
        int            first_control = 1;
        int            i;

        for (i = 0; i < window_count; i++) {
            if (seen_windows[i] == address) {
                *truncated = 1;          /* a cycle: stop, do not loop */
                break;
            }
        }
        if (i < window_count) {
            break;
        }
        seen_windows[window_count] = address;
        if (cap - *used < kObsTailSlack) {
            *truncated = 1;
            break;
        }
        if (now_ax_read_window(&target->context.memory, address, &window)
            != kNowAxOk) {
            *truncated = 1;
            break;
        }
        if (now_ax_title_counter_next(&window_counter, window.title,
                                      (size_t)window.title_len, &occurrence)
            != kNowAxOk) {
            *truncated = 1;
            break;
        }

        memset(&id, 0, sizeof(id));
        id.psn_hi = (unsigned long)target->psn.highLongOfPSN;
        id.psn_lo = (unsigned long)target->psn.lowLongOfPSN;
        id.process_fingerprint = target->process_fingerprint;
        id.window_address = address;
        id.control_handle = 0;
        id.minted_ticks = (unsigned long)TickCount();
        id.node_fingerprint = now_ax_ref_fingerprint(id.psn_hi, id.psn_lo,
                                                     address, 0UL);
        id.ref.psn_hi = id.psn_hi;
        id.ref.psn_lo = id.psn_lo;
        memcpy(id.ref.window_title, window.title, (size_t)window.title_len);
        id.ref.window_title_len = (size_t)window.title_len;
        id.ref.window_occurrence = occurrence;
        id.ref.node_fingerprint = id.node_fingerprint;
        token[0] = '\0';
        (void)now_obs_mint(&g_registry, kNowObsKindWindow, &id, token,
                           sizeof(token));

        now_json_escape(window.title, title, sizeof(title));
        if (!append(out, cap, used,
                    "%s{\"ref\":\"%s\",\"title\":\"%s\",\"occurrence\":%u,"
                    "\"z\":%d,\"visible\":%s,\"kind\":%d,"
                    "\"bounds\":{\"left\":%d,\"top\":%d,\"right\":%d,"
                    "\"bottom\":%d}",
                    first_window ? "" : ",", token, title, occurrence,
                    window_count, window.visible ? "true" : "false",
                    (int)window.kind, (int)window.left, (int)window.top,
                    (int)window.right, (int)window.bottom)) {
            *truncated = 1;
            break;
        }
        if (!emit_window_text(out, cap, used, target, &window, &id)) {
            *truncated = 1;
            break;
        }
        if (!append(out, cap, used, ",\"controls\":[")) {
            *truncated = 1;
            break;
        }

        now_ax_title_counter_reset(&control_counter, control_titles,
                                   kObsMaxControls);
        control = window.control_list;
        while (control != 0 && control_count < kObsMaxControls) {
            NowAxControl item;
            unsigned int control_occurrence = 0;

            if (cap - *used < kObsTailSlack) {
                *truncated = 1;
                break;
            }
            if (now_ax_read_control(&target->context.memory, &window, control,
                                    &item) != kNowAxOk) {
                *truncated = 1;
                break;
            }
            if (now_ax_title_counter_next(&control_counter, item.title,
                                          (size_t)item.title_len,
                                          &control_occurrence) != kNowAxOk) {
                *truncated = 1;
                break;
            }
            id.control_handle = control;
            id.minted_ticks = (unsigned long)TickCount();
            id.node_fingerprint = now_ax_ref_fingerprint(id.psn_hi, id.psn_lo,
                                                         address, control);
            memcpy(id.ref.control_title, item.title,
                   (size_t)item.title_len);
            id.ref.control_title[item.title_len] = 0;
            id.ref.control_title_len = (size_t)item.title_len;
            id.ref.control_occurrence = control_occurrence;
            id.ref.node_fingerprint = id.node_fingerprint;
            token[0] = '\0';
            (void)now_obs_mint(&g_registry, kNowObsKindElement, &id, token,
                               sizeof(token));

            now_json_escape(item.title, title, sizeof(title));
            if (!append(out, cap, used,
                        "%s{\"ref\":\"%s\",\"title\":\"%s\","
                        "\"occurrence\":%u,\"visible\":%s,\"enabled\":%s,"
                        "\"bounds\":{\"left\":%d,\"top\":%d,\"right\":%d,"
                        "\"bottom\":%d},\"value\":%d,\"min\":%d,\"max\":%d}",
                        first_control ? "" : ",", token, title,
                        control_occurrence,
                        item.visible ? "true" : "false",
                        item.enabled ? "true" : "false",
                        (int)item.left, (int)item.top, (int)item.right,
                        (int)item.bottom, (int)item.value, (int)item.min,
                        (int)item.max)) {
                *truncated = 1;
                break;
            }
            first_control = 0;
            control_count++;
            control = item.next_control;
        }
        if (control != 0) {
            *truncated = 1;
        }
        if (!append(out, cap, used, "]}")) {
            *truncated = 1;
            break;
        }
        first_window = 0;
        window_count++;
        address = window.next_window;
    }
    if (address != 0) {
        *truncated = 1;
    }
    return append(out, cap, used, "]");
}

static void fail(char *out, long cap, long id, const char *code,
                 const char *message)
{
    snprintf(out, (size_t)cap,
             "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
             "\"error\":{\"code\":\"%s\",\"message\":\"%s\"}}",
             id, code, message);
}

static int read_scope(const char *request_json, char *scope, long cap)
{
    strcpy(scope, "front");
    if (request_json != NULL) {
        (void)now_json_find_string(request_json, "scope", scope, cap);
    }
    return (strcmp(scope, "front") == 0 || strcmp(scope, "all") == 0);
}

/* --- the walk, and the three doors onto it ------------------------------
 *
 * ONE MINTER, ONE WALK, ONE EMITTER. `observe`, `axtree` and `elements`
 * are three names a caller may reach this by, differing only in what
 * they SELECT (a scope, or one process) and in the key they answer
 * under. They are not three implementations: two things minting one
 * token shape is the defect this layer was unified to remove, and two
 * emitters over one registry is the same defect one layer down - the two
 * would eventually describe the same machine differently.
 *
 * `key` is the command's own name, because a reply names the command it
 * answers. `want`, when it is not NULL, is the one process to walk, and
 * `scope` is then that fact in a word rather than a second selector. */
static void walk_reply(const char *key, const char *scope, long id,
                       char *out, long cap,
                       const ProcessSerialNumber *want)
{
    NowProcRosterIter   it;
    NowProcRosterRow    proc;
    NowObsTarget        target;
    long                used = 0;
    int                 count = 0;
    int                 first = 1;
    int                 truncated = 0;
    int                 front_only = (want == NULL
                                      && strcmp(scope, "front") == 0);

    now_observe_init();
    arm_anchor_plane();
    if (!append(out, cap, &used,
                "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
                "\"output\":{\"%s\":{\"scope\":\"%s\",\"processes\":[",
                id, key, scope)) {
        fail(out, cap, id, "overflow", "observe header");
        return;
    }
    /* ONE front sample for the whole reply, taken here, before the first
       row - so `scope: front` and every row's `front` field describe the
       same instant. */
    now_proc_roster_begin(&it);
    if (front_only && !it.have_front) {
        fail(out, cap, id, "no-front", "no front process");
        return;
    }
    while (now_proc_roster_next(&it, &proc)) {
        long mark = used;

        if (count >= kObsMaxProcs || cap - used < kObsTailSlack) {
            truncated = 1;
            break;
        }
        if (want != NULL) {
            Boolean same = false;

            if (SameProcess(&proc.psn, want, &same) != noErr || !same) {
                continue;
            }
        }
        if (front_only && !proc.is_front) {
            continue;           /* decided from the one sample, not a new one */
        }
        if (!bind_target_row(&proc, &target)) {
            continue;
        }
        if (!append(out, cap, &used, "%s", first ? "" : ",")
            || !emit_process_head(out, cap, &used, &target)
            || !emit_tree(out, cap, &used, &target, &truncated)
            || !append(out, cap, &used, "}")) {
            used = mark;
            truncated = 1;
            break;
        }
        first = 0;
        count++;
    }
    if (!append(out, cap, &used,
                "],\"count\":%d,\"truncated\":%s,\"live\":%lu}}}",
                count, truncated ? "true" : "false",
                (unsigned long)(g_registry.minted - g_registry.evicted))) {
        fail(out, cap, id, "overflow", "observe tail");
    }
}

/* --- observe ----------------------------------------------------------- */

void now_observe_command(const char *request_json, long id, char *out,
                         long cap)
{
    char scope[16];

    if (!read_scope(request_json, scope, sizeof(scope))) {
        fail(out, cap, id, "bad-request", "scope must be front or all");
        return;
    }
    walk_reply("observe", scope, id, out, cap, NULL);
}

/* --- axtree ------------------------------------------------------------ */

/* The read surface over the same walk. It differs from observe in what
   it is FOR rather than in what it does: observe is the call an agent
   makes to obtain references, axtree the one it makes to look.

   IT IS NOT AN ALIAS ANY MORE, and the difference is one word: the reply
   answers under its own command's name, because a caller that sent
   axtree and got back an object called observe would have to know they
   are the same call - which is a fact about our implementation and none
   of its business. Everything that could describe the machine is still
   the one emitter. */
void now_observe_axtree_command(const char *request_json, long id, char *out,
                                long cap)
{
    char scope[16];

    if (!read_scope(request_json, scope, sizeof(scope))) {
        fail(out, cap, id, "bad-request", "scope must be front or all");
        return;
    }
    walk_reply("axtree", scope, id, out, cap, NULL);
}

/* --- elements ----------------------------------------------------------
 *
 * The act plane's door. It differs from observe only in how it AIMS:
 * serialHi/serialLo name one process, and omitting them means the
 * frontmost one. That is a selector for an OBSERVATION and not for an
 * act - it says which process to look at, never which element to act on,
 * and there is still no spelling anywhere here for "the frontmost
 * window". The act plane can only name what this returned. */
void now_observe_elements_command(const char *request_json, long id,
                                  char *out, long cap)
{
    ProcessSerialNumber psn;
    long                hi = 0;
    long                lo = 0;

    if (request_json != NULL
        && now_json_find_int(request_json, "serialHi", -2147483647L)
           == now_json_find_int(request_json, "serialHi", 2147483646L)
        && now_json_find_int(request_json, "serialLo", -2147483647L)
           == now_json_find_int(request_json, "serialLo", 2147483646L)) {
        hi = now_json_find_int(request_json, "serialHi", 0L);
        lo = now_json_find_int(request_json, "serialLo", 0L);
        psn.highLongOfPSN = hi;
        psn.lowLongOfPSN = (unsigned long)lo;
        walk_reply("elements", "process", id, out, cap, &psn);
        return;
    }
    walk_reply("elements", "front", id, out, cap, NULL);
}

/* --- axsnap ------------------------------------------------------------ */

void now_observe_axsnap_command(const char *request_json, long id, char *out,
                                long cap)
{
    ProcessSerialNumber front;
    NowObsTarget        target;
    long                used = 0;

    (void)request_json;
    now_observe_init();
    arm_anchor_plane();
    if (!now_proc_roster_front(&front)) {
        fail(out, cap, id, "no-front", "no front process");
        return;
    }
    if (!bind_target(&front, &target)) {
        fail(out, cap, id, "no-process", "the front process is unreadable");
        return;
    }
    if (!append(out, cap, &used,
                "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
                "\"output\":{\"axsnap\":{\"front\":", id)
        || !emit_process_head(out, cap, &used, &target)
        || !append(out, cap, &used,
                   ",\"hasWindows\":%s,\"hasMenus\":%s},"
                   "\"references\":{\"live\":%lu,\"minted\":%lu,"
                   "\"evicted\":%lu,\"capacity\":%d}}}}",
                   target.context.window_list != 0 ? "true" : "false",
                   target.context.menu_list != 0 ? "true" : "false",
                   (unsigned long)(g_registry.minted - g_registry.evicted),
                   (unsigned long)g_registry.minted,
                   (unsigned long)g_registry.evicted,
                   (int)kNowObsRegistryMax)) {
        fail(out, cap, id, "overflow", "axsnap");
    }
}

/* --- handle ------------------------------------------------------------ */

/* One reference in, one live element or one named refusal out.

   THE REFUSAL IS THE PRODUCT HERE. `ok` stays true for every verdict
   including the four that resolve to nothing, because "your reference
   is stale" is an ANSWER - it tells the caller to observe again - while
   an error would read as "the call failed" and invite a retry of the
   same reference. What is never true is `resolved`. */
void now_observe_handle_command(const char *request_json, long id, char *out,
                                long cap)
{
    NowObsHandle handle;
    char         reference[kNowObsTokenMax];
    char         escaped[128];
    long         used = 0;
    int          resolved;

    now_observe_init();
    /* Revalidation reads the same plane the walk that minted the
       reference did. Without this, "is this reference still good?" could
       answer no for the one reason that is not about the reference. */
    arm_anchor_plane();
    reference[0] = '\0';
    if (request_json == NULL
        || !now_json_find_string(request_json, "ref", reference,
                                 (long)sizeof(reference))) {
        fail(out, cap, id, "bad-request", "ref is required");
        return;
    }
    /* Which kind, asked of the module that owns the spelling. This read
       "now-window-" and 11 as literals until 2026-07-31 - a second copy
       of a format obsref.c defines, in the one function whose whole job
       is to tell the two kinds apart, and the copy that would have been
       wrong first if either prefix ever changed. */
    {
        const char *window_prefix = now_obs_kind_prefix(kNowObsKindWindow);

        if (strncmp(reference, window_prefix, strlen(window_prefix)) == 0) {
            now_observe_resolve_window(reference, 0, &handle);
        } else {
            now_observe_resolve_element(reference, 0, &handle);
        }
    }
    now_json_escape(reference, escaped, sizeof(escaped));

    /* VERDICT, REASON AND `resolved` ARE ONE VALUE HERE, not three that
       agree. All three are read off `handle.why` through the mapping
       obsresolve.c owns, so there is no arrangement of this struct in
       which the reply can say `ok` beside a sentence explaining a
       refusal - the shape that reads as a failure to everyone quoting
       it, and the worst direction for a reply to lie in.

       `handle.verdict` is deliberately not consulted. It is the same
       fact, and consulting it would be the second copy: this file has no
       host test (see one_minter_source_test.py on why that matters), so
       the invariant that keeps the two in step would be enforced here by
       nothing at all. handle_reason_source_test.py fails if it comes
       back. */
    resolved = (handle.why == kNowObsWhyNone);
    if (!append(out, cap, &used,
                "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
                "\"output\":{\"handle\":{\"ref\":\"%s\",\"verdict\":\"%s\","
                "\"reason\":\"%s\",\"resolved\":%s",
                id, escaped,
                now_obs_verdict_name(now_obs_verdict_for_why(handle.why)),
                now_obs_why_text(handle.why),
                resolved ? "true" : "false")) {
        fail(out, cap, id, "overflow", "handle");
        return;
    }
    if (resolved) {
        char window_title[512];
        char control_title[512];

        now_json_escape(handle.detail.window.title, window_title,
                        sizeof(window_title));
        now_json_escape(handle.detail.control.title, control_title,
                        sizeof(control_title));
        if (!append(out, cap, &used,
                    ",\"serialHi\":%lu,\"serialLo\":%lu,"
                    "\"window\":{\"title\":\"%s\",\"z\":%u,"
                    "\"visibleZ\":%u,\"visible\":%s,"
                    "\"bounds\":{\"left\":%d,\"top\":%d,\"right\":%d,"
                    "\"bottom\":%d}}",
                    (unsigned long)handle.psn.highLongOfPSN,
                    (unsigned long)handle.psn.lowLongOfPSN,
                    window_title, handle.detail.window_z,
                    handle.detail.visible_window_z,
                    handle.detail.window.visible ? "true" : "false",
                    (int)handle.detail.window.left,
                    (int)handle.detail.window.top,
                    (int)handle.detail.window.right,
                    (int)handle.detail.window.bottom)) {
            fail(out, cap, id, "overflow", "handle window");
            return;
        }
        /* `defProc` is the RAW `contrlDefProc` longword and `variant` is
           the Control Manager's own answer for this control. They are
           here because the scene reports only the CONCLUSION of the CDEF
           route - `derived`, and a kind - and on 2026-08-07 that
           conclusion was wrong for every control of the button family in
           every OS 9 control panel, with nothing in any document to say
           so. A reader could see "pushButton" and could not see that the
           variation code behind it had never been read. One control's
           two source numbers, printed beside the conclusion, is what
           tells a mis-read variant from an unreadable one. */
        if (handle.control != NULL
            && !append(out, cap, &used,
                       ",\"element\":{\"title\":\"%s\",\"visible\":%s,"
                       "\"enabled\":%s,\"bounds\":{\"left\":%d,\"top\":%d,"
                       "\"right\":%d,\"bottom\":%d},\"value\":%d,"
                       "\"min\":%d,\"max\":%d,"
                       "\"defProc\":\"0x%08lX\",\"variant\":%d}",
                       control_title,
                       handle.detail.control.visible ? "true" : "false",
                       handle.detail.control.enabled ? "true" : "false",
                       (int)handle.detail.control.left,
                       (int)handle.detail.control.top,
                       (int)handle.detail.control.right,
                       (int)handle.detail.control.bottom,
                       (int)handle.detail.control.value,
                       (int)handle.detail.control.min,
                       (int)handle.detail.control.max,
                       (unsigned long)handle.detail.control.def_proc,
                       (int)GetControlVariant(handle.control))) {
            fail(out, cap, id, "overflow", "handle element");
            return;
        }
    }
    if (!append(out, cap, &used, "}}}")) {
        fail(out, cap, id, "overflow", "handle tail");
    }
}
