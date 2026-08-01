/*
 * mirrorverbs.c - the mirror agent's verb surface.
 *
 * Every response is a full newline-terminated JSON envelope, one per line, so
 * the host's WireClient reads the same grammar the lab's wire always spoke.
 *
 * Provenance: P-DOC/P-OBS. The Window/Control/Menu/Dialog record layouts these
 * verbs walk come from Apple's published Universal Interfaces (compile-checked
 * below with _Static_assert against the SDK's own structs), cross-checked
 * against our probes on mac99, q800, a Quadra 950, and a PowerBook 1400c. No
 * offset here is a guess; where one would be, it is a named TODO instead.
 *
 * The AX plane is NOT fenced behind a build flag here. In the lab these verbs
 * live inside a 309 KB verbs.c behind `#ifdef TBT_MORDOR` - a toolkit build the
 * Runner refuses to lease, which is why AX was always hand-deployed there. In
 * this app the AX plane is the product, so it is simply present. That is the
 * structural fix, and the reason this app exists (AGENTS.md).
 *
 * Carried from the lab's harness/src/verbs.c at extraction (2026-07-29) and
 * expected to diverge; the lab's copy is frozen. Do not sync them.
 */
#include "mirrorverbs.h"
#include "wire.h"
#include "xfer_crc.h"
#include "xfer_state.h"
#include "macbin.h"
#include "axwalk.h"    /* bounded foreign Window/Control memory walk */
#include "axmenu.h"    /* bounded foreign MenuList/MenuInfo walk */
#include "axtext.h"    /* bounded DialogRecord/TextEdit read */
#include "axref.h"     /* pointer-free process/window/control references */
#include "axresolve.h" /* shared occurrence and stable-ref traversal policy */
#include "axbinding.h" /* validated PSN lifetime -> stale context binding */
#include "axoracle.h"
#include "qdshared.h"
#include "ptshared.h"  /* Portal in-process agent shared block (Gestalt TBpt) */  /* QDPeek QuickDraw-capture shared block (Gestalt TBqd) */  /* AXPeek A5-world sample -> Process Manager partition */

#include <Gestalt.h>
#include <Processes.h>
#include <MacWindows.h>
#include <Quickdraw.h>
#include <Menus.h>
#include <Dialogs.h>
#include <TextEdit.h>
#include <Controls.h>
#include <Events.h>          /* TickCount; PPostEvent + event codes (input) */
#include <LowMem.h>          /* LMSet* mouse accessors (input injection) */
#include <MacMemory.h>
#include <Files.h>            /* HFS catalog walk (list/stat) */
#include <Devices.h>          /* OpenDriver/CloseDriver (.Journal probe) */
#include <OSUtils.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <stddef.h>

#define kVerbMax   32
#define kMsgMax    1024
#define kMaxProcs  64      /* observe: cap the process list (classic runs few) */
#define kMaxWins   64      /* observe: cap the window list */
#define kMaxCtls   64      /* observe: cap controls per window (bounded walk) */
#define kEscMax    1024    /* escaped Str255 / OSType scratch */
#define kItemMax   1280    /* one JSON array element */

/* Menu IDs a windowed shell installs; `observe` reports them when present.
 * This agent is faceless, so GetMenuHandle returns NULL and observe reports an
 * empty menus list for its own process - correct, not a gap. */
#define kMenuApple 128
#define kMenuFile  129

/* Cursor low-memory globals. P-DOC: CrsrNew (0x08CE) and CrsrCouple (0x08CF)
 * are documented low-memory globals with no Universal Interfaces accessor;
 * writing CrsrNew = CrsrCouple is the documented way to tell the cursor task to
 * redraw after moving the mouse location behind its back. */
#define kLMCrsrNew    (*(volatile UInt8 *)0x08CEUL)
#define kLMCrsrCouple (*(volatile UInt8 *)0x08CFUL)

/* Journaling low-memory globals. P-DOC: JournalFlag (0x08DE, word) and
 * JournalRef (0x08E8, word) are documented low-memory globals from the Event
 * Manager's journaling mechanism (Inside Macintosh Vol. I, Event Manager).
 * Modern Universal Interfaces expose only LMGet/SetJournalRef; the Multiversal
 * interfaces (toolchain/multiversal/CIncludes/Multiverse.h) carry BOTH as
 * LMGet/SetJournalFlag and LMGet/SetJournalRef at exactly these addresses,
 * which is where these two came from rather than from recollection.
 *
 * READ-ONLY here, deliberately. Writing JournalFlag is what arms record or
 * playback, and playback is a system-wide takeover: every application's Event
 * Manager reads from the journal device, the human is locked out, and a flag
 * left set means a reboot. The probe below establishes what EXISTS before
 * anything tries to drive it. */
#define kLMJournalFlag (*(volatile SInt16 *)0x08DEUL)
#define kLMJournalRef  (*(volatile SInt16 *)0x08E8UL)

/* main.c owns the loop; these are its state, read here for ping/liveness. */
extern int           g_shutdown;
extern unsigned long g_start_ticks;
extern unsigned long g_last_activity;
static unsigned long g_requests = 0;

#ifndef TBT_BACKING
#define TBT_BACKING "mirror"
#endif
#ifndef MIRROR_VERSION
#define MIRROR_VERSION "0.1a"
#endif
#ifndef MIRROR_GIT_REV
#define MIRROR_GIT_REV ""
#endif

/* The secondary "these exact bytes" signal alongside the semver: read it back
 * to confirm the running agent is what you just built, not a stale leftover -
 * the "iterated in memory, deployed nothing" failure mode. */
#define kBuildStamp __DATE__ " " __TIME__

/* --- response builders ------------------------------------------------ */

/* --- response builders --------------------------------------------------- */

/* Append a formatted fragment at out[*used..cap). Returns 1 on success, 0 if it
 * would not fit (caller decides whether that is fatal or just truncation). */
static int append(char *out, size_t cap, size_t *used, const char *fmt, ...)
{
    va_list ap;
    int     n;

    if (*used >= cap) {
        return 0;
    }
    va_start(ap, fmt);
    n = vsnprintf(out + *used, cap - *used, fmt, ap);
    va_end(ap);
    if (n < 0 || (size_t)n >= cap - *used) {
        return 0;
    }
    *used += (size_t)n;
    return 1;
}

/* JSON-escape a Pascal string's characters into out (no surrounding quotes).
 * On overflow, yields an empty string rather than a partial one. */
static void pstr_escape(const unsigned char *pstr, char *out, size_t cap)
{
    if (wire_escape((const char *)(pstr + 1), (size_t)pstr[0], out, cap) < 0) {
        out[0] = '\0';
    }
}

/* JSON-escape a four-char OSType (big-endian) into out (no quotes). */
static void ostype_escape(OSType t, char *out, size_t cap)
{
    char b[4];

    b[0] = (char)((t >> 24) & 0xFF);
    b[1] = (char)((t >> 16) & 0xFF);
    b[2] = (char)((t >> 8) & 0xFF);
    b[3] = (char)(t & 0xFF);
    if (wire_escape(b, sizeof(b), out, cap) < 0) {
        out[0] = '\0';
    }
}

static int resp_error(char *out, size_t cap, long id,
                      const char *code, const char *message)
{
    int n = snprintf(out, cap,
        "{\"proto\":1,\"id\":%ld,\"ok\":false,"
        "\"error\":{\"code\":\"%s\",\"message\":\"%s\"},"
        "\"backing\":\"" TBT_BACKING "\"}\n",
        id, code, message);
    return (n < 0 || (size_t)n >= cap) ? -1 : n;
}

/* --- perceive: the process plane ------------------------------------- */

static int verb_observe(char *out, size_t cap, long id)
{
    size_t              used = 0;
    ProcessSerialNumber front = {0, 0};
    Boolean             haveFront;
    ProcessSerialNumber psn = {0, kNoProcess};
    WindowRef           fw;
    WindowRef           w;
    GrafPtr             savePort;
    char                esc[kEscMax];
    char                sig[kEscMax];
    char                item[kItemMax];
    int                 truncated = 0;
    int                 first;

    haveFront = (GetFrontProcess(&front) == noErr);

    if (!append(out, cap, &used,
                "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{", id)) {
        return resp_error(out, cap, id, "overflow", "observe header");
    }

    /* processes (system-wide) */
    if (!append(out, cap, &used, "\"processes\":[")) {
        return resp_error(out, cap, id, "overflow", "observe processes");
    }
    first = 1;
    {
        int count = 0;
        while (GetNextProcess(&psn) == noErr) {
            ProcessInfoRec info;
            Str255         name;
            Boolean        isFront;

            if (count >= kMaxProcs) {
                truncated = 1;
                break;
            }
            info.processInfoLength = sizeof(info);
            info.processName       = name;
            info.processAppSpec    = NULL;
            if (GetProcessInformation(&psn, &info) != noErr) {
                continue;
            }
            pstr_escape(name, esc, sizeof(esc));
            ostype_escape(info.processSignature, sig, sizeof(sig));
            isFront = haveFront
                      && psn.highLongOfPSN == front.highLongOfPSN
                      && psn.lowLongOfPSN == front.lowLongOfPSN;
            snprintf(item, sizeof(item),
                "%s{\"name\":\"%s\",\"signature\":\"%s\","
                "\"serialHi\":%lu,\"serialLo\":%lu,\"front\":%s}",
                first ? "" : ",", esc, sig,
                (unsigned long)psn.highLongOfPSN,
                (unsigned long)psn.lowLongOfPSN,
                isFront ? "true" : "false");
            if (!append(out, cap, &used, "%s", item)) {
                truncated = 1;
                break;
            }
            first = 0;
            count++;
        }
    }

    /* windows (this process's Window Manager list) */
    if (!append(out, cap, &used, "],\"windows\":[")) {
        return resp_error(out, cap, id, "overflow", "observe windows");
    }
    fw = FrontWindow();
    GetPort(&savePort);
    first = 1;
    {
        int count = 0;
        for (w = fw; w != NULL; w = GetNextWindow(w)) {
            Str255 title;
            Rect   r;
            Point  tl, br;

            if (count >= kMaxWins) {
                truncated = 1;
                break;
            }
            GetWTitle(w, title);
            pstr_escape(title, esc, sizeof(esc));

            SetPort((GrafPtr)w);
            GetWindowPortBounds(w, &r);
            tl.v = r.top;    tl.h = r.left;
            br.v = r.bottom; br.h = r.right;
            LocalToGlobal(&tl);
            LocalToGlobal(&br);

            /* Build the window object incrementally so its `controls` array can
             * nest; on any overflow, roll `used` back to wmark so we never emit
             * a half-written object (bytes past `used` are never sent). */
            {
                size_t        wmark = used;
                ControlHandle ctl;
                int           cfirst = 1;
                int           ccount = 0;

                if (!append(out, cap, &used,
                    "%s{\"handle\":%lu,\"title\":\"%s\",\"visible\":%s,"
                    "\"front\":%s,\"kind\":%d,"
                    "\"bounds\":{\"left\":%d,\"top\":%d,\"right\":%d,"
                    "\"bottom\":%d},\"controls\":[",
                    first ? "" : ",", (unsigned long)w, esc,
                    IsWindowVisible(w) ? "true" : "false",
                    (w == fw) ? "true" : "false", (int)GetWindowKind(w),
                    (int)tl.h, (int)tl.v, (int)br.h, (int)br.v)) {
                    used = wmark;
                    truncated = 1;
                    break;
                }

                /* Bounded walk of the window's control list. The cap and NULL
                 * head (NewWindow zeroes it) keep this safe on real hardware. */
                for (ctl = GetControlListFromWindow(w); ctl != NULL;
                     ctl = (*ctl)->nextControl) {
                    Str255 ctitle;
                    Rect   cr;
                    Point  ctl_tl, ctl_br;

                    if (ccount >= kMaxCtls) {
                        truncated = 1;
                        break;
                    }
                    GetControlTitle(ctl, ctitle);
                    pstr_escape(ctitle, esc, sizeof(esc));
                    cr = (*ctl)->contrlRect;          /* local to owner window */
                    ctl_tl.v = cr.top;    ctl_tl.h = cr.left;
                    ctl_br.v = cr.bottom; ctl_br.h = cr.right;
                    LocalToGlobal(&ctl_tl);
                    LocalToGlobal(&ctl_br);
                    if (!append(out, cap, &used,
                        "%s{\"title\":\"%s\",\"value\":%d,\"bounds\":{"
                        "\"left\":%d,\"top\":%d,\"right\":%d,\"bottom\":%d}}",
                        cfirst ? "" : ",", esc, (int)GetControlValue(ctl),
                        (int)ctl_tl.h, (int)ctl_tl.v,
                        (int)ctl_br.h, (int)ctl_br.v)) {
                        truncated = 1;
                        break;              /* keep controls that fit */
                    }
                    cfirst = 0;
                    ccount++;
                }

                if (!append(out, cap, &used, "]}")) {
                    used = wmark;
                    truncated = 1;
                    break;
                }
            }
            first = 0;
            count++;
        }
    }
    SetPort(savePort);

    /* menus (this process's menu bar - the IDs the harness installs) */
    if (!append(out, cap, &used, "],\"menus\":[")) {
        return resp_error(out, cap, id, "overflow", "observe menus");
    }
    {
        static const short menuIDs[] = { kMenuApple, kMenuFile };
        int i;

        first = 1;
        for (i = 0; i < (int)(sizeof(menuIDs) / sizeof(menuIDs[0])); i++) {
            MenuHandle m = GetMenuHandle(menuIDs[i]);
            size_t     mmark = used;
            short      nitems;
            short      it;
            int        ifirst = 1;

            if (m == NULL) {
                continue;
            }
            pstr_escape((const unsigned char *)(*m)->menuData, esc,
                        sizeof(esc));           /* menuData begins with the title */
            if (!append(out, cap, &used,
                        "%s{\"id\":%d,\"title\":\"%s\",\"items\":[",
                        first ? "" : ",", (int)menuIDs[i], esc)) {
                used = mmark;
                truncated = 1;
                break;
            }
            nitems = CountMItems(m);
            for (it = 1; it <= nitems; it++) {
                Str255 itxt;

                GetMenuItemText(m, it, itxt);
                pstr_escape(itxt, esc, sizeof(esc));
                if (!append(out, cap, &used, "%s\"%s\"",
                            ifirst ? "" : ",", esc)) {
                    truncated = 1;
                    break;                       /* keep items that fit */
                }
                ifirst = 0;
            }
            if (!append(out, cap, &used, "]}")) {
                used = mmark;
                truncated = 1;
                break;
            }
            first = 0;
        }
    }

    if (!append(out, cap, &used,
                "],\"truncated\":%s},\"backing\":\"" TBT_BACKING "\"}\n",
                truncated ? "true" : "false")) {
        return resp_error(out, cap, id, "overflow", "observe tail");
    }
    return (int)used;
}
static int verb_axsnap(char *out, size_t cap, long id)
{
    ProcessSerialNumber psn;
    ProcessInfoRec      info;
    Str63               name;
    char                esc[kEscMax];
    char                sig[kEscMax];
    int                 n;

    if (GetFrontProcess(&psn) != noErr) {
        return resp_error(out, cap, id, "no_front", "no front process");
    }
    info.processInfoLength = sizeof(info);
    info.processName       = name;
    info.processAppSpec    = NULL;
    if (GetProcessInformation(&psn, &info) != noErr) {
        return resp_error(out, cap, id, "proc_info", "GetProcessInformation failed");
    }

    pstr_escape(name, esc, sizeof(esc));
    ostype_escape(info.processSignature, sig, sizeof(sig));
    n = snprintf(out, cap,
        "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{\"front\":{"
        "\"name\":\"%s\",\"signature\":\"%s\",\"serialHi\":%lu,\"serialLo\":%lu}"
        "},\"backing\":\"" TBT_BACKING "\"}\n",
        id, esc, sig,
        (unsigned long)psn.highLongOfPSN, (unsigned long)psn.lowLongOfPSN);
    return (n < 0 || (size_t)n >= cap) ? -1 : n;
}

/* --- act: process activation ----------------------------------------- */

static int verb_activate(char *out, size_t cap, long id,
                         const char *line, size_t len)
{
    ProcessSerialNumber target;
    ProcessSerialNumber front;
    ProcessInfoRec      info;
    Str63               name;
    Boolean             same = false;
    uint32_t            serial_hi;
    uint32_t            serial_lo;
    char                name_esc[kEscMax];
    char                sig_esc[kEscMax];
    OSErr               err;
    int                 changed;
    int                 n;

    if (!wire_find_u32(line, len, "serialHi", &serial_hi)
        || !wire_find_u32(line, len, "serialLo", &serial_lo)) {
        return resp_error(out, cap, id, "bad_request",
                          "activate needs unsigned 32-bit serialHi/serialLo");
    }
    target.highLongOfPSN = (unsigned long)serial_hi;
    target.lowLongOfPSN = (unsigned long)serial_lo;
    info.processInfoLength = sizeof(info);
    info.processName = name;
    info.processAppSpec = NULL;
    if (GetProcessInformation(&target, &info) != noErr) {
        return resp_error(out, cap, id, "stale_process",
                          "target process no longer exists");
    }
    if ((info.processMode & modeOnlyBackground) != 0) {
        return resp_error(out, cap, id, "not_foreground_capable",
                          "target is a background-only process");
    }

    changed = 1;
    if (GetFrontProcess(&front) == noErr
        && SameProcess(&front, &target, &same) == noErr && same) {
        changed = 0;
    } else {
        err = SetFrontProcess(&target);
        if (err != noErr) {
            return resp_error(out, cap, id, "activate_failed",
                              "SetFrontProcess failed");
        }
    }

    /* A foreground switch completes when this cooperative process yields. The
     * wire reply therefore reports whether it is already observable; the MCP
     * composite confirms with axsnap on the next request after that yield. */
    same = false;
    if (GetFrontProcess(&front) == noErr) {
        (void)SameProcess(&front, &target, &same);
    }
    pstr_escape(name, name_esc, sizeof(name_esc));
    ostype_escape(info.processSignature, sig_esc, sizeof(sig_esc));
    n = snprintf(out, cap,
        "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{"
        "\"name\":\"%s\",\"signature\":\"%s\","
        "\"serialHi\":%lu,\"serialLo\":%lu,\"changed\":%s,"
        "\"requested\":true,\"front\":%s},\"backing\":\""
        TBT_BACKING "\"}\n",
        id, name_esc, sig_esc,
        (unsigned long)target.highLongOfPSN,
        (unsigned long)target.lowLongOfPSN,
        changed ? "true" : "false", same ? "true" : "false");
    return (n < 0 || (size_t)n >= cap) ? -1 : n;
}

/* --- perceive + act: the AX plane ------------------------------------ */


enum {
    kClickPostOK = 0,
    kClickPostDownFailed = 1,
    kClickPostUpFailed = 2
};

static int post_click_at(short x, short y, int count, short mods);


#define kAXMaxWins AX_RESOLVE_MAX_WINDOWS
#define kAXMaxCtls AX_RESOLVE_MAX_CONTROLS
#define kAXMaxApps AX_SAMPLE_MAX
#define kAXEscMax  (AX_TITLE_MAX * 6 + 1)
#define kAXSampleMaxAge 120UL          /* 2 s at 60 Hz; fail stale, never guess */
#define kAXWalkMaxTicks 120UL          /* partial result before agent stall */

/* The System 8/9 SDK defines GrafPort and CGrafPort as the same 108-byte
 * prefix, so every WindowRecord field the passive parser uses has the same
 * offset in CWindowRecord. Keep the raw-layout contract compiler-checked. */
_Static_assert(sizeof(GrafPort) == 108, "unexpected GrafPort layout");
_Static_assert(sizeof(CGrafPort) == 108, "unexpected CGrafPort layout");
_Static_assert(offsetof(WindowRecord, windowKind) == 108,
               "unexpected WindowRecord layout");
