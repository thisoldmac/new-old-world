/*
 * input_args_test.c - the input plane's decisions, on a host compiler.
 *
 * `mouseloc`, `key`, `script` and `aesend` each touch the machine in a
 * way this host cannot reproduce, so what is checked here is everything
 * they decide BEFORE they touch it: the modifier refusal and the key
 * tables, the timeout clamp, the CR conversion, the whole-disk-search
 * refusal, the closed four-op vocabulary, and the serials that name no
 * process or name us.
 *
 * Two of these guard hazards whose failure mode is unrecoverable from
 * the guest side, which is the argument for testing them at all:
 *   - `entire contents` wedged a real machine for twelve minutes. There
 *     is no error path after that; the refusal is the only chance.
 *   - a core event addressed at our own serial takes the connection down
 *     mid-reply, so the caller sees a dropped socket rather than an
 *     answer.
 *
 * Mutations watched failing (2026-07-31) - fifteen, each reverted:
 *   - clamp floor 500 -> 0                    : a 0 ms request is honoured
 *   - clamp ceiling 60000 -> 600000           : a ten-minute script is legal
 *   - `present` ignored in now_script_clamp_ms: an absent timeoutMs floors
 *                                               to 500 rather than
 *                                               defaulting to 15000
 *   - timeout_secs rounds down, not up        : 1500 ms is capped at 1 s
 *   - drop the '\n' -> '\r' loop              : a source keeps LF endings
 *   - drop the whole-disk-search refusal      : `entire contents` runs
 *   - phrase_at's space run -> single space   : `entire  contents` passes
 *   - drop the case fold in lower()           : `Entire Contents` passes
 *   - now_script_timed_out: `osa_err != 0 && hit_deadline` -> `hit_deadline`
 *                                             : a script that SUCCEEDED on
 *                                               the deadline is reported as
 *                                               a timeout
 *   - now_ae_op_from_name: strcmp -> strncmp(,,4) : "quitter" maps to quit
 *   - now_ae_check: drop the kNowAeSelf clause    : the guest is asked to
 *                                                   quit itself
 *   - now_ae_check: drop the kNowAeNoProcess clause : (0,0) is sent
 *   - now_ae_serial_same: compare the low half only : a self-quit gets
 *                                                     through on a
 *                                                     differing high half
 *   - now_ae_check: path bound `255` -> `(long)path_length > 0x7FFFFFFFL`
 *     : a 256-byte path is accepted. THIS ONE IS THE REPO'S OWN WIDTH TRAP,
 *     and it is why the real bound is an `int` compared against a small
 *     decimal. A guard written against a `long`'s range is decorative on
 *     one side of this port and load-bearing on the other - this host's
 *     `long` is 64 bits and the guest's is 32 - and a mutation of exactly
 *     that shape passed a native run in this repo today. It is caught here
 *     only because the test asserts the BEHAVIOUR (256 is refused) rather
 *     than the expression.
 */

#include "input_args.h"

#include <stdio.h>
#include <string.h>

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        g_failures++;
    }
}

/* Static, because the type's own header says so: 2 KB plus a wrapper is
   exactly the fat frame an OSA call must not sit on. Held to here too,
   so the test does not model a shape the guest is forbidden. */
static NowScriptRequest g_req;

static NowScriptStatus prepare(const char *src, long ms, int present)
{
    return now_script_prepare(src, src == NULL ? -1 : (int)strlen(src),
                              ms, present, &g_req);
}

/* The result must FIT. Upstream returned 4096 bytes down a socket it
   owned; NOW's command.result is built in a 3072-byte buffer in
   src/core/wire.c, and an output that does not fit is not truncated
   politely - it is cut by the serializer at whatever byte ran out and
   sent as if it were whole. This is arithmetic rather than a
   measurement, and that is the point: it is the kind of number that
   drifts silently, so it fails here instead. */
static void test_reply_budget(void)
{
    check(kNowScriptEscMax + kNowScriptRowOverhead <= kNowScriptReplyBudget,
          "the escaped result plus the envelope fits wire.c's result buffer");
    check(kNowScriptOutMax <= kNowScriptEscMax,
          "a result that escapes 1:1 - which ASCII AppleScript output does - "
          "always fits without truncation");
    check(kNowScriptOutMax < 4096,
          "and it is NOT upstream's 4096, deliberately: that number was "
          "measured against a guest with a whole socket to write to");
}

