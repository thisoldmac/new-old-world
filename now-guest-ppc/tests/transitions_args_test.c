/*
 * `transitions start`, parsed from a WHOLE request frame.
 *
 * This test exists because of a specific, expensive absence. P5 shipped
 * with an arg key that could not be read, past a green suite, and the
 * reason the suite was green is written into every fixture below: every
 * existing test entered the plane BELOW the parse, with a
 * NowTransitionsStartReq a test had filled in by hand. The parse itself
 * sat in a static function above `#include <Carbon.h>`, where no host
 * compiler could reach it and no test ever had.
 *
 * The defect was one key. `transitions start` read its target with
 * `now_json_find_string(json, "name", ...)` where `json` is the whole
 * request — and every request envelope already carries `"name"`, the
 * verb's own:
 *
 *   {"type":"command.request","id":101,"name":"transitions",
 *    "args":{"op":"start","serialHi":0,"serialLo":34734082}}
 *
 * The classic guest scans a frame FLAT and first occurrence wins, so the
 * target was always the literal string `transitions`, which is never a
 * running process. Worse, the by-name route is tried BEFORE the
 * serial/front/a5 selector, so it short-circuited every other route too:
 * `transitions start` could not arm AT ALL, by any route, and P5's plane
 * could never publish. Proven three ways on a live emulated Power Mac G4,
 * all giving the identical by-NAME refusal.
 *
 * SO EVERY FIXTURE HERE CARRIES A REAL ENVELOPE. That is the whole point
 * and not decoration: the collision is invisible in the presence of an
 * `args` object alone, which is exactly why a bare-args fixture would
 * have shipped this bug just as happily. A test that feeds this function
 * only the inner object is not a weaker version of this test — it is the
 * test that already passed while the verb did not work.
 *
 * The contract's preamble states the rule these fixtures enforce: an arg
 * key must not shadow an envelope key (type, id, name, args, line).
 * `launch` shipped it once with an arg named "name"; the family uses
 * "target". contract_arg_key_source_test.py holds the whole family to it.
 */
#include <stdio.h>
#include <string.h>

#include "transitions_logic.h"

static int failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++failures;
    }
}

/* A request frame exactly as the wire delivers it. Every field the real
   envelope carries is here, in the real order, because the bug lived in
   the ORDER: `name` before `args`. */
static const char *kFrameByTarget =
    "{\"type\":\"command.request\",\"id\":101,\"name\":\"transitions\","
    "\"args\":{\"op\":\"start\",\"target\":\"New Old World\"}}";

static const char *kFrameBySerial =
    "{\"type\":\"command.request\",\"id\":101,\"name\":\"transitions\","
    "\"args\":{\"op\":\"start\",\"serialHi\":0,\"serialLo\":34734082}}";

static const char *kFrameByFront =
    "{\"type\":\"command.request\",\"id\":101,\"name\":\"transitions\","
    "\"args\":{\"op\":\"start\",\"front\":true}}";

static const char *kFrameBare =
    "{\"type\":\"command.request\",\"id\":101,\"name\":\"transitions\","
    "\"args\":{\"op\":\"start\"}}";

