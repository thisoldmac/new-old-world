#include "input_args.h"

#include <stdio.h>
#include <string.h>

#include "json.h"

/* Shared by both halves of this file: the key table folds a character
   before looking it up, and the script scanner folds while matching a
   phrase. */
static int lower(int c)
{
    if (c >= 'A' && c <= 'Z') {
        return c - 'A' + 'a';
    }
    return c;
}

/* ---- key --------------------------------------------------------------
 *
 * The US virtual key code table, character keys first and the named keys
 * after it. Both are P-DOC (Inside Macintosh: Text, "Keyboard Virtual Key
 * Codes"); neither was measured here, and the one number that WAS
 * measured on a live machine by the upstream project - `n` is 45 - agrees
 * with the row below, which is the only cross-check available short of a
 * Macintosh.
 *
 * The character is the UNSHIFTED one. A shifted character (an upper-case
 * letter, `!`, `?`) has no row of its own on purpose: it is the same KEY
 * with the shift modifier, and the modifier is the thing this verb cannot
 * post. What it can do is carry the character the caller sent in the
 * message's low half unchanged, which is what makes `key {char:'N'}`
 * type an N in an application that reads the character - and it reports
 * that the code half came from `n`, so a caller matching on the code
 * knows exactly what it got. */
typedef struct {
    int  code;
    int  ch;
} NowKeyRow;

static const NowKeyRow g_key_chars[] = {
    {  0, 'a' }, {  1, 's' }, {  2, 'd' }, {  3, 'f' }, {  4, 'h' },
    {  5, 'g' }, {  6, 'z' }, {  7, 'x' }, {  8, 'c' }, {  9, 'v' },
    { 11, 'b' }, { 12, 'q' }, { 13, 'w' }, { 14, 'e' }, { 15, 'r' },
    { 16, 'y' }, { 17, 't' }, { 18, '1' }, { 19, '2' }, { 20, '3' },
    { 21, '4' }, { 22, '6' }, { 23, '5' }, { 24, '=' }, { 25, '9' },
    { 26, '7' }, { 27, '-' }, { 28, '8' }, { 29, '0' }, { 30, ']' },
    { 31, 'o' }, { 32, 'u' }, { 33, '[' }, { 34, 'i' }, { 35, 'p' },
    { 37, 'l' }, { 38, 'j' }, { 39, '\'' }, { 40, 'k' }, { 41, ';' },
    { 42, '\\' }, { 43, ',' }, { 44, '/' }, { 45, 'n' }, { 46, 'm' },
    { 47, '.' }, { 50, '`' }
};

/* The keys with no character to type, which are the whole reason a
   text-writing verb could not cover this ground. Each carries the
   control character the Toolbox associates with it, because that is what
   an application's own key handler switches on. */
typedef struct {
    const char *name;
    int         code;
    int         ch;
} NowKeyNamed;

static const NowKeyNamed g_key_named[] = {
    { "return",    36, 13 },
    { "enter",     76,  3 },     /* the keypad's, a different key */
    { "tab",       48,  9 },
    { "space",     49, 32 },
    { "delete",    51,  8 },     /* backspace */
    { "escape",    53, 27 },
    { "help",     114,  5 },
    { "home",     115,  1 },
    { "fwddelete",117, 127 },
    { "end",      119,  4 },
    { "pageup",   116, 11 },
    { "pagedown", 121, 12 },
    { "left",     123, 28 },
    { "right",    124, 29 },
    { "down",     125, 31 },
    { "up",       126, 30 }
};

int now_key_named(const char *name, int *code_out, int *char_out)
{
    unsigned int i;

    if (name == NULL || name[0] == '\0') {
        return 0;
    }
    for (i = 0; i < sizeof g_key_named / sizeof g_key_named[0]; i++) {
        if (strcmp(name, g_key_named[i].name) == 0) {
            if (code_out != NULL) {
                *code_out = g_key_named[i].code;
            }
            if (char_out != NULL) {
                *char_out = g_key_named[i].ch;
            }
            return 1;
        }
    }
    return 0;
}

