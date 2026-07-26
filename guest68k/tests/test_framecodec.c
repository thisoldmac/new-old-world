/* Host-side test for the NOW-68K wire frame codec. Expectations are taken
 * from contract/asyncapi.yaml, cross-checked against (never copied from)
 * now/guest/src/wire.c and json.c. See the divergence note at the bottom
 * of this file for what that cross-check turned up. */

#include "frame.h"
#include "contract.h"
#include "hello.h"
#include "ping.h"
#include "json_scan.h"
#include "numfmt.h"

#include <stdio.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg) do { \
        g_checks++; \
        if (!(cond)) { \
            g_failures++; \
            printf("FAIL: %s (%s:%d)\n", msg, __FILE__, __LINE__); \
        } \
    } while (0)

/* --- 1. header round trip ------------------------------------------- */

static void check_roundtrip(unsigned char channel, unsigned char flags,
                             unsigned short transfer, unsigned long length,
                             const char *label)
{
    Now68kFrameHeader in;
    Now68kFrameHeader out;
    unsigned char wire[NOW68K_FRAME_HEADER_BYTES];

    in.channel = channel;
    in.flags = flags;
    in.transfer = transfer;
    in.length = length;

    now68k_frame_pack(&in, wire);
    now68k_frame_unpack(wire, &out);

    CHECK(out.channel == in.channel, label);
    CHECK(out.flags == in.flags, label);
    CHECK(out.transfer == in.transfer, label);
    CHECK(out.length == in.length, label);
}

static void test_header_roundtrip(void)
{
    /* Ordinary control frame. */
    check_roundtrip(NOW68K_CHANNEL_CONTROL, 0, 0, 42,
                     "roundtrip: small control frame");

    /* Ordinary bulk frame with the END flag set. */
    check_roundtrip(NOW68K_CHANNEL_BULK, NOW68K_FLAG_END, 7, 4096,
                     "roundtrip: bulk frame, END flag");

    /* Boundary: exactly our control buffer cap. */
    check_roundtrip(NOW68K_CHANNEL_CONTROL, 0, 0, NOW68K_CONTROL_BUFFER_CAP,
                     "roundtrip: length at NOW68K_CONTROL_BUFFER_CAP");

    /* Maximum legal length for any frame. */
    check_roundtrip(NOW68K_CHANNEL_BULK, NOW68K_FLAG_END, 65535,
                     NOW68K_MAX_PAYLOAD,
                     "roundtrip: max legal length, max transfer id");

    /* Mechanical boundary: the codec itself does not clamp, so a length
     * field beyond the contract's stated max must still encode/decode
     * exactly -- legality is now68k_frame_length_ok()'s job, checked
     * separately below. */
    check_roundtrip(NOW68K_CHANNEL_BULK, 0, 1, 0xFFFFFFFFUL,
                     "roundtrip: length field mechanical max (u32)");

    /* Zero-length frame (e.g. an "empty" stream frame per
     * CaptureBegin.frame: "empty means nothing changed - bytes is 0"). */
    check_roundtrip(NOW68K_CHANNEL_CONTROL, 0, 0, 0,
                     "roundtrip: zero length");
}

/* Exact byte layout: catches an endianness or field-order mistake that a
 * pack-then-unpack round trip alone would hide (packing and unpacking
 * with the same bug still round-trips). */
static void test_header_byte_layout(void)
{
    Now68kFrameHeader hdr;
    unsigned char wire[NOW68K_FRAME_HEADER_BYTES];
    static const unsigned char expect[NOW68K_FRAME_HEADER_BYTES] = {
        0x01,             /* channel = bulk */
        0x01,             /* flags = END */
        0x12, 0x34,       /* transfer = 0x1234 */
        0x00, 0x00, 0x80, 0x00  /* length = 0x8000 = 32768 */
    };

    hdr.channel = NOW68K_CHANNEL_BULK;
    hdr.flags = NOW68K_FLAG_END;
    hdr.transfer = 0x1234;
    hdr.length = NOW68K_MAX_PAYLOAD;

    now68k_frame_pack(&hdr, wire);
    CHECK(memcmp(wire, expect, NOW68K_FRAME_HEADER_BYTES) == 0,
          "pack: exact big-endian byte layout");
}

