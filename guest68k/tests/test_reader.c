/* Host-side test for the NOW-68K inbound frame reader (src/n68_reader.c).
 *
 * These are the branches the PowerBook 180c has never executed, because
 * reaching them means a host that sends something no host sends: a control
 * frame between the 4 KB receive buffer and the 32 KB protocol maximum, a
 * bulk frame, a zero-length frame, a length past the maximum. The claim
 * being tested is not "the odd frame is handled" but "FRAME SYNC SURVIVES
 * it" - so nearly every case here ends by sending an ordinary control
 * message afterwards and checking it arrives intact.
 *
 * The other half is partial delivery. MacTCP hands back whatever it has,
 * so the fake transport below can be told to yield one byte per take(),
 * and the same scripts are replayed through it: a state machine that only
 * works when frames arrive whole is a state machine that has never met the
 * network it was written for.
 *
 * Expectations come from frame.h (which bound is fatal and which is not)
 * and from the behaviour wire68.c's drain_frames() had before extraction. */

#include "n68_reader.h"

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

/* ---- fake transport + recorder ----------------------------------------- */

/* Enough for two max-size frames back to back plus headers. */
#define FEED_CAP (2u * (NOW68K_MAX_PAYLOAD + NOW68K_FRAME_HEADER_BYTES) + 64u)

/* Longest control payload we record for inspection. */
#define SEEN_CAP 256

/* Longest bulk payload we record. */
#define BULK_CAP 8192

typedef struct {
    unsigned char feed[FEED_CAP];
    long feed_len;
    long feed_pos;

    /* 0 = hand back everything asked for; otherwise the most bytes any one
       take() may return. 1 is the pathological MacTCP case. */
    long chunk;

    /* Set to stop the transport dead mid-stream, the way a socket with
       nothing buffered yet does: take() returns 0 from here on. */
    long stall_at;

    /* Cleared by the fatal callback; the reader must not be driven past a
       teardown, exactly as wire68.c stops draining. */
    int connected;

    long bytes_taken;    /* through took() */
    long frames_started;
    int  fatal_calls;
    unsigned long fatal_len;
    int  oversize_calls;
    unsigned long oversize_len;
    int  empty_calls;

    int  msg_count;
    char last_msg[SEEN_CAP];
    long last_msg_len;

    int  want_bulk;              /* what bulk_wanted answers */
    int  bulk_offers;            /* bulk_wanted calls */
    unsigned long bulk_offered_len;
    int  bulk_runs;              /* bulk_data calls */
    /* Sized for the whole bulk payload a case feeds, not SEEN_CAP: the
       point of recording it is to compare EVERY byte, and a recorder
       that quietly stopped at 256 would make a reader that dropped the
       rest look correct. */
    unsigned char bulk[BULK_CAP];
    long bulk_len;
} Fake;

static long fake_take(void *ctx, void *dst, long cap)
{
    Fake *f = (Fake *)ctx;
    long avail = f->feed_len - f->feed_pos;
    long n;

    if (f->stall_at >= 0 && f->feed_pos >= f->stall_at) {
        return 0;
    }
    if (avail <= 0 || cap <= 0) {
        return 0;
    }
    n = (cap < avail) ? cap : avail;
    if (f->chunk > 0 && n > f->chunk) {
        n = f->chunk;
    }
    if (f->stall_at >= 0 && f->feed_pos + n > f->stall_at) {
        n = f->stall_at - f->feed_pos;
    }
    memcpy(dst, f->feed + f->feed_pos, (size_t)n);
    f->feed_pos += n;
    return n;
}

static void fake_took(void *ctx, long got)
{
    ((Fake *)ctx)->bytes_taken += got;
}

static void fake_frame_started(void *ctx)
{
    ((Fake *)ctx)->frames_started++;
}

static void fake_oversized_frame(void *ctx, unsigned long length)
{
    Fake *f = (Fake *)ctx;

    f->fatal_calls++;
    f->fatal_len = length;
    f->connected = 0;
}

static void fake_oversized_control(void *ctx, unsigned long length)
{
    Fake *f = (Fake *)ctx;

    f->oversize_calls++;
    f->oversize_len = length;
}

static void fake_empty_control(void *ctx)
{
    ((Fake *)ctx)->empty_calls++;
}

