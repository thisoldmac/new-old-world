/*
 * qdtrace_json_test.c - what a drain and a status actually say.
 *
 *   cc -Wall -Wextra -Werror -DNOW_PEEK_TABLE_HOST -I contract \
 *      -I ext/src -I now-guest-ppc/src/content -I now-guest-ppc/src/core \
 *      now-guest-ppc/tests/qdtrace_json_test.c \
 *      now-guest-ppc/src/content/qdtrace_json.c \
 *      now-guest-ppc/src/content/qdtrace_read.c \
 *      now-guest-ppc/src/core/json.c ext/src/now_content_logic.c \
 *      -o /tmp/t && /tmp/t
 *
 * The subject of this file is the ONE property a drain has to have: a
 * short answer says why it is short. There are four different reasons and
 * they must never collapse into each other, because three of them are
 * loss or a retry and the fourth is "this machine is not drawing" - and a
 * caller that cannot tell them apart reads every one of them as the
 * fourth.
 *
 * ONE PATH HERE IS NOT REACHABLE FROM A FIXTURE and is named rather than
 * pretended: the retraction a TORN drain performs (the ops already
 * printed are rolled back before the tail is written). A tear requires
 * the writer to lap the ring BETWEEN the seqlock sample and the
 * re-sample, and from this side of the emitter there is no moment to do
 * that in - the sink belongs to now_qdtrace_drain_json. The tear itself
 * is covered in qdtrace_read_test.c, where the sink is the test's own;
 * what is uncovered is the one line that discards the JSON. It is listed
 * as a gap in this thread's report and it is the first thing to watch
 * when this drains on a real machine.
 *
 * Every reply is also checked for BALANCE - braces and brackets matched
 * outside strings - because the failure mode of an emitter that runs out
 * of room is not a short reply, it is a reply that parses as far as it
 * goes.
 */

#include "qdtrace.h"

#include <stdio.h>
#include <string.h>

static int failures;

static void check_has(const char *hay, const char *needle, const char *what)
{
    if (strstr(hay, needle) == NULL) {
        printf("FAIL %s: no \"%s\" in\n  %s\n", what, needle, hay);
        failures++;
    }
}

static void check_lacks(const char *hay, const char *needle, const char *what)
{
    if (strstr(hay, needle) != NULL) {
        printf("FAIL %s: unexpected \"%s\" in\n  %s\n", what, needle, hay);
        failures++;
    }
}

/* Braces and brackets, matched outside strings. Not a parser - a parser
   would be the third JSON implementation in this repository - but it does
   catch the one thing an out-of-room emitter produces. */
static int balanced(const char *s)
{
    int depth = 0;
    int in_str = 0;

    for (; *s != '\0'; ++s) {
        if (in_str) {
            if (*s == '\\' && s[1] != '\0') {
                s++;
            } else if (*s == '"') {
                in_str = 0;
            }
            continue;
        }
        if (*s == '"') {
            in_str = 1;
        } else if (*s == '{' || *s == '[') {
            depth++;
        } else if (*s == '}' || *s == ']') {
            depth--;
            if (depth < 0) {
                return 0;
            }
        }
    }
    return depth == 0 && !in_str;
}

static void check_balanced(const char *s, const char *what)
{
    if (!balanced(s)) {
        printf("FAIL %s: unbalanced\n  %s\n", what, s);
        failures++;
    }
}

/* ---- fixtures -------------------------------------------------------- */

static NowContentBlock g_block;
static char g_out[4096];

static void init_block(NowContentU32 cap)
{
    memset(&g_block, 0, sizeof g_block);
    g_block.format = (NowContentU16)kNowContentFormatV2;
    g_block.ring_cap = cap;
    g_block.length = (NowContentU32)sizeof(NowContentBlock);
    g_block.magic = (NowContentU32)kNowContentBlockMagic;
}

static void put_bare(NowContentU32 port)
{
    (void)now_content_ring_put(&g_block, kNowContentOpRgn, 0, port, NULL, 0);
}