static void test_clamp(void)
{
    check(now_script_clamp_ms(0, 0) == kNowScriptDefaultMs,
          "no timeoutMs at all is the default, not the floor");
    check(now_script_clamp_ms(15000, 0) == kNowScriptDefaultMs,
          "and the value is ignored when the key was absent");
    check(now_script_clamp_ms(0, 1) == kNowScriptMinMs,
          "a caller who sent 0 asked for something, and gets the floor");
    check(now_script_clamp_ms(-5000, 1) == kNowScriptMinMs,
          "so does a caller who sent a negative");
    check(now_script_clamp_ms(499, 1) == kNowScriptMinMs, "one under the floor");
    check(now_script_clamp_ms(500, 1) == 500, "the floor itself is honoured");
    check(now_script_clamp_ms(30000, 1) == 30000, "and so is the middle");
    check(now_script_clamp_ms(60000, 1) == kNowScriptMaxMs, "the ceiling");
    check(now_script_clamp_ms(60001, 1) == kNowScriptMaxMs,
          "one over it is capped, not refused");
    check(now_script_clamp_ms(3600000L, 1) == kNowScriptMaxMs,
          "an hour is capped: this guest is serial and nothing else runs");
}

static void test_source_bounds(void)
{
    static char big[kNowScriptSrcMax + 8];

    check(prepare(NULL, 0, 0) == kNowScriptNoSource, "no source, no script");
    check(prepare("", 0, 0) == kNowScriptNoSource, "and empty is no source");

    memset(big, 'x', sizeof big);
    big[kNowScriptSrcMax] = '\0';
    check(prepare(big, 0, 0) == kNowScriptOk,
          "2048 bytes is the largest source accepted");
    /* The wrapper's 64 bytes of headroom is enough for a maximum-length
       source at every legal timeout (the longest wrapper is 26 + 12
       bytes), so the unwrapped fallback in prepare() is DEFENSIVE and
       unreachable from the wire. Pinned here so a later change to
       kNowScriptWrapExtra makes that claim false out loud. */
    check(g_req.wrapped == 1,
          "and the wrapper still fits around it - the unwrapped fallback is "
          "defensive, not a path the wire can reach");
    check(g_req.length > kNowScriptSrcMax
          && g_req.length < (int)sizeof g_req.text,
          "wrapped, and inside the buffer");

    big[kNowScriptSrcMax] = 'x';
    big[kNowScriptSrcMax + 1] = '\0';
    check(prepare(big, 0, 0) == kNowScriptSourceTooLong,
          "2049 is refused rather than truncated - a truncated script is a "
          "DIFFERENT script and it would run");
}

static void test_wrapping_and_line_endings(void)
{
    check(prepare("tell application \"Finder\"\nactivate\nend tell",
                  1500, 1) == kNowScriptOk, "an ordinary script prepares");
    check(g_req.wrapped == 1, "and gets the timeout wrapper");
    check(g_req.timeout_ms == 1500, "at the timeout it asked for");
    check(g_req.timeout_secs == 2,
          "rounded UP: a 1500 ms request must not be capped at one second");
    check(strstr(g_req.text, "with timeout of 2 seconds") != NULL,
          "the wrapper names that many seconds");
    check(strstr(g_req.text, "end timeout") != NULL, "and closes itself");
    check(strchr(g_req.text, '\n') == NULL,
          "NO LF SURVIVES: classic AppleScript's terminator is CR, and an "
          "LF source parses as one very long line");
    check(strchr(g_req.text, '\r') != NULL, "the CRs are there");
    check(g_req.lines == 5,
          "wrapper line, three source lines, and the closing line");
    check((int)strlen(g_req.text) == g_req.length,
          "the reported length is the string's");

    /* A source already using CR is left alone rather than doubled. */
    check(prepare("beep\rbeep", 0, 0) == kNowScriptOk, "a CR source prepares");
    check(strchr(g_req.text, '\n') == NULL, "and stays CR-only");
}