static void fake_control_message(void *ctx, const char *json, long len)
{
    Fake *f = (Fake *)ctx;
    long n = (len < SEEN_CAP - 1) ? len : SEEN_CAP - 1;

    f->msg_count++;
    memcpy(f->last_msg, json, (size_t)n);
    f->last_msg[n] = '\0';
    f->last_msg_len = len;
}

static int fake_still_reading(void *ctx)
{
    return ((Fake *)ctx)->connected;
}

static int fake_bulk_wanted(void *ctx, unsigned long length)
{
    Fake *f = (Fake *)ctx;

    f->bulk_offers++;
    f->bulk_offered_len = length;
    return f->want_bulk;
}

static void fake_bulk_data(void *ctx, const unsigned char *bytes, long len)
{
    Fake *f = (Fake *)ctx;
    long i;

    f->bulk_runs++;
    for (i = 0; i < len && f->bulk_len < BULK_CAP; ++i) {
        f->bulk[f->bulk_len++] = bytes[i];
    }
}

static const N68ReaderOps kFakeOps = {
    fake_take,
    fake_took,
    fake_frame_started,
    fake_oversized_frame,
    fake_oversized_control,
    fake_empty_control,
    fake_bulk_wanted,
    fake_bulk_data,
    fake_control_message,
    fake_still_reading
};

/* The reader's buffers are the caller's; these match wire68.c's. */
static char g_ctrl_buf[NOW68K_CONTROL_BUFFER_CAP];
static unsigned char g_sink[256];

static void fake_reset(Fake *f, N68Reader *r)
{
    memset(f, 0, sizeof *f);
    f->connected = 1;
    f->stall_at = -1;
    n68_reader_init(r, g_ctrl_buf, g_sink, (long)sizeof g_sink,
                     &kFakeOps, f);
}

/* Appends one frame: 8-byte header then `len` payload bytes. `payload` may
 * be NULL, in which case the body is filler - the point of the big frames
 * is their length, not their contents. */
static void feed_frame(Fake *f, unsigned char channel, unsigned long len,
                        const char *payload)
{
    Now68kFrameHeader hdr;
    unsigned long i;

    hdr.channel = channel;
    hdr.flags = 0;
    hdr.transfer = 0;
    hdr.length = len;

    now68k_frame_pack(&hdr, f->feed + f->feed_len);
    f->feed_len += (long)NOW68K_FRAME_HEADER_BYTES;
    for (i = 0; i < len; ++i) {
        f->feed[f->feed_len + (long)i] =
            payload ? (unsigned char)payload[i] : (unsigned char)('a' + (i % 26));
    }
    f->feed_len += (long)len;
}

static void feed_json(Fake *f, const char *json)
{
    feed_frame(f, NOW68K_CHANNEL_CONTROL, (unsigned long)strlen(json), json);
}

/* One n68_reader_drain() call is ONE event-loop pass, not "read everything
 * available": on a partial header or a partial control body the machine
 * returns to its caller and waits to be polled again (wire68.c calls it
 * from wire_idle()). So a test that hands back one byte per take() must
 * poll it the same way the application does. Stops on teardown, because
 * wire_idle() does not call it again after one. */
static void drain_until_idle(N68Reader *r, Fake *f)
{
    long guard;

    for (guard = 0; guard < f->feed_len + 32; ++guard) {
        long before = f->feed_pos;

        n68_reader_drain(r);
        if (!f->connected || f->feed_pos == before) {
            return;
        }
    }
    printf("FAIL: reader stopped making progress at %ld/%ld (%s:%d)\n",
            f->feed_pos, f->feed_len, __FILE__, __LINE__);
    g_failures++;
}

/* ---- the cases ---------------------------------------------------------- */

/* Every scripted case is run through three transports: whole reads, one
 * byte at a time, and 3-byte reads (which lands mid-header on an 8-byte
 * header and mid-body on nearly everything). If a case passes only under
 * one of them the state machine is not doing its job. */
static const long kChunkings[] = { 0, 1, 3, 7 };
#define CHUNKINGS (sizeof kChunkings / sizeof kChunkings[0])

static const char *kMsgA = "{\"type\":\"pong\",\"id\":1}";
static const char *kMsgB = "{\"type\":\"bye\",\"code\":\"done\"}";