int now_key_char_for_code(int code)
{
    unsigned int i;

    for (i = 0; i < sizeof g_key_chars / sizeof g_key_chars[0]; i++) {
        if (g_key_chars[i].code == code) {
            return g_key_chars[i].ch;
        }
    }
    for (i = 0; i < sizeof g_key_named / sizeof g_key_named[0]; i++) {
        if (g_key_named[i].code == code) {
            return g_key_named[i].ch;
        }
    }
    return 0;
}

int now_key_code_for_char(int ch)
{
    unsigned int i;
    int          folded = lower(ch);

    for (i = 0; i < sizeof g_key_chars / sizeof g_key_chars[0]; i++) {
        if (g_key_chars[i].ch == folded) {
            return g_key_chars[i].code;
        }
    }
    for (i = 0; i < sizeof g_key_named / sizeof g_key_named[0]; i++) {
        if (g_key_named[i].ch == ch) {
            return g_key_named[i].code;
        }
    }
    return -1;
}

NowKeyStatus now_key_check(const char *name,
                           long code, int code_present,
                           long ch, int char_present,
                           long mods, int mods_present,
                           int mods_available,
                           NowKeyRequest *out)
{
    NowKeyRequest r;

    r.code = 0;
    r.ch = 0;
    r.code_known = 0;
    r.char_known = 0;
    r.mods = 0;
    if (out != NULL) {
        *out = r;
    }

    /* FIRST, and before any other complaint. A shape this verb has never
       heard of is a caller bug regardless of what can carry it. */
    if (mods_present && (mods < 0 || mods > (long)kNowKeyModMask)) {
        return kNowKeyModRange;
    }
    /* THE WALL, NARROWED rather than removed: mods 0 (or absent) is the
       caller saying "none", which the plain PostEvent path already does
       and needs no route at all. A nonzero mods with nowhere to go is
       still refused here - never silently dropped - but `mods_available`
       is what decides whether "nowhere" is true right now, and that
       answer belongs to the caller (now_input_run_key), not to this
       file, which has no way to ask the act plane anything. */
    if (mods_present && mods != 0 && !mods_available) {
        return kNowKeyModifiers;
    }
    r.mods = (mods_present) ? (int)mods : 0;

    if (name != NULL && name[0] != '\0') {
        int nc = 0;
        int nch = 0;

        if (!now_key_named(name, &nc, &nch)) {
            return kNowKeyUnknownName;
        }
        r.code = nc;
        r.ch = nch;
        r.code_known = 1;
        r.char_known = 1;
        if (out != NULL) {
            *out = r;
        }
        return kNowKeyOk;
    }

    if (!code_present && !char_present) {
        return kNowKeyNoKey;
    }
    /* Compared as `long` against small decimal constants, which is the
       one comparison shape this file's opening note permits: the bound is
       the constant, not the type's width, so it means the same thing on a
       64-bit host and a 32-bit guest. */
    if (code_present && (code < 0 || code > (long)kNowKeyCodeMax)) {
        return kNowKeyCodeRange;
    }
    if (char_present && (ch < 0 || ch > (long)kNowKeyCharMax)) {
        return kNowKeyCharRange;
    }

    if (code_present) {
        r.code = (int)code;
        r.code_known = 1;
    }
    if (char_present) {
        r.ch = (int)ch;
        r.char_known = 1;
    }
    if (!r.code_known) {
        int derived = now_key_code_for_char(r.ch);

        if (derived >= 0) {
            r.code = derived;
            r.code_known = 1;
        }
    }
    if (!r.char_known) {
        int derived = now_key_char_for_code(r.code);

        if (derived != 0) {
            r.ch = derived;
            r.char_known = 1;
        }
    }
    if (out != NULL) {
        *out = r;
    }
    return kNowKeyOk;
}