static void test_whole_disk_search(void)
{
    check(now_script_is_whole_disk_search("entire contents", 15) == 1,
          "the phrase itself");
    check(now_script_is_whole_disk_search("Entire Contents", 15) == 1,
          "case does not save it");
    check(now_script_is_whole_disk_search("ENTIRE\tCONTENTS", 15) == 1,
          "and neither does a tab");
    check(now_script_is_whole_disk_search("entire  contents", 16) == 1,
          "nor two spaces");
    check(now_script_is_whole_disk_search(
              "get every item of entire contents of window 1", 45) == 1,
          "found mid-source");
    check(now_script_is_whole_disk_search("entirecontents", 14) == 0,
          "one word is not the phrase");
    check(now_script_is_whole_disk_search("entire", 6) == 0,
          "and neither is half of it, even at the very end");
    check(now_script_is_whole_disk_search("count windows", 13) == 0,
          "an ordinary script is not a search");
    check(now_script_is_whole_disk_search(NULL, 0) == 0, "nothing is not one");

    check(prepare("tell application \"Finder\" to get entire contents of "
                  "disk 1", 0, 0) == kNowScriptSearches,
          "and prepare refuses it: the wedge is not recoverable from here, "
          "so there is no error path after the fact");
    check(strcmp(now_script_status_code(kNowScriptSearches), "refused") == 0,
          "refused, which is not the same code as a malformed request");
    check(strstr(now_script_status_message(kNowScriptSearches),
                 "entire contents") != NULL,
          "and the message names the phrase, so the caller can fix it");
}

static void test_timeout_classification(void)
{
    check(now_script_timed_out(1, 0, 0) == 1,
          "the active procedure firing is a timeout on its own");
    check(now_script_timed_out(0, -1712, 1) == 1,
          "an error that reached the deadline is a timeout - a `with "
          "timeout` cap arrives as a GENERIC OSA error, not errAETimeout");
    check(now_script_timed_out(0, -1728, 0) == 0,
          "an error well inside the deadline is that error, not a timeout");
    check(now_script_timed_out(0, 0, 1) == 0,
          "AND A SUCCESS ON THE DEADLINE IS A SUCCESS. Reporting it as a "
          "timeout would discard a result the machine actually produced");
    check(now_script_timed_out(0, 0, 0) == 0, "the ordinary case");
}

static void test_ae_vocabulary(void)
{
    check(now_ae_op_from_name("quit") == kNowAeOpQuit, "quit");
    check(now_ae_op_from_name("oapp") == kNowAeOpOpenApp, "oapp");
    check(now_ae_op_from_name("odoc") == kNowAeOpOpenDoc, "odoc");
    check(now_ae_op_from_name("pdoc") == kNowAeOpPrintDoc, "pdoc");
    check(now_ae_op_from_name("dele") == kNowAeOpNone,
          "a real four-char code this plane does not serve is not served");
    check(now_ae_op_from_name("quitter") == kNowAeOpNone,
          "and a prefix is not a match - the vocabulary is exact");
    check(now_ae_op_from_name("qui") == kNowAeOpNone, "nor is a truncation");
    check(now_ae_op_from_name("QUIT") == kNowAeOpNone, "nor another case");
    check(now_ae_op_from_name("") == kNowAeOpNone, "nor nothing");
    check(now_ae_op_from_name(NULL) == kNowAeOpNone, "nor NULL");

    check(strcmp(now_ae_op_name(kNowAeOpPrintDoc), "pdoc") == 0,
          "the names round-trip");
    check(now_ae_op_needs_document(kNowAeOpOpenDoc) == 1, "odoc carries one");
    check(now_ae_op_needs_document(kNowAeOpPrintDoc) == 1, "pdoc carries one");
    check(now_ae_op_needs_document(kNowAeOpQuit) == 0, "quit does not");
    check(now_ae_op_needs_document(kNowAeOpOpenApp) == 0, "nor does oapp");
}