static void put_text(const char *s, NowContentU16 full_len,
                     unsigned char flags)
{
    NowContentTextPayload tp;
    unsigned char buf[sizeof tp + kNowContentTextMax];
    size_t n = strlen(s);

    memset(&tp, 0, sizeof tp);
    tp.pen_h = 40;
    tp.pen_v = 12;
    tp.tx_font = 1;
    tp.tx_size = 12;
    tp.tx_face = 0;
    tp.len = (unsigned char)n;
    tp.full_len = full_len;
    memcpy(buf, &tp, sizeof tp);
    memcpy(buf + sizeof tp, s, n);
    (void)now_content_ring_put(&g_block, kNowContentOpText, flags, 0x5000u,
                               buf, (NowContentU16)(sizeof tp + n));
}

/* ---- status ---------------------------------------------------------- */

static void test_status_json(void)
{
    NowQDStatus st;

    init_block(4096);
    g_block.counters.text = 41;
    g_block.counters.bits = 0;
    g_block.counters.dropped = 3;
    g_block.counters.skipped_ports = 2;
    g_block.counters.refused_wrong_context = 9;
    g_block.arm_a5 = 0x00123456u;
    g_block.arm_window = 0x00654321u;
    g_block.arm_psn_lo = 42u;
    g_block.arm_generation = 7u;
    g_block.arm_commit = (NowContentU32)kNowContentArmCommit;
    g_block.mode = kNowContentModeRecord;
    g_block.active_a5 = 0;              /* asked for, not yet honoured */
    put_bare(1);

    now_qdtrace_status(&g_block, 0, &st);
    now_qdtrace_status_json(&st, 7, g_out, (long)sizeof g_out);
    check_balanced(g_out, "status is balanced");
    check_has(g_out, "\"id\":7", "status carries the id");
    check_has(g_out, "\"cmd\":\"status\"", "status names itself");

    /* The count-only question, answered without moving a record: text 41
       and bits 0 is upstream's own airtight-re-entrancy-guard reading. */
    check_has(g_out, "\"total\":41", "the op total is there");
    check_has(g_out, "\"text\":41", "and the family that produced it");

    /* Requested versus active, side by side. A request the extension
       never honoured must not look like no request at all. */
    check_has(g_out, "\"request\":{\"a5\":\"0x00123456\"",
              "the request names its target");
    check_has(g_out, "\"committed\":true", "and says it is committed");
    check_has(g_out, "\"window\":\"0x00654321\"",
              "the request names one exact window");
    check_has(g_out, "\"generation\":7",
              "the request carries a monotonic generation");
    check_has(g_out, "\"active\":{\"a5\":\"0x00000000\"",
              "while active says nothing is hooked yet");
    check_has(g_out, "\"refused\":{", "refusal counters are reported");
    check_has(g_out, "\"wrongContext\":9", "including a misaddressed arm");
    check_has(g_out, "\"loss\":{\"dropped\":3,\"skippedPorts\":2}",
              "and loss is its own object, never summed into ops");
}

static void test_status_absent_and_mismatched(void)
{
    NowQDStatus st;

    now_qdtrace_status(NULL, 0, &st);
    now_qdtrace_status_json(&st, 1, g_out, (long)sizeof g_out);
    check_balanced(g_out, "absent status is balanced");
    check_has(g_out, "\"ok\":false", "absent is a refusal");
    check_has(g_out, "content-plane-absent", "named as such");

    init_block(4096);
    g_block.format = 99;
    now_qdtrace_status(&g_block, 0, &st);
    now_qdtrace_status_json(&st, 1, g_out, (long)sizeof g_out);
    check_has(g_out, "content-plane-mismatch", "a wrong format is a mismatch");
    /* The numbers travel with the refusal: a version mismatch whose
       numbers the caller cannot see is a support call. */
    check_has(g_out, "format 99", "with the format it actually found");
}

/* ---- a drain that succeeds -------------------------------------------- */

