#include "input_cmds.h"

#include <Carbon.h>
#include <AppleEvents.h>
#include <Aliases.h>
#include <stdio.h>
#include <string.h>

#include "input_args.h"
#include "json.h"

/* ---- replies ----------------------------------------------------------
 *
 * Same shape as every other command in this guest: output.<name> as an
 * array of [label, value] rows. The buffer is bigger than the act
 * plane's because one row here - a script's output - is the only row in
 * the guest whose size a REMOTE caller chooses, and input_args.h states
 * the budget it has to fit inside. */

typedef struct {
    char rows[kNowScriptEscMax + 512];
    long used;
    int  overflow;
} InputRows;

/* Escaping scratch. Static for the same reason NowScriptRequest is: a
   2.5 KB local under an OSA call is exactly the fat frame this family
   of verbs must not sit on. */
static char g_esc[kNowScriptEscMax];

static void rows_reset(InputRows *r)
{
    r->rows[0] = '\0';
    r->used = 0;
    r->overflow = 0;
}

/* Appends a row whose value is ALREADY escaped. The two-step form
   exists for the script output, which is escaped once into a buffer
   sized for it rather than into a per-row scratch. */
static void row_add_raw(InputRows *r, const char *label, const char *escaped)
{
    char esc_label[64];
    int  n;

    if (r->overflow) {
        return;
    }
    now_json_escape(label, esc_label, (long)sizeof esc_label);
    n = snprintf(r->rows + r->used, (size_t)((long)sizeof r->rows - r->used),
                 "%s[\"%s\",\"%s\"]", r->used > 0 ? "," : "",
                 esc_label, escaped);
    if (n < 0 || (long)n >= (long)sizeof r->rows - r->used) {
        r->overflow = 1;
        return;
    }
    r->used += n;
}

static void row_add(InputRows *r, const char *label, const char *value)
{
    char esc_value[256];

    now_json_escape(value, esc_value, (long)sizeof esc_value);
    row_add_raw(r, label, esc_value);
}

static void row_addl(InputRows *r, const char *label, long value)
{
    char text[32];

    snprintf(text, sizeof text, "%ld", value);
    row_add_raw(r, label, text);
}

static void row_addu(InputRows *r, const char *label, unsigned long value)
{
    char text[32];

    snprintf(text, sizeof text, "%lu", value);
    row_add_raw(r, label, text);
}

static void reply_rows(char *out, long cap, long id, const char *name,
                       const InputRows *r)
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

/* ---- arguments --------------------------------------------------------
 *
 * Presence for an integer argument, by the same two-probe trick the act
 * plane uses: ask twice with different fallbacks and require them to
 * agree. A serialLo that defaulted to 0 and a serialLo the caller sent
 * are different requests, and for this plane the difference is between
 * "no target" and "kNoProcess". */
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

/* ---- mouseloc ---------------------------------------------------------
 *
 * GetGlobalMouse, not LMGetMouseLocation: this guest is Carbon, and
 * LowMem.h itself says "Carbon Usage: use GetGlobalMouse" against that
 * accessor. Upstream read the low-memory global because its guest was
 * not Carbon. Same number, and only one of the two is guaranteed to
 * keep answering here.
 *
 * A READ, AND ONLY A READ. There is no companion verb that moves the
 * pointer, deliberately: on this project the pointer is moved from
 * OUTSIDE the guest CPU (QMP), because that is the only way to produce a
 * click the guest cannot tell from a person's - which is the whole
 * premise of the no-hijack measurement. A guest-side mouse-move would
 * give every one of those probes a way to fake its own control. */
void now_input_run_mouseloc(const char *request_json, long id,
                            char *out, long cap)
{
    InputRows rows;
    Point     where;

    (void)request_json;                 /* mouseloc takes no arguments */
    where.h = 0;
    where.v = 0;
    GetGlobalMouse(&where);

    rows_reset(&rows);
    row_addl(&rows, "x", (long)where.h);
    row_addl(&rows, "y", (long)where.v);
    reply_rows(out, cap, id, "mouseloc", &rows);
}

/* ---- script -----------------------------------------------------------
 *
 * The deadline that actually binds is the OSA ACTIVE PROCEDURE, not the
 * `with timeout` wrapper. The wrapper needs an AppleScript that parses
 * it; the active procedure is called by the component itself while the
 * script runs and works on any version. Both are used, and the wrapper
 * is the weaker one - which is why a source too long to wrap runs
 * anyway (input_args.c) rather than being refused. */