_Static_assert(offsetof(CWindowRecord, windowKind) == 108,
               "unexpected CWindowRecord layout");
_Static_assert(offsetof(WindowRecord, nextWindow) == 144,
               "unexpected WindowRecord links");
_Static_assert(offsetof(CWindowRecord, nextWindow) == 144,
               "unexpected CWindowRecord links");
_Static_assert(offsetof(ControlRecord, contrlHilite) == 17,
               "unexpected ControlRecord action state");
_Static_assert(offsetof(DialogRecord, textH) == 160,
               "unexpected DialogRecord TextEdit handle");
_Static_assert(offsetof(TERec, selStart) == 32,
               "unexpected TERec selection layout");
_Static_assert(offsetof(TERec, teLength) == 60,
               "unexpected TERec length layout");
_Static_assert(offsetof(TERec, hText) == 62,
               "unexpected TERec text handle");
_Static_assert(offsetof(MenuInfo, menuData) == 14,
               "unexpected MenuInfo variable data layout");

/* The axwalk seam's guest binding. axwalk performs every range check before it
 * calls this function; pointers stay in the target partition or SysZone. */
static int ax_guest_read(void *ctx, unsigned long addr, void *dst, size_t len)
{
    (void)ctx;
    BlockMoveData((Ptr)addr, dst, (Size)len);
    return 1;
}

static const char *ax_oracle_error_code(int rc)
{
    switch (rc) {
    case AX_ORACLE_AMBIGUOUS:
        return "ax_oracle_ambiguous";
    case AX_ORACLE_STALE:
        return "ax_oracle_stale";
    case AX_ORACLE_MISMATCH:
        return "ax_oracle_mismatch";
    case AX_ORACLE_NOT_FOUND:
        return "ax_oracle_not_found";
    default:
        return "ax_oracle_invalid";
    }
}

/* Copy the resident producer buffer under its seqlock. The Gestalt result is
 * range-checked before dereference, and an unstable writer fails closed. */
static int ax_oracle_snapshot(unsigned long system_lo, unsigned long system_hi,
                              AXShared *out)
{
    volatile AXShared *source;
    long               response = 0;
    int                attempt;

    if (out == NULL || Gestalt(AX_GESTALT, &response) != noErr
        || response <= 0
        || !ax_oracle_buffer_range_valid((uint32_t)response,
                                         (uint32_t)system_lo,
                                         (uint32_t)system_hi,
                                         sizeof(*out))) {
        return AX_ORACLE_NOT_FOUND;
    }
    source = (volatile AXShared *)(unsigned long)response;
    for (attempt = 0; attempt < 8; attempt++) {
        uint32_t before = source->seq;
        uint32_t after;

        if ((before & 1UL) != 0) {
            continue;
        }
        BlockMoveData((Ptr)source, out, (Size)sizeof(*out));
        after = source->seq;
        if (before == after && (after & 1UL) == 0) {
            if (out->magic != AX_MAGIC || out->version != AX_VERSION
                || out->sampleCount > AX_SAMPLE_MAX) {
                return AX_ORACLE_INVALID;
            }
            return AX_ORACLE_OK;
        }
    }
    return AX_ORACLE_INVALID;
}

typedef struct {
    ProcessSerialNumber front;
    ProcessSerialNumber process;
    ProcessSerialNumber current;
    ProcessInfoRec      info;
    Str63               name;
    Boolean             is_front;
    Boolean             is_self;
    Boolean             bound_sample;
    ax_memory           memory;
    AXContextSample     sample;
    unsigned long       started;
    unsigned long       oracle_started;
    unsigned long       oracle_done;
    unsigned long       sample_age;
} ax_target;

static ax_binding_cache g_ax_bindings;

/* Resolve and validate one process's complete read boundary. A NULL `process`
 * selects the front process. `expected_front` is used by axdo to require that a
 * reference still names the front process; all-process perception leaves it
 * NULL and never changes focus. */
static int ax_open_target(ax_target *target,
                          const ProcessSerialNumber *process,
                          const ProcessSerialNumber *expected_front,
                          int allow_bound_stale,
                          const char **error_code,
                          const char **error_message)
{
    static AXShared snapshot;          /* keep the 1.7 KB copy off 68K stack */
    THz             system_zone;
    Boolean         same = false;
    long            logical_size = 0;
    long            physical_size = 0;
    unsigned long   target_lo;
    unsigned long   target_hi;
    unsigned long   system_lo;
    unsigned long   system_hi;
    int             rc;

    memset(target, 0, sizeof(*target));
    target->started = (unsigned long)LMGetTicks();
    if (GetFrontProcess(&target->front) != noErr
        || GetCurrentProcess(&target->current) != noErr) {
        *error_code = "no_front";
        *error_message = "no front process";
        return 0;
    }
    if (expected_front != NULL
        && (SameProcess(&target->front, expected_front, &same) != noErr
            || !same)) {
        *error_code = "ref_not_front";
        *error_message = "reference process is no longer frontmost";
        return 0;
    }
    target->process = process != NULL ? *process : target->front;
    same = false;
    (void)SameProcess(&target->process, &target->front, &same);
    target->is_front = same;
    same = false;
    (void)SameProcess(&target->process, &target->current, &same);
    target->is_self = same;
    target->info.processInfoLength = sizeof(target->info);
    target->info.processName = target->name;
    target->info.processAppSpec = NULL;
    if (GetProcessInformation(&target->process, &target->info) != noErr) {
        *error_code = "proc_info";
        *error_message = "GetProcessInformation failed";
        return 0;
    }

    (void)Gestalt(gestaltLogicalRAMSize, &logical_size);
    if (logical_size <= 0) {
        (void)Gestalt(gestaltPhysicalRAMSize, &physical_size);
        logical_size = physical_size;
    }
    if (logical_size <= 0) {
        *error_code = "ax_bounds";
        *error_message = "logical RAM bounds unavailable";
        return 0;
    }
    system_zone = LMGetSysZone();
    system_lo = (unsigned long)system_zone;
    if (system_lo == 0
        || (unsigned long)logical_size < sizeof(Zone)
        || system_lo > (unsigned long)logical_size - sizeof(Zone)) {
        *error_code = "ax_bounds";
        *error_message = "SysZone header is outside logical RAM";
        return 0;
    }
    system_hi = (unsigned long)system_zone->bkLim;
    if (system_hi <= system_lo
        || system_hi > (unsigned long)logical_size) {
        *error_code = "ax_bounds";
        *error_message = "SysZone limit is outside logical RAM";
        return 0;
    }

    target_lo = (unsigned long)target->info.processLocation;
    target_hi = target_lo + (unsigned long)target->info.processSize;
    if (target_hi <= target_lo
        || target_hi > (unsigned long)logical_size) {
        *error_code = "ax_partition_invalid";
        *error_message = "process partition is outside logical RAM";
        return 0;
    }
    target->memory.read = ax_guest_read;
    target->memory.ctx = NULL;
    target->memory.target_lo = target_lo;
    target->memory.target_hi = target_hi;
    target->memory.system_lo = system_lo;
    target->memory.system_hi = system_hi;

    target->oracle_started = (unsigned long)LMGetTicks();
    if (target->is_self) {
        target->sample.windowList = (unsigned long)LMGetWindowList();
        target->sample.menuList = (unsigned long)LMGetMenuList();
        target->sample.ticks = target->started;
        rc = AX_ORACLE_OK;
    } else {
        rc = ax_oracle_snapshot(system_lo, system_hi, &snapshot);
        if (rc == AX_ORACLE_OK) {
            rc = ax_oracle_match(&snapshot, target_lo,
                                 (unsigned long)target->info.processSize,
                                 system_lo, system_hi - system_lo,
                                 target->name, target->started,
                                 kAXSampleMaxAge, &target->sample);
            if (rc == AX_ORACLE_STALE && allow_bound_stale) {
                AXContextSample old_sample;
                int any_age;

                any_age = ax_oracle_match_any_age(
                    &snapshot, target_lo,
                    (unsigned long)target->info.processSize,
                    system_lo, system_hi - system_lo,
                    target->name, &old_sample);
                if (any_age == AX_ORACLE_OK
                    && ax_binding_matches(
                        &g_ax_bindings,
                        (uint32_t)target->process.highLongOfPSN,
                        (uint32_t)target->process.lowLongOfPSN,
                        (uint32_t)target_lo,
                        (uint32_t)target->info.processSize,
                        old_sample.currentA5, old_sample.stackBase)) {
                    target->sample = old_sample;
                    target->bound_sample = true;
                    rc = AX_ORACLE_OK;
                }
            }
        }
    }
    if (rc != AX_ORACLE_OK) {
        *error_code = ax_oracle_error_code(rc);
        *error_message = "process has no durable AXPeek context sample";
        return 0;
    }
    target->oracle_done = (unsigned long)LMGetTicks();
    if (!target->is_self) {
        unsigned long now = (unsigned long)LMGetTicks();

        target->sample_age = now - target->sample.ticks;
        if (!target->bound_sample
            && !ax_oracle_sample_fresh(&target->sample, now,
                                       kAXSampleMaxAge)) {
            *error_code = "ax_oracle_stale";
            *error_message = "process AXPeek sample is older than 2 seconds";
            return 0;
        }
        if (!target->bound_sample) {
            ax_binding_record(
                &g_ax_bindings,
                (uint32_t)target->process.highLongOfPSN,
                (uint32_t)target->process.lowLongOfPSN,
                (uint32_t)target_lo,
                (uint32_t)target->info.processSize,
                target->sample.currentA5, target->sample.stackBase);
        }
        if (!ax_oracle_name_matches(&target->sample, target->name)) {
            *error_code = "ax_oracle_mismatch";
            *error_message = "AXPeek sample name disagrees with Process Manager";
            return 0;
        }
    }
    return 1;
}

static const char *ax_error_code(int rc)
{
    switch (rc) {
    case AX_READ_ERROR:
        return "ax_read";
    case AX_AMBIGUOUS:
        return "ax_ambiguous";
    case AX_NOT_FOUND:
        return "ax_not_found";
    default:
        return "ax_invalid";
    }
}

static int ax_emit_fail(const char **code, const char **message,
                        const char *value, const char *detail)
{
    *code = value;
    *message = detail;
    return 0;
}

static int ax_append_target_menus(char *out, size_t cap, size_t *used,
                                  ax_target *target,
                                  unsigned long budget_started,
                                  int *truncated,
                                  const char **emit_error_code,
                                  const char **emit_error_message)
{
    ax_menu_list list;
    unsigned int menu_index;
    int          first_menu = 1;
    int          menus_truncated = 0;
    int          rc;

    rc = ax_open_menu_list(&target->memory, target->sample.menuList, &list);
    if (rc != AX_OK) {
        return ax_emit_fail(emit_error_code, emit_error_message,
                            ax_error_code(rc), "invalid MenuList");
    }
    menus_truncated = list.truncated;
    if (!append(out, cap, used, ",\"menus\":[")) {
        return ax_emit_fail(emit_error_code, emit_error_message,
                            "overflow", "axtree menus header");
    }
    for (menu_index = 0; menu_index < list.count; menu_index++) {
        ax_menu_info   menu;
        ax_menu_cursor cursor;
        ax_menu_item   item;
        char           title_esc[kAXEscMax];
        int            first_item = 1;
        int            items_truncated = 0;

        if ((unsigned long)LMGetTicks() - budget_started
            >= kAXWalkMaxTicks || cap - *used < 2048) {
            menus_truncated = 1;
            *truncated = 1;
            break;
        }
        rc = ax_read_menu(&target->memory, &list, menu_index, &menu);
        if (rc != AX_OK) {
            return ax_emit_fail(emit_error_code, emit_error_message,
                                ax_error_code(rc), "invalid MenuInfo");
        }
        if (wire_escape(menu.title, menu.title_len, title_esc,
                        sizeof(title_esc)) < 0
            || !append(out, cap, used,
                "%s{\"id\":%d,\"title\":\"%s\",\"left\":%d,"
                "\"enabled\":%s,\"items\":[",
                first_menu ? "" : ",", (int)menu.id, title_esc,
                (int)menu.left,
                (menu.enable_flags & 1UL) != 0 ? "true" : "false")) {
            return ax_emit_fail(emit_error_code, emit_error_message,
                                "overflow", "axtree menu");
        }
        ax_menu_cursor_init(&menu, &cursor);
        for (;;) {
            rc = ax_menu_next(&target->memory, &cursor, &item);
            if (rc == AX_NOT_FOUND) {
                break;
            }
            if (rc == AX_AMBIGUOUS) {
                items_truncated = 1;
                *truncated = 1;
                break;
            }
            if (rc != AX_OK) {
                return ax_emit_fail(emit_error_code, emit_error_message,
                                    ax_error_code(rc), "invalid menu item");
            }
            if ((unsigned long)LMGetTicks() - budget_started
                >= kAXWalkMaxTicks || cap - *used < 2048) {
                items_truncated = 1;
                menus_truncated = 1;
                *truncated = 1;
                break;
            }
            if (wire_escape(item.title, item.title_len, title_esc,
                            sizeof(title_esc)) < 0
                || !append(out, cap, used,
                    "%s{\"index\":%u,\"title\":\"%s\","
                    "\"enabled\":%s,\"command\":%u,\"mark\":%u,"
                    "\"icon\":%u,\"style\":%u}",
                    first_item ? "" : ",", item.index, title_esc,
                    item.enabled ? "true" : "false",
                    (unsigned int)item.command, (unsigned int)item.mark,
                    (unsigned int)item.icon, (unsigned int)item.style)) {
                return ax_emit_fail(emit_error_code, emit_error_message,
                                    "overflow", "axtree menu item");
            }
            first_item = 0;
        }
        if (!append(out, cap, used, "],\"itemsTruncated\":%s}",
                    items_truncated ? "true" : "false")) {
            return ax_emit_fail(emit_error_code, emit_error_message,
                                "overflow", "axtree menu tail");
        }
        first_menu = 0;
        if (items_truncated) {
            break;
        }
    }
    if (!append(out, cap, used, "],\"menusTruncated\":%s",
                menus_truncated ? "true" : "false")) {
        return ax_emit_fail(emit_error_code, emit_error_message,
                            "overflow", "axtree menus tail");
    }
    return 1;
}

/* Append one selected app's standard Window/Control tree from RAM.
 *
 * AXPeek records CurrentA5, CurStackBase, and WindowList while each app's
 * low-memory world is active. This worker maps A5+stack to the process's
 * public ProcessInfoRec partition and starts at that exact WindowList. No
 * system-heap scan, private Process Manager offset, or temporary window.
 */