static void test_drain_json(void)
{
    NowContentRectPayload rp;
    NowContentBitsPayload bp;

    init_block(4096);
    put_text("hi \"there\"", 10, 0);

    memset(&rp, 0, sizeof rp);
    rp.verb = 0;
    rp.l = 10; rp.t = 20; rp.r = 110; rp.b = 60;
    (void)now_content_ring_put(&g_block, kNowContentOpRect, 0, 0x6000u,
                               &rp, (NowContentU16)sizeof rp);

    memset(&bp, 0, sizeof bp);
    bp.sl = 4; bp.st = 4; bp.sr = 418; bp.sb = 147;
    bp.dl = 4; bp.dt = -29; bp.dr = 418; bp.db = 114;
    bp.mode = 8; bp.src_row_bytes = 64;
    (void)now_content_ring_put(&g_block, kNowContentOpBits, 0, 0x6000u,
                               &bp, (NowContentU16)sizeof bp);

    now_qdtrace_drain_json(&g_block, 0, 0, 0, 5, g_out, (long)sizeof g_out);
    check_balanced(g_out, "a drain is balanced");
    check_has(g_out, "\"cmd\":\"drain\"", "the drain names itself");
    check_has(g_out, "\"records\":3", "three records");
    check_has(g_out, "\"more\":false", "and nothing left");
    check_has(g_out, "\"resync\":false", "no loss");
    check_has(g_out, "\"torn\":false", "no tear");
    check_has(g_out, "\"busy\":false", "no commit in flight");

    check_has(g_out, "\"op\":\"text\"", "text decoded");
    check_has(g_out, "\\\"there\\\"", "with its quotes escaped");
    check_has(g_out, "\"pen\":[40,12]", "and its pen");
    check_has(g_out, "\"op\":\"rect\",\"port\":\"0x00006000\"",
              "rect keeps the port that identifies its window");
    /* BITS carries geometry and NEVER pixels - the contract's rule, and
       the visible form of it is that a bits op has no byte field at all.
       A negative dst top is the MoveBits scroll signature. */
    check_has(g_out, "\"dst\":[4,-29,418,114]", "bits keeps a scroll's dst");
    check_lacks(g_out, "\"pixels\"", "and carries no pixels");
    check_lacks(g_out, "\"data\"", "and no data blob");

    check_has(g_out, "\"nextCursor\":", "a cursor to resume from");
}

/* The blit-source record (013): the join key precedes its bits record
   on the wire, as hex strings for `port`'s top-bit reason. */
static void test_drain_blit_source(void)
{
    NowContentBlitSourcePayload jp;
    NowContentBitsPayload bp;
    const char *src;
    const char *bits;

    init_block(4096);
    memset(&jp, 0, sizeof jp);
    jp.src_port = 0x1f472e60u;
    jp.src_pixmap = 0x00445566u;
    (void)now_content_ring_put(&g_block, kNowContentOpBlitSource, 0,
                               0x00AC7AF0u, &jp, (NowContentU16)sizeof jp);
    memset(&bp, 0, sizeof bp);
    bp.sl = 0; bp.st = 0; bp.sr = 404; bp.sb = 203;
    bp.dl = 4; bp.dt = 24; bp.dr = 408; bp.db = 227;
    bp.mode = 0; bp.src_row_bytes = 0x0660u;
    (void)now_content_ring_put(&g_block, kNowContentOpBits, 0, 0x00AC7AF0u,
                               &bp, (NowContentU16)sizeof bp);

    now_qdtrace_drain_json(&g_block, 0, 0, 0, 5, g_out, (long)sizeof g_out);
    check_balanced(g_out, "a blitsrc drain is balanced");
    check_has(g_out, "\"op\":\"blitsrc\"", "blitsrc decoded");
    check_has(g_out, "\"srcPort\":\"0x1f472e60\"", "the source port, hex");
    check_has(g_out, "\"srcPixmap\":\"0x00445566\"", "the source handle, hex");
    src = strstr(g_out, "\"op\":\"blitsrc\"");
    bits = strstr(g_out, "\"op\":\"bits\"");
    if (src == NULL || bits == NULL || src > bits) {
        printf("FAIL blitsrc precedes the bits record it names\n  %s\n",
               g_out);
        failures++;
    }
}