static void test_ae_serials(void)
{
    check(now_ae_serial_is_none(0, 0) == 1, "(0,0) is kNoProcess");
    check(now_ae_serial_is_none(0, 1) == 0, "(0,1) is a process");
    check(now_ae_serial_is_none(1, 0) == 0, "and so is (1,0)");
    check(now_ae_serial_same(0, 7, 0, 7) == 1, "same serial");
    check(now_ae_serial_same(0, 7, 0, 8) == 0, "different low half");
    check(now_ae_serial_same(1, 7, 0, 7) == 0,
          "AND A DIFFERENT HIGH HALF IS A DIFFERENT PROCESS. Comparing only "
          "the low half is how a self-quit gets through");
    /* The high half is a full 32 bits on the guest and 64 on this host;
       the comparison must not care. */
    check(now_ae_serial_same(0xFFFFFFFFUL, 2, 0xFFFFFFFFUL, 2) == 1,
          "a serial with the top bit set compares equal to itself");
    check(now_ae_serial_same(0xFFFFFFFFUL, 2, 0x7FFFFFFFUL, 2) == 0,
          "and unequal to one that differs only above the sign bit");
}

static void test_ae_gate(void)
{
    NowAeOp     op = kNowAeOpQuit;
    NowAeStatus st;
    const unsigned long me_hi = 0, me_lo = 0x5A5A;

    st = now_ae_check("quit", 1, 0, 0x1234, me_hi, me_lo, -1, &op);
    check(st == kNowAeOk && op == kNowAeOpQuit, "a plain quit passes");

    st = now_ae_check(NULL, 1, 0, 0x1234, me_hi, me_lo, -1, &op);
    check(st == kNowAeNoEvent && op == kNowAeOpNone, "no event, no send");

    st = now_ae_check("dele", 1, 0, 0x1234, me_hi, me_lo, -1, &op);
    check(st == kNowAeUnknownEvent && op == kNowAeOpNone,
          "an off-vocabulary event is refused BEFORE the serial is looked "
          "at, so a caller learns the real objection");

    st = now_ae_check("quit", 0, 0, 0, me_hi, me_lo, -1, &op);
    check(st == kNowAeNoSerial,
          "there is no frontmost default: an event must name its target");

    st = now_ae_check("quit", 1, 0, 0, me_hi, me_lo, -1, &op);
    check(st == kNowAeNoProcess,
          "(0,0) is refused here rather than sent and returned as "
          "procNotFound - same answer, no Apple Event");

    st = now_ae_check("quit", 1, me_hi, me_lo, me_hi, me_lo, -1, &op);
    check(st == kNowAeSelf,
          "AND WE REFUSE TO QUIT OURSELVES. Sent, it would answer the caller "
          "with a dropped socket");
    st = now_ae_check("oapp", 1, me_hi, me_lo, me_hi, me_lo, -1, &op);
    check(st == kNowAeSelf, "the refusal is per-target, not per-op");

    st = now_ae_check("odoc", 1, 0, 0x1234, me_hi, me_lo, -1, &op);
    check(st == kNowAeNoPath && op == kNowAeOpOpenDoc,
          "odoc with no path is refused, and the op is still reported");
    st = now_ae_check("pdoc", 1, 0, 0x1234, me_hi, me_lo, 0, &op);
    check(st == kNowAeNoPath, "an empty path is no path");
    st = now_ae_check("pdoc", 1, 0, 0x1234, me_hi, me_lo, 255, &op);
    check(st == kNowAeOk, "255 bytes is the longest a Str255 holds");
    st = now_ae_check("pdoc", 1, 0, 0x1234, me_hi, me_lo, 256, &op);
    check(st == kNowAePathTooLong, "256 is refused rather than truncated");
    st = now_ae_check("quit", 1, 0, 0x1234, me_hi, me_lo, 900, &op);
    check(st == kNowAeOk, "a path quit has no use for is simply not read");

    check(strcmp(now_ae_status_code(kNowAeNoProcess), "not-found") == 0,
          "a serial naming nothing is not-found, not bad-request");
    check(strcmp(now_ae_status_code(kNowAeUnknownEvent), "bad-request") == 0,
          "an unserved event is the caller's error");
    check(strstr(now_ae_status_message(kNowAeUnknownEvent), "class/id")
          != NULL,
          "and the message says why there is no general form");
}

/* ---- key --------------------------------------------------------------
 *
 * The verb whose most important behaviour is a REFUSAL, so that is what
 * most of this section is about. A `key` that accepted `mods` and posted
 * the keystroke without them would type a bare character and report
 * success - the exact defect the upstream act plane paid for - and no
 * test that only checked the happy path would notice.
 */