static void label_for(char *out, long cap, const char *base, long chunk)
{
    if (chunk == 0) {
        snprintf(out, (size_t)cap, "%s [whole reads]", base);
    } else {
        snprintf(out, (size_t)cap, "%s [%ld-byte reads]", base, chunk);
    }
}

/* 1. The headline case: a control frame legal on the wire but bigger than
 * our 4 KB buffer is SKIPPED, the connection survives, and - the actual
 * claim - the NEXT frame is still parsed correctly. */
static void test_oversized_control_skipped(void)
{
    unsigned i;

    for (i = 0; i < CHUNKINGS; ++i) {
        Fake f;
        N68Reader r;
        char label[128];

        fake_reset(&f, &r);
        f.chunk = kChunkings[i];
        feed_frame(&f, NOW68K_CHANNEL_CONTROL, 8192, NULL);
        feed_json(&f, kMsgA);
        drain_until_idle(&r, &f);

        label_for(label, sizeof label,
                   "oversized control: skipped, not fatal", kChunkings[i]);
        CHECK(f.fatal_calls == 0, label);
        CHECK(f.connected, label);
        label_for(label, sizeof label,
                   "oversized control: reported once with its length",
                   kChunkings[i]);
        CHECK(f.oversize_calls == 1 && f.oversize_len == 8192, label);
        label_for(label, sizeof label,
                   "oversized control: frame sync survived, next frame parsed",
                   kChunkings[i]);
        CHECK(f.msg_count == 1, label);
        CHECK(f.last_msg_len == (long)strlen(kMsgA)
              && strcmp(f.last_msg, kMsgA) == 0, label);
        label_for(label, sizeof label,
                   "oversized control: every byte accounted for",
                   kChunkings[i]);
        CHECK(f.bytes_taken == f.feed_len, label);
        CHECK(f.feed_pos == f.feed_len, label);
    }
}

/* Boundary pair around NOW68K_CONTROL_BUFFER_CAP: exactly 4096 must be
 * delivered, 4097 must be skipped. An off-by-one here is the difference
 * between a lost message and a buffer overrun. */
static void test_control_buffer_boundary(void)
{
    Fake f;
    N68Reader r;

    fake_reset(&f, &r);
    feed_frame(&f, NOW68K_CHANNEL_CONTROL, NOW68K_CONTROL_BUFFER_CAP, NULL);
    drain_until_idle(&r, &f);
    CHECK(f.oversize_calls == 0 && f.msg_count == 1
          && f.last_msg_len == (long)NOW68K_CONTROL_BUFFER_CAP,
          "boundary: exactly NOW68K_CONTROL_BUFFER_CAP is delivered");

    fake_reset(&f, &r);
    feed_frame(&f, NOW68K_CHANNEL_CONTROL, NOW68K_CONTROL_BUFFER_CAP + 1,
                NULL);
    feed_json(&f, kMsgA);
    drain_until_idle(&r, &f);
    CHECK(f.oversize_calls == 1 && f.msg_count == 1
          && strcmp(f.last_msg, kMsgA) == 0,
          "boundary: one byte over the cap is skipped, sync survives");
}

/* Boundary pair around NOW68K_MAX_PAYLOAD: 32768 is legal (and, on the
 * control channel, skipped); 32769 is the one fatal case. */
static void test_oversized_frame_is_fatal(void)
{
    unsigned i;

    for (i = 0; i < CHUNKINGS; ++i) {
        Fake f;
        N68Reader r;
        char label[128];

        fake_reset(&f, &r);
        f.chunk = kChunkings[i];
        feed_frame(&f, NOW68K_CHANNEL_CONTROL, NOW68K_MAX_PAYLOAD + 1, NULL);
        feed_json(&f, kMsgA);
        drain_until_idle(&r, &f);

        label_for(label, sizeof label, "past max payload: fatal, once",
                   kChunkings[i]);
        CHECK(f.fatal_calls == 1 && f.fatal_len == NOW68K_MAX_PAYLOAD + 1,
              label);
        label_for(label, sizeof label,
                   "past max payload: nothing after it is parsed",
                   kChunkings[i]);
        CHECK(f.msg_count == 0, label);
        label_for(label, sizeof label,
                   "past max payload: not counted as a started frame",
                   kChunkings[i]);
        CHECK(f.frames_started == 0, label);
        label_for(label, sizeof label,
                   "past max payload: draining stopped at the header",
                   kChunkings[i]);
        CHECK(f.feed_pos == (long)NOW68K_FRAME_HEADER_BYTES, label);
    }

    {
        Fake f;
        N68Reader r;

        fake_reset(&f, &r);
        feed_frame(&f, NOW68K_CHANNEL_BULK, NOW68K_MAX_PAYLOAD, NULL);
        feed_json(&f, kMsgA);
        drain_until_idle(&r, &f);
        CHECK(f.fatal_calls == 0 && f.msg_count == 1,
              "boundary: exactly NOW68K_MAX_PAYLOAD is legal");
    }
}