/* The world records on the wire (plan 014): born carries shape, died
   deliberately does not. */
static void test_drain_world_records(void)
{
    NowContentWorldPayload wp;

    init_block(4096);
    memset(&wp, 0, sizeof wp);
    wp.port = 0x1f472e60u;
    wp.pixmap = 0x00445566u;
    wp.l = 0; wp.t = 0; wp.r = 490; wp.b = 448;
    (void)now_content_ring_put(&g_block, kNowContentOpWorldBorn, 0,
                               wp.port, &wp, (NowContentU16)sizeof wp);
    memset(&wp, 0, sizeof wp);
    wp.port = 0x1f472e60u;
    (void)now_content_ring_put(&g_block, kNowContentOpWorldDied, 0,
                               wp.port, &wp, (NowContentU16)sizeof wp);

    now_qdtrace_drain_json(&g_block, 0, 0, 0, 7, g_out, (long)sizeof g_out);
    check_balanced(g_out, "world records are balanced");
    check_has(g_out, "\"op\":\"worldborn\"", "born decoded");
    check_has(g_out, "\"world\":\"0x1f472e60\"", "and names its world");
    check_has(g_out, "\"rect\":[0,0,490,448]", "with the world's shape");
    check_has(g_out, "\"op\":\"worlddied\"", "died decoded");
}

static void test_drain_truncation_flag(void)
{
    init_block(4096);
    put_text("abc", 400, kNowContentFlagTruncText);
    now_qdtrace_drain_json(&g_block, 0, 0, 0, 5, g_out, (long)sizeof g_out);
    check_has(g_out, "\"trunc\":true", "a truncated run says so");
    check_has(g_out, "\"fullLen\":400", "and still reports its true length");
    check_has(g_out, "\"len\":3", "beside the bytes that are really there");
}

/* ---- the four ways an answer ends short ------------------------------- */

static void test_more_is_not_silence(void)
{
    int i;

    init_block(4096);
    for (i = 0; i < 10; ++i) {
        put_bare((NowContentU32)i);
    }
    now_qdtrace_drain_json(&g_block, 0, 0, 3u, 5, g_out, (long)sizeof g_out);
    check_balanced(g_out, "a bounded drain is balanced");
    check_has(g_out, "\"records\":3", "three of ten");
    check_has(g_out, "\"more\":true", "and the rest is announced");
    check_has(g_out, "\"pending\":224", "with the byte count still waiting");
}

/* The output budget, not the ring budget, is what ends a drain in
   practice: a 4096-byte control frame fills long before a 64 KiB ring
   does. A buffer too small for even one record must still produce a
   VALID, HONEST reply - not a truncated object. */
static void test_output_budget_ends_it_honestly(void)
{
    char small[600];
    int i;

    init_block(4096);
    for (i = 0; i < 20; ++i) {
        put_bare((NowContentU32)i);
    }
    now_qdtrace_drain_json(&g_block, 0, 0, 0, 5, small, (long)sizeof small);
    check_balanced(small, "a cramped drain is still balanced");
    check_has(small, "\"more\":true", "and still says there is more");
    check_has(small, "\"nextCursor\":0",
              "with a cursor that did not advance past what it could not print");
}

static void test_overrun_is_reported_not_hidden(void)
{
    int i;

    init_block(256);
    for (i = 0; i < 30; ++i) {
        put_bare((NowContentU32)i);
    }
    now_qdtrace_drain_json(&g_block, 0, 0, 0, 5, g_out, (long)sizeof g_out);
    check_balanced(g_out, "an overrun drain is balanced");
    check_has(g_out, "\"ok\":true", "an overrun is not an error");
    check_has(g_out, "\"resync\":true", "it is a resync");
    /* 30 bare records are 364 bytes, not 360: one of them absorbed the
       4-byte tail the ring could not hold a header in. 364 - 256 = 108,
       and the number being ODD-LOOKING is the point - it is measured
       from the ring, not from a multiplication. */
    check_has(g_out, "\"lostBytes\":704", "with the bytes lost, exactly");
    check_has(g_out, "\"records\":0", "and no records invented from it");
    /* The distinction this whole file exists for: a resync is NOT a
       `more`, and a caller must not read it as one. */
    check_has(g_out, "\"more\":false", "an overrun is not a `more`");
}