static int ax_append_target_tree(char *out, size_t cap, size_t *used,
                                 ax_target *target,
                                 const char *identity_key,
                                 unsigned long budget_started,
                                 int *hit_budget,
                                 const char **emit_error_code,
                                 const char **emit_error_message)
{
    static ax_title_entry window_titles[kAXMaxWins];
    static ax_title_entry control_titles[kAXMaxCtls];
    static char           ref_text[AX_REF_MAX];
    static ax_ref         control_ref;
    static ax_text_info   dialog_text;
    static char           text_esc[AX_TEXT_MAX * 6 + 1];
    unsigned long       window_addr;
    unsigned long       seen_windows[kAXMaxWins];
    ax_title_counter    window_counter;
    ax_title_counter    control_counter;
    char                name_esc[63 * 6 + 1];
    char                sig_esc[4 * 6 + 1];
    char                title_esc[kAXEscMax];
    int                 rc;
    int                 window_count = 0;
    int                 first_window = 1;
    int                 truncated = 0;
    int                 windows_truncated = 0;
    int                 budget_exceeded = 0;
    unsigned long       walk_started;
    unsigned long       finished;

    *hit_budget = 0;
    *emit_error_code = NULL;
    *emit_error_message = NULL;
    ax_title_counter_reset(&window_counter, window_titles, kAXMaxWins);
    pstr_escape(target->name, name_esc, sizeof(name_esc));
    ostype_escape(target->info.processSignature, sig_esc, sizeof(sig_esc));
    if (!append(out, cap, used,
        "{\"%s\":{\"name\":\"%s\",\"signature\":\"%s\","
        "\"serialHi\":%lu,\"serialLo\":%lu,\"front\":%s},"
        "\"source\":\"ram\",\"locator\":{"
        "\"strategy\":\"%s\",\"sampleTicks\":%lu,"
        "\"sampleAgeTicks\":%lu,\"sampleFresh\":%s,"
        "\"bytesScanned\":0},\"windows\":[",
        identity_key, name_esc, sig_esc,
        (unsigned long)target->process.highLongOfPSN,
        (unsigned long)target->process.lowLongOfPSN,
        target->is_front ? "true" : "false",
        target->is_self ? "current-lowmem"
                        : (target->bound_sample ? "axpeek-psn-bound"
                                                : "axpeek-context"),
        target->sample.ticks, target->sample_age,
        target->bound_sample ? "false" : "true")) {
        *emit_error_code = "overflow";
        *emit_error_message = "axtree header";
        return 0;
    }

    window_addr = target->sample.windowList;
    walk_started = target->oracle_done;
    while (window_addr != 0) {
        ax_window_info window;
        unsigned long  control;
        unsigned long  seen_controls[kAXMaxCtls];
        unsigned int   window_occurrence;
        int            control_count = 0;
        int            first_control = 1;
        int            controls_truncated = 0;
        int            stop_after_window = 0;
        int            i;

        if ((unsigned long)LMGetTicks() - budget_started
            >= kAXWalkMaxTicks) {
            truncated = 1;
            windows_truncated = 1;
            budget_exceeded = 1;
            *hit_budget = 1;
            break;
        }
        if (window_count >= kAXMaxWins || cap - *used < 4096) {
            truncated = 1;
            windows_truncated = 1;
            break;
        }
        for (i = 0; i < window_count; i++) {
            if (seen_windows[i] == window_addr) {
                return ax_emit_fail(emit_error_code, emit_error_message,
                                    "ax_cycle",
                                    "window list contains a cycle");
            }
        }
        seen_windows[window_count] = window_addr;
        rc = ax_read_window(&target->memory, window_addr, &window);
        if (rc != AX_OK) {
            return ax_emit_fail(emit_error_code, emit_error_message,
                                ax_error_code(rc), "invalid window record");
        }
        rc = ax_title_counter_next(&window_counter, window.title,
                                   window.title_len, &window_occurrence);
        if (rc != AX_OK) {
            return ax_emit_fail(emit_error_code, emit_error_message,
                                ax_error_code(rc),
                                "could not derive window occurrence");
        }
        if (wire_escape(window.title, window.title_len, title_esc,
                        sizeof(title_esc)) < 0
            || !append(out, cap, used,
                "%s{\"z\":%d,\"title\":\"%s\",\"kind\":%d,"
                "\"visible\":%s,\"rect\":[%d,%d,%d,%d],\"controls\":[",
                first_window ? "" : ",", window_count, title_esc,
                (int)window.kind, window.visible ? "true" : "false",
                (int)window.left, (int)window.top,
                (int)window.right, (int)window.bottom)) {
            return ax_emit_fail(emit_error_code, emit_error_message,
                                "overflow", "axtree window");
        }

        ax_title_counter_reset(&control_counter, control_titles, kAXMaxCtls);
        control = window.control_list;
        while (control != 0) {
            ax_control_info item;
            size_t          control_mark;
            unsigned int    control_occurrence;

            if ((unsigned long)LMGetTicks() - budget_started
                >= kAXWalkMaxTicks) {
                truncated = 1;
                controls_truncated = 1;
                windows_truncated = 1;
                budget_exceeded = 1;
                *hit_budget = 1;
                stop_after_window = 1;
                break;
            }
            if (control_count >= kAXMaxCtls) {
                truncated = 1;
                controls_truncated = 1;
                break;
            }
            if (cap - *used < 512) {
                truncated = 1;
                controls_truncated = 1;
                windows_truncated = 1;
                stop_after_window = 1;
                break;
            }
            for (i = 0; i < control_count; i++) {
                if (seen_controls[i] == control) {
                    return ax_emit_fail(emit_error_code, emit_error_message,
                                        "ax_cycle",
                                        "control list contains a cycle");
                }
            }
            seen_controls[control_count] = control;
            rc = ax_read_control(&target->memory, &window, control, &item);
            if (rc != AX_OK) {
                return ax_emit_fail(emit_error_code, emit_error_message,
                                    ax_error_code(rc),
                                    "invalid control record");
            }
            rc = ax_title_counter_next(&control_counter, item.title,
                                       item.title_len, &control_occurrence);
            if (rc != AX_OK) {
                return ax_emit_fail(emit_error_code, emit_error_message,
                                    ax_error_code(rc),
                                    "could not derive control occurrence");
            }
            memset(&control_ref, 0, sizeof(control_ref));
            control_ref.serial_hi =
                (uint32_t)target->process.highLongOfPSN;
            control_ref.serial_lo =
                (uint32_t)target->process.lowLongOfPSN;
            memcpy(control_ref.window_title, window.title, window.title_len);
            control_ref.window_title_len = window.title_len;
            control_ref.window_occurrence = window_occurrence;
            memcpy(control_ref.control_title, item.title, item.title_len);
            control_ref.control_title_len = item.title_len;
            control_ref.control_occurrence = control_occurrence;
            control_ref.node_fingerprint = ax_ref_node_fingerprint(
                control_ref.serial_hi, control_ref.serial_lo,
                (uint32_t)window_addr, (uint32_t)control);
            if (ax_ref_build(ref_text, sizeof(ref_text), &control_ref)
                != AX_REF_OK) {
                return ax_emit_fail(emit_error_code, emit_error_message,
                                    "ax_ref_invalid",
                                    "control reference could not be encoded");
            }
            control_mark = *used;
            if (wire_escape(item.title, item.title_len, title_esc,
                            sizeof(title_esc)) < 0
                || !append(out, cap, used,
                    "%s{\"role\":\"%s\",\"title\":\"%s\","
                    "\"visible\":%s,\"enabled\":%s,\"ref\":\"%s\","
                    "\"rect\":[%d,%d,%d,%d],"
                    "\"value\":%d,\"min\":%d,\"max\":%d,\"checked\":%s}",
                    first_control ? "" : ",",
                    /* Only the range case is reliably typed from the record;
                     * everything else stays "control" and lets value/min/max
                     * speak. */
                    (item.max - item.min > 1) ? "scrollbar" : "control",
                    title_esc,
                    item.visible ? "true" : "false",
                    item.enabled ? "true" : "false", ref_text,
                    (int)item.left, (int)item.top,
                    (int)item.right, (int)item.bottom,
                    (int)item.value, (int)item.min, (int)item.max,
                    /* precise for on/off controls; a push button keeps
                     * value 0 so it never reads as checked */
                    (item.min == 0 && item.max == 1 && item.value != 0)
                        ? "true" : "false")) {
                *used = control_mark;
                truncated = 1;
                controls_truncated = 1;
                windows_truncated = 1;
                stop_after_window = 1;
                break;
            }
            first_control = 0;
            control_count++;
            control = item.next_control;
        }
        if (!append(out, cap, used, "],\"controlsTruncated\":%s",
                    controls_truncated ? "true" : "false")) {
            return ax_emit_fail(emit_error_code, emit_error_message,
                                "overflow", "axtree window tail");
        }
        if (window.kind == dialogKind) {
            rc = ax_read_dialog_text(&target->memory, window.address,
                                     &dialog_text);
            if (rc != AX_OK && rc != AX_NOT_FOUND) {
                return ax_emit_fail(emit_error_code, emit_error_message,
                                    ax_error_code(rc),
                                    "invalid DialogRecord TextEdit state");
            }
            if (rc == AX_OK) {
                if (wire_escape(dialog_text.text, dialog_text.returned,
                                text_esc, sizeof(text_esc)) < 0
                    || !append(out, cap, used,
                        ",\"textEdit\":{\"text\":\"%s\","
                        "\"length\":%u,\"returned\":%u,"
                        "\"selection\":[%u,%u],\"active\":%s,"
                        "\"truncated\":%s}",
                        text_esc, dialog_text.length, dialog_text.returned,
                        dialog_text.selection_start,
                        dialog_text.selection_end,
                        dialog_text.active ? "true" : "false",
                        dialog_text.truncated ? "true" : "false")) {
                    return ax_emit_fail(emit_error_code, emit_error_message,
                                        "overflow", "axtree TextEdit state");
                }
            } else if (!append(out, cap, used, ",\"textEdit\":null")) {
                return ax_emit_fail(emit_error_code, emit_error_message,
                                    "overflow", "axtree TextEdit state");
            }
        }
        if (!append(out, cap, used, "}")) {
            return ax_emit_fail(emit_error_code, emit_error_message,
                                "overflow", "axtree window close");
        }
        first_window = 0;
        window_count++;
        window_addr = window.next_window;
        if (stop_after_window) {
            break;
        }
    }

    if (!append(out, cap, used, "]")) {
        return ax_emit_fail(emit_error_code, emit_error_message,
                            "overflow", "axtree windows close");
    }
    if (!ax_append_target_menus(out, cap, used, target, budget_started,
                                &truncated, emit_error_code,
                                emit_error_message)) {
        return 0;
    }
    if ((unsigned long)LMGetTicks() - budget_started >= kAXWalkMaxTicks) {
        budget_exceeded = 1;
        *hit_budget = 1;
    }
    finished = (unsigned long)LMGetTicks();
    if (!append(out, cap, used,
                ",\"truncated\":%s,\"windowsTruncated\":%s,"
                "\"budgetExceeded\":%s,\"timing\":{"
                "\"identityTicks\":%lu,\"oracleTicks\":%lu,"
                "\"walkAndSerializeTicks\":%lu},\"elapsedTicks\":%lu}",
                truncated ? "true" : "false",
                windows_truncated ? "true" : "false",
                budget_exceeded ? "true" : "false",
                target->oracle_started - target->started,
                target->oracle_done - target->oracle_started,
                finished - walk_started, finished - target->started)) {
        return ax_emit_fail(emit_error_code, emit_error_message,
                            "overflow", "axtree tail");
    }
    return 1;
}

static int ax_append_target_error(char *out, size_t cap, size_t *used,
                                  ax_target *target,
                                  const char *error_code,
                                  const char *error_message)
{
    char name_esc[63 * 6 + 1];
    char sig_esc[4 * 6 + 1];
    char message_esc[512];

    pstr_escape(target->name, name_esc, sizeof(name_esc));
    ostype_escape(target->info.processSignature, sig_esc, sizeof(sig_esc));
    if (wire_escape(error_message, strlen(error_message), message_esc,
                    sizeof(message_esc)) < 0) {
        message_esc[0] = '\0';
    }
    return append(out, cap, used,
        "{\"process\":{\"name\":\"%s\",\"signature\":\"%s\","
        "\"serialHi\":%lu,\"serialLo\":%lu,\"front\":%s},"
        "\"error\":{\"code\":\"%s\",\"message\":\"%s\"}}",
        name_esc, sig_esc,
        (unsigned long)target->process.highLongOfPSN,
        (unsigned long)target->process.lowLongOfPSN,
        target->is_front ? "true" : "false", error_code, message_esc);
}

/* axtree defaults to the latency-critical front process. `scope:"all"` walks
 * the Process Manager list without activation and gives every process either a
 * bounded tree or its own precise error. One stale background sample therefore
 * cannot erase useful fleet state. The whole fleet shares the same two-second
 * guest budget and response cap. */

static int verb_axtree(char *out, size_t cap, long id,
                       const char *line, size_t len)
{
    char                  scope[8];
    int                   scope_len;
    size_t                used = 0;
    ax_target             target;
    const char           *error_code;
    const char           *error_message;
    int                   hit_budget;

    scope_len = wire_find_str(line, len, "scope", scope, sizeof(scope));
    if (scope_len == kWireOverflow) {
        return resp_error(out, cap, id, "bad_request", "scope too large");
    }
    if (scope_len < 0) {
        strcpy(scope, "front");
    }
    if (strcmp(scope, "front") == 0) {
        if (!ax_open_target(&target, NULL, NULL, 0,
                            &error_code, &error_message)) {
            return resp_error(out, cap, id, error_code, error_message);
        }
        if (!append(out, cap, &used,
                    "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":",
                    id)) {
            return resp_error(out, cap, id, "overflow", "axtree envelope");
        }
        if (!ax_append_target_tree(out, cap, &used, &target, "front",
                                   target.oracle_done, &hit_budget,
                                   &error_code, &error_message)) {
            return resp_error(out, cap, id, error_code, error_message);
        }
        if (!append(out, cap, &used,
                    ",\"backing\":\"" TBT_BACKING "\"}\n")) {
            return resp_error(out, cap, id, "overflow", "axtree envelope");
        }
        return (int)used;
    }
    if (strcmp(scope, "all") == 0) {
        ProcessSerialNumber psn = {0, kNoProcess};
        unsigned long       started = (unsigned long)LMGetTicks();
        int                 app_count = 0;
        int                 first_app = 1;
        int                 truncated = 0;
        int                 budget_exceeded = 0;

        if (!append(out, cap, &used,
            "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{"
            "\"scope\":\"all\",\"apps\":[", id)) {
            return resp_error(out, cap, id, "overflow", "axtree all header");
        }
        while (GetNextProcess(&psn) == noErr) {
            size_t app_mark = used;

            hit_budget = 0;
            if (app_count >= kAXMaxApps || cap - used < 4096) {
                truncated = 1;
                break;
            }
            if ((unsigned long)LMGetTicks() - started >= kAXWalkMaxTicks) {
                truncated = 1;
                budget_exceeded = 1;
                break;
            }
            if (!append(out, cap, &used, "%s", first_app ? "" : ",")) {
                truncated = 1;
                break;
            }
            if (!ax_open_target(&target, &psn, NULL, 1,
                                &error_code, &error_message)) {
                if (!ax_append_target_error(out, cap, &used, &target,
                                            error_code, error_message)) {
                    used = app_mark;
                    truncated = 1;
                    break;
                }
            } else if (!ax_append_target_tree(out, cap, &used, &target,
                                              "process", started,
                                              &hit_budget, &error_code,
                                              &error_message)) {
                used = app_mark;
                if (!append(out, cap, &used, "%s", first_app ? "" : ",")
                    || !ax_append_target_error(out, cap, &used, &target,
                                               error_code, error_message)) {
                    used = app_mark;
                    truncated = 1;
                    break;
                }
            }
            first_app = 0;
            app_count++;
            if (hit_budget) {
                truncated = 1;
                budget_exceeded = 1;
                break;
            }
        }
        if (!append(out, cap, &used,
            "],\"count\":%d,\"appsTruncated\":%s,"
            "\"budgetExceeded\":%s,\"elapsedTicks\":%lu},"
            "\"backing\":\"" TBT_BACKING "\"}\n",
            app_count, truncated ? "true" : "false",
            budget_exceeded ? "true" : "false",
            (unsigned long)LMGetTicks() - started)) {
            return resp_error(out, cap, id, "overflow", "axtree all tail");
        }
        return (int)used;
    }
    return resp_error(out, cap, id, "bad_request",
                      "scope must be front or all");
}

/* axdo - re-resolve one stable control reference against a fresh front-app
 * snapshot, then dispatch the existing above-line click primitive. It never
 * activates: a ref from another front process fails before any input event. */
static int verb_axdo(char *out, size_t cap, long id,
                     const char *line, size_t len)
{
    static char         ref_text[AX_REF_MAX];
    static ax_ref       ref;
    static ax_target      target;
    static ax_resolved_control resolved;
    ProcessSerialNumber expected;
    const char         *error_code;
    const char         *error_message;
    unsigned long       started = (unsigned long)LMGetTicks();
    ProcessSerialNumber front;
    Boolean             same = false;
    short               x;
    short               y;
    int                 ref_len;
    int                 n;
    int                 rc;
    const char         *axdo_action = "click";

    ref_len = wire_find_str(line, len, "ref", ref_text, sizeof(ref_text));
    if (ref_len == kWireOverflow) {
        return resp_error(out, cap, id, "bad_ref", "reference is too large");
    }
    if (ref_len < 0
        || ax_ref_parse(ref_text, (size_t)ref_len, &ref) != AX_REF_OK) {
        return resp_error(out, cap, id, "bad_ref",
                          "reference is missing or malformed");
    }
    expected.highLongOfPSN = ref.serial_hi;
    expected.lowLongOfPSN = ref.serial_lo;
    if (!ax_open_target(&target, &expected, &expected, 0,
                        &error_code, &error_message)) {
        return resp_error(out, cap, id, error_code, error_message);
    }
    rc = ax_resolve_ref(&target.memory, target.sample.windowList,
                        &ref, &resolved);
    if ((unsigned long)LMGetTicks() - started >= kAXWalkMaxTicks) {
        return resp_error(out, cap, id, "ref_stale",
                          "reference resolution exceeded its time budget");
    }
    if (rc == AX_RESOLVE_CYCLE) {
        return resp_error(out, cap, id, "ax_cycle",
                          "window or control list contains a cycle");
    }
    if (rc == AX_RESOLVE_NOT_FOUND) {
        return resp_error(out, cap, id, "ref_not_found",
                          "referenced control no longer exists");
    }
    if (rc == AX_RESOLVE_STALE) {
        return resp_error(out, cap, id, "ref_stale",
                          "referenced control identity changed");
    }
    if (rc != AX_RESOLVE_OK) {
        return resp_error(out, cap, id, ax_error_code(rc),
                          "invalid window or control record");
    }
    if (resolved.visible_window_z != 0 || !resolved.window.visible) {
        return resp_error(out, cap, id, "not_actionable",
                          "referenced window is hidden or covered");
    }
    if (!resolved.control.visible || !resolved.control.enabled
        || resolved.control.right <= resolved.control.left
        || resolved.control.bottom <= resolved.control.top) {
        return resp_error(out, cap, id, "not_actionable",
                          "referenced control is hidden or inactive");
    }
    if (GetFrontProcess(&front) != noErr
        || SameProcess(&front, &expected, &same) != noErr || !same) {
        return resp_error(out, cap, id, "ref_not_front",
                          "front process changed during resolution");
    }
    x = (short)(resolved.control.left
                + (resolved.control.right - resolved.control.left) / 2);
    y = (short)(resolved.control.top
                + (resolved.control.bottom - resolved.control.top) / 2);
    {
        long count = 1, mods = 0;
        (void)wire_find_int(line, len, "count", &count);
        (void)wire_find_int(line, len, "mods", &mods);
        if (count < 1) { count = 1; }
        if (count > 3) { count = 3; }       /* single / double-click by ref */
        rc = post_click_at(x, y, (int)count, (short)mods);
    }
    if (rc == kClickPostDownFailed) {
        return resp_error(out, cap, id, "event_queue_full",
                          "mouse-down event could not be queued");
    }
    if (rc == kClickPostUpFailed) {
        return resp_error(out, cap, id, "event_partial",
                          "mouse-down queued but mouse-up failed");
    }
    /* Optional text: the click focused the control (e.g. an edit field);
     * queue the keystrokes AFTER it so the app processes focus-then-type. */
    {
        static char text[kMsgMax];
        int tlen = wire_find_str(line, len, "text", text, sizeof(text));
        if (tlen > 0) {
            int ti;
            for (ti = 0; ti < tlen; ti++) {
                UInt32 km = (UInt32)(unsigned char)text[ti];
                (void)PostEvent(keyDown, km);
                (void)PostEvent(keyUp, km);
            }
            axdo_action = "type";
        }
    }
    n = snprintf(out, cap,
        "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{"
        "\"ref\":\"%s\",\"action\":\"%s\","
        "\"serialHi\":%lu,\"serialLo\":%lu,"
        "\"rect\":[%d,%d,%d,%d],\"point\":[%d,%d],"
        "\"elapsedTicks\":%lu},\"backing\":\""
        TBT_BACKING "\"}\n",
        id, ref_text, axdo_action,
        (unsigned long)expected.highLongOfPSN,
        (unsigned long)expected.lowLongOfPSN,
        (int)resolved.control.left, (int)resolved.control.top,
        (int)resolved.control.right, (int)resolved.control.bottom,
        (int)x, (int)y, (unsigned long)LMGetTicks() - started);
    return (n < 0 || (size_t)n >= cap) ? -1 : n;
}



/* --- act: raw input injection ---------------------------------------- */