/* 2. Bulk frames: NOW-68K implements no bulk features, so they are
 * consumed and discarded to stay in sync - never fatal, never delivered. */
static void test_bulk_consumed_and_discarded(void)
{
    unsigned i;

    for (i = 0; i < CHUNKINGS; ++i) {
        Fake f;
        N68Reader r;
        char label[128];

        fake_reset(&f, &r);
        f.chunk = kChunkings[i];
        feed_frame(&f, NOW68K_CHANNEL_BULK, 1000, NULL);
        feed_json(&f, kMsgA);
        /* Larger than the 256-byte sink by a wide margin, so the skip state
           has to loop many times over its own buffer. */
        feed_frame(&f, NOW68K_CHANNEL_BULK, 5000, NULL);
        feed_json(&f, kMsgB);
        drain_until_idle(&r, &f);

        label_for(label, sizeof label, "bulk: never delivered, never fatal",
                   kChunkings[i]);
        CHECK(f.fatal_calls == 0 && f.oversize_calls == 0, label);
        CHECK(f.msg_count == 2, label);
        label_for(label, sizeof label,
                   "bulk: interleaved control frames still parsed",
                   kChunkings[i]);
        CHECK(strcmp(f.last_msg, kMsgB) == 0, label);
        label_for(label, sizeof label, "bulk: all four frames counted",
                   kChunkings[i]);
        CHECK(f.frames_started == 4, label);
        CHECK(f.feed_pos == f.feed_len && f.bytes_taken == f.feed_len, label);
    }
}

/* 3. Zero-length frames on both channels. A zero-length body must not put
 * the reader into a body/skip state it can never leave - the whole frame is
 * its header. */
/* The same frames, WANTED. Everything the discard test asserts about
 * frame sync still has to hold, and on top of it every payload byte must
 * arrive exactly once and in order - across every chunking, because the
 * transport decides where the runs fall and it never picks the tidy
 * ones. This is the path a file push takes. */
static void test_bulk_delivered_when_wanted(void)
{
    unsigned i;

    for (i = 0; i < CHUNKINGS; ++i) {
        Fake f;
        N68Reader r;
        char label[128];
        long n;
        int ok = 1;

        fake_reset(&f, &r);
        f.want_bulk = 1;
        f.chunk = kChunkings[i];
        /* Well past the 256-byte sink, so the bulk state loops over its
         * own buffer many times inside one frame. */
        feed_frame(&f, NOW68K_CHANNEL_BULK, 1000, NULL);
        feed_json(&f, kMsgA);
        feed_frame(&f, NOW68K_CHANNEL_BULK, 5000, NULL);
        feed_json(&f, kMsgB);
        drain_until_idle(&r, &f);

        label_for(label, sizeof label, "bulk wanted: never fatal",
                   kChunkings[i]);
        CHECK(f.fatal_calls == 0 && f.oversize_calls == 0, label);
        label_for(label, sizeof label,
                   "bulk wanted: control frames still parsed",
                   kChunkings[i]);
        CHECK(f.msg_count == 2 && strcmp(f.last_msg, kMsgB) == 0, label);
        label_for(label, sizeof label, "bulk wanted: every frame counted",
                   kChunkings[i]);
        CHECK(f.frames_started == 4, label);
        CHECK(f.feed_pos == f.feed_len && f.bytes_taken == f.feed_len, label);

        label_for(label, sizeof label,
                   "bulk wanted: asked once per bulk frame, with its length",
                   kChunkings[i]);
        CHECK(f.bulk_offers == 2 && f.bulk_offered_len == 5000, label);

        /* 6000 payload bytes, in order, no duplicates and no gaps. The
         * filler feed_frame writes is 'a' + (i % 26) per frame, so the
         * expected stream is that pattern twice - and a reader that
         * replayed a run or dropped one lands off the pattern rather
         * than merely off the count. */
        label_for(label, sizeof label, "bulk wanted: 6000 bytes delivered",
                   kChunkings[i]);
        CHECK(f.bulk_len == 6000, label);
        for (n = 0; n < f.bulk_len && n < 6000; ++n) {
            long within = (n < 1000) ? n : n - 1000;

            if (f.bulk[n] != (unsigned char)('a' + (within % 26))) {
                ok = 0;
                break;
            }
        }
        label_for(label, sizeof label,
                   "bulk wanted: bytes arrive in order, exactly once",
                   kChunkings[i]);
        CHECK(ok, label);
    }
}

