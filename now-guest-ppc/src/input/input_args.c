#include "input_args.h"

#include <stdio.h>
#include <string.h>

/* ---- script ----------------------------------------------------------- */

int now_script_clamp_ms(long requested, int present)
{
    if (!present) {
        return kNowScriptDefaultMs;
    }
    if (requested < (long)kNowScriptMinMs) {
        return kNowScriptMinMs;
    }
    if (requested > (long)kNowScriptMaxMs) {
        return kNowScriptMaxMs;
    }
    return (int)requested;
}

static int lower(int c)
{
    if (c >= 'A' && c <= 'Z') {
        return c - 'A' + 'a';
    }
    return c;
}

static int is_space(int c)
{
    return c == ' ' || c == '\t';
}

/* Does `phrase` (single-spaced, lower case) occur at src[i], allowing any
   run of spaces or tabs wherever the phrase has one space? */
static int phrase_at(const char *src, int length, int i, const char *phrase)
{
    int j = 0;

    while (phrase[j] != '\0') {
        if (phrase[j] == ' ') {
            if (i >= length || !is_space((unsigned char)src[i])) {
                return 0;
            }
            while (i < length && is_space((unsigned char)src[i])) {
                i++;
            }
            j++;
            continue;
        }
        if (i >= length
            || lower((unsigned char)src[i]) != phrase[j]) {
            return 0;
        }
        i++;
        j++;
    }
    return 1;
}

int now_script_is_whole_disk_search(const char *source, int length)
{
    int i;

    if (source == NULL || length <= 0) {
        return 0;
    }
    for (i = 0; i < length; i++) {
        if (phrase_at(source, length, i, "entire contents")) {
            return 1;
        }
    }
    return 0;
}

NowScriptStatus now_script_prepare(const char *source, int length,
                                   long timeout_ms, int timeout_present,
                                   NowScriptRequest *out)
{
    int written;
    int i;

    if (out == NULL) {
        return kNowScriptNoSource;
    }
    out->text[0] = '\0';
    out->length = 0;
    out->wrapped = 0;
    out->lines = 0;
    out->timeout_ms = now_script_clamp_ms(timeout_ms, timeout_present);
    /* Rounded UP, so a 1500 ms request is never capped at one second by
       the wrapper the caller did not ask for. */
    out->timeout_secs = (out->timeout_ms + 999) / 1000;

    if (source == NULL || length < 0) {
        return kNowScriptNoSource;
    }
    if (length == 0) {
        return kNowScriptNoSource;
    }
    if (length > kNowScriptSrcMax) {
        return kNowScriptSourceTooLong;
    }
    if (now_script_is_whole_disk_search(source, length)) {
        return kNowScriptSearches;
    }

    /* The wrapper is belt to the active procedure's braces, and it is
       the weaker of the two: `with timeout` needs an AppleScript that
       parses it, and the deadline the caller actually gets is enforced
       by the OSA active procedure, which is version-independent. So a
       source too long to wrap is run unwrapped rather than refused -
       it still has a deadline. */
    written = snprintf(out->text, sizeof out->text,
                       "with timeout of %d seconds\n%.*s\nend timeout",
                       out->timeout_secs, length, source);
    if (written < 0 || (size_t)written >= sizeof out->text) {
        memcpy(out->text, source, (size_t)length);
        out->text[length] = '\0';
        written = length;
    } else {
        out->wrapped = 1;
    }
    out->length = written;

    /* Classic AppleScript's line terminator is CR. A source that arrived
       with LF endings would otherwise parse as one very long line, which
       is the OS-8.1-era failure this project has already paid for once. */
    out->lines = 1;
    for (i = 0; i < out->length; i++) {
        if (out->text[i] == '\n') {
            out->text[i] = '\r';
        }
        if (out->text[i] == '\r') {
            out->lines++;
        }
    }
    return kNowScriptOk;
}

const char *now_script_status_code(NowScriptStatus status)
{
    switch (status) {
    case kNowScriptOk:
        return "ok";
    case kNowScriptSourceTooLong:
        return "too-large";
    case kNowScriptSearches:
        return "refused";
    case kNowScriptNoSource:
    default:
        return "bad-request";
    }
}

const char *now_script_status_message(NowScriptStatus status)
{
    switch (status) {
    case kNowScriptOk:
        return "ok";
    case kNowScriptSourceTooLong:
        return "script source is longer than 2048 bytes, which is all this "
               "guest accepts";
    case kNowScriptSearches:
        return "that script asks the Finder for `entire contents`, a "
               "whole-disk search that wedged a real machine for twelve "
               "minutes. Scope the script to a window the Finder is already "
               "showing";
    case kNowScriptNoSource:
    default:
        return "script requires source: one AppleScript, as a string";
    }
}