static int verb_mouseloc(char *out, size_t cap, long id)
{
    Point pt = LMGetMouseLocation();
    int nn = snprintf(out, cap,
        "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{\"x\":%d,\"y\":%d},"
        "\"backing\":\"" TBT_BACKING "\"}\n", id, (int)pt.h, (int)pt.v);
    return (nn < 0 || (size_t)nn >= cap) ? -1 : nn;
}
static int verb_key(char *out, size_t cap, long id,
                    const char *line, size_t len)
{
    long   code = 0, ch = 0, mods = 0;
    UInt32 msg;
    int    nn;

    (void)wire_find_int(line, len, "code", &code);
    (void)wire_find_int(line, len, "char", &ch);
    (void)wire_find_int(line, len, "mods", &mods);
    msg = ((UInt32)(code & 0xFF) << 8) | (UInt32)(ch & 0xFF);

    if (mods != 0) {
        EvQElPtr      qel = NULL;
        OSErr         perr;
        OSErr         uerr;
        unsigned long t;
        char          b[128];

        /* A modified keystroke is posted as a PAIR, and a real keystroke has
         * duration, so the pair gets a beat between its halves — the same
         * discipline post_click_at uses to space the clicks of a multi-click
         * set. Defensible on its own terms; NOT a proven fix (docs/STATUS.md).
         *
         * BOTH posts are now checked. Only the keyDown's return was ever looked
         * at, and it always said noErr — which is how this verb kept claiming
         * success while actuation had been dead for a hundred trials. The keyUp
         * goes through plain PostEvent, whose return had never been read at
         * all. A keystroke whose halves did not both make it into the queue is
         * not a keystroke, and the verb must say so rather than report ok. */
        perr = PPostEvent(keyDown, msg, &qel);
        if (perr == noErr && qel != NULL) {
            /* Stamp the modifiers on the QUEUED event rather than trusting the
             * live modifier state, which the keyboard driver can overwrite
             * between our set and the front app's dequeue. Same trick the click
             * path uses for evtQWhere. */
            qel->evtQModifiers = (short)mods;
        }
        t = (unsigned long)LMGetTicks();
        while ((unsigned long)LMGetTicks() - t < 3UL) {   /* ~3/60 s */
        }
        uerr = PostEvent(keyUp, msg);

        snprintf(b, sizeof b,
                 "key: code=%ld mods=%ld keyDown=%d qel=%s keyUp=%d",
                 code, mods, (int)perr, qel == NULL ? "NULL" : "ok",
                 (int)uerr);
        mirror_log(b);

        /* keyUp routinely returns evtNotEnb (1): keyUp is not enabled in the
         * system event mask on classic Mac OS, so the Event Manager declines it
         * and that is NORMAL — measured on every single trial, including the
         * ones that actuated correctly. The lab's `(void)PostEvent(keyUp, msg)`
         * was deliberate, not sloppy. Treating it as a failure turned a working
         * verb into one that errored 20/20 while still actuating 9/20.
         *
         * So only the keyDown is load-bearing. Report a failure when the half
         * that matters did not make it into the queue. NOTE for the queue-
         * exhaustion theory: keyDown returns noErr even when actuation has been
         * dead for a dozen trials, so a full queue is NOT how this verb fails. */
        if (perr != noErr || qel == NULL) {
            char detail[112];
            snprintf(detail, sizeof detail,
                     "keyDown=%d qel=%s - the event queue refused the keystroke",
                     (int)perr, qel == NULL ? "NULL" : "ok");
            return resp_error(out, cap, id, "post_failed", detail);
        }
    } else {
        OSErr derr = PostEvent(keyDown, msg);

        (void)PostEvent(keyUp, msg);   /* evtNotEnb is normal; see above */
        if (derr != noErr) {
            char detail[96];
            snprintf(detail, sizeof detail,
                     "keyDown=%d - the event queue refused the keystroke",
                     (int)derr);
            return resp_error(out, cap, id, "post_failed", detail);
        }
    }
    nn = snprintf(out, cap,
        "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{\"code\":%ld,\"mods\":%ld},"
        "\"backing\":\"" TBT_BACKING "\"}\n", id, code, mods);
    return (nn < 0 || (size_t)nn >= cap) ? -1 : nn;
}
static int post_click_at(short x, short y, int count, short mods)
{
    Point         pt;
    int           i;
    unsigned long t;

    pt.h = x;
    pt.v = y;

    /* Move the visible cursor to the target (cosmetic + apps that re-read
     * GetMouse). But the authoritative click location is set per-event below. */
    LMSetMouseTemp(pt);
    LMSetRawMouseLocation(pt);
    LMSetMouseLocation(pt);
    kLMCrsrNew = kLMCrsrCouple;             /* signal the cursor task to redraw */

    for (i = 0; i < count; i++) {
        EvQElPtr qd = NULL;
        EvQElPtr qu = NULL;
        if (i > 0) {                        /* small gap between clicks of a set */
            t = TickCount();
            while (TickCount() - t < 3) { }  /* ~3/60 s, well under GetDblTime */
        }
        /* Set `where` on the queued event EXPLICITLY. Relying on the live mouse
         * location loses the race: the ADB (metal) / emulated (emu) mouse VBL
         * can overwrite MouseLocation between our set and the app's dequeue, so
         * the click lands wherever the real pointer is. PPostEvent hands back the
         * queue element; stamping evtQWhere makes the click land where we aim,
         * regardless of the mouse driver. (Same trick as modifiers for keys.) */
        LMSetMouseButtonState(0x00);        /* button down */
        if (PPostEvent(mouseDown, 0, &qd) != noErr || qd == NULL) {
            LMSetMouseButtonState(0x80);
            return kClickPostDownFailed;
        }
        qd->evtQWhere = pt;
        qd->evtQModifiers = mods;           /* ctrl = contextual, shift, etc. */
        LMSetMouseButtonState(0x80);        /* button up */
        if (PPostEvent(mouseUp, 0, &qu) != noErr || qu == NULL) {
            return kClickPostUpFailed;
        }
        qu->evtQWhere = pt;
        qu->evtQModifiers = mods;
    }
    return kClickPostOK;
}
static int verb_click(char *out, size_t cap, long id,
                      const char *line, size_t len)
{
    long x = 0, y = 0, button = 0, count = 1, mods = 0;
    int  post_status;
    int  nn;

    (void)wire_find_int(line, len, "x", &x);
    (void)wire_find_int(line, len, "y", &y);
    (void)wire_find_int(line, len, "button", &button);
    (void)wire_find_int(line, len, "count", &count);
    (void)wire_find_int(line, len, "mods", &mods);
    /* Classic Mac OS is single-button; a "right" click is a Control-click
     * (the contextual-menu gesture, System 8+). Fold button 2/3 into the
     * control modifier so callers can ask for either way. */
    if (button >= 2) { mods |= 4096; }      /* controlKey */
    if (count < 1) { count = 1; }
    if (count > 3) { count = 3; }           /* single / double / triple */
    post_status = post_click_at((short)x, (short)y, (int)count, (short)mods);
    if (post_status == kClickPostDownFailed) {
        return resp_error(out, cap, id, "event_queue_full",
                          "mouse-down event could not be queued");
    }
    if (post_status == kClickPostUpFailed) {
        return resp_error(out, cap, id, "event_partial",
                          "mouse-down queued but mouse-up failed");
    }

    nn = snprintf(out, cap,
        "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{\"x\":%ld,\"y\":%ld,"
        "\"count\":%ld},\"backing\":\"" TBT_BACKING "\"}\n", id, x, y, count);
    return (nn < 0 || (size_t)nn >= cap) ? -1 : nn;
}

/* --- perceive: the filesystem plane (the Finder's contents) --------------- */
/*
 * `list` and `stat`, carried from the lab at 2026-07-30.
 *
 * These are CONTENT, not chrome, and the host has always wanted them:
 * ScenePoller asks for `list` on "Macintosh HD:Desktop Folder" to place the
 * desktop's icons, and once per Finder window to fill it. Without them the
 * mirror draws correct windows around empty space — which is exactly what it
 * did, and it was read as "the content plane is unsourced by design". Only the
 * QuickDraw stream is unsourced by design; the Finder's own contents are a
 * directory listing, and this is it.
 *
 * kPathMax/kMaxList and the Str255 conversion come with them.
 */
#define kPathMax   256     /* HFS path (Str255 + NUL) */
#define kMaxList   128     /* cap directory entries per call */

static int path_arg(const char *line, size_t len, char *out, size_t cap, long id,
                    char *path, Str255 ppath, char *esc, size_t escCap, int *rc)
{
    int plen = wire_find_str(line, len, "path", path, kPathMax);

    if (plen == kWireOverflow) {
        *rc = resp_error(out, cap, id, "overflow", "path too long");
        return -1;
    }
    if (plen < 0) {
        *rc = resp_error(out, cap, id, "bad_request", "missing path");
        return -1;
    }
    if (plen > 255) {
        *rc = resp_error(out, cap, id, "bad_request", "path too long");
        return -1;
    }
    if (wire_escape(path, (size_t)plen, esc, escCap) < 0) {
        *rc = resp_error(out, cap, id, "overflow", "path");
        return -1;
    }
    ppath[0] = (unsigned char)plen;
    memcpy(ppath + 1, path, (size_t)plen);
    return plen;
}

static int verb_list(char *out, size_t cap, long id,
                     const char *line, size_t len)
{
    char        path[kPathMax];
    char        esc[kPathMax * 6 + 1];
    Str255      ppath;
    Str255      name;
    FSSpec      spec;
    CInfoPBRec  pb;
    long        dirID;
    OSErr       err;
    size_t      used = 0;
    int         rc;
    int         truncated = 0;
    int         first;
    int         count;
    short       i;
    char        msg[64];

    if (path_arg(line, len, out, cap, id, path, ppath, esc, sizeof(esc),
                 &rc) < 0) {
        return rc;
    }

    /* Resolve the folder and get its own dirID. */
    err = FSMakeFSSpec(0, 0, ppath, &spec);
    if (err != noErr) {
        snprintf(msg, sizeof(msg), "FSMakeFSSpec err %d", (int)err);
        return resp_error(out, cap, id,
                          (err == fnfErr) ? "not_found" : "io_error", msg);
    }
    memcpy(name, spec.name, (size_t)spec.name[0] + 1);
    memset(&pb, 0, sizeof(pb));
    pb.dirInfo.ioNamePtr   = name;
    pb.dirInfo.ioVRefNum   = spec.vRefNum;
    pb.dirInfo.ioDrDirID   = spec.parID;
    pb.dirInfo.ioFDirIndex = 0;
    err = PBGetCatInfoSync(&pb);
    if (err != noErr) {
        snprintf(msg, sizeof(msg), "PBGetCatInfo err %d", (int)err);
        return resp_error(out, cap, id, "io_error", msg);
    }
    if ((pb.dirInfo.ioFlAttrib & ioDirMask) == 0) {
        return resp_error(out, cap, id, "not_a_folder", "path is a file");
    }
    dirID = pb.dirInfo.ioDrDirID;

    if (!append(out, cap, &used,
        "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{"
        "\"path\":\"%s\",\"items\":[", id, esc)) {
        return resp_error(out, cap, id, "overflow", "list header");
    }

    first = 1;
    count = 0;
    for (i = 1; ; i++) {
        Str255  iname;
        Boolean isDir;
        size_t  mark;

        if (count >= kMaxList) {
            truncated = 1;
            break;
        }
        memset(&pb, 0, sizeof(pb));
        pb.dirInfo.ioNamePtr   = iname;
        pb.dirInfo.ioVRefNum   = spec.vRefNum;
        pb.dirInfo.ioDrDirID   = dirID;        /* re-seed: the call rewrites it */
        pb.dirInfo.ioFDirIndex = i;
        err = PBGetCatInfoSync(&pb);
        if (err != noErr) {
            break;                             /* past the last entry */
        }
        isDir = (pb.hFileInfo.ioFlAttrib & ioDirMask) != 0;
        pstr_escape(iname, esc, sizeof(esc));  /* path already emitted; reuse */
        mark = used;
        if (isDir) {
            /* Finder Info for a folder lives in ioDrUsrWds (DInfo). Its
             * frLocation is the icon position (Point h,v); {0,0} means the
             * Finder auto-places it. flags carries fdInvisible etc. */
            if (!append(out, cap, &used,
                "%s{\"name\":\"%s\",\"kind\":\"folder\","
                "\"loc\":{\"h\":%d,\"v\":%d},\"flags\":%u}",
                first ? "" : ",", esc,
                pb.dirInfo.ioDrUsrWds.frLocation.h,
                pb.dirInfo.ioDrUsrWds.frLocation.v,
                (unsigned)pb.dirInfo.ioDrUsrWds.frFlags)) {
                used = mark;
                truncated = 1;
                break;
            }
        } else {
            /* FInfo: type + creator key the icon; fdLocation is the saved
             * icon position; fdFlags has fdIsAlias/fdInvisible. */
            char tesc[32], cesc[32];
            ostype_escape(pb.hFileInfo.ioFlFndrInfo.fdType, tesc, sizeof(tesc));
            ostype_escape(pb.hFileInfo.ioFlFndrInfo.fdCreator, cesc,
                          sizeof(cesc));
            if (!append(out, cap, &used,
                "%s{\"name\":\"%s\",\"kind\":\"file\",\"type\":\"%s\","
                "\"creator\":\"%s\",\"size\":%lu,"
                "\"loc\":{\"h\":%d,\"v\":%d},\"flags\":%u}",
                first ? "" : ",", esc, tesc, cesc,
                (unsigned long)pb.hFileInfo.ioFlLgLen,
                pb.hFileInfo.ioFlFndrInfo.fdLocation.h,
                pb.hFileInfo.ioFlFndrInfo.fdLocation.v,
                (unsigned)pb.hFileInfo.ioFlFndrInfo.fdFlags)) {
                used = mark;
                truncated = 1;
                break;
            }
        }
        first = 0;
        count++;
    }

    if (!append(out, cap, &used,
        "],\"count\":%d,\"truncated\":%s},\"backing\":\"" TBT_BACKING "\"}\n",
        count, truncated ? "true" : "false")) {
        return resp_error(out, cap, id, "overflow", "list tail");
    }
    return (int)used;
}

static int verb_stat(char *out, size_t cap, long id,
                     const char *line, size_t len)
{
    char        path[kPathMax];
    char        esc[kPathMax * 6 + 1];
    Str255      ppath;
    Str255      name;
    FSSpec      spec;
    CInfoPBRec  pb;
    OSErr       err;
    size_t      used = 0;
    int         rc;

    if (path_arg(line, len, out, cap, id, path, ppath, esc, sizeof(esc),
                 &rc) < 0) {
        return rc;
    }

    err = FSMakeFSSpec(0, 0, ppath, &spec);
    if (err == fnfErr) {
        if (!append(out, cap, &used,
            "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{"
            "\"path\":\"%s\",\"exists\":false},\"backing\":\"" TBT_BACKING "\"}\n",
            id, esc)) {
            return resp_error(out, cap, id, "overflow", "stat");
        }
        return (int)used;
    }
    if (err != noErr) {
        char msg[64];
        snprintf(msg, sizeof(msg), "FSMakeFSSpec err %d", (int)err);
        return resp_error(out, cap, id, "io_error", msg);
    }

    /* Catalog info: look up spec.name in its parent dir. */
    memcpy(name, spec.name, (size_t)spec.name[0] + 1);
    memset(&pb, 0, sizeof(pb));
    pb.hFileInfo.ioNamePtr   = name;
    pb.hFileInfo.ioVRefNum   = spec.vRefNum;
    pb.hFileInfo.ioDirID     = spec.parID;
    pb.hFileInfo.ioFDirIndex = 0;
    err = PBGetCatInfoSync(&pb);
    if (err != noErr) {
        char msg[64];
        snprintf(msg, sizeof(msg), "PBGetCatInfo err %d", (int)err);
        return resp_error(out, cap, id, "io_error", msg);
    }

    if ((pb.hFileInfo.ioFlAttrib & ioDirMask) != 0) {
        if (!append(out, cap, &used,
            "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{"
            "\"path\":\"%s\",\"exists\":true,\"kind\":\"folder\","
            "\"items\":%u,\"created\":%lu,\"modified\":%lu"
            "},\"backing\":\"" TBT_BACKING "\"}\n",
            id, esc, (unsigned)pb.dirInfo.ioDrNmFls,
            (unsigned long)pb.dirInfo.ioDrCrDat,
            (unsigned long)pb.dirInfo.ioDrMdDat)) {
            return resp_error(out, cap, id, "overflow", "stat");
        }
    } else {
        char tesc[32];   /* 4 control bytes escape to 4*6 = 24 chars + NUL */
        char cesc[32];

        ostype_escape(pb.hFileInfo.ioFlFndrInfo.fdType, tesc, sizeof(tesc));
        ostype_escape(pb.hFileInfo.ioFlFndrInfo.fdCreator, cesc, sizeof(cesc));
        if (!append(out, cap, &used,
            "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{"
            "\"path\":\"%s\",\"exists\":true,\"kind\":\"file\","
            "\"dataSize\":%lu,\"rsrcSize\":%lu,\"type\":\"%s\","
            "\"creator\":\"%s\",\"locked\":%s,\"created\":%lu,\"modified\":%lu"
            "},\"backing\":\"" TBT_BACKING "\"}\n",
            id, esc,
            (unsigned long)pb.hFileInfo.ioFlLgLen,
            (unsigned long)pb.hFileInfo.ioFlRLgLen,
            tesc, cesc,
            (pb.hFileInfo.ioFlAttrib & 0x01) ? "true" : "false",
            (unsigned long)pb.hFileInfo.ioFlCrDat,
            (unsigned long)pb.hFileInfo.ioFlMdDat)) {
            return resp_error(out, cap, id, "overflow", "stat");
        }
    }
    return (int)used;
}



/* The capture path's stage tracing. The lab gates this behind a build flag and
 * routes it to its own hlog; here it goes to the agent's journal, which is where
 * a wedge investigation will already be looking. */
#ifdef MIRROR_SHOT_TRACE
#define SHOT_LOG(...) mirror_log_fmt(__VA_ARGS__)
#else
#define SHOT_LOG(...) ((void)0)
#endif

/* --- the pixel plane: capture / fetch / close ------------------------------
 *
 * Carried from the lab 2026-07-30. This is what fills a window's INTERIOR.
 *
 * The host asks for it as three verbs, not one: `capture` opens a region and
 * either returns the payload inline or hands back a handle, then `fetch` pages
 * the bytes and `close` releases the slot (MirrorKit's PixelIsland.pull). The
 * bounded transfer-slot machinery comes with it — one resident buffer plus file
 * slots, using the lab's xfer_* CRC/state helpers and MacBinary parsing.
 *
 * Scope note, stated because it is easy to over-claim: only the FRONT window
 * gets an island, and with no `qdtrace` op stream the host has nothing telling
 * it a window repainted — so an interior fills on the first poll and then holds
 * that image. Live interiors need the QuickDraw plane, a separate project
 * (QDPEEK-SPEC.md). This makes interiors appear and be correct-at-capture.
 */

/* transfer-slot machinery */
/* --- transfer handles (W1 pager + W3 file channel, docs/18-file-transfer.md) ---
 * A small typed handle table. RESIDENT handles page the shared g_xfer_buf (a
 * captured screenshot); FILE_WRITE handles assemble an uploaded MacBinary stream
 * into a temp file, committed to a real file (both forks) on close. There is one
 * resident buffer (RAM-tight PB1400; a frame is ~7-8 KB) held by the single
 * RESIDENT slot (index 0), but several FILE_WRITE handles can be open at once
 * (they live on disk) - so a screenshot never supersedes a transfer. One
 * connection is served serially, so the table needs no locking. A monotonic id
 * invalidates stale handles; the id arg is `handle`, never `id` (which would
 * shadow the envelope key in the flat request parser - see wire.c find_value). */
#define kXferChunk 1056    /* sub-cliff page size. Metal-measured 2026-07-07
                              (docs/29-screenshot-latency.md): the OT+Farallon
                              response cliff starts when a reply line takes a
                              substantial 2nd TCP segment (>~1.5 KB); 1056 raw
                              -> ~1518 B line = 1 MSS + 58 B, still in the fast
                              ~30 ms class on the PB1400c, 37% more payload per
                              page than the old 768. NEVER default into the
                              1400-2048 band (delayed-ACK/retransmit stalls). */
/* Cap for the negotiable get-open chunk (mirrors kPutRawMax on the upload
 * side): `fetch` pages a FILE_READ handle through a buffer this big, and its
 * response line (b64 of the chunk + envelope) must fit kRespBuf. Chunks past
 * the metal send cliff are the client's informed choice — the default stays
 * the sub-cliff kXferChunk. */
#define kGetRawMax 8192
/* The single resident buffer holds either a packed 1-bit `screenshot` frame
 * (~24 KB) or a packed gray8 `capture` region. Sized to fit a whole standard
 * dialog captured at native res (e.g. ~400x300 gray8 packs well under this);
 * a bigger crop is rejected as too_large so the client scales or tiles it. */
#define kXferBufMax (131072L)                           /* 128 KB */
#define kXferSlots  4                                   /* 1 resident + 3 file */

/* capture (docs/25): sanity bound on either side of a crop, in pixels. Bounds
 * the per-row scratch and, with the packed-size check, the resident buffer. */
#define kCapMaxDim  1024

typedef enum {
    kSlotFree = 0,
    kSlotResident,       /* screenshot: data lives in g_xfer_buf */
    kSlotFileWrite,      /* put: MacBinary stream -> temp file -> commit */
    kSlotFileRead        /* get: a file paged AS a virtual MacBinary envelope */
} SlotKind;

typedef struct {
    long          id;        /* 0 = free; else the live handle id */
    SlotKind      kind;
    long          chunk;     /* suggested page size */
    long          len;       /* resident: bytes in g_xfer_buf; file-read: totalLen */
    unsigned long crc;       /* CRC-32 of the served bytes (integrity + ETag) */
    /* file-write (put) */
    short         tmpRef;    /* temp data-fork refnum (0 = none) */
    FSSpec        tmpSpec;   /* temp file, deleted on commit / free */
    FSSpec        dstSpec;   /* commit target */
    long          expect;    /* total MacBinary-stream bytes expected */
    long          high;      /* contiguous bytes written (resume point) */
    /* per-transfer instrumentation (summed TickCount deltas; see put_commit).
     * A single chunk's phase is sub-tick, but the sum over a whole transfer is an
     * unbiased estimate of total phase time - enough to split "guest grinding"
     * from "waiting on the wire/poll loop" and decide if pipelining is worth it. */
    long          chunks;    /* number of `put` calls */
    long          tExtract;  /* ticks: pulling the b64 `data` out of the line */
    long          tDecode;   /* ticks: base64 -> raw */
    long          tWrite;    /* ticks: SetFPos + FSWrite */
    XferCrc       putCrc;    /* sequential path; invalid means reread */
    /* file-read (get): page the forks on disk as one virtual MacBinary envelope */
    short         dataRef;   /* open data-fork refnum (0 = none) */
    short         rsrcRef;   /* open resource-fork refnum (0 = none) */
    long          dataLen;
    long          rsrcLen;
    long          dataOff;   /* kMacBinHeader */
    long          rsrcOff;   /* kMacBinHeader + pad128(dataLen) */
    unsigned char header[kMacBinHeader];   /* the prebuilt 128-byte MB header */
} XferSlot;