/* A frame the callee declines mid-stream is still drained. Nothing about
 * frame sync may depend on whether anyone wanted the bytes. */
static void test_declining_one_bulk_frame_keeps_sync(void)
{
    Fake f;
    N68Reader r;

    fake_reset(&f, &r);
    f.want_bulk = 0;              /* nothing is expecting bytes */
    feed_frame(&f, NOW68K_CHANNEL_BULK, 3000, NULL);
    feed_json(&f, kMsgA);
    drain_until_idle(&r, &f);

    CHECK(f.bulk_offers == 1, "declined bulk: still offered");
    CHECK(f.bulk_runs == 0, "declined bulk: nothing delivered");
    CHECK(f.msg_count == 1 && strcmp(f.last_msg, kMsgA) == 0,
          "declined bulk: the next control frame still parses");
    CHECK(f.feed_pos == f.feed_len, "declined bulk: fully drained");
}

static void test_zero_length_frames(void)
{
    unsigned i;

    for (i = 0; i < CHUNKINGS; ++i) {
        Fake f;
        N68Reader r;
        char label[128];

        fake_reset(&f, &r);
        f.chunk = kChunkings[i];
        feed_frame(&f, NOW68K_CHANNEL_CONTROL, 0, NULL);
        feed_frame(&f, NOW68K_CHANNEL_BULK, 0, NULL);
        feed_json(&f, kMsgA);
        drain_until_idle(&r, &f);

        label_for(label, sizeof label,
                   "zero length: empty control reported, not dispatched",
                   kChunkings[i]);
        CHECK(f.empty_calls == 1, label);
        label_for(label, sizeof label,
                   "zero length: sync survives both channels", kChunkings[i]);
        CHECK(f.msg_count == 1 && strcmp(f.last_msg, kMsgA) == 0, label);
        CHECK(f.fatal_calls == 0 && f.feed_pos == f.feed_len, label);
    }

    /* A zero-length control frame that is ALSO past the buffer cap cannot
     * exist, but a zero-length bulk frame directly before a body-carrying
     * one can - check the skip state was left, not entered with 0. */
    {
        Fake f;
        N68Reader r;

        fake_reset(&f, &r);
        f.chunk = 1;
        feed_frame(&f, NOW68K_CHANNEL_BULK, 0, NULL);
        feed_frame(&f, NOW68K_CHANNEL_BULK, 0, NULL);
        feed_json(&f, kMsgB);
        drain_until_idle(&r, &f);
        CHECK(f.msg_count == 1 && strcmp(f.last_msg, kMsgB) == 0,
              "zero length: back-to-back empty bulk frames keep sync");
    }
}

/* 4. Back-to-back frames in a single read: the drain loop must keep going
 * after dispatching one message rather than returning to the event loop. */
static void test_back_to_back_in_one_read(void)
{
    Fake f;
    N68Reader r;

    fake_reset(&f, &r);
    feed_json(&f, kMsgA);
    feed_json(&f, kMsgB);
    feed_json(&f, kMsgA);
    /* chunk 0: the whole three-frame stream is available at once, so ONE
       drain call must consume all of it - the loop has to keep going after
       dispatching a message rather than returning to the event loop. */
    n68_reader_drain(&r);
    CHECK(f.msg_count == 3, "back-to-back: three frames in one drain");
    CHECK(f.frames_started == 3 && f.feed_pos == f.feed_len,
          "back-to-back: stream fully consumed");
}