/* A RESYNC AND A `MORE` ARE NOT THE SAME SHORT ANSWER, and this is the
   pair a caller is most likely to conflate: both end early, one is loss
   and one is pacing. They must never both be true, and the caller's
   remedy differs - one re-drains from nextCursor and has lost nothing,
   the other has a hole in its history. */
static void test_resync_and_more_are_never_confused(void)
{
    int i;

    init_block(256);
    for (i = 0; i < 30; ++i) {
        put_bare((NowContentU32)i);
    }
    now_qdtrace_drain_json(&g_block, 0, 0, 0, 5, g_out, (long)sizeof g_out);
    check_has(g_out, "\"resync\":true", "lapped: resync");
    check_has(g_out, "\"more\":false", "and not `more`");

    init_block(4096);
    for (i = 0; i < 30; ++i) {
        put_bare((NowContentU32)i);
    }
    now_qdtrace_drain_json(&g_block, 0, 0, 5u, 5, g_out, (long)sizeof g_out);
    check_has(g_out, "\"more\":true", "bounded: more");
    check_has(g_out, "\"resync\":false", "and not a resync");
    check_has(g_out, "\"lostBytes\":0", "with nothing lost");
}

static void test_busy_says_call_again(void)
{
    init_block(256);
    put_bare(1);
    g_block.seq |= 1u;

    now_qdtrace_drain_json(&g_block, 0, 0, 0, 5, g_out, (long)sizeof g_out);
    check_balanced(g_out, "a busy drain is balanced");
    check_has(g_out, "\"busy\":true", "busy is said out loud");
    check_has(g_out, "\"records\":0", "with nothing read under it");
    check_has(g_out, "\"ops\":[]", "and an empty ops array, not a partial one");
}

/* ---- the refusals ----------------------------------------------------- */

static void test_drain_refusals(void)
{
    NowContentRecHeader h;

    now_qdtrace_drain_json(NULL, 0, 0, 0, 5, g_out, (long)sizeof g_out);
    check_balanced(g_out, "absent drain is balanced");
    check_has(g_out, "content-plane-absent", "no block is a refusal");

    init_block(256);
    g_block.magic = 0;
    now_qdtrace_drain_json(&g_block, 0, 0, 0, 5, g_out, (long)sizeof g_out);
    check_has(g_out, "content-plane-mismatch", "a bad block is a refusal");

    /* Corruption is a REFUSAL, not an empty drain. The remedy is to stop
       and re-arm, not to poll again, and an empty ok reply would send the
       caller round the loop forever. */
    init_block(256);
    memset(&h, 0, sizeof h);
    h.size = 4;
    memcpy(&g_block.ring[0], &h, sizeof h);
    g_block.write_cursor = 64;
    now_qdtrace_drain_json(&g_block, 0, 0, 0, 5, g_out, (long)sizeof g_out);
    check_balanced(g_out, "a corrupt drain is balanced");
    check_has(g_out, "\"ok\":false", "corruption is not a successful drain");
    check_has(g_out, "content-ring-corrupt", "and is named");
}

int main(void)
{
    test_status_json();
    test_status_absent_and_mismatched();
    test_drain_json();
    test_drain_blit_source();
    test_drain_world_records();
    test_drain_truncation_flag();
    test_more_is_not_silence();
    test_output_budget_ends_it_honestly();
    test_overrun_is_reported_not_hidden();
    test_resync_and_more_are_never_confused();
    test_busy_says_call_again();
    test_drain_refusals();

    if (failures != 0) {
        printf("%d failure(s)\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