static XferSlot      g_slots[kXferSlots];
static unsigned char g_xfer_buf[kXferBufMax];      /* the single RESIDENT buffer */
static long          g_xfer_seq = 0;               /* handle-id source */
static unsigned long g_xfer_generation = 0;

int verbs_session_begin(unsigned long generation, long *scavenged,
                        long *failures)
{
    CInfoPBRec pb;
    Str255 name;
    FSSpec spec;
    short vref;
    long dir;
    short index = 1;
    long removed = 0;
    long failed = 0;

    if (generation == 0 || HGetVol(NULL, &vref, &dir) != noErr) {
        return -1;
    }
    for (;;) {
        memset(&pb, 0, sizeof pb);
        pb.hFileInfo.ioNamePtr = name;
        pb.hFileInfo.ioVRefNum = vref;
        pb.hFileInfo.ioDirID = dir;
        pb.hFileInfo.ioFDirIndex = index;
        if (PBGetCatInfoSync(&pb) != noErr) {
            break;
        }
        if (!(pb.hFileInfo.ioFlAttrib & ioDirMask)) {
            char cname[32];
            size_t length = name[0];

            if (length < sizeof cname) {
                memcpy(cname, name + 1, length);
                cname[length] = '\0';
                if (xfer_state_parse(cname, NULL, NULL)) {
                    spec.vRefNum = vref;
                    spec.parID = dir;
                    BlockMoveData(name, spec.name, (long)length + 1);
                    if (FSpDelete(&spec) == noErr) {
                        removed++;
                        continue;
                    }
                    failed++;
                }
            }
        }
        index++;
    }
    g_xfer_generation = generation;
    if (scavenged != NULL) {
        *scavenged = removed;
    }
    if (failures != NULL) {
        *failures = failed;
    }
    return failed == 0 ? 0 : -1;
}

static XferSlot *slot_find(long id)
{
    int i;

    if (id == 0) {
        return NULL;
    }
    for (i = 0; i < kXferSlots; i++) {
        if (g_slots[i].id == id) {
            return &g_slots[i];
        }
    }
    return NULL;
}

/* The one RESIDENT slot lives at index 0 (there is a single shared buffer). */
static XferSlot *slot_resident(void)
{
    return &g_slots[0];
}

/* A free FILE_WRITE slot (indices 1..), or NULL if all busy. */
static XferSlot *slot_alloc_file(void)
{
    int i;

    for (i = 1; i < kXferSlots; i++) {
        if (g_slots[i].id == 0) {
            return &g_slots[i];
        }
    }
    return NULL;
}

/* Release a slot: FILE_WRITE closes+deletes its temp; FILE_READ closes its open
 * fork refnums. */
static void slot_free(XferSlot *s)
{
    if (s->kind == kSlotFileWrite) {
        if (s->tmpRef != 0) {
            (void)FSClose(s->tmpRef);
            s->tmpRef = 0;
        }
        (void)FSpDelete(&s->tmpSpec);
    } else if (s->kind == kSlotFileRead) {
        if (s->dataRef != 0) {
            (void)FSClose(s->dataRef);
            s->dataRef = 0;
        }
        if (s->rsrcRef != 0) {
            (void)FSClose(s->rsrcRef);
            s->rsrcRef = 0;
        }
    }
    s->id = 0;
    s->kind = kSlotFree;
    s->tmpRef = 0;
    s->dataRef = 0;
    s->rsrcRef = 0;
}

/* Read n bytes of a FILE_READ handle's virtual MacBinary envelope at stream
 * offset `off` into out. The envelope is header | data fork | zero-pad | rsrc
 * fork | zero-pad; forks are read from disk on demand (O(1) RAM), so an
 * arbitrarily large file never lands in memory. A page may straddle regions. */
static OSErr envelope_read(XferSlot *s, long off, long n, unsigned char *out)
{
    long  done = 0;
    OSErr err;

    while (done < n) {
        long pos = off + done;
        long room = n - done;
        long take;

        if (pos < s->dataOff) {                        /* header */
            take = s->dataOff - pos;
            if (take > room) {
                take = room;
            }
            memcpy(out + done, s->header + pos, (size_t)take);
        } else if (pos < s->dataOff + s->dataLen) {    /* data fork (from disk) */
            long got;
            take = (s->dataOff + s->dataLen) - pos;
            if (take > room) {
                take = room;
            }
            err = SetFPos(s->dataRef, fsFromStart, pos - s->dataOff);
            if (err != noErr) {
                return err;
            }
            got = take;
            err = FSRead(s->dataRef, &got, out + done);
            if (err != noErr && err != eofErr) {
                return err;
            }
            take = got;
        } else if (pos < s->rsrcOff) {                 /* data-fork zero padding */
            take = s->rsrcOff - pos;
            if (take > room) {
                take = room;
            }
            memset(out + done, 0, (size_t)take);
        } else if (pos < s->rsrcOff + s->rsrcLen) {    /* rsrc fork (from disk) */
            long got;
            take = (s->rsrcOff + s->rsrcLen) - pos;
            if (take > room) {
                take = room;
            }
            err = SetFPos(s->rsrcRef, fsFromStart, pos - s->rsrcOff);
            if (err != noErr) {
                return err;
            }
            got = take;
            err = FSRead(s->rsrcRef, &got, out + done);
            if (err != noErr && err != eofErr) {
                return err;
            }
            take = got;
        } else if (pos < s->len) {                     /* rsrc-fork zero padding */
            take = s->len - pos;
            if (take > room) {
                take = room;
            }
            memset(out + done, 0, (size_t)take);
        } else {
            break;                                     /* past end of envelope */
        }
        if (take <= 0) {
            break;
        }
        done += take;
    }
    return noErr;
}

/* Publish g_xfer_buf[0..len) as the resident transfer; returns the handle id.
 * Producers pack their bytes into g_xfer_buf, then call this to stamp the id and
 * CRC. `chunk` is the producer's suggested page size (<=0 -> the default). */
static long xfer_commit(long len, long chunk)
{
    XferSlot *s = slot_resident();

    s->id    = ++g_xfer_seq;
    s->kind  = kSlotResident;
    s->len   = len;
    s->chunk = (chunk > 0) ? chunk : kXferChunk;
    s->crc   = wire_crc32(g_xfer_buf, (size_t)len);
    return s->id;
}

/* verb_capture */
static int verb_capture(char *out, size_t cap, long id,
                        const char *line, size_t len)
{
    static unsigned char caprow[kCapMaxDim * 2];  /* one extracted row, tight
                                                     (x2: a 16-bit row is two
                                                     bytes per pixel) */
    GDHandle     mainDev;
    PixMapHandle srcPM;
    PixMapHandle dstPM;
    CTabHandle   grayCT = NULL;
    GWorldPtr    gw = NULL;
    GWorldPtr    savePort;
    GDHandle     saveDev;
    QDErr        qerr;
    Rect         devRect;
    Rect         clip;
    Rect         srcRect;
    Rect         dstRect;
    long         l, t, r, b;
    long         scale = 1, depth = 8;
    int          dither = 0;
    int          regionW, regionH, dstW, dstH, bytesPerRow;
    long         perRowMax, packMax, packedLen;
    long         mode;
    size_t       used = 0;
    int          y;
    unsigned long t0;

    mainDev = GetMainDevice();
    if (mainDev == NULL) {
        return resp_error(out, cap, id, "qd_error", "no main device");
    }
    srcPM = (*mainDev)->gdPMap;
    devRect = (*mainDev)->gdRect;                /* global screen bounds */

    /* rect: default to the whole device if any bound is missing. */
    if (wire_find_int(line, len, "left", &l)
        && wire_find_int(line, len, "top", &t)
        && wire_find_int(line, len, "right", &r)
        && wire_find_int(line, len, "bottom", &b)) {
        SetRect(&clip, (short)l, (short)t, (short)r, (short)b);
        SectRect(&clip, &devRect, &clip);        /* clamp to the screen */
    } else {
        clip = devRect;
    }
    if (EmptyRect(&clip)) {
        return resp_error(out, cap, id, "bad_request", "rect off-screen or empty");
    }

    (void)wire_find_int(line, len, "scale", &scale);
    if (scale < 1) {
        scale = 1;
    }
    (void)wire_find_int(line, len, "depth", &depth);
    if (depth != 1 && depth != 8 && depth != 16) {
        return resp_error(out, cap, id, "bad_request",
                          "depth must be 1, 8 or 16");
    }
    (void)wire_find_bool(line, len, "dither", &dither);

    regionW = clip.right - clip.left;
    regionH = clip.bottom - clip.top;
    dstW = regionW / (int)scale;
    dstH = regionH / (int)scale;
    if (dstW < 1 || dstH < 1) {
        return resp_error(out, cap, id, "bad_request", "region smaller than scale");
    }
    if (dstW > kCapMaxDim || dstH > kCapMaxDim) {
        return resp_error(out, cap, id, "too_large", "crop side over 1024px");
    }

    /* depth 16 = full colour (RGB555 direct, big-endian - the native screen
     * format on our PPC targets); 8 = gray ramp (OCR); 1 = mono threshold.
     * A 16-bit full screen cannot fit the resident buffer - callers tile by
     * rect (bands) and stitch host-side. */
    bytesPerRow = (depth == 16) ? (dstW * 2)
                : (depth == 8) ? dstW
                : ((dstW + 7) / 8);
    /* PackBits emits at most n + ceil(n/127) bytes per row; make sure the whole
     * packed image cannot overrun the resident buffer BEFORE we allocate. */
    perRowMax = (long)bytesPerRow + ((long)bytesPerRow + 126) / 127;
    packMax = perRowMax * dstH;
    if (packMax > (long)sizeof(g_xfer_buf)) {
        return resp_error(out, cap, id, "too_large",
                          "crop exceeds resident buffer; scale or tile it");
    }

    t0 = TickCount();
    SetRect(&dstRect, 0, 0, dstW, dstH);
    /* srcRect: clip is global; main device origin is (0,0) on our targets. */
    srcRect = clip;

    if (depth == 8) {
        /* Build a 256-level gray ramp so CopyBits maps colour -> luminance. */
        int i;
        grayCT = (CTabHandle)NewHandleClear(
            (Size)(sizeof(ColorTable) + 255L * sizeof(ColorSpec)));
        if (grayCT == NULL) {
            return resp_error(out, cap, id, "qd_error", "gray CLUT alloc");
        }
        (**grayCT).ctSeed = GetCTSeed();
        (**grayCT).ctFlags = 0;
        (**grayCT).ctSize = 255;                 /* max index; 256 entries */
        for (i = 0; i < 256; i++) {
            (**grayCT).ctTable[i].value = (short)i;
            (**grayCT).ctTable[i].rgb.red = (unsigned short)(i * 257);
            (**grayCT).ctTable[i].rgb.green = (unsigned short)(i * 257);
            (**grayCT).ctTable[i].rgb.blue = (unsigned short)(i * 257);
        }
    }

    qerr = NewGWorld(&gw, (short)depth, &dstRect, grayCT, NULL, 0);
    if (grayCT != NULL) {
        DisposeHandle((Handle)grayCT);           /* NewGWorld copied it */
        grayCT = NULL;
    }
    if (qerr != noErr || gw == NULL) {
        return resp_error(out, cap, id, "qd_error", "NewGWorld failed");
    }

    GetGWorld(&savePort, &saveDev);
    SetGWorld(gw, NULL);
    dstPM = GetGWorldPixMap(gw);
    (void)LockPixels(dstPM);
    mode = dither ? ditherCopy : srcCopy;
    CopyBits((BitMap *)*srcPM, (BitMap *)*dstPM, &srcRect, &dstRect,
             (short)mode, NULL);
    SetGWorld(savePort, saveDev);

    /* Extract each row tight (dropping GWorld rowBytes padding) and PackBits it
     * straight into the resident buffer - no full-frame raw intermediate. */
    {
        Ptr  base = GetPixBaseAddr(dstPM);
        short rb = (short)((*dstPM)->rowBytes & 0x3FFF);
        Ptr  dp = (Ptr)g_xfer_buf;
        for (y = 0; y < dstH; y++) {
            Ptr sp = (Ptr)caprow;
            memcpy(caprow, base + y * rb, (size_t)bytesPerRow);
            PackBits(&sp, &dp, bytesPerRow);
        }
        packedLen = (long)(dp - (Ptr)g_xfer_buf);
    }
    UnlockPixels(dstPM);
    DisposeGWorld(gw);

    (void)xfer_commit(packedLen, kXferChunk);    /* publish; page with `fetch` */
    SHOT_LOG("capture: %dx%d depth=%d packed=%ld (%ld ticks)\n",
             dstW, dstH, (int)depth, packedLen, (long)(TickCount() - t0));

    if (!append(out, cap, &used,
        "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{"
        "\"origin\":{\"x\":%d,\"y\":%d},\"scale\":%d,\"depth\":%d,"
        "\"format\":\"%s\",\"width\":%d,\"height\":%d,\"rowBytes\":%d,"
        "\"srcDepth\":%d,\"compression\":\"packbits\","
        "\"handle\":%ld,\"bytes\":%ld,\"chunk\":%d,\"crc\":\"%08lx\","
        "\"encoding\":\"base64\"},\"backing\":\"" TBT_BACKING "\"}\n",
        id, (int)clip.left, (int)clip.top, (int)scale, (int)depth,
        (depth == 16) ? "rgb555be" : (depth == 8) ? "gray8" : "mono1",
        dstW, dstH, bytesPerRow,
        (int)(*srcPM)->pixelSize,
        slot_resident()->id, slot_resident()->len, (int)kXferChunk,
        slot_resident()->crc)) {
        return resp_error(out, cap, id, "overflow", "capture header");
    }
    return (int)used;
}

/* verb_fetch */
static int verb_fetch(char *out, size_t cap, long id,
                      const char *line, size_t len)
{
    XferSlot *s;
    long   hid = 0;
    long   offset = 0;
    long   maxBytes = 0;
    long   avail, n;
    size_t used = 0;
    int    e;

    (void)wire_find_int(line, len, "handle", &hid);
    (void)wire_find_int(line, len, "offset", &offset);
    (void)wire_find_int(line, len, "maxBytes", &maxBytes);

    s = slot_find(hid);
    if (s == NULL) {
        /* Not open: distinguish "superseded" (a newer transfer holds the resident
         * slot) from "nothing open" so the client knows whether to re-produce. */
        if (slot_resident()->id != 0) {
            return resp_error(out, cap, id, "stale_handle",
                              "handle superseded by a newer transfer");
        }
        return resp_error(out, cap, id, "bad_handle", "no open transfer");
    }
    if (s->kind != kSlotResident && s->kind != kSlotFileRead) {
        return resp_error(out, cap, id, "bad_handle",
                          "handle is not a readable transfer");
    }
    if (offset < 0) {
        offset = 0;
    }
    if (offset > s->len) {
        offset = s->len;
    }
    if (maxBytes <= 0 || maxBytes > s->chunk) {
        maxBytes = s->chunk;
    }
    avail = s->len - offset;
    n = (avail < maxBytes) ? avail : maxBytes;

    if (!append(out, cap, &used,
        "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{"
        "\"handle\":%ld,\"offset\":%ld,\"length\":%ld,\"bytes\":%ld,\"eof\":%s,"
        "\"encoding\":\"base64\",\"data\":\"",
        id, hid, offset, n, s->len,
        (offset + n >= s->len) ? "true" : "false")) {
        return resp_error(out, cap, id, "overflow", "fetch header");
    }
    if (s->kind == kSlotResident) {
        e = wire_base64(g_xfer_buf + offset, (size_t)n, out + used, cap - used);
    } else {                                     /* FILE_READ: page off disk */
        static unsigned char fbuf[kGetRawMax];
        if (envelope_read(s, offset, n, fbuf) != noErr) {
            return resp_error(out, cap, id, "io_error", "fork read");
        }
        e = wire_base64(fbuf, (size_t)n, out + used, cap - used);
    }
    if (e < 0) {
        return resp_error(out, cap, id, "overflow", "fetch data");
    }
    used += (size_t)e;
    if (!append(out, cap, &used, "\"},\"backing\":\"" TBT_BACKING "\"}\n")) {
        return resp_error(out, cap, id, "overflow", "fetch tail");
    }
    return (int)used;
}

/* put-path helpers, pulled in by put_commit */
/* Fork-copy / CRC streaming buffer: off-disk, O(1) RAM (lab verbs.c). */
#define kXferIO    2048

static OSErr xfer_copy(short srcRef, long srcOff, long n, short dstRef)
{
    static char buf[kXferIO];
    OSErr       err;

    err = SetFPos(srcRef, fsFromStart, srcOff);
    if (err != noErr) {
        return err;
    }
    while (n > 0) {
        long want = (n < (long)sizeof(buf)) ? n : (long)sizeof(buf);
        long got = want;

        err = FSRead(srcRef, &got, buf);
        if ((err != noErr && err != eofErr) || got <= 0) {
            return (err != noErr) ? err : ioErr;
        }
        {
            long put = got;
            err = FSWrite(dstRef, &put, buf);
            if (err != noErr) {
                return err;
            }
        }
        n -= got;
    }
    return noErr;
}

static OSErr xfer_temp_crc(short ref, long total, unsigned long *outCrc)
{
    static char   buf[kXferIO];
    unsigned long crc = 0xFFFFFFFFUL;
    OSErr         err;

    err = SetFPos(ref, fsFromStart, 0);
    if (err != noErr) {
        return err;
    }
    while (total > 0) {
        long want = (total < (long)sizeof(buf)) ? total : (long)sizeof(buf);
        long got = want;

        err = FSRead(ref, &got, buf);
        if ((err != noErr && err != eofErr) || got <= 0) {
            return (err != noErr) ? err : ioErr;
        }
        crc = wire_crc32_update(crc, (const unsigned char *)buf, (size_t)got);
        total -= got;
    }
    *outCrc = crc ^ 0xFFFFFFFFUL;
    return noErr;
}

static OSErr xfer_restore_dates(const FSSpec *spec, const MacBinInfo *mb)
{
    CInfoPBRec pb;
    Str255     name;
    OSErr      err;

    if (mb->created == 0 && mb->modified == 0) {
        return noErr;
    }
    BlockMoveData(spec->name, name, (long)spec->name[0] + 1);
    memset(&pb, 0, sizeof(pb));
    pb.hFileInfo.ioNamePtr   = name;
    pb.hFileInfo.ioVRefNum   = spec->vRefNum;
    pb.hFileInfo.ioDirID     = spec->parID;
    pb.hFileInfo.ioFDirIndex = 0;
    err = PBGetCatInfoSync(&pb);
    if (err != noErr) {
        return err;
    }
    /* PBGetCatInfo returns the FILE ID in ioDirID for a file (IM: Files);
     * PBSetCatInfo resolves ioNamePtr against ioDirID as a DIRECTORY, so the
     * clobbered field makes every set fail fnfErr -43 (the "catalog dates
     * err -43" every push reported). Restore the parent directory ID. */
    pb.hFileInfo.ioDirID = spec->parID;
    (void)macbin_merge_dates(mb, &pb.hFileInfo.ioFlCrDat,
                             &pb.hFileInfo.ioFlMdDat);
    return PBSetCatInfoSync(&pb);
}