/* 5. Partial delivery: the transport stalls at a chosen byte offset, the
 * reader returns, and a later drain picks up exactly where it left off.
 * Every offset in a two-frame stream is tried, so the stall lands mid-
 * header, on a header boundary, mid-body and on a body boundary. */
static void test_stall_at_every_offset(void)
{
    Fake probe;
    N68Reader r;
    long total;
    long stall;

    /* Build once to learn the length, then replay it stalled at each byte. */
    fake_reset(&probe, &r);
    feed_json(&probe, kMsgA);
    feed_frame(&probe, NOW68K_CHANNEL_BULK, 300, NULL);
    feed_json(&probe, kMsgB);
    total = probe.feed_len;

    for (stall = 0; stall <= total; ++stall) {
        Fake f;

        fake_reset(&f, &r);
        feed_json(&f, kMsgA);
        feed_frame(&f, NOW68K_CHANNEL_BULK, 300, NULL);
        feed_json(&f, kMsgB);

        f.stall_at = stall;
        f.chunk = 1;
        drain_until_idle(&r, &f);
        /* Whatever the reader got, it must have stopped at the stall and
           never invented bytes past it. */
        if (f.feed_pos != stall) {
            printf("FAIL: stall at %ld consumed %ld bytes (%s:%d)\n",
                    stall, f.feed_pos, __FILE__, __LINE__);
            g_failures++;
        }
        g_checks++;

        /* Now let the rest through, still a byte at a time. */
        f.stall_at = -1;
        drain_until_idle(&r, &f);
        if (f.msg_count != 2 || strcmp(f.last_msg, kMsgB) != 0
            || f.fatal_calls != 0 || f.feed_pos != f.feed_len) {
            printf("FAIL: resume after stall at %ld: %d msgs, pos %ld/%ld "
                    "(%s:%d)\n", stall, f.msg_count, f.feed_pos, f.feed_len,
                    __FILE__, __LINE__);
            g_failures++;
        }
        g_checks++;
    }
}

/* 6. A handler that tears the connection down stops the drain, leaving the
 * rest of the buffered stream unread - wire68.c's "handler tore the
 * connection down" exit. */
static void test_teardown_stops_drain(void)
{
    Fake f;
    N68Reader r;

    fake_reset(&f, &r);
    feed_json(&f, kMsgA);
    feed_json(&f, kMsgB);
    drain_until_idle(&r, &f);
    CHECK(f.msg_count == 2, "teardown: baseline delivers both frames");

    fake_reset(&f, &r);
    feed_json(&f, kMsgA);
    feed_json(&f, kMsgB);
    f.connected = 0;   /* still_reading() says stop after the first */
    drain_until_idle(&r, &f);
    CHECK(f.msg_count == 1 && strcmp(f.last_msg, kMsgA) == 0,
          "teardown: drain stops after the handler tears down");
    CHECK(f.feed_pos < f.feed_len,
          "teardown: the rest of the stream is left unread");
}

/* 7. reset() must discard a half-read frame. A connection that dropped
 * mid-body and redialed would otherwise interpret the new connection's
 * first bytes as the tail of the old one's payload. */
static void test_reset_discards_partial_frame(void)
{
    Fake f;
    N68Reader r;

    fake_reset(&f, &r);
    feed_json(&f, kMsgA);
    f.stall_at = (long)NOW68K_FRAME_HEADER_BYTES + 4;   /* mid-body */
    drain_until_idle(&r, &f);
    CHECK(f.msg_count == 0, "reset: baseline is genuinely mid-body");

    n68_reader_reset(&r);
    f.stall_at = -1;
    f.feed_len = 0;
    f.feed_pos = 0;
    feed_json(&f, kMsgB);
    drain_until_idle(&r, &f);
    CHECK(f.msg_count == 1 && strcmp(f.last_msg, kMsgB) == 0,
          "reset: the next connection starts at a frame boundary");
}

int main(void)
{
    test_oversized_control_skipped();
    test_control_buffer_boundary();
    test_oversized_frame_is_fatal();
    test_bulk_consumed_and_discarded();
    test_bulk_delivered_when_wanted();
    test_declining_one_bulk_frame_keeps_sync();
    test_zero_length_frames();
    test_back_to_back_in_one_read();
    test_stall_at_every_offset();
    test_teardown_stops_drain();
    test_reset_discards_partial_frame();

    printf("%d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