/* --- 2. frame legality vs. our own buffer capacity -------------------
 *
 * Confirmed defect: now68k_frame_length_ok() used to treat
 * NOW68K_MAX_CONTROL (4096, a BUFFER size lifted from this codec's own
 * receive buffer) as a PROTOCOL bound on the control channel, rejecting
 * any control frame over 4096 bytes as illegal. It is not illegal: the
 * contract's only normative frame bound is 32768 for either channel
 * (contract/asyncapi.yaml's frame-header comment, cross-checked against
 * host/Sources/Host/FrameCodec.swift's maxPayloadLength and the PPC
 * guest's kNowMaxPayload, both 32768). A control frame we cannot buffer
 * is OUR problem, not the sender's -- the PPC guest skips it and keeps
 * the connection (now/guest/src/wire.c, on_frame_ready(), "Bigger than
 * we can hold"); it never calls that a protocol violation. Treating our
 * buffer size as protocol law would have killed a live connection over a
 * message the wire format allows.
 *
 * These two questions are now two functions so they cannot be
 * re-conflated: now68k_frame_length_ok() answers ONLY protocol legality,
 * now68k_control_frame_fits() answers ONLY whether it fits our buffer.
 */

static void test_frame_length_ok_is_protocol_legality_only(void)
{
    /* The contract's literal stated bound, not this codec's own
     * constant -- deliberately spelled out as 32768 here instead of
     * NOW68K_MAX_PAYLOAD so a change to that constant cannot silently
     * make this assertion untrue-to-the-contract without a human
     * noticing the mismatch. */
    CHECK(now68k_frame_length_ok(32768UL),
          "protocol: a frame of exactly 32768 bytes is legal");
    CHECK(!now68k_frame_length_ok(32769UL),
          "protocol: a frame of 32769 bytes violates the wire format");

    /* The confirmed defect, directly: a control frame between our buffer
     * cap and the true protocol max must be LEGAL, not fatal. */
    CHECK(now68k_frame_length_ok(NOW68K_CONTROL_BUFFER_CAP + 1UL),
          "protocol: a control-sized frame over our buffer cap but under"
          " 32768 is still protocol-legal -- it must not be treated as a"
          " wire violation");
    CHECK(now68k_frame_length_ok(NOW68K_MAX_PAYLOAD),
          "protocol: a control-sized frame at the general max is legal");
}

static void test_control_frame_fits_is_buffer_capacity_only(void)
{
    CHECK(now68k_control_frame_fits(NOW68K_CONTROL_BUFFER_CAP),
          "buffer: a control frame exactly at our cap fits");
    CHECK(!now68k_control_frame_fits(NOW68K_CONTROL_BUFFER_CAP + 1UL),
          "buffer: one byte over our cap does not fit");

    /* The skip-vs-fatal split: a frame that fails this check can still
     * pass now68k_frame_length_ok() (it is legal, just too big for us).
     * A caller must read BOTH answers before deciding what to do --
     * "doesn't fit" is a skip, never treated as "doesn't parse". */
    CHECK(now68k_frame_length_ok(8192UL)
          && !now68k_control_frame_fits(8192UL),
          "buffer: an 8192-byte control frame is protocol-legal AND"
          " does not fit our buffer -- these are independent answers,"
          " and neither one is fatal on its own");
}

/* --- 3. hello ---------------------------------------------------------
 *
 * Also exercises the hand-rolled integer/string builder in numfmt.c
 * (replacing snprintf) -- these checks compare its output against the
 * same JSON scanner used to read real inbound messages, so a formatting
 * mistake in either would show up as a mismatch here.
 */