/* put_commit */
static int put_commit(char *out, size_t cap, long id, XferSlot *s,
                      const char *line, size_t len)
{
    unsigned char hdr[kMacBinHeader];
    MacBinInfo    mb;
    char          crcArg[16];
    char          crcHex[16];
    char          dtype[32];
    char          dcreat[32];
    FSSpec        dst = s->dstSpec;
    long          hid = s->id;
    OSErr         err;
    unsigned long crc = 0;
    long          got;
    long          tempEof = 0;
    long          tCommit;                         /* ticks for the commit body   */
    long          nchunks  = s->chunks;            /* snapshot before slot_free    */
    long          tExtract = s->tExtract;
    long          tDecode  = s->tDecode;
    long          tWrite   = s->tWrite;
    long          tCrc;
    long          tMaterialize;
    int           crcIncremental;
    short         dref;
    int           nn;
    int           clen;
    char          msg[64];

    clen = wire_find_str(line, len, "crc", crcArg, sizeof(crcArg));
    if (clen == kWireOverflow) {
        /* Malformed, not an abort: keep the slot so the client can retry. */
        return resp_error(out, cap, id, "overflow", "crc too long");
    }
    if (clen < 0) {
        slot_free(s);                              /* no crc => client aborted */
        nn = snprintf(out, cap,
            "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{"
            "\"handle\":%ld,\"committed\":false,\"aborted\":true},"
            "\"backing\":\"" TBT_BACKING "\"}\n", id, hid);
        return (nn < 0 || (size_t)nn >= cap) ? -1 : nn;
    }

    (void)GetEOF(s->tmpRef, &tempEof);
    if (s->high != s->expect || tempEof != s->expect) {
        return resp_error(out, cap, id, "incomplete",
                          "upload not fully received");
    }

    err = SetFPos(s->tmpRef, fsFromStart, 0);
    got = kMacBinHeader;
    if (err == noErr) {
        err = FSRead(s->tmpRef, &got, (Ptr)hdr);
    }
    if (err != noErr || got != kMacBinHeader || macbin_parse(hdr, &mb) != 0) {
        return resp_error(out, cap, id, "bad_macbin",
                          "not a valid MacBinary stream");
    }
    if (mb.totalLen != s->expect) {
        return resp_error(out, cap, id, "bad_macbin",
                          "envelope length mismatch");
    }

    tCommit = (long)TickCount();
    tCrc = (long)TickCount();
    crcIncremental = xfer_crc_finish(&s->putCrc, s->expect, &crc);
    if (!crcIncremental
        && xfer_temp_crc(s->tmpRef, s->expect, &crc) != noErr) {
        return resp_error(out, cap, id, "io_error", "crc read");
    }
    tCrc = (long)TickCount() - tCrc;
    snprintf(crcHex, sizeof(crcHex), "%08lx", crc);
    if (strcmp(crcArg, crcHex) != 0) {
        return resp_error(out, cap, id, "crc_mismatch",
                          "stream crc disagreed (temp kept)");
    }

    /* Commit: recreate the target with both forks + Finder info. */
    tMaterialize = (long)TickCount();
    (void)FSpDelete(&dst);                         /* overwrite (checked at open) */
    err = FSpCreate(&dst, mb.creator, mb.type, smSystemScript);
    if (err != noErr) {
        snprintf(msg, sizeof(msg), "create err %d", (int)err);
        return resp_error(out, cap, id, "io_error", msg);
    }
    err = FSpOpenDF(&dst, fsWrPerm, &dref);
    if (err == noErr) {
        err = xfer_copy(s->tmpRef, mb.dataOff, mb.dataLen, dref);
        (void)FSClose(dref);
    }
    if (err != noErr) {
        snprintf(msg, sizeof(msg), "data fork err %d", (int)err);
        return resp_error(out, cap, id, "io_error", msg);
    }
    if (mb.rsrcLen > 0) {
        err = FSpOpenRF(&dst, fsWrPerm, &dref);
        if (err == noErr) {
            err = xfer_copy(s->tmpRef, mb.rsrcOff, mb.rsrcLen, dref);
            (void)FSClose(dref);
        }
        if (err != noErr) {
            snprintf(msg, sizeof(msg), "rsrc fork err %d", (int)err);
            return resp_error(out, cap, id, "io_error", msg);
        }
    }
    {
        FInfo fi;
        if (FSpGetFInfo(&dst, &fi) == noErr) {
            fi.fdFlags = mb.finderFlags;
            (void)FSpSetFInfo(&dst, &fi);
        }
    }
    err = xfer_restore_dates(&dst, &mb);
    if (err != noErr) {
        snprintf(msg, sizeof(msg), "catalog dates err %d", (int)err);
        return resp_error(out, cap, id, "io_error", msg);
    }
    tMaterialize = (long)TickCount() - tMaterialize;

    tCommit = (long)TickCount() - tCommit;
    ostype_escape(mb.type, dtype, sizeof(dtype));
    ostype_escape(mb.creator, dcreat, sizeof(dcreat));
    slot_free(s);                                  /* closes temp ref + deletes it */
    /* Commit both forks + the catalog entry to the volume now. A pushed file
     * (e.g. a staged INIT) must survive a cold power-off; without this it can
     * sit in the volume cache and be lost on a QMP `quit`
     * (qdpeek-guest-staging-does-not-persist). */
    (void)FlushVol(NULL, dst.vRefNum);

    /* `ticks*` are 60.15 Hz TickCount sums (guest-side, whole transfer); the host
     * divides by `chunks` and subtracts from its measured wall time to see how
     * much of the transfer is the guest working vs. waiting on the wire/poll. */
    nn = snprintf(out, cap,
        "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{"
        "\"handle\":%ld,\"committed\":true,\"dataSize\":%ld,\"rsrcSize\":%ld,"
        "\"type\":\"%s\",\"creator\":\"%s\",\"chunks\":%ld,"
        "\"ticksExtract\":%ld,\"ticksDecode\":%ld,\"ticksWrite\":%ld,"
        "\"ticksCRC\":%ld,\"ticksMaterialize\":%ld,"
        "\"crcMode\":\"%s\",\"ticksCommit\":%ld},"
        "\"backing\":\"" TBT_BACKING "\"}\n",
        id, hid, mb.dataLen, mb.rsrcLen, dtype, dcreat, nchunks,
        tExtract, tDecode, tWrite, tCrc, tMaterialize,
        crcIncremental ? "incremental" : "reread", tCommit);
    return (nn < 0 || (size_t)nn >= cap) ? -1 : nn;
}

/* verb_close */
static int verb_close(char *out, size_t cap, long id,
                      const char *line, size_t len)
{
    XferSlot *s;
    long hid = 0;
    int  n;

    (void)wire_find_int(line, len, "handle", &hid);
    s = slot_find(hid);
    if (s == NULL) {
        n = snprintf(out, cap,
            "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{"
            "\"handle\":%ld,\"freed\":false},\"backing\":\"" TBT_BACKING "\"}\n",
            id, hid);
        return (n < 0 || (size_t)n >= cap) ? -1 : n;
    }
    if (s->kind == kSlotFileWrite) {
        return put_commit(out, cap, id, s, line, len);
    }
    slot_free(s);
    n = snprintf(out, cap,
        "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{"
        "\"handle\":%ld,\"freed\":true},\"backing\":\"" TBT_BACKING "\"}\n",
        id, hid);
    return (n < 0 || (size_t)n >= cap) ? -1 : n;
}


/* --- the QuickDraw plane: qdtrace ------------------------------------------
 *
 * Carried from the lab 2026-07-30, and the reason the pixel plane goes from
 * correct-at-capture to LIVE.
 *
 * The host does not use this to draw. It uses it to know WHEN to redraw: the
 * op stream tells ScenePoller that a window repainted (a content-sized blit)
 * so an island is re-captured only then, and it exposes screen-to-screen moves
 * so a scroll can be served by shifting pixels the host already holds and
 * fetching just the exposed band. Without it `lastBlitTick` is always 0, the
 * cache key never changes, and an interior freezes at its first capture.
 *
 * Requires the QDPeek INIT (guest/extensions/qdpeek) to be installed and
 * loaded at boot; qd_shared() locates its block via Gestalt('TBqd') and
 * range-checks it against the system heap before any dereference — the same
 * discipline the AXPeek oracle uses. A NULL return means the INIT is not live,
 * and the verb says so rather than guessing.
 */
/* Locate the QDPeek shared block via Gestalt('TBqd'), range-checked against the
 * system heap before any dereference — same discipline as the AXPeek oracle. A
 * NULL return means the INIT isn't installed/live. */
static volatile QDShared *qd_shared(void)
{
    long          response = 0;
    THz           system_zone;
    unsigned long system_lo, system_hi, addr;

    if (Gestalt(QD_GESTALT, &response) != noErr || response <= 0) {
        return NULL;
    }
    system_zone = LMGetSysZone();
    if (system_zone == NULL) {
        return NULL;
    }
    system_lo = (unsigned long)system_zone;
    system_hi = (unsigned long)system_zone->bkLim;
    addr = (unsigned long)response;
    if (system_hi <= system_lo || addr < system_lo
        || addr > system_hi - sizeof(QDShared)) {
        return NULL;
    }
    return (volatile QDShared *)addr;
}

/* qdtrace - drive the QDPeek QuickDraw-capture INIT (QDPEEK-SPEC.md).
 *   cmd=status                          -> counters + command state
 *   cmd=start serialHi serialLo [mode]  -> install hooks on that app (mode
 *                                          count|record; M0 honors count)
 *   cmd=stop                            -> uninstall
 * start/stop write the command block and bump cmdSeq; the INIT applies it at
 * the traced app's next event-loop moment (poll status.applied). */
static int verb_qdtrace(char *out, size_t cap, long id,
                        const char *line, size_t len)
{
    char               cmd[16];
    int                cmd_len;
    volatile QDShared *qd;
    size_t             used = 0;
    long               hi = 0, lo = 0;
    char               mode_str[8];
    unsigned long      mode;

    cmd_len = wire_find_str(line, len, "cmd", cmd, sizeof(cmd));
    if (cmd_len < 0) {
        strcpy(cmd, "status");
    }

    qd = qd_shared();
    if (qd == NULL) {
        return resp_error(out, cap, id, "qd_not_found",
                          "QDPeek INIT not installed or not live");
    }
    if (qd->magic != QD_MAGIC || qd->version != QD_VERSION) {
        return resp_error(out, cap, id, "qd_invalid",
                          "QDPeek shared block magic/version mismatch");
    }

    if (strcmp(cmd, "start") == 0) {
        (void)wire_find_int(line, len, "serialHi", &hi);
        (void)wire_find_int(line, len, "serialLo", &lo);
        mode = QD_MODE_COUNT;
        if (wire_find_str(line, len, "mode", mode_str, sizeof(mode_str)) >= 0
            && strcmp(mode_str, "record") == 0) {
            mode = QD_MODE_RECORD;
        }
        qd->cmd.mode  = mode;
        qd->cmd.psnHi = (uint32_t)hi;
        qd->cmd.psnLo = (uint32_t)lo;
        qd->cmd.cmdSeq++;                    /* handshake: INIT acks in-context */
        if (!append(out, cap, &used,
            "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{"
            "\"requested\":true,\"cmd\":\"start\",\"mode\":%lu,"
            "\"cmdSeq\":%lu},\"backing\":\"" TBT_BACKING "\"}\n",
            id, (unsigned long)mode, (unsigned long)qd->cmd.cmdSeq)) {
            return resp_error(out, cap, id, "overflow", "qdtrace start");
        }
        return (int)used;
    }

    if (strcmp(cmd, "stop") == 0) {
        qd->cmd.mode = QD_MODE_OFF;
        qd->cmd.cmdSeq++;
        if (!append(out, cap, &used,
            "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{"
            "\"requested\":true,\"cmd\":\"stop\",\"cmdSeq\":%lu},"
            "\"backing\":\"" TBT_BACKING "\"}\n",
            id, (unsigned long)qd->cmd.cmdSeq)) {
            return resp_error(out, cap, id, "overflow", "qdtrace stop");
        }
        return (int)used;
    }

    /* fetch: drain ring records since the client's `cursor` (its last
     * nextCursor). Decodes TEXT records fully; other ops minimally (record
     * mode only writes TEXT in M1). The guest isn't running during a fetch
     * (cooperative), so the ring is static — records below writeCursor are
     * complete. Overrun (writeCursor - cursor > ringCap) => resync. */
    if (strcmp(cmd, "fetch") == 0) {
        const unsigned char *ring = (const unsigned char *)qd->ring;
        unsigned long ringcap = qd->ringCap;
        unsigned long wc = qd->writeCursor;
        long cursor_l = 0, max_l = 8192;
        unsigned long cursor, budget, consumed = 0;
        int first = 1, resync = 0;

        (void)wire_find_int(line, len, "cursor", &cursor_l);
        (void)wire_find_int(line, len, "maxBytes", &max_l);
        cursor = (unsigned long)cursor_l;
        if (cursor > wc || wc - cursor > ringcap) {   /* stale/overrun */
            /* Resync to live rather than to (wc - ringcap): the latter can
             * land mid-record and decode garbage. The reader lost the window;
             * resume from now and report resync. The `dropped` counter and
             * writeCursor let the host quantify the gap. */
            cursor = wc;
            resync = 1;
        }
        budget = wc - cursor;
        if (max_l > 0 && (unsigned long)max_l < budget) {
            budget = (unsigned long)max_l;
        }

        if (!append(out, cap, &used,
            "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{\"ops\":[",
            id)) {
            return resp_error(out, cap, id, "overflow", "qdtrace fetch head");
        }

        while (consumed < budget) {
            unsigned long pos = (cursor + consumed) % ringcap;
            const QDRecHeader *h = (const QDRecHeader *)(ring + pos);
            unsigned short rsize = h->size;
            size_t before = used;

            if (rsize < sizeof(QDRecHeader) || rsize > ringcap
                || consumed + rsize > budget) {
                break;                        /* corrupt or would split: stop */
            }
            /* Reserve room for the biggest op JSON (a full-text record) plus
             * the tail, so the response never overflows. Output size, not ring
             * bytes, is the real fetch limit — the client re-fetches from
             * nextCursor. */
            if (used + (QD_TEXT_MAX * 6 + 256) > cap) {
                break;
            }
            if (h->op == QD_OP_WRAP) {
                consumed += rsize;
                continue;
            }
            if (h->op == QD_OP_TEXT) {
                const QDTextPayload *tp =
                    (const QDTextPayload *)(ring + pos + sizeof(QDRecHeader));
                const char *bytes =
                    (const char *)(ring + pos + sizeof(QDRecHeader)
                                   + sizeof(QDTextPayload));
                char tesc[QD_TEXT_MAX * 6 + 1];
                if (wire_escape(bytes, (size_t)tp->len, tesc,
                                sizeof(tesc)) < 0) {
                    tesc[0] = '\0';
                }
                if (!append(out, cap, &used,
                    "%s{\"op\":\"text\",\"port\":\"0x%08lx\",\"ticks\":%lu,"
                    "\"pen\":[%d,%d],\"font\":%u,\"size\":%u,\"face\":%u,"
                    "\"len\":%u,\"fullLen\":%u,\"trunc\":%s,\"text\":\"%s\"}",
                    first ? "" : ",", (unsigned long)h->port,
                    (unsigned long)h->ticks,
                    (int)tp->penH, (int)tp->penV, (unsigned)tp->txFont,
                    (unsigned)tp->txSize, (unsigned)tp->txFace,
                    (unsigned)tp->len, (unsigned)tp->fullLen,
                    (h->flags & QD_FLAG_TRUNC_TEXT) ? "true" : "false", tesc)) {
                    used = before;            /* out full: stop cleanly here */
                    break;
                }
            } else if (h->op == QD_OP_LINE) {
                const QDLinePayload *lp =
                    (const QDLinePayload *)(ring + pos + sizeof(QDRecHeader));
                if (!append(out, cap, &used,
                    "%s{\"op\":\"line\",\"port\":\"0x%08lx\",\"ticks\":%lu,"
                    "\"from\":[%d,%d],\"to\":[%d,%d],\"pen\":[%d,%d]}",
                    first ? "" : ",", (unsigned long)h->port,
                    (unsigned long)h->ticks, (int)lp->fromH, (int)lp->fromV,
                    (int)lp->toH, (int)lp->toV, (int)lp->pnH, (int)lp->pnV)) {
                    used = before; break;
                }
            } else if (h->op == QD_OP_RECT || h->op == QD_OP_RRECT
                       || h->op == QD_OP_OVAL || h->op == QD_OP_ARC
                       || h->op == QD_OP_POLY || h->op == QD_OP_RGN) {
                const QDRectPayload *rp =
                    (const QDRectPayload *)(ring + pos + sizeof(QDRecHeader));
                const char *opn =
                    (h->op == QD_OP_RECT)  ? "rect"  :
                    (h->op == QD_OP_RRECT) ? "rrect" :
                    (h->op == QD_OP_OVAL)  ? "oval"  :
                    (h->op == QD_OP_ARC)   ? "arc"   :
                    (h->op == QD_OP_POLY)  ? "poly"  : "rgn";
                if (!append(out, cap, &used,
                    "%s{\"op\":\"%s\",\"port\":\"0x%08lx\",\"ticks\":%lu,"
                    "\"verb\":%u,\"rect\":[%d,%d,%d,%d],\"ext\":[%d,%d]}",
                    first ? "" : ",", opn, (unsigned long)h->port,
                    (unsigned long)h->ticks, (unsigned)rp->verb,
                    (int)rp->l, (int)rp->t, (int)rp->r, (int)rp->b,
                    (int)rp->ext1, (int)rp->ext2)) {
                    used = before; break;
                }
            } else if (h->op == QD_OP_STATE) {
                const QDStatePayload *sp =
                    (const QDStatePayload *)(ring + pos + sizeof(QDRecHeader));
                const char *kn =
                    (sp->kind == QD_STATE_CLIP)   ? "clip"   :
                    (sp->kind == QD_STATE_ORIGIN) ? "origin" :
                    (sp->kind == QD_STATE_FG)     ? "fg"     :
                    (sp->kind == QD_STATE_BG)     ? "bg"     : "?";
                if (sp->kind == QD_STATE_CLIP) {
                    if (!append(out, cap, &used,
                        "%s{\"op\":\"state\",\"kind\":\"clip\",\"port\":\"0x%08lx\","
                        "\"ticks\":%lu,\"rect\":[%d,%d,%d,%d]}",
                        first ? "" : ",", (unsigned long)h->port,
                        (unsigned long)h->ticks,
                        (int)sp->a, (int)sp->b, (int)sp->c, (int)sp->d)) {
                        used = before; break;
                    }
                } else if (sp->kind == QD_STATE_ORIGIN) {
                    if (!append(out, cap, &used,
                        "%s{\"op\":\"state\",\"kind\":\"origin\",\"port\":\"0x%08lx\","
                        "\"ticks\":%lu,\"origin\":[%d,%d]}",
                        first ? "" : ",", (unsigned long)h->port,
                        (unsigned long)h->ticks, (int)sp->a, (int)sp->b)) {
                        used = before; break;
                    }
                } else {   /* fg / bg: RGBColor components are unsigned */
                    if (!append(out, cap, &used,
                        "%s{\"op\":\"state\",\"kind\":\"%s\",\"port\":\"0x%08lx\","
                        "\"ticks\":%lu,\"rgb\":[%u,%u,%u]}",
                        first ? "" : ",", kn, (unsigned long)h->port,
                        (unsigned long)h->ticks, (unsigned)(uint16_t)sp->a,
                        (unsigned)(uint16_t)sp->b, (unsigned)(uint16_t)sp->c)) {
                        used = before; break;
                    }
                }
            } else if (h->op == QD_OP_BITS) {
                const QDBitsPayload *bp =
                    (const QDBitsPayload *)(ring + pos + sizeof(QDRecHeader));
                if (!append(out, cap, &used,
                    "%s{\"op\":\"bits\",\"port\":\"0x%08lx\",\"ticks\":%lu,"
                    "\"src\":[%d,%d,%d,%d],\"dst\":[%d,%d,%d,%d],"
                    "\"mode\":%u,\"srcRowBytes\":%u}",
                    first ? "" : ",", (unsigned long)h->port,
                    (unsigned long)h->ticks,
                    (int)bp->sl, (int)bp->st, (int)bp->sr, (int)bp->sb,
                    (int)bp->dl, (int)bp->dt, (int)bp->dr, (int)bp->db,
                    (unsigned)bp->mode, (unsigned)bp->srcRowBytes)) {
                    used = before; break;
                }
            } else {
                if (!append(out, cap, &used,
                    "%s{\"op\":%u,\"port\":\"0x%08lx\",\"ticks\":%lu}",
                    first ? "" : ",", (unsigned)h->op,
                    (unsigned long)h->port, (unsigned long)h->ticks)) {
                    used = before;
                    break;
                }
            }
            consumed += rsize;
            first = 0;
        }

        if (!append(out, cap, &used,
            "],\"nextCursor\":%lu,\"resync\":%s,\"dropped\":%lu,"
            "\"writeCursor\":%lu},\"backing\":\"" TBT_BACKING "\"}\n",
            (unsigned long)(cursor + consumed), resync ? "true" : "false",
            (unsigned long)qd->counters.dropped, (unsigned long)wc)) {
            return resp_error(out, cap, id, "overflow", "qdtrace fetch tail");
        }
        return (int)used;
    }

    /* status (default): counters + command state. Counters are individually
     * aligned u32 writes (atomic on this target); a coarse read is fine for
     * the M0 rate table. */
    if (!append(out, cap, &used,
        "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{"
        "\"present\":true,\"version\":%lu,\"mode\":%lu,"
        "\"psn\":{\"hi\":%lu,\"lo\":%lu},"
        "\"applied\":%s,\"ticks\":%lu,\"cursor\":%lu,\"ringCap\":%lu,"
        "\"counters\":{\"text\":%lu,\"line\":%lu,\"rect\":%lu,\"rrect\":%lu,"
        "\"oval\":%lu,\"arc\":%lu,\"poly\":%lu,\"rgn\":%lu,\"bits\":%lu,"
        "\"comment\":%lu,\"other\":%lu,\"dropped\":%lu,\"skippedPorts\":%lu,"
        "\"installs\":%lu,\"uninstalls\":%lu,\"repairs\":%lu,"
        "\"cmdApplies\":%lu}},\"backing\":\"" TBT_BACKING "\"}\n",
        id, (unsigned long)qd->version, (unsigned long)qd->cmd.mode,
        (unsigned long)qd->cmd.psnHi, (unsigned long)qd->cmd.psnLo,
        (qd->cmd.cmdSeq == qd->cmd.ackSeq) ? "true" : "false",
        (unsigned long)qd->ticks, (unsigned long)qd->writeCursor,
        (unsigned long)qd->ringCap,
        (unsigned long)qd->counters.text, (unsigned long)qd->counters.line,
        (unsigned long)qd->counters.rect, (unsigned long)qd->counters.rrect,
        (unsigned long)qd->counters.oval, (unsigned long)qd->counters.arc,
        (unsigned long)qd->counters.poly, (unsigned long)qd->counters.rgn,
        (unsigned long)qd->counters.bits, (unsigned long)qd->counters.comment,
        (unsigned long)qd->counters.other, (unsigned long)qd->counters.dropped,
        (unsigned long)qd->counters.skippedPorts,
        (unsigned long)qd->counters.installs,
        (unsigned long)qd->counters.uninstalls,
        (unsigned long)qd->counters.repairs,
        (unsigned long)qd->counters.cmdApplies)) {
        return resp_error(out, cap, id, "overflow", "qdtrace status");
    }
    return (int)used;
}