static unsigned long g_script_deadline;   /* TickCount; 0 = disarmed */
static int           g_script_fired;
static OSAActiveUPP  g_script_active;

/* Every buffer here is static and none is a local. That is upstream's
   rule, recorded against this exact function, and it is about the stack
   frame an OSA call sits on rather than about memory. */
static NowScriptRequest g_script_req;
static char             g_script_result[kNowScriptOutMax + 1];

static pascal OSErr script_active_proc(long refCon)
{
    (void)refCon;
    if (g_script_deadline != 0
        && (unsigned long)TickCount() >= g_script_deadline) {
        g_script_fired = 1;
        return userCanceledErr;
    }
    return noErr;
}

void now_input_run_script(const char *request_json, long id,
                          char *out, long cap)
{
    static char       source[kNowScriptSrcMax + 2];
    NowScriptStatus   prep;
    long              timeout_ms = 0;
    int               timeout_present;
    int               source_len;
    int               result_len = 0;
    int               hit_deadline;
    int               truncated;
    ComponentInstance osa;
    AEDesc            src_desc;
    AEDesc            res_desc;
    OSAError          oerr;
    OSErr             err;
    InputRows         rows;
    char              message[80];

    source[0] = '\0';
    /* find_TEXT for the same reason as aesend's path: an AppleScript
       source is authored text, not a protocol token, and it routinely
       carries a file or window name a person typed. Left undecoded, a
       host's UTF-8 reaches the OSA component as bytes this machine cannot
       read and the script fails on a name that is right. */
    if (!now_json_find_text(request_json, "source", source,
                            (long)sizeof source)) {
        source_len = -1;
    } else {
        source_len = (int)strlen(source);
    }
    timeout_present = arg_int(request_json, "timeoutMs", &timeout_ms);

    prep = now_script_prepare(source, source_len, timeout_ms, timeout_present,
                              &g_script_req);
    if (prep != kNowScriptOk) {
        reply_error(out, cap, id, now_script_status_code(prep),
                    now_script_status_message(prep));
        return;
    }

    src_desc.descriptorType = typeNull;
    src_desc.dataHandle = NULL;
    res_desc.descriptorType = typeNull;
    res_desc.dataHandle = NULL;

    osa = OpenDefaultComponent(kOSAComponentType, typeAppleScript);
    if (osa == NULL) {
        reply_error(out, cap, id, "unavailable",
                    "this Mac has no AppleScript OSA component, so there is "
                    "nothing here to run a script");
        return;
    }
    err = AECreateDesc(typeChar, g_script_req.text, (Size)g_script_req.length,
                       &src_desc);
    if (err != noErr) {
        (void)CloseComponent(osa);
        snprintf(message, sizeof message,
                 "the script could not be handed to AppleScript "
                 "(AECreateDesc %d)", (int)err);
        reply_error(out, cap, id, "io-error", message);
        return;
    }
    if (g_script_active == NULL) {
        g_script_active = NewOSAActiveUPP(script_active_proc);
    }
    if (g_script_active != NULL) {
        (void)OSASetActiveProc(osa, g_script_active, 0);
    }
    g_script_fired = 0;
    /* 60 ticks a second: ms * 3 / 50. */
    g_script_deadline = (unsigned long)TickCount()
                        + (unsigned long)(g_script_req.timeout_ms * 3L / 50L);

    oerr = OSADoScript(osa, &src_desc, kOSANullScript, typeChar,
                       kOSAModeCanInteract, &res_desc);
    AEDisposeDesc(&src_desc);
    hit_deadline = (g_script_deadline != 0
                    && (unsigned long)TickCount() >= g_script_deadline);
    g_script_deadline = 0;

    if (res_desc.dataHandle != NULL) {
        Size size = GetHandleSize((Handle)res_desc.dataHandle);

        result_len = (size > (Size)kNowScriptOutMax)
                     ? kNowScriptOutMax : (int)size;
        HLock((Handle)res_desc.dataHandle);
        memcpy(g_script_result, *(Handle)res_desc.dataHandle,
               (size_t)result_len);
        HUnlock((Handle)res_desc.dataHandle);
    }
    g_script_result[result_len] = '\0';
    AEDisposeDesc(&res_desc);
    (void)CloseComponent(osa);

    if (now_script_timed_out(g_script_fired, (int)oerr, hit_deadline)) {
        reply_error(out, cap, id, "timeout",
                    "the script was stopped at its deadline. It may have "
                    "left work half done - this guest is serial and could "
                    "not wait longer");
        return;
    }

    now_json_escape(g_script_result, g_esc, (long)sizeof g_esc);
    /* Truncated either because the OSA result was longer than we carry,
       or because escaping it filled the buffer. Both are the same fact
       to a caller - the answer on the wire is not the whole answer - and
       reporting it is what stops a cut result reading as a short one. */
    truncated = (result_len >= kNowScriptOutMax)
                || ((long)strlen(g_esc) >= (long)sizeof g_esc - 8);

    rows_reset(&rows);
    row_add_raw(&rows, "output", g_esc);
    row_addl(&rows, "osaErr", (long)oerr);
    row_add(&rows, "truncated", truncated ? "true" : "false");
    row_addl(&rows, "timeoutMs", (long)g_script_req.timeout_ms);
    row_add(&rows, "wrapped", g_script_req.wrapped ? "true" : "false");
    reply_rows(out, cap, id, "script", &rows);
}