static void test_hello(void)
{
    char buf[512];
    long n;
    char text[64];
    long ival;

    n = now68k_hello_build(buf, sizeof buf, NOW68K_CONTRACT_REVISION,
                            "0.1");
    CHECK(n > 0, "hello: build succeeds");
    CHECK((long)strlen(buf) == n, "hello: reported length matches string");

    /* Hello.required = [type, contract, side, version]. */
    CHECK(now68k_json_read_type(buf, (size_t)n, text, sizeof text)
          && strcmp(text, "hello") == 0, "hello: type == \"hello\"");
    CHECK(now68k_json_find_int(buf, (size_t)n, "contract", &ival)
          && ival == NOW68K_CONTRACT_REVISION, "hello: contract revision");
    CHECK(strstr(buf, "\"side\":\"guest\"") != NULL,
          "hello: side == \"guest\"");
    CHECK(strstr(buf, "\"version\":\"0.1\"") != NULL,
          "hello: version field present");

    /* This guest's own choices for the optional fields. */
    CHECK(strstr(buf, "\"name\":\"now-68k\"") != NULL,
          "hello: name == \"now-68k\"");
    CHECK(strstr(buf, "\"os\":\"7.1\"") != NULL, "hello: os == \"7.1\"");
    CHECK(now68k_json_find_int(buf, (size_t)n, "chunk", &ival)
          && ival == 4096, "hello: chunk == 4096");
}

static void test_hello_rejects_undersize_buffer(void)
{
    char tiny[8];
    long n = now68k_hello_build(tiny, sizeof tiny, NOW68K_CONTRACT_REVISION,
                                 "0.1");

    CHECK(n == 0, "hello: refuses rather than truncates into a short buffer");
}

static void test_hello_negative_contract(void)
{
    /* Exercises now68k_fmt_append_long's negative path -- not a real
     * contract value, but the hand-rolled formatter must not be
     * special-cased to positive numbers only the way the JSON scanner's
     * integer reader isn't either. */
    char buf[512];
    long n = now68k_hello_build(buf, sizeof buf, -7, "0.1");
    long ival = 0;

    CHECK(n > 0, "hello: build succeeds with a negative contract value");
    CHECK(now68k_json_find_int(buf, (size_t)n, "contract", &ival)
          && ival == -7, "hello: negative contract round-trips");
}

/* --- 4. ping / pong ---------------------------------------------------- */

static void test_ping_pong_roundtrip(void)
{
    char buf[64];
    long n;
    long id = 0;
    char text[16];

    n = now68k_ping_build(buf, sizeof buf, 99);
    CHECK(n > 0, "ping: build succeeds");
    CHECK(now68k_json_read_type(buf, (size_t)n, text, sizeof text)
          && strcmp(text, "ping") == 0, "ping: type == \"ping\"");
    CHECK(now68k_json_find_int(buf, (size_t)n, "id", &id) && id == 99,
          "ping: id round-trips through the scanner");

    /* The host answers with pong carrying the same id (Pong schema,
     * required [type, id]); build that answer by hand since this
     * deliverable is the GUEST side and never emits pong. */
    {
        long pong_id = -1;
        static const char *msg = "{\"type\":\"pong\",\"id\":99}";
        CHECK(now68k_pong_read(msg, strlen(msg), &pong_id)
              && pong_id == 99, "pong: recognised and id extracted");
    }

    /* Rejections: wrong type, and a pong missing its required id. */
    {
        static const char *wrong_type = "{\"type\":\"refuse\",\"id\":99}";
        static const char *no_id = "{\"type\":\"pong\"}";
        CHECK(!now68k_pong_read(wrong_type, strlen(wrong_type), NULL),
              "pong: a differently-typed message is not recognised as"
              " pong");
        CHECK(!now68k_pong_read(no_id, strlen(no_id), NULL),
              "pong: missing required id is not recognised as pong");
    }
}

/* Confirmed defect: a pong preceded by a string VALUE equal to "id"
 * (e.g. a "note" field) made the old scanner give up instead of resuming
 * the search, so a legal pong was silently rejected. Verified by hand:
 * now68k_pong_read on {"type":"pong","note":"id","id":42} used to
 * return 0. The contract declares the peer dead after ~65s of no pong
 * answer, so this would have silently dropped a live connection. */
static void test_pong_survives_decoy_string_value_before_real_key(void)
{
    static const char *msg =
        "{\"type\":\"pong\",\"note\":\"id\",\"id\":42}";
    long id = -1;

    CHECK(now68k_pong_read(msg, strlen(msg), &id) && id == 42,
          "pong: a decoy string value (\"note\":\"id\") BEFORE the real"
          " id key does not abort recognition of a legal pong");
}

/* --- 5. JSON scanner: decoy-key shadowing ----------------------------- */