int main(void)
{
    NowTransitionsStartReq req;
    char target[64];

    /* ---- the defect itself -------------------------------------------
     *
     * The one assertion that would have caught it. Against the shipped
     * code this reads "transitions" — the envelope's verb name — and this
     * check fails naming the string it actually got.
     */
    check(now_transitions_start_args(kFrameByTarget, &req, target,
                                     (long)sizeof target)
              == kNowTransitionsArgsOK,
          "a well-formed start frame parses");
    check(req.target != NULL && strcmp(req.target, "New Old World") == 0,
          "the target comes from args, NOT from the envelope's own name");
    /* Stated separately and deliberately redundantly: this is the exact
       value the bug produced, and a future reader should see it refused
       by name rather than have to infer it from the check above. */
    check(req.target == NULL || strcmp(req.target, "transitions") != 0,
          "the target is never the verb's own name");

    /* ---- the short-circuit -------------------------------------------
     *
     * Each of these is a route the by-name read STOLE. A frame that names
     * no target must leave `target` absent, or now_transitions_start
     * never reaches its selector at all — which is how a serial, a front
     * and a bare frame all refused `no-process` on metal.
     */
    check(now_transitions_start_args(kFrameBySerial, &req, target,
                                     (long)sizeof target)
              == kNowTransitionsArgsOK,
          "a serial-targeted start frame parses");
    check(req.target == NULL || req.target[0] == '\0',
          "a serial frame names no target, so the selector gets its turn");
    check(req.has_serial_hi && req.has_serial_lo,
          "both serial halves are seen");
    check(req.serial_lo == 34734082UL, "serialLo survives the envelope");
    check(req.serial_hi == 0, "serialHi of zero is present, not absent");

    check(now_transitions_start_args(kFrameByFront, &req, target,
                                     (long)sizeof target)
              == kNowTransitionsArgsOK,
          "a front-targeted start frame parses");
    check(req.target == NULL || req.target[0] == '\0',
          "a front frame names no target either");
    check(req.has_front && req.front_true, "front:true is seen as true");

    check(now_transitions_start_args(kFrameBare, &req, target,
                                     (long)sizeof target)
              == kNowTransitionsArgsOK,
          "a start frame with no target at all parses");
    check(req.target == NULL || req.target[0] == '\0',
          "no target means no target - it must fall to the selector");
    check(!req.has_front && !req.has_serial_hi && !req.has_serial_lo
              && !req.has_a5,
          "and it selects nothing, so start refuses with no-target");

    /* ---- the other envelope keys are not readable as args either -----
     *
     * `type` and `id` shadow nothing this verb wants today, but the rule
     * is a CLASS. A frame whose args deliberately do not carry a5 must
     * not pick one up from anywhere, and the same for ttlTicks.
     */
    check(!req.has_a5, "no a5 arg means no a5, whatever the envelope says");
    check(req.ttl_ticks == 0,
          "an absent ttlTicks is 0 (the default), not a number read from "
          "the envelope's id");

    /* ---- the values that do belong to args --------------------------- */
    check(now_transitions_start_args(
              "{\"type\":\"command.request\",\"id\":7,\"name\":\"transitions\","
              "\"args\":{\"op\":\"start\",\"target\":\"Finder\","
              "\"ttlTicks\":600}}",
              &req, target, (long)sizeof target) == kNowTransitionsArgsOK,
          "a target and a ttl together parse");
    check(req.target != NULL && strcmp(req.target, "Finder") == 0,
          "a one-word target is read whole");
    check(req.ttl_ticks == 600, "ttlTicks comes from args");

    /* A process name with spaces, which is the normal case on this
       machine and the reason the console takes the whole rest of a line.
       `id` is 3600 here on purpose: a parse that read ttlTicks off the
       envelope would look correct against the default. */
    check(now_transitions_start_args(
              "{\"type\":\"command.request\",\"id\":3600,"
              "\"name\":\"transitions\",\"args\":{\"op\":\"start\","
              "\"target\":\"Adobe Photoshop 5.5\"}}",
              &req, target, (long)sizeof target) == kNowTransitionsArgsOK,
          "a spaced target parses");
    check(req.target != NULL
              && strcmp(req.target, "Adobe Photoshop 5.5") == 0,
          "spaces in a process name survive");
    check(req.ttl_ticks == 0,
          "ttlTicks is absent even though the envelope's id is a legal "
          "ttl - the collision class, caught in the other direction");

    /* ---- malformed args still refuse with the field that is wrong ---- */
    check(now_transitions_start_args(
              "{\"type\":\"command.request\",\"id\":1,\"name\":\"transitions\","
              "\"args\":{\"op\":\"start\",\"a5\":\"zzz\"}}",
              &req, target, (long)sizeof target) == kNowTransitionsArgsBadA5,
          "a non-numeric a5 is refused");
    check(strcmp(now_transitions_args_code(kNowTransitionsArgsBadA5),
                 "bad-a5") == 0,
          "and refused under the code the contract names");
    check(now_transitions_start_args(
              "{\"type\":\"command.request\",\"id\":1,\"name\":\"transitions\","
              "\"args\":{\"op\":\"start\",\"serialLo\":\"nope\"}}",
              &req, target, (long)sizeof target)
              == kNowTransitionsArgsBadSerial,
          "a non-numeric serialLo is refused");
    check(now_transitions_start_args(
              "{\"type\":\"command.request\",\"id\":1,\"name\":\"transitions\","
              "\"args\":{\"op\":\"start\",\"front\":\"maybe\"}}",
              &req, target, (long)sizeof target)
              == kNowTransitionsArgsBadFront,
          "a non-boolean front is refused");
    check(now_transitions_start_args(kFrameBare, NULL, target,
                                     (long)sizeof target)
              == kNowTransitionsArgsUnreadable,
          "no request at all is unreadable, not a field refusal");

    /* ---- a target longer than the buffer ------------------------------
     *
     * Not a wire refusal: the walk that resolves it will find nothing by
     * a truncated name and say so honestly. Asserted so that a future
     * change to the buffer is a decision rather than a surprise.
     */
    check(now_transitions_start_args(
              "{\"type\":\"command.request\",\"id\":1,\"name\":\"transitions\","
              "\"args\":{\"op\":\"start\",\"target\":\""
              "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
              "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}}",
              &req, target, (long)sizeof target) == kNowTransitionsArgsOK,
          "an over-long target parses rather than failing the frame");
    check(req.target != NULL && strlen(req.target) < sizeof target,
          "and is bounded by the buffer it was given");

    /* ---- the console's grammar still reaches the same field ----------
     *
     * Parity, in the one place it can be checked without a Toolbox: the
     * console never sends JSON, so the collision never touched it, and
     * this asserts the fix did not quietly move the console's route.
     */
    {
        char op[16];
        const char *rest = now_transitions_parse_line("start Finder", op,
                                                      (long)sizeof op);
        NowTransitionsStartReq console_req;

        memset(&console_req, 0, sizeof console_req);
        console_req.target = rest;
        check(strcmp(op, "start") == 0, "the console line's op is start");
        check(console_req.target != NULL
                  && strcmp(console_req.target, "Finder") == 0,
              "and its target is the rest of the line, in the same field "
              "the wire fills");
    }

    if (failures != 0) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("transitions_args_test: ok\n");
    return 0;
}