static void test_key_modifiers(void)
{
    NowKeyRequest req;

    check(now_key_check(NULL, 0, 0, 'n', 1, 0x0100, 1, &req)
          == kNowKeyModifiers,
          "a command modifier is REFUSED, never dropped");
    check(now_key_check("return", 0, 0, 0, 0, 0x0200, 1, &req)
          == kNowKeyModifiers,
          "and refused for a named key too");
    /* Refused BEFORE any other complaint: a caller that asked for
       Command-<nothing> is told about the modifier, not about the
       missing key, because the modifier is the reason it will never
       work. */
    check(now_key_check(NULL, 0, 0, 0, 0, 0x0100, 1, &req)
          == kNowKeyModifiers,
          "the modifier refusal outranks every other argument complaint");
    check(now_key_check(NULL, 999, 1, 0, 0, 0x0100, 1, &req)
          == kNowKeyModifiers,
          "including an out-of-range code");

    check(now_key_check(NULL, 0, 0, 'n', 1, 0, 1, &req) == kNowKeyOk,
          "mods 0 is a caller saying `none`, which is what this verb does");
    check(now_key_check(NULL, 0, 0, 'n', 1, 0, 0, &req) == kNowKeyOk,
          "and an absent mods is the same request");

    check(strcmp(now_key_status_code(kNowKeyModifiers), "unsupported") == 0,
          "the modifier refusal is `unsupported`, not the caller's error");
    check(strstr(now_key_status_message(kNowKeyModifiers), "PPostEvent")
          != NULL,
          "and the message names the call that is missing");
    check(strstr(now_key_status_message(kNowKeyModifiers), "menuact")
          != NULL,
          "and the verb to use instead");
}

static void test_key_resolution(void)
{
    NowKeyRequest req;
    int           code = -1;
    int           ch = -1;

    check(now_key_check(NULL, 0, 0, 0, 0, 0, 0, &req) == kNowKeyNoKey,
          "no name, no code and no char is not a keystroke");
    check(now_key_check("wiggle", 0, 0, 0, 0, 0, 0, &req)
          == kNowKeyUnknownName,
          "a name the table does not have is refused, not guessed at");

    check(now_key_named("return", &code, &ch) && code == 36 && ch == 13,
          "return is code 36, character 13");
    check(now_key_named("escape", &code, &ch) && code == 53 && ch == 27,
          "escape is code 53, character 27");
    check(now_key_named("enter", &code, &ch) && code == 76,
          "enter is the keypad's key, 76, and is not return");
    check(!now_key_named("Return", &code, &ch),
          "the name table is matched exactly; the caller folds case");

    /* The one number in either table that a live machine agreed with. */
    check(now_key_code_for_char('n') == 45,
          "n is virtual key code 45, which upstream measured");
    check(now_key_code_for_char('N') == 45,
          "and N is the same KEY - the difference is a modifier we "
          "cannot send, so the code is the unshifted one");
    check(now_key_char_for_code(45) == 'n', "and 45 reads back as n");
    check(now_key_code_for_char('@') == -1,
          "a character with no unshifted key of its own has no code");

    /* char alone: the code half is derived, and the character is passed
       through with its case intact - which is what makes an upper-case
       letter type correctly with no shift. */
    check(now_key_check(NULL, 0, 0, 'N', 1, 0, 0, &req) == kNowKeyOk
          && req.code == 45 && req.ch == 'N'
          && req.code_known && req.char_known,
          "char N derives code 45 and keeps the character it was given");
    check(now_key_check(NULL, 0, 0, '@', 1, 0, 0, &req) == kNowKeyOk
          && req.ch == '@' && !req.code_known && req.code == 0,
          "an underivable code is reported as unknown, not invented");
    /* code alone: the character half is derived. */
    check(now_key_check(NULL, 36, 1, 0, 0, 0, 0, &req) == kNowKeyOk
          && req.ch == 13 && req.char_known,
          "code 36 derives the carriage return it types");
    check(now_key_check(NULL, 10, 1, 0, 0, 0, 0, &req) == kNowKeyOk
          && req.ch == 0 && !req.char_known,
          "a code with no character says so rather than sending one");
    /* Both: neither is derived and neither is second-guessed. */
    check(now_key_check(NULL, 45, 1, 3, 1, 0, 0, &req) == kNowKeyOk
          && req.code == 45 && req.ch == 3,
          "a caller that sent both halves gets both halves back");

    check(now_key_check(NULL, -1, 1, 0, 0, 0, 0, &req) == kNowKeyCodeRange,
          "a negative code is refused");
    check(now_key_check(NULL, 127, 1, 0, 0, 0, 0, &req) == kNowKeyOk,
          "127 is the last virtual key code");
    check(now_key_check(NULL, 128, 1, 0, 0, 0, 0, &req) == kNowKeyCodeRange,
          "128 is refused rather than masked down to 0");
    check(now_key_check(NULL, 0, 0, 255, 1, 0, 0, &req) == kNowKeyOk,
          "255 is the last character code");
    check(now_key_check(NULL, 0, 0, 256, 1, 0, 0, &req) == kNowKeyCharRange,
          "256 is refused rather than masked down to 0");
}