/* ---- aesend -----------------------------------------------------------
 *
 * FIRE AND FORGET (kAENoReply), and the reply says `sent`, never
 * `performed`. Waiting for a reply would block this guest's single
 * threaded loop on a foreign application's event loop, and the answer we
 * want is not the target's acknowledgement anyway: an application with
 * an unsaved document answers a quit event by putting up a save-changes
 * alert and STAYING RUNNING. That is correct behaviour, and it is only
 * visible in a fresh observation of the machine. kAECanInteract is what
 * permits that alert to appear rather than the send failing.
 *
 * Above the bright line: the AppleEvent Manager is a first-class OS API,
 * so this is one of the few things on this plane with no emulator-only
 * clause. Ported from upstream as FACTS - the four-event whitelist, the
 * PSN addressing, the alias-list shape for a document - and written
 * here. */
void now_input_run_aesend(const char *request_json, long id,
                          char *out, long cap)
{
    static char         path[kNowAePathMax];
    char                event[24];
    long                hi = 0;
    long                lo = 0;
    int                 serial_present;
    int                 path_len;
    NowAeOp             op = kNowAeOpNone;
    NowAeStatus         status;
    ProcessSerialNumber psn;
    ProcessSerialNumber self;
    AEEventID           eid;
    AEAddressDesc       target;
    AppleEvent          ae;
    AppleEvent          reply;
    OSErr               err;
    InputRows           rows;
    char                message[96];

    event[0] = '\0';
    (void)now_json_find_string(request_json, "event", event,
                               (long)sizeof event);
    path[0] = '\0';
    /* find_TEXT, not find_string: `path` is an HFS name that goes to the
       File Manager, and the host sends UTF-8. Undecoded, an accented
       document name does not resolve and the caller is told the file does
       not exist. `event` above is the opposite case - a protocol token,
       ASCII by contract - and takes find_string. */
    path_len = now_json_find_text(request_json, "path", path,
                                  (long)sizeof path)
               ? (int)strlen(path) : -1;
    serial_present = arg_int(request_json, "serialHi", &hi)
                     && arg_int(request_json, "serialLo", &lo);

    self.highLongOfPSN = 0;
    self.lowLongOfPSN = 0;
    (void)GetCurrentProcess(&self);

    status = now_ae_check(event, serial_present,
                          (unsigned long)hi, (unsigned long)lo,
                          self.highLongOfPSN, self.lowLongOfPSN,
                          path_len, &op);
    if (status != kNowAeOk) {
        reply_error(out, cap, id, now_ae_status_code(status),
                    now_ae_status_message(status));
        return;
    }

    switch (op) {
    case kNowAeOpOpenApp:
        eid = kAEOpenApplication;
        break;
    case kNowAeOpOpenDoc:
        eid = kAEOpenDocuments;
        break;
    case kNowAeOpPrintDoc:
        eid = kAEPrintDocuments;
        break;
    case kNowAeOpQuit:
    default:
        eid = kAEQuitApplication;
        break;
    }

    psn.highLongOfPSN = (unsigned long)hi;
    psn.lowLongOfPSN = (unsigned long)lo;
    err = AECreateDesc(typeProcessSerialNumber, &psn, sizeof psn, &target);
    if (err != noErr) {
        snprintf(message, sizeof message,
                 "that serial could not be addressed (AECreateDesc %d)",
                 (int)err);
        reply_error(out, cap, id, "io-error", message);
        return;
    }
    err = AECreateAppleEvent(kCoreEventClass, eid, &target,
                             kAutoGenerateReturnID, kAnyTransactionID, &ae);
    AEDisposeDesc(&target);
    if (err != noErr) {
        snprintf(message, sizeof message,
                 "the event could not be built (AECreateAppleEvent %d)",
                 (int)err);
        reply_error(out, cap, id, "io-error", message);
        return;
    }

    if (now_ae_op_needs_document(op)) {
        Str255      ppath;
        FSSpec      spec;
        AliasHandle alias = NULL;
        AEDescList  list;
        AEDesc      file_desc;

        ppath[0] = (unsigned char)path_len;
        memcpy(ppath + 1, path, (size_t)path_len);
        err = FSMakeFSSpec(0, 0, ppath, &spec);
        if (err != noErr) {
            AEDisposeDesc(&ae);
            /* Same reading as this guest's other path verbs: any absent
               segment is not-found, whether it is the leaf (-43), a
               folder (-120) or the volume (-35). */
            snprintf(message, sizeof message,
                     "no such document (FSMakeFSSpec %d)", (int)err);
            reply_error(out, cap, id,
                        (err == fnfErr || err == dirNFErr || err == nsvErr)
                        ? "not-found" : "io-error", message);
            return;
        }
        err = NewAliasMinimal(&spec, &alias);
        if (err != noErr || alias == NULL) {
            AEDisposeDesc(&ae);
            reply_error(out, cap, id, "io-error",
                        "the document could not be described to the target");
            return;
        }
        (void)AECreateList(NULL, 0, false, &list);
        HLock((Handle)alias);
        err = AECreateDesc(typeAlias, *alias, GetHandleSize((Handle)alias),
                           &file_desc);
        HUnlock((Handle)alias);
        if (err == noErr) {
            (void)AEPutDesc(&list, 1, &file_desc);
            (void)AEPutParamDesc(&ae, keyDirectObject, &list);
            AEDisposeDesc(&file_desc);
        }
        AEDisposeDesc(&list);
        DisposeHandle((Handle)alias);
        if (err != noErr) {
            AEDisposeDesc(&ae);
            reply_error(out, cap, id, "io-error",
                        "the document could not be attached to the event");
            return;
        }
    }

    /* Initialised BEFORE the send. With kAENoReply the AppleEvent
       Manager returns a null descriptor here, but on an early error it
       may not write `reply` at all, and disposing a stack-garbage
       descriptor is a crash we would have to reproduce on metal to
       believe. */
    reply.descriptorType = typeNull;
    reply.dataHandle = NULL;
    err = AESend(&ae, &reply, kAENoReply | kAECanInteract,
                 kAENormalPriority, kAEDefaultTimeout, NULL, NULL);
    AEDisposeDesc(&reply);
    AEDisposeDesc(&ae);
    if (err != noErr) {
        /* procNotFound (-600) is a serial that no longer names a
           process - a stale observation, not a broken caller. */
        snprintf(message, sizeof message, "the event was not sent (AESend %d)",
                 (int)err);
        reply_error(out, cap, id,
                    (err == procNotFound) ? "not-found" : "io-error", message);
        return;
    }

    rows_reset(&rows);
    row_add(&rows, "event", now_ae_op_name(op));
    row_addu(&rows, "serialHi", psn.highLongOfPSN);
    row_addu(&rows, "serialLo", psn.lowLongOfPSN);
    /* `sent`, and never `performed`. The event left here. Whether the
       target quit, or raised a save-changes alert and stayed, is the
       CALLER's to read out of a fresh observation - claiming the
       stronger thing is how a broken act plane stays invisible. */
    row_add(&rows, "sent", "true");
    row_add(&rows, "mechanism", "apple-event");
    row_add(&rows, "availability", "metal-safe");
    reply_rows(out, cap, id, "aesend", &rows);
}