/* --- the journaling mechanism: phase 1, what exists ----------------------- */

/* journalprobe: does this machine still HAVE the Event Manager's journaling
 * mechanism, and is anything using it?
 *
 * Why this verb exists. The lab excluded the journaling driver from the input
 * plane on a secondhand report — Advanced Mac Substitute's finding that the
 * driver is "broken and unusable under System 7's multi-tasking" — and that
 * report closed the question for OS 9.1 without anyone measuring it here
 * (finding input-injection-postevent-not-journal, evidence
 * "memory:timbottu-harness-state"). The exclusion may well be right. It is
 * currently inherited rather than known, and the alternative it selected turns
 * out to have a ceiling of its own (~9 actuations per boot).
 *
 * This verb is the cheap half of settling it, and it is strictly read-only:
 * report the two low-memory globals, and ask the Device Manager whether a
 * '.Journal' driver can be opened at all. It does NOT arm journaling — writing
 * JournalFlag is a separate, dangerous act that belongs behind its own verb,
 * its own emulator-only gate, and a recovery plan.
 *
 * A note on OpenDriver: opening a driver is not the same as enabling it. The
 * journal device only becomes live when JournalFlag says so, which we do not
 * touch. If the open succeeds we close it again immediately. */
static int verb_journalprobe(char *out, size_t cap, long id)
{
    SInt16 flag;
    SInt16 ref;
    SInt16 drvrRef = 0;
    OSErr  openErr;
    int    closed = 0;
    int    n;

    flag = kLMJournalFlag;
    ref  = kLMJournalRef;

    openErr = OpenDriver("\p.Journal", &drvrRef);
    if (openErr == noErr) {
        /* Leave the machine exactly as we found it. */
        closed = (CloseDriver(drvrRef) == noErr);
    }

    n = snprintf(out, cap,
        "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{"
        "\"journalFlag\":%d,\"journalRef\":%d,"
        "\"driverPresent\":%s,\"openErr\":%d,\"driverRefNum\":%d,"
        "\"reclosed\":%s,\"armed\":false},"
        "\"backing\":\"" TBT_BACKING "\"}\n",
        id, (int)flag, (int)ref,
        openErr == noErr ? "true" : "false",
        (int)openErr, (int)drvrRef,
        closed ? "true" : "false");
    return (n < 0 || (size_t)n >= cap) ? -1 : n;
}


/* --- the Portal: acting from inside the target process --------------------- */
/*
 * `menugeom` — what a menu's items ACTUALLY are, asked of the target's own Menu
 * Manager.
 *
 * This exists because computing menu geometry from outside is not possible and
 * guessing it is wrong. The host assumed uniform 16 px rows; a standard menu
 * draws separators shorter, so every item below one resolved to a different row
 * and selection hit the wrong command. Nothing in `axtree`'s menu data carries
 * geometry — items report index, title, enabled, command, mark, icon, style and
 * nothing spatial — because from outside the process there is nothing to report.
 *
 * The Portal INIT runs inside every application via the same GNEFilter window
 * AXPeek uses to read per-process roots. We post a request addressed to the
 * target's A5 world; the next time that application pumps its event loop, the
 * hook is running AS that process and can call the menu's own MDEF with
 * mCalcItemMsg for each item. The answer is the Menu Manager's, not ours.
 *
 * A5 rather than PSN is the address because inside the hook the current A5 world
 * is one low-memory read while a PSN would need Process Manager calls that are
 * not safe there. The caller does not have to know that: this verb takes a PSN
 * like every other AX verb and resolves it through the AXPeek oracle, which
 * already publishes A5 per process — that is what the oracle is for.
 */
static volatile PTShared *pt_shared(void)
{
    long response = 0;

    if (Gestalt(PT_GESTALT, &response) != noErr || response == 0) {
        return NULL;
    }
    return (volatile PTShared *)(unsigned long)response;
}

static int verb_menugeom(char *out, size_t cap, long id,
                         const char *line, size_t len)
{
    volatile PTShared  *pt;
    PTShared            snap;
    static ax_target    target;      /* keep the big record off the stack */
    ProcessSerialNumber psn;
    const char         *err_code = NULL;
    const char         *err_msg = NULL;
    long                menu_id = 0;
    uint32_t            hi = 0, lo = 0;
    unsigned long       a5;
    unsigned long       deadline;
    size_t              used = 0;
    int                 i;

    pt = pt_shared();
    if (pt == NULL) {
        return resp_error(out, cap, id, "portal_absent",
                          "the Portal INIT is not installed or not live");
    }
    if (pt->magic != PT_MAGIC) {
        return resp_error(out, cap, id, "portal_absent",
                          "Gestalt answered but the block is not a Portal");
    }
    if (!pt->enabled) {
        return resp_error(out, cap, id, "portal_disabled",
                          "the Portal is installed but bypassed - "
                          "enable it with `portal {enabled:true}`");
    }
    if (!wire_find_int(line, len, "menuID", &menu_id)) {
        return resp_error(out, cap, id, "bad_request", "missing menuID");
    }
    /* Resolve the target the same way every other AX verb does: a PSN on the
     * wire, an A5 world out of the oracle. Defaults to the front process. */
    if (wire_find_u32(line, len, "serialHi", &hi)
        && wire_find_u32(line, len, "serialLo", &lo)) {
        psn.highLongOfPSN = hi;
        psn.lowLongOfPSN = lo;
        if (!ax_open_target(&target, &psn, NULL, 1, &err_code, &err_msg)) {
            return resp_error(out, cap, id, err_code, err_msg);
        }
    } else if (!ax_open_target(&target, NULL, NULL, 1, &err_code, &err_msg)) {
        return resp_error(out, cap, id, err_code, err_msg);
    }
    a5 = (unsigned long)target.sample.currentA5;
    if (a5 == 0) {
        return resp_error(out, cap, id, "ax_oracle_not_found",
                          "no AXPeek A5 sample for that process");
    }

    /* Post the request. Only one is in flight at a time by design: this is a
     * single-consumer channel and the caller is the mirror's one wire client. */
    pt->op = PT_OP_MENU_GEOMETRY;
    pt->menuID = (int32_t)menu_id;
    pt->targetA5 = (uint32_t)a5;
    pt->error = PT_ERR_NONE;
    pt->itemCount = 0;
    pt->status = PT_STATUS_PENDING;

    /* Wait for the target to pump its event loop — and YIELD while waiting.
     *
     * This is cooperative multitasking: spinning here would hold the CPU in OUR
     * process, so the target would never run, never call GetNextEvent, and never
     * serve the request. A busy-wait doesn't just waste time, it guarantees the
     * timeout it is waiting through. (Measured: a spin loop timed out at 2 s
     * every time; yielding serves in a couple of ticks.)
     *
     * WaitNextEvent with an event mask of ZERO is the documented way to give up
     * the processor without dequeuing anything — we want the scheduler, not the
     * events, and stealing an event here would break the app we are mirroring.
     * Bound it regardless: a frontmost app answers immediately, a suspended one
     * may never, and saying so beats hanging the wire. */
    deadline = (unsigned long)LMGetTicks() + 300UL;      /* ~5 s */
    while (pt->status == PT_STATUS_PENDING
           && (unsigned long)LMGetTicks() < deadline) {
        EventRecord ev;
        (void)WaitNextEvent(0, &ev, 2L, NULL);
    }
    if (pt->status == PT_STATUS_PENDING) {
        pt->status = PT_STATUS_IDLE;                     /* withdraw it */
        return resp_error(out, cap, id, "portal_timeout",
                          "the target did not pump its event loop in ~2 s");
    }

    /* Seqlock read: retry while the writer is mid-update. */
    for (i = 0; i < 8; i++) {
        uint32_t before = pt->seq;
        if ((before & 1UL) != 0) {
            continue;
        }
        BlockMoveData((Ptr)pt, (Ptr)&snap, (Size)sizeof(snap));
        if (pt->seq == before) {
            break;
        }
    }
    pt->status = PT_STATUS_IDLE;

    if (snap.status == PT_STATUS_ERROR) {
        return resp_error(out, cap, id,
                          snap.error == PT_ERR_NO_MENU ? "no_such_menu"
                          : snap.error == PT_ERR_NO_MDEF ? "no_mdef"
                          : "portal_error",
                          "the target's Menu Manager refused the request");
    }
    if (snap.itemCount > PT_MAX_ITEMS) {
        snap.itemCount = PT_MAX_ITEMS;
    }

    if (!append(out, cap, &used,
                "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{"
                "\"menuID\":%ld,\"servedA5\":%lu,\"servedTicks\":%lu,"
                "\"menuWidth\":%d,\"menuHeight\":%d,\"items\":[",
                id, menu_id, (unsigned long)snap.servedA5,
                (unsigned long)snap.servedTicks,
                (int)snap.menuWidth, (int)snap.menuHeight)) {
        return resp_error(out, cap, id, "overflow", "menugeom header");
    }
    for (i = 0; i < (int)snap.itemCount; i++) {
        if (!append(out, cap, &used,
                    "%s{\"index\":%d,\"rect\":[%d,%d,%d,%d]}",
                    i == 0 ? "" : ",", i + 1,
                    (int)snap.items[i].left, (int)snap.items[i].top,
                    (int)snap.items[i].right, (int)snap.items[i].bottom)) {
            return resp_error(out, cap, id, "overflow", "menugeom items");
        }
    }
    if (!append(out, cap, &used, "]},\"backing\":\"" TBT_BACKING "\"}\n")) {
        return resp_error(out, cap, id, "overflow", "menugeom tail");
    }
    return (int)used;
}


/*
 * `menuinvoke` — perform a menu command the way the application would.
 *
 * The app's own path is: a mouseDown in the menu bar, then MenuSelect, then its
 * own command handler on the packed (menuID, item). We do not simulate a user
 * well enough to fool it — we let it run its handler and simply answer the
 * question it asks along the way.
 *
 * Sequence: arm the Portal's guarded MenuSelect patch IN THE TARGET (which also
 * proves the target is alive and pumping), then post a mouseDown on the menu
 * title, because MenuSelect is only called in response to one. The patch returns
 * our item immediately: no menu is drawn, no tracking loop runs, nothing depends
 * on mouse motion or timing, and nothing here is emulator-only.
 *
 * This is the verb that makes a shortcut-less item reachable. A ⌘ item should
 * still go through `key` — it is simpler and needs no patch at all.
 */
static int verb_menuinvoke(char *out, size_t cap, long id,
                           const char *line, size_t len)
{
    volatile PTShared  *pt;
    static ax_target    target;
    ProcessSerialNumber psn;
    const char         *err_code = NULL;
    const char         *err_msg = NULL;
    long                menu_id = 0;
    long                item_index = 0;
    long                title_left = 0;
    uint32_t            hi = 0, lo = 0;
    unsigned long       a5;
    unsigned long       deadline;
    int                 n;

    pt = pt_shared();
    if (pt == NULL || pt->magic != PT_MAGIC) {
        return resp_error(out, cap, id, "portal_absent",
                          "the Portal INIT is not installed or not live");
    }
    if (!pt->enabled) {
        return resp_error(out, cap, id, "portal_disabled",
                          "the Portal is installed but bypassed - "
                          "enable it with `portal {enabled:true}`");
    }
    if (!wire_find_int(line, len, "menuID", &menu_id)
        || !wire_find_int(line, len, "item", &item_index)) {
        return resp_error(out, cap, id, "bad_request",
                          "need menuID and item (1-based)");
    }
    /* Where to click to make the app call MenuSelect. The menu bar title's left
     * edge is the one coordinate we DO know reliably — axtree reports it. */
    if (!wire_find_int(line, len, "titleLeft", &title_left)) {
        return resp_error(out, cap, id, "bad_request",
                          "need titleLeft (the menu title's x, from axtree)");
    }

    if (wire_find_u32(line, len, "serialHi", &hi)
        && wire_find_u32(line, len, "serialLo", &lo)) {
        psn.highLongOfPSN = hi;
        psn.lowLongOfPSN = lo;
        if (!ax_open_target(&target, &psn, NULL, 1, &err_code, &err_msg)) {
            return resp_error(out, cap, id, err_code, err_msg);
        }
    } else if (!ax_open_target(&target, NULL, NULL, 1, &err_code, &err_msg)) {
        return resp_error(out, cap, id, err_code, err_msg);
    }
    a5 = (unsigned long)target.sample.currentA5;
    if (a5 == 0) {
        return resp_error(out, cap, id, "ax_oracle_not_found",
                          "no AXPeek A5 sample for that process");
    }

    /* 1. Arm, in the target's context. */
    pt->op = PT_OP_MENU_INVOKE;
    pt->menuID = (int32_t)menu_id;
    pt->itemIndex = (int32_t)item_index;
    pt->targetA5 = (uint32_t)a5;
    pt->error = PT_ERR_NONE;
    pt->armed = 0;
    pt->fired = 0;
    pt->status = PT_STATUS_PENDING;

    deadline = (unsigned long)LMGetTicks() + 300UL;
    while (pt->status == PT_STATUS_PENDING
           && (unsigned long)LMGetTicks() < deadline) {
        EventRecord ev;
        (void)WaitNextEvent(0, &ev, 2L, NULL);   /* yield; never spin */
    }
    if (pt->status != PT_STATUS_DONE || !pt->armed) {
        pt->status = PT_STATUS_IDLE;
        pt->armed = 0;
        return resp_error(out, cap, id,
                          pt->error == PT_ERR_NO_PATCH ? "no_patch"
                                                       : "portal_timeout",
                          "the target did not arm (not pumping, or no patch)");
    }

    /* 2. Post the mouseDown that makes the app call MenuSelect. The menubar is
     * 20 px tall; aim at its middle. */
    (void)post_click_at((short)(title_left + 4), 10, 1, 0);

    /* 3. Wait for the patch to answer. */
    deadline = (unsigned long)LMGetTicks() + 300UL;
    while (!pt->fired && (unsigned long)LMGetTicks() < deadline) {
        EventRecord ev;
        (void)WaitNextEvent(0, &ev, 2L, NULL);
    }
    if (!pt->fired) {
        pt->armed = 0;                  /* never leave a patch armed */
        pt->status = PT_STATUS_IDLE;
        return resp_error(out, cap, id, "not_taken",
                          "armed, but the app never called MenuSelect");
    }
    pt->status = PT_STATUS_IDLE;

    n = snprintf(out, cap,
        "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{"
        /* `answered`, not `performed`: what we know is that the application's
         * MenuSelect returned our item. Whether its command handler then did
         * what the caller wanted is the CALLER's to verify against guest state.
         * Reporting the stronger claim is how an ABI bug stayed invisible. */
        "\"menuID\":%ld,\"item\":%ld,\"answered\":true,"
        "\"mechanism\":\"portal-menuselect\","
        "\"availability\":\"metal-safe\"},"
        "\"backing\":\"" TBT_BACKING "\"}\n",
        id, menu_id, item_index);
    return (n < 0 || (size_t)n >= cap) ? -1 : n;
}


/* `portalselftest` — prove the patch's calling convention in the target.
 *
 * Exists because the ABI bug that cost an afternoon was SILENT: the patch
 * reported firing and the Finder did nothing, because the classic Pascal
 * convention puts the result slot BELOW the argument and makes the callee pop —
 * so the value the application read was never the value we wrote. A wrong ABI
 * does not crash, it lies. This runs the real convention against a known answer
 * and reports a mismatch as `abi_mismatch` rather than as silence. */