/* Presence for an integer argument already scoped to one JSON object -
   the same two-probe trick input_cmds.c's own arg_int uses and for the
   same reason: a fallback of 0 cannot tell "the caller sent 0" from
   "the caller sent nothing", so two different fallbacks are asked and
   must agree before the value is believed. Kept as its own copy rather
   than shared with input_cmds.c's arg_int: that one is static to a
   Toolbox file this host cc never builds, and this file's whole reason
   to exist is not needing one. */
static int scoped_arg_int(const char *json, const char *key, long *out)
{
    long a = now_json_find_int(json, key, -2147483647L);
    long b = now_json_find_int(json, key, 2147483646L);

    if (a != b) {
        return 0;
    }
    *out = a;
    return 1;
}

void now_key_args_from_wire(const char *request_json,
                            char *name_out, long name_cap,
                            long *code_out, int *code_present_out,
                            long *char_out, int *char_present_out,
                            long *mods_out, int *mods_present_out)
{
    char args[kNowKeyArgsScopeMax];

    name_out[0] = '\0';
    *code_out = 0;
    *char_out = 0;
    *mods_out = 0;

    /* Scoped to the envelope's OWN args object - see this function's
       header comment (input_args.h) for the collision this exists to
       avoid. An absent or malformed args leaves `args` as "", which
       every now_json_find_* below reads as "key absent", the correct
       answer for a request that sent none. */
    (void)now_json_scope_object(request_json, "args", args, (long)sizeof args);

    /* find_string and not find_text: a key name is a protocol token,
       ASCII by contract - the same reading aesend's `event` gets. */
    (void)now_json_find_string(args, "name", name_out, name_cap);
    *code_present_out = scoped_arg_int(args, "code", code_out);
    *char_present_out = scoped_arg_int(args, "char", char_out);
    *mods_present_out = scoped_arg_int(args, "mods", mods_out);
}

/* One space-delimited token into `buf`, returning where to keep reading.
   A token longer than the buffer is truncated and will simply fail to
   match anything, which is the right answer for every caller here. */
static const char *key_token(const char *p, char *buf, int cap)
{
    int n = 0;

    buf[0] = '\0';
    if (p == NULL) {
        return NULL;
    }
    while (*p == ' ' || *p == '\t') {
        p++;
    }
    while (*p != '\0' && *p != ' ' && *p != '\t') {
        if (n < cap - 1) {
            buf[n++] = *p;
        }
        p++;
    }
    buf[n] = '\0';
    return p;
}

static int key_is_modifier_word(const char *tok)
{
    return strcmp(tok, "cmd") == 0 || strcmp(tok, "command") == 0
        || strcmp(tok, "option") == 0 || strcmp(tok, "opt") == 0
        || strcmp(tok, "shift") == 0 || strcmp(tok, "control") == 0
        || strcmp(tok, "ctrl") == 0;
}

/* Digits only, and no sign: every number this grammar takes is a small
   non-negative one, and `-1` is a range complaint rather than a parse. */
static int key_decimal(const char *tok, long *out)
{
    long value = 0;
    int  i;

    if (tok[0] == '\0') {
        return 0;
    }
    for (i = 0; tok[i] != '\0'; i++) {
        if (tok[i] < '0' || tok[i] > '9') {
            return 0;
        }
        if (i >= 5) {                 /* far past any legal key number */
            return 0;
        }
        value = value * 10 + (tok[i] - '0');
    }
    *out = value;
    return 1;
}