static void test_key_message(void)
{
    NowKeyRequest req;

    check(now_key_check("return", 0, 0, 0, 0, 0, 0, &req) == kNowKeyOk,
          "return resolves");
    check(now_key_message(&req) == 0x240Du,
          "the message is code in the second byte, character in the low");
    check(now_key_check(NULL, 0, 0, 'n', 1, 0, 0, &req) == kNowKeyOk,
          "n resolves");
    check(now_key_message(&req) == 0x2D6Eu, "code 45, character 0x6E");
    /* The bound that a masked-off shift would hide. A message built by
       OR-ing an unmasked code would corrupt the byte above it. */
    req.code = 0x1FF;
    req.ch = 0x1FF;
    check(now_key_message(&req) == 0xFFFFu,
          "both halves are masked to a byte, so neither can climb");
}

static void test_key_console_grammar(void)
{
    NowKeyRequest req;

    check(now_key_parse_line("", &req) == kNowKeyNoKey,
          "an empty line names no key");
    check(now_key_parse_line("   ", &req) == kNowKeyNoKey,
          "and neither does whitespace");
    check(now_key_parse_line("return", &req) == kNowKeyOk
          && req.code == 36, "a name is a name");
    check(now_key_parse_line("  RETURN  ", &req) == kNowKeyOk
          && req.code == 36, "typed case and padding do not matter");
    check(now_key_parse_line("n", &req) == kNowKeyOk
          && req.ch == 'n' && req.code == 45,
          "one character is that character, not a key named n");
    check(now_key_parse_line("N", &req) == kNowKeyOk && req.ch == 'N',
          "and the case a person typed survives the fold used to match "
          "names");
    check(now_key_parse_line("char 13", &req) == kNowKeyOk
          && req.ch == 13 && req.code == 36,
          "char N is the character, and the code follows");
    check(now_key_parse_line("code 36", &req) == kNowKeyOk
          && req.code == 36 && req.ch == 13,
          "code N is the code, and the character follows");
    check(now_key_parse_line("char", &req) == kNowKeyNoKey,
          "char with no number is not a keystroke");
    check(now_key_parse_line("code -1", &req) == kNowKeyNoKey,
          "a sign is not part of this grammar");
    check(now_key_parse_line("code 128", &req) == kNowKeyCodeRange,
          "and the typed face gets the same bound as the wire's");
    check(now_key_parse_line("wiggle", &req) == kNowKeyUnknownName,
          "a word that is not a name and not one character is refused");

    /* The person who types the thing this verb cannot do gets the real
       reason rather than a list of names not containing their word. */
    check(now_key_parse_line("cmd n", &req) == kNowKeyModifiers,
          "cmd n is answered with the modifier wall");
    check(now_key_parse_line("Command Q", &req) == kNowKeyModifiers,
          "and so is Command Q");
    check(now_key_parse_line("shift tab", &req) == kNowKeyModifiers,
          "and shift tab");
    check(now_key_parse_line("option x", &req) == kNowKeyModifiers,
          "and option x");
}

int main(void)
{
    test_key_modifiers();
    test_key_resolution();
    test_key_message();
    test_key_console_grammar();
    test_reply_budget();
    test_clamp();
    test_source_bounds();
    test_wrapping_and_line_endings();
    test_whole_disk_search();
    test_timeout_classification();
    test_ae_vocabulary();
    test_ae_serials();
    test_ae_gate();

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("input_args: ok\n");
    return 0;
}