static void test_json_decoy_does_not_shadow(void)
{
    /* Modelled on command.result, whose optional "output" object may
     * legitimately contain a key also named "id" as PART OF THE OUTPUT
     * DATA (e.g. echoing some other id back to a human at the console).
     * The envelope's own id comes first in every message this codebase
     * builds, so first-occurrence-wins must read the REAL id (42), not
     * the decoy nested further into the string (999). This is the
     * shadowing hazard the contract preamble names directly ("an arg key
     * must not shadow an envelope key ... launch shipped that bug to
     * metal with an arg named 'name'"), tested from the reader's side. */
    static const char *msg =
        "{\"type\":\"command.result\",\"id\":42,\"ok\":true,"
        "\"output\":{\"id\":999,\"note\":\"decoy\"}}";
    long id = -1;
    char text[32];
    size_t msg_len = strlen(msg);

    CHECK(now68k_json_find_int(msg, msg_len, "id", &id) && id == 42,
          "decoy: real top-level id (42) wins over nested decoy (999)");
    CHECK(now68k_json_read_type(msg, msg_len, text, sizeof text)
          && strcmp(text, "command.result") == 0,
          "decoy: type is unaffected by the nested object");

    /* A key whose name merely CONTAINS "id" must not false-match the
     * quoted, exact "id" pattern. */
    {
        long junk = -1;
        static const char *msg2 = "{\"type\":\"pong\",\"validid\":7,"
                                   "\"id\":13}";
        CHECK(now68k_json_find_int(msg2, strlen(msg2), "id", &junk)
              && junk == 13,
              "decoy: a longer key name containing \"id\" does not"
              " false-match the exact key");
    }
}

/* This is the direction the pre-existing decoy test above cannot reach:
 * its decoy sits AFTER the real key, so first-occurrence-wins finds the
 * real one before ever touching the decoy, regardless of whether the
 * scanner resumes on a false match. Placing the decoy BEFORE the real
 * key is the only arrangement that actually exercises the resume
 * behaviour -- see test_pong_survives_decoy_string_value_before_real_key
 * above for the same case from now68k_pong_read's side. */
static void test_json_value_resumes_past_decoy_before_real_key(void)
{
    static const char *msg = "{\"type\":\"pong\",\"note\":\"id\",\"id\":42}";
    long id = -1;
    size_t msg_len = strlen(msg);

    CHECK(now68k_json_find_int(msg, msg_len, "id", &id) && id == 42,
          "resume: a quoted-but-uncolon'd \"id\" occurrence before the"
          " real key does not stop the search");

    /* Two decoys in a row, still before the real key. */
    {
        static const char *msg2 =
            "{\"type\":\"pong\",\"a\":\"id\",\"b\":\"id\",\"id\":7}";
        long id2 = -1;
        CHECK(now68k_json_find_int(msg2, strlen(msg2), "id", &id2)
              && id2 == 7,
              "resume: multiple decoys in a row are all skipped past");
    }
}

/* --- 6. JSON scanner: explicit length, no assumed NUL terminator ------
 *
 * Confirmed defect: now68k_json_value/read_type/find_int used to take a
 * bare `const char *` and run strstr/strlen on it, even though the frame
 * layer only ever hands the caller an explicit payload length, not a C
 * string. A reused receive buffer holding a previous, longer frame's
 * trailing bytes right past the current payload's end would let the
 * scanner run straight through the boundary. A test built from string
 * literals cannot exercise this: literals are always NUL-terminated, so
 * the missing-terminator case never arises. This test instead builds a
 * buffer by hand with no NUL anywhere in it, so an implementation that
 * ignored the given length and searched further would find the wrong
 * answer instead of crashing unpredictably -- it demonstrates the
 * WRONGNESS of over-reading deterministically, not just its danger.
 */