int now_script_timed_out(int active_fired, int osa_err, int hit_deadline)
{
    if (active_fired) {
        return 1;
    }
    /* An error that also reached the deadline is a timeout; a SUCCESS
       that happened to land on it is not, and that asymmetry is the
       point of taking three signals rather than one. */
    if (osa_err != 0 && hit_deadline) {
        return 1;
    }
    return 0;
}

/* ---- aesend ----------------------------------------------------------- */

NowAeOp now_ae_op_from_name(const char *name)
{
    if (name == NULL) {
        return kNowAeOpNone;
    }
    if (strcmp(name, "quit") == 0) {
        return kNowAeOpQuit;
    }
    if (strcmp(name, "oapp") == 0) {
        return kNowAeOpOpenApp;
    }
    if (strcmp(name, "odoc") == 0) {
        return kNowAeOpOpenDoc;
    }
    if (strcmp(name, "pdoc") == 0) {
        return kNowAeOpPrintDoc;
    }
    return kNowAeOpNone;
}

const char *now_ae_op_name(NowAeOp op)
{
    switch (op) {
    case kNowAeOpQuit:
        return "quit";
    case kNowAeOpOpenApp:
        return "oapp";
    case kNowAeOpOpenDoc:
        return "odoc";
    case kNowAeOpPrintDoc:
        return "pdoc";
    case kNowAeOpNone:
    default:
        return "";
    }
}

int now_ae_op_needs_document(NowAeOp op)
{
    return op == kNowAeOpOpenDoc || op == kNowAeOpPrintDoc;
}

int now_ae_serial_is_none(unsigned long hi, unsigned long lo)
{
    return hi == 0UL && lo == 0UL;
}

int now_ae_serial_same(unsigned long a_hi, unsigned long a_lo,
                       unsigned long b_hi, unsigned long b_lo)
{
    return a_hi == b_hi && a_lo == b_lo;
}

NowAeStatus now_ae_check(const char *event, int serial_present,
                         unsigned long hi, unsigned long lo,
                         unsigned long self_hi, unsigned long self_lo,
                         int path_length, NowAeOp *op_out)
{
    NowAeOp op;

    if (op_out != NULL) {
        *op_out = kNowAeOpNone;
    }
    if (event == NULL || event[0] == '\0') {
        return kNowAeNoEvent;
    }
    op = now_ae_op_from_name(event);
    if (op == kNowAeOpNone) {
        return kNowAeUnknownEvent;
    }
    if (op_out != NULL) {
        *op_out = op;
    }
    if (!serial_present) {
        return kNowAeNoSerial;
    }
    if (now_ae_serial_is_none(hi, lo)) {
        return kNowAeNoProcess;
    }
    if (now_ae_serial_same(hi, lo, self_hi, self_lo)) {
        return kNowAeSelf;
    }
    if (now_ae_op_needs_document(op)) {
        if (path_length <= 0) {
            return kNowAeNoPath;
        }
        if (path_length > 255) {
            return kNowAePathTooLong;
        }
    }
    return kNowAeOk;
}

const char *now_ae_status_code(NowAeStatus status)
{
    switch (status) {
    case kNowAeOk:
        return "ok";
    case kNowAeNoProcess:
        return "not-found";
    case kNowAeSelf:
        return "refused";
    case kNowAePathTooLong:
        return "too-large";
    case kNowAeNoEvent:
    case kNowAeUnknownEvent:
    case kNowAeNoSerial:
    case kNowAeNoPath:
    default:
        return "bad-request";
    }
}

const char *now_ae_status_message(NowAeStatus status)
{
    switch (status) {
    case kNowAeOk:
        return "ok";
    case kNowAeNoEvent:
        return "aesend requires event: one of quit, oapp, odoc, pdoc";
    case kNowAeUnknownEvent:
        return "aesend serves four events and no others: quit, oapp, odoc, "
               "pdoc. There is no class/id form, deliberately - an argument "
               "that cannot bound what the event does is not an argument";
    case kNowAeNoSerial:
        return "aesend requires serialHi and serialLo, the process serial "
               "`observe` reports. There is no frontmost default";
    case kNowAeNoProcess:
        return "serialHi 0 with serialLo 0 is kNoProcess: that names no "
               "application";
    case kNowAeSelf:
        return "that serial is this guest. Sending it a core event would "
               "take the connection down mid-reply, so it is refused rather "
               "than answered by a dropped socket";
    case kNowAeNoPath:
        return "odoc and pdoc require path: the document, as a full classic "
               "path";
    case kNowAePathTooLong:
        return "path is longer than 255 bytes, which is longer than a "
               "classic path can be";
    default:
        return "aesend refused the request";
    }
}