NowKeyStatus now_key_parse_line(const char *args, NowKeyRequest *out)
{
    char        tok[kNowKeyNameMax + 1];
    char        num[kNowKeyNameMax + 1];
    const char *p;
    long        value = 0;
    int         i;

    if (out != NULL) {
        out->code = 0;
        out->ch = 0;
        out->code_known = 0;
        out->char_known = 0;
    }
    p = key_token(args, tok, (int)sizeof tok);
    if (tok[0] == '\0') {
        return kNowKeyNoKey;
    }
    for (i = 0; tok[i] != '\0'; i++) {
        tok[i] = (char)lower((unsigned char)tok[i]);
    }
    if (key_is_modifier_word(tok)) {
        return kNowKeyModifiers;
    }
    if (strcmp(tok, "char") == 0 || strcmp(tok, "code") == 0) {
        int is_code = (strcmp(tok, "code") == 0);

        (void)key_token(p, num, (int)sizeof num);
        if (!key_decimal(num, &value)) {
            return kNowKeyNoKey;
        }
        /* mods_available is 0 for every console call site: the console
           grammar names no process to arm the act plane against (a typed
           line carries no serialHi/serialLo), so it has no route to offer
           regardless of what the extension can do. It is never actually
           consulted here since mods_present is 0 on every one of these
           calls - key_is_modifier_word above already intercepted the one
           console spelling that would have set mods_present. */
        if (is_code) {
            return now_key_check(NULL, value, 1, 0, 0, 0, 0, 0, out);
        }
        return now_key_check(NULL, 0, 0, value, 1, 0, 0, 0, out);
    }
    if (tok[1] == '\0') {
        /* One character is the character, not a key name. `key n` is the
           letter, and there is no key in the table named "n". The case
           the person typed is preserved: re-read the ORIGINAL token,
           because the fold above was for the name comparison. */
        char raw[kNowKeyNameMax + 1];

        (void)key_token(args, raw, (int)sizeof raw);
        return now_key_check(NULL, 0, 0, (long)(unsigned char)raw[0], 1,
                             0, 0, 0, out);
    }
    return now_key_check(tok, 0, 0, 0, 0, 0, 0, 0, out);
}

unsigned int now_key_message(const NowKeyRequest *req)
{
    unsigned int code;
    unsigned int ch;

    if (req == NULL) {
        return 0u;
    }
    code = (unsigned int)req->code & 0xFFu;
    ch = (unsigned int)req->ch & 0xFFu;
    return (code << 8) | ch;
}

const char *now_key_status_code(NowKeyStatus status)
{
    switch (status) {
    case kNowKeyOk:
        return "ok";
    case kNowKeyModifiers:
        return "unsupported";
    case kNowKeyNoKey:
    case kNowKeyUnknownName:
    case kNowKeyCodeRange:
    case kNowKeyCharRange:
    case kNowKeyModRange:
    default:
        return "bad-request";
    }
}

const char *now_key_status_message(NowKeyStatus status)
{
    switch (status) {
    case kNowKeyOk:
        return "ok";
    case kNowKeyModifiers:
        /* NARROWED, 2026-08-01: this used to say the modifier could never
           be posted at all. It can, through the NOW Extension's act
           plane (kNowPeekActOpKey) - PPostEvent is reachable from that
           68K resident context even though it is not from this Carbon
           application. A caller sees this message when that route was
           tried, or would have been, and was not there: the extension is
           absent, stale, dark, or the target process is not pumping its
           event loop right now. Posting the keystroke without the
           modifier would type a bare character and report success, so it
           is refused instead of silently degrading. */
        return "the NOW Extension's act plane could not post a modified "
               "keystroke right now - it may be absent, stale, dark, or "
               "the target process is not pumping its event loop. Posting "
               "the keystroke without the modifier would type a bare "
               "character and report success, so it is refused instead. "
               "For a menu command use `menuact`, which needs no modifier "
               "at all";
    case kNowKeyNoKey:
        return "key requires one of: name (return, escape, tab and the "
               "rest), code (a virtual key code) or char (a character "
               "code)";
    case kNowKeyUnknownName:
        return "that is not a key this verb names. The names are return, "
               "enter, tab, space, delete, escape, help, home, fwddelete, "
               "end, pageup, pagedown, left, right, down, up - anything "
               "else is a character, so send char or code";
    case kNowKeyCodeRange:
        return "code is a virtual key code and must be 0..127";
    case kNowKeyCharRange:
        return "char is one byte of the event message and must be 0..255";
    case kNowKeyModRange:
        return "mods must be 0 or a combination of the standard modifier "
               "bits: cmd 256, shift 512, alphaLock 1024, option 2048, "
               "control 4096";
    default:
        return "key refused the request";
    }
}

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