static int verb_portalselftest(char *out, size_t cap, long id,
                               const char *line, size_t len)
{
    volatile PTShared  *pt;
    PTShared            snap;
    static ax_target    target;
    ProcessSerialNumber psn;
    const char         *err_code = NULL;
    const char         *err_msg = NULL;
    uint32_t            hi = 0, lo = 0;
    unsigned long       a5;
    unsigned long       deadline;
    int                 i;
    int                 n;

    pt = pt_shared();
    if (pt == NULL || pt->magic != PT_MAGIC) {
        return resp_error(out, cap, id, "portal_absent",
                          "the Portal INIT is not installed or not live");
    }
    if (wire_find_u32(line, len, "serialHi", &hi)
        && wire_find_u32(line, len, "serialLo", &lo)) {
        psn.highLongOfPSN = hi;
        psn.lowLongOfPSN = lo;
        if (!ax_open_target(&target, &psn, NULL, 1, &err_code, &err_msg)) {
            return resp_error(out, cap, id, err_code, err_msg);
        }
    } else if (!ax_open_target(&target, NULL, NULL, 1, &err_code, &err_msg)) {
        return resp_error(out, cap, id, err_code, err_msg);
    }
    a5 = (unsigned long)target.sample.currentA5;
    if (a5 == 0) {
        return resp_error(out, cap, id, "ax_oracle_not_found",
                          "no AXPeek A5 sample for that process");
    }

    pt->op = PT_OP_SELFTEST;
    pt->targetA5 = (uint32_t)a5;
    pt->error = PT_ERR_NONE;
    pt->status = PT_STATUS_PENDING;

    deadline = (unsigned long)LMGetTicks() + 300UL;
    while (pt->status == PT_STATUS_PENDING
           && (unsigned long)LMGetTicks() < deadline) {
        EventRecord ev;
        (void)WaitNextEvent(0, &ev, 2L, NULL);
    }
    if (pt->status == PT_STATUS_PENDING) {
        pt->status = PT_STATUS_IDLE;
        return resp_error(out, cap, id, "portal_timeout",
                          "the target did not pump its event loop");
    }
    for (i = 0; i < 8; i++) {
        uint32_t before = pt->seq;
        if ((before & 1UL) != 0) {
            continue;
        }
        BlockMoveData((Ptr)pt, (Ptr)&snap, (Size)sizeof(snap));
        if (pt->seq == before) {
            break;
        }
    }
    pt->status = PT_STATUS_IDLE;

    if (snap.status == PT_STATUS_ERROR && snap.error == PT_ERR_ABI) {
        char detail[112];
        snprintf(detail, sizeof detail,
                 "answered 0x%08lX but the caller read 0x%08lX - the Pascal "
                 "result slot or callee-pops contract is wrong",
                 (unsigned long)snap.selftestWant,
                 (unsigned long)snap.selftestGot);
        return resp_error(out, cap, id, "abi_mismatch", detail);
    }
    if (snap.status != PT_STATUS_DONE) {
        return resp_error(out, cap, id, "selftest_failed",
                          "the patch did not answer its own MenuSelect");
    }
    n = snprintf(out, cap,
        "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{"
        "\"abi\":\"ok\",\"want\":%lu,\"got\":%lu,\"servedA5\":%lu},"
        "\"backing\":\"" TBT_BACKING "\"}\n",
        id, (unsigned long)snap.selftestWant, (unsigned long)snap.selftestGot,
        (unsigned long)snap.servedA5);
    return (n < 0 || (size_t)n >= cap) ? -1 : n;
}


/*
 * `portal` — read or set the Portal's bypass switch.
 *
 *   portal                  -> report state
 *   portal {enabled:false}  -> the Portal does nothing until turned back on
 *
 * The extension stays installed and its hook stays chained either way; what
 * changes is that the hook returns immediately and the MenuSelect patch chains
 * straight to the real trap, so the machine behaves as though the Portal were
 * not there. We deliberately do NOT unpatch: a trap patch that disappears while
 * a caller is inside it is a worse hazard than one that stays and does nothing.
 *
 * The switch is a plain word in the shared block rather than a request the hook
 * has to serve, which means turning the Portal OFF takes effect immediately and
 * does not require the target process to be alive, frontmost, or pumping its
 * event loop. A kill switch that depends on the cooperation of the thing it
 * protects you from is not a kill switch.
 *
 * Disabling also clears any armed request, so a request armed a moment ago can
 * never fire after someone has switched the Portal off.
 */
static int verb_portal(char *out, size_t cap, long id,
                       const char *line, size_t len)
{
    volatile PTShared *pt;
    int                want = 0;
    int                have_arg;
    int                n;

    pt = pt_shared();
    if (pt == NULL || pt->magic != PT_MAGIC) {
        return resp_error(out, cap, id, "portal_absent",
                          "the Portal INIT is not installed or not live");
    }

    have_arg = wire_find_bool(line, len, "enabled", &want);
    if (have_arg) {
        if (!want) {
            /* Clear the arm BEFORE clearing enabled, so there is no window in
             * which a pending arm could still be honoured. */
            pt->armed = 0;
            pt->status = PT_STATUS_IDLE;
        }
        pt->enabled = want ? 1UL : 0UL;
    }

    n = snprintf(out, cap,
        "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{"
        "\"enabled\":%s,\"changed\":%s,\"version\":%lu,"
        "\"note\":\"disabled means bypassed, not uninstalled\"},"
        "\"backing\":\"" TBT_BACKING "\"}\n",
        id, pt->enabled ? "true" : "false",
        have_arg ? "true" : "false", (unsigned long)pt->version);
    return (n < 0 || (size_t)n >= cap) ? -1 : n;
}


/*
 * `volumes` — the mounted volumes, which are NOT Desktop Folder entries.
 *
 * The desktop's files and folders come from `list` on "Desktop Folder" and
 * carry their own icon positions. Mounted disks do not live there: the Finder
 * places them itself, so they were simply missing from the mirror's desktop.
 *
 * The host used to ask for them via AppleScript (`tell application "Finder" ...
 * position of every disk`), which this agent has no `script` verb for. The File
 * Manager can enumerate them directly and cheaply — an indexed PBHGetVInfo walk
 * — so that is what this does. It is also honest about what it cannot know:
 *
 *   POSITIONS ARE NOT REPORTED. The Finder stores a disk's icon position in its
 *   own desktop database, which is not a File Manager fact. Rather than invent
 *   coordinates, each volume reports `placed:false` and the host lays them out
 *   by the Finder's default rule (top-right, stacked down). A wrong position
 *   drawn confidently is worse than an admitted default.
 */
static int verb_volumes(char *out, size_t cap, long id)
{
    HParamBlockRec pb;
    Str63          name;
    size_t         used = 0;
    short          index;
    int            count = 0;
    char           esc[kEscMax];

    if (!append(out, cap, &used,
                "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{"
                "\"volumes\":[", id)) {
        return resp_error(out, cap, id, "overflow", "volumes header");
    }

    for (index = 1; index <= 32; index++) {
        memset(&pb, 0, sizeof(pb));
        name[0] = 0;
        pb.volumeParam.ioNamePtr = name;
        pb.volumeParam.ioVRefNum = 0;
        pb.volumeParam.ioVolIndex = index;
        if (PBHGetVInfoSync(&pb) != noErr) {
            break;                      /* past the last mounted volume */
        }
        pstr_escape(name, esc, sizeof(esc));
        if (!append(out, cap, &used,
                    "%s{\"name\":\"%s\",\"vRefNum\":%d,"
                    "\"totalBlocks\":%lu,\"freeBlocks\":%lu,"
                    "\"blockSize\":%lu,\"placed\":false}",
                    count == 0 ? "" : ",", esc,
                    (int)pb.volumeParam.ioVRefNum,
                    (unsigned long)pb.volumeParam.ioVNmAlBlks,
                    (unsigned long)pb.volumeParam.ioVFrBlk,
                    (unsigned long)pb.volumeParam.ioVAlBlkSiz)) {
            return resp_error(out, cap, id, "overflow", "volumes list");
        }
        count++;
    }

    if (!append(out, cap, &used, "],\"count\":%d},\"backing\":\""
                TBT_BACKING "\"}\n", count)) {
        return resp_error(out, cap, id, "overflow", "volumes tail");
    }
    return (int)used;
}


/*
 * `ctlinvoke` — act on a control the way the application would.
 *
 * `axdo` posts a real click at the control's centre and lets the Control
 * Manager track it. That works, but it is a CLICK: it depends on the control
 * being where we think, on nothing intercepting the press, and — for anything
 * needing a drag — on the QMP plane, which is emulator-only.
 *
 * This asks the application's own TrackControl to return the part code we
 * choose. The app then runs its real mouse-down handler for that control, with
 * no press, no motion and no tracking. Same shape as `menuinvoke`: answer the
 * question the app asks rather than simulate a user convincingly enough to make
 * it ask.
 *
 * The part code is the caller's, because only the caller knows the intent: 10
 * (inUpButton), 11 (inDownButton), 12 (inPageUp), 13 (inPageDown), 129
 * (inButton/inCheckBox) and so on are Control Manager constants, not ours to
 * guess from a rect.
 */
static int verb_ctlinvoke(char *out, size_t cap, long id,
                          const char *line, size_t len)
{
    volatile PTShared         *pt;
    static char                ref_text[AX_REF_MAX];
    static ax_ref              ref;
    static ax_target           target;
    static ax_resolved_control resolved;
    ProcessSerialNumber        expected;
    const char                *error_code;
    const char                *error_message;
    long                       part = 0;
    unsigned long              a5;
    unsigned long              deadline;
    int                        ref_len;
    int                        rc;
    int                        n;

    pt = pt_shared();
    if (pt == NULL || pt->magic != PT_MAGIC) {
        return resp_error(out, cap, id, "portal_absent",
                          "the Portal INIT is not installed or not live");
    }
    if (!pt->enabled) {
        return resp_error(out, cap, id, "portal_disabled",
                          "the Portal is installed but bypassed - "
                          "enable it with `portal {enabled:true}`");
    }
    if (!wire_find_int(line, len, "part", &part)) {
        return resp_error(out, cap, id, "bad_request",
                          "need part (a Control Manager part code)");
    }

    ref_len = wire_find_str(line, len, "ref", ref_text, sizeof(ref_text));
    if (ref_len < 0
        || ax_ref_parse(ref_text, (size_t)ref_len, &ref) != AX_REF_OK) {
        return resp_error(out, cap, id, "bad_ref",
                          "reference is missing or malformed");
    }
    expected.highLongOfPSN = ref.serial_hi;
    expected.lowLongOfPSN = ref.serial_lo;
    if (!ax_open_target(&target, &expected, &expected, 0,
                        &error_code, &error_message)) {
        return resp_error(out, cap, id, error_code, error_message);
    }
    rc = ax_resolve_ref(&target.memory, target.sample.windowList,
                        &ref, &resolved);
    if (rc != AX_RESOLVE_OK) {
        return resp_error(out, cap, id, "element_not_found",
                          "the reference did not resolve to a control");
    }
    a5 = (unsigned long)target.sample.currentA5;
    if (a5 == 0) {
        return resp_error(out, cap, id, "ax_oracle_not_found",
                          "no AXPeek A5 sample for that process");
    }

    /* Arm against THIS control: the patch must not answer for whichever control
     * the user happens to drag next. */
    pt->op = PT_OP_CONTROL_INVOKE;
    pt->controlHandle = (uint32_t)resolved.control_handle;
    pt->partCode = (int32_t)part;
    pt->targetA5 = (uint32_t)a5;
    pt->error = PT_ERR_NONE;
    pt->armed = 0;
    pt->fired = 0;
    pt->status = PT_STATUS_PENDING;

    deadline = (unsigned long)LMGetTicks() + 300UL;
    while (pt->status == PT_STATUS_PENDING
           && (unsigned long)LMGetTicks() < deadline) {
        EventRecord ev;
        (void)WaitNextEvent(0, &ev, 2L, NULL);       /* yield; never spin */
    }
    if (pt->status != PT_STATUS_DONE || !pt->armed) {
        pt->status = PT_STATUS_IDLE;
        pt->armed = 0;
        return resp_error(out, cap, id,
                          pt->error == PT_ERR_NO_CTL_PATCH ? "no_patch"
                                                           : "portal_timeout",
                          "the target did not arm (not pumping, or no patch)");
    }

    /* The app calls TrackControl from its mouseDown handler, so it still needs
     * a press to get there — but where the press lands no longer decides
     * anything: the patch answers with the part we named. */
    (void)post_click_at((short)((resolved.control.left
                                 + resolved.control.right) / 2),
                        (short)((resolved.control.top
                                 + resolved.control.bottom) / 2), 1, 0);

    deadline = (unsigned long)LMGetTicks() + 300UL;
    while (!pt->fired && (unsigned long)LMGetTicks() < deadline) {
        EventRecord ev;
        (void)WaitNextEvent(0, &ev, 2L, NULL);
    }
    if (!pt->fired) {
        pt->armed = 0;
        pt->status = PT_STATUS_IDLE;
        return resp_error(out, cap, id, "not_taken",
                          "armed, but the app never called TrackControl");
    }
    pt->status = PT_STATUS_IDLE;

    n = snprintf(out, cap,
        "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{"
        "\"part\":%ld,\"answered\":true,\"sawActionProc\":%lu,"
        "\"mechanism\":\"portal-trackcontrol\","
        "\"availability\":\"metal-safe\"},"
        "\"backing\":\"" TBT_BACKING "\"}\n", id, part,
        (unsigned long)pt->sawActionProc);
    return (n < 0 || (size_t)n >= cap) ? -1 : n;
}

/* --- identity + liveness -------------------------------------------------- */

/* hello: what the host binds against before it trusts a scene. It reports the
 * build identity AND whether the AXPeek oracle is actually present, because a
 * mirror against a machine with no extension installed is not a degraded
 * mirror - it is a different situation, and the host must be able to say so
 * rather than render an empty desktop that looks like a working one. */
static int verb_hello(char *out, size_t cap, long id)
{
    AXShared           snapshot;
    volatile PTShared *portal;
    long               axVersion = 0;
    int                oracleRc;
    char          machine[64];
    long          gestaltResp = 0;
    int           n;

    /* Read the oracle through the same seqlock snapshot the walk uses, and
     * report its RESULT CODE rather than a bare bool: "no extension installed"
     * and "installed but stale" are different situations, and the host must be
     * able to say which instead of rendering an empty desktop that looks like a
     * working one. */
    portal = pt_shared();
    if (portal != NULL && portal->magic != PT_MAGIC) {
        portal = NULL;
    }

    oracleRc = ax_oracle_snapshot((unsigned long)LMGetSysZone(),
                                  (unsigned long)LMGetSysZone()->bkLim,
                                  &snapshot);
    if (oracleRc == AX_ORACLE_OK) {
        axVersion = (long)snapshot.version;
    }

    machine[0] = '\0';
    if (Gestalt(gestaltMachineType, &gestaltResp) == noErr) {
        snprintf(machine, sizeof(machine), "%ld", gestaltResp);
    }

    n = snprintf(out, cap,
        "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{"
        "\"agent\":\"mirror\",\"version\":\"" MIRROR_VERSION "\","
        "\"gitRev\":\"" MIRROR_GIT_REV "\",\"build\":\"" kBuildStamp "\","
        "\"machineType\":\"%s\",\"oracle\":%s,\"oracleStatus\":\"%s\","
        "\"oracleVersion\":%ld,"
        "\"portal\":{\"present\":%s,\"enabled\":%s},"
        "\"scenePlanes\":[\"observe\",\"axtree\"],"
        "\"actionPlanes\":[\"activate\",\"click\",\"key\",\"axdo\"]},"
        "\"backing\":\"" TBT_BACKING "\"}\n",
        /* ax_oracle_error_code has no AX_ORACLE_OK case - in the lab it is only
         * ever called on a failure path, so OK falls through to "invalid".
         * Handle success here rather than editing the carried helper. */
        id, machine, oracleRc == AX_ORACLE_OK ? "true" : "false",
        oracleRc == AX_ORACLE_OK ? "ok" : ax_oracle_error_code(oracleRc),
        axVersion,
        portal != NULL ? "true" : "false",
        (portal != NULL && portal->enabled) ? "true" : "false");
    return (n < 0 || (size_t)n >= cap) ? -1 : n;
}

static int verb_ping(char *out, size_t cap, long id)
{
    int n = snprintf(out, cap,
        "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{"
        "\"version\":\"" MIRROR_VERSION "\",\"build\":\"" kBuildStamp "\","
        "\"upTicks\":%lu,\"requests\":%lu,\"idleTicks\":%lu},"
        "\"backing\":\"" TBT_BACKING "\"}\n",
        id, (unsigned long)LMGetTicks() - g_start_ticks, g_requests,
        (unsigned long)LMGetTicks() - g_last_activity);
    return (n < 0 || (size_t)n >= cap) ? -1 : n;
}

/* quit: the host's clean shutdown. Sets the loop's exit flag rather than
 * calling ExitToShell here - the reply must reach the wire first, and the
 * listener must tear its endpoint down in the order ot.c expects. */
static int verb_quit(char *out, size_t cap, long id)
{
    int n = snprintf(out, cap,
        "{\"proto\":1,\"id\":%ld,\"ok\":true,\"result\":{\"quitting\":true},"
        "\"backing\":\"" TBT_BACKING "\"}\n", id);
    g_shutdown = 1;
    return (n < 0 || (size_t)n >= cap) ? -1 : n;
}

/* --- dispatch ------------------------------------------------------------- */

static int dispatch_verb(const char *verb, char *out, size_t cap, long id,
                         const char *line, size_t len)
{
    /* Perceive. */
    if (strcmp(verb, "observe") == 0) {
        return verb_observe(out, cap, id);
    }
    if (strcmp(verb, "axtree") == 0) {
        return verb_axtree(out, cap, id, line, len);
    }
    if (strcmp(verb, "axsnap") == 0) {
        return verb_axsnap(out, cap, id);
    }
    if (strcmp(verb, "mouseloc") == 0) {
        return verb_mouseloc(out, cap, id);
    }
    if (strcmp(verb, "qdtrace") == 0) {
        return verb_qdtrace(out, cap, id, line, len);
    }
    if (strcmp(verb, "capture") == 0) {
        return verb_capture(out, cap, id, line, len);
    }
    if (strcmp(verb, "fetch") == 0) {
        return verb_fetch(out, cap, id, line, len);
    }
    if (strcmp(verb, "close") == 0) {
        return verb_close(out, cap, id, line, len);
    }
    if (strcmp(verb, "list") == 0) {
        return verb_list(out, cap, id, line, len);
    }
    if (strcmp(verb, "stat") == 0) {
        return verb_stat(out, cap, id, line, len);
    }
    if (strcmp(verb, "volumes") == 0) {
        return verb_volumes(out, cap, id);
    }
    if (strcmp(verb, "portal") == 0) {
        return verb_portal(out, cap, id, line, len);
    }
    if (strcmp(verb, "portalselftest") == 0) {
        return verb_portalselftest(out, cap, id, line, len);
    }
    if (strcmp(verb, "ctlinvoke") == 0) {
        return verb_ctlinvoke(out, cap, id, line, len);
    }
    if (strcmp(verb, "menuinvoke") == 0) {
        return verb_menuinvoke(out, cap, id, line, len);
    }
    if (strcmp(verb, "menugeom") == 0) {
        return verb_menugeom(out, cap, id, line, len);
    }
    if (strcmp(verb, "journalprobe") == 0) {
        return verb_journalprobe(out, cap, id);
    }
    /* Act. */
    if (strcmp(verb, "axdo") == 0) {
        return verb_axdo(out, cap, id, line, len);
    }
    if (strcmp(verb, "activate") == 0) {
        return verb_activate(out, cap, id, line, len);
    }
    if (strcmp(verb, "click") == 0) {
        return verb_click(out, cap, id, line, len);
    }
    if (strcmp(verb, "key") == 0) {
        return verb_key(out, cap, id, line, len);
    }
    /* Identity + lifecycle. */
    if (strcmp(verb, "hello") == 0) {
        return verb_hello(out, cap, id);
    }
    if (strcmp(verb, "ping") == 0) {
        return verb_ping(out, cap, id);
    }
    if (strcmp(verb, "quit") == 0) {
        return verb_quit(out, cap, id);
    }
    return resp_error(out, cap, id, "unknown_verb", verb);
}

/* Parse one request line and produce one reply line. A malformed request still
 * gets a well-formed error envelope - the host must never have to guess whether
 * silence meant a wedge or a rejection. */
int mirror_verb_handle(const char *line, size_t len, char *out, size_t cap)
{
    char verb[kVerbMax];
    long id = 0;
    int  vlen;

    g_last_activity = (unsigned long)LMGetTicks();
    g_requests++;

    if (!wire_find_int(line, len, "id", &id)) {   /* returns 1 on success */
        id = 0;
    }
    vlen = wire_find_str(line, len, "verb", verb, sizeof(verb));
    if (vlen == kWireOverflow) {
        return resp_error(out, cap, id, "bad_request", "verb too long");
    }
    if (vlen < 0) {                               /* kWireAbsent or malformed */
        return resp_error(out, cap, id, "bad_request", "missing verb");
    }
    return dispatch_verb(verb, out, cap, id, line, len);
}