static void test_json_scan_stops_at_explicit_length(void)
{
    char buf[128];
    const char *real = "{\"type\":\"ping\",\"id\":5}";
    const char *stale =
        "\"id\":999,\"leftover\":\"bytes-from-a-previous-bigger-frame\"";
    size_t real_len = strlen(real);
    size_t stale_len = strlen(stale);
    long junk;

    /* Fill the whole array with a non-NUL filler first: this guarantees
     * there is no incidental '\0' anywhere in buf, even past what we
     * explicitly write below, so a scan that ignored json_len and
     * searched past it would read defined (if wrong) bytes rather than
     * running off the array -- deterministic either way. */
    memset(buf, 'X', sizeof buf);
    memcpy(buf, real, real_len);
    memcpy(buf + real_len, stale, stale_len);

    CHECK(now68k_json_value(buf, real_len, "leftover") == NULL,
          "length-bounded scan: a key that exists only past the given"
          " length is not found");

    junk = -1;
    CHECK(now68k_json_find_int(buf, real_len, "id", &junk) && junk == 5,
          "length-bounded scan: the in-bounds id (5) is found, not the"
          " stale id (999) sitting just past the given length");

    /* now68k_json_read_type must also respect the boundary: "type" is
     * well inside real_len here, so this is really testing that the
     * unterminated tail past real_len does not confuse the closing-quote
     * search for a value that DOES close inside the bound. */
    {
        char text[16];
        CHECK(now68k_json_read_type(buf, real_len, text, sizeof text)
              && strcmp(text, "ping") == 0,
              "length-bounded scan: type reads correctly with no NUL"
              " anywhere in the underlying buffer");
    }
}

/* A CRC-32 is unsigned and `long` here is not.
 *
 * Half of all checksums are above 0x7FFFFFFF, so a writer or reader that
 * went through a signed long would render or parse them as negative -
 * and the failure would present as "this guest corrupts every other
 * file", with perfect bytes on the disk. The sign boundary is where this
 * has to be checked, so the values below straddle it deliberately. */
static void test_u32_survives_the_sign_boundary(void)
{
    static const unsigned long values[] = {
        0UL, 1UL, 0x7FFFFFFEUL, 0x7FFFFFFFUL, 0x80000000UL,
        0x80000001UL, 0xCBF43926UL, 0xFFFFFFFFUL
    };
    unsigned i;

    for (i = 0; i < sizeof values / sizeof values[0]; ++i) {
        char buf[64];
        long pos = 0;
        unsigned long back = 0;

        CHECK(now68k_fmt_append_str(buf, (long)sizeof buf, &pos,
                                     "{\"crc32\":"),
              "u32: envelope built");
        CHECK(now68k_fmt_append_u32(buf, (long)sizeof buf, &pos, values[i]),
              "u32: value appended");
        CHECK(now68k_fmt_append_str(buf, (long)sizeof buf, &pos, "}"),
              "u32: envelope closed");
        CHECK(now68k_json_find_u32(buf, (size_t)pos, "crc32", &back),
              "u32: value found");
        if (back != values[i]) {
            printf("FAIL: u32 round trip %08lX came back %08lX (%.*s)\n",
                   values[i], back, (int)pos, buf);
            g_failures++;
        }
        g_checks++;
    }

    /* The rendering must be plain unsigned decimal - the host reads it
     * as a JSON integer, so a "-1" for 0xFFFFFFFF is a wire defect and
     * not merely an internal one. */
    {
        char buf[32];
        long pos = 0;

        (void)now68k_fmt_append_u32(buf, (long)sizeof buf, &pos, 0xFFFFFFFFUL);
        buf[pos] = '\0';
        CHECK(strcmp(buf, "4294967295") == 0,
              "u32: 0xFFFFFFFF renders as 4294967295, not as a negative");
    }

    /* A negative number is not a checksum. Refused rather than wrapped,
     * so a malformed file.end fails as "unchecked" rather than as a
     * mismatch against a number nobody computed. */
    {
        static const char neg[] = "{\"crc32\":-1}";
        unsigned long back = 12345UL;

        CHECK(!now68k_json_find_u32(neg, sizeof neg - 1, "crc32", &back),
              "u32: a negative value is refused");
        CHECK(back == 12345UL, "u32: a refused read leaves out untouched");
    }
}

int main(void)
{
    test_u32_survives_the_sign_boundary();
    test_header_roundtrip();
    test_header_byte_layout();
    test_frame_length_ok_is_protocol_legality_only();
    test_control_frame_fits_is_buffer_capacity_only();
    test_hello();
    test_hello_rejects_undersize_buffer();
    test_hello_negative_contract();
    test_ping_pong_roundtrip();
    test_pong_survives_decoy_string_value_before_real_key();
    test_json_decoy_does_not_shadow();
    test_json_value_resumes_past_decoy_before_real_key();
    test_json_scan_stops_at_explicit_length();

    printf("%d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
