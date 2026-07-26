/*
 * test_puttx.c - native test for n68_puttx.c, the guest->host sender.
 *
 *   cc -Wall -Wextra -Werror -I ../src test_puttx.c ../src/n68_puttx.c \
 *      ../src/n68_crc32.c ../src/n68_cmdresult.c ../src/numfmt.c \
 *      ../src/frame.c -o /tmp/t
 *
 * (scripts/test-native runs this; the line above is for editing one file.)
 *
 * WHAT THIS IS ACTUALLY FOR. The send half needs a Macintosh, a host, a
 * link and several minutes to try once, and when it goes wrong the
 * evidence is a truncated file on a machine in another room. Everything
 * that is a DECISION lives in n68_puttx.c behind the byte-source
 * interface, so the whole sequence - including the failures a real
 * source produces and the splits a real chunking produces - runs here in
 * milliseconds.
 *
 * The fake sources below are the point. A real file source hands back
 * tidy full buffers; the interface promises much less than that
 * (n68_bytesrc.h), and every one of those weaker promises is a case the
 * metal will eventually produce and this file produces on demand.
 */

#include "n68_puttx.h"
#include "n68_crc32.h"

#include <stdio.h>
#include <string.h>

static int failures;

static void check_long(const char *what, long got, long want)
{
    if (got != want) {
        printf("FAIL %s: got %ld, wanted %ld\n", what, got, want);
        ++failures;
    }
}

static void check_str(const char *what, const char *got, const char *want)
{
    if (got == NULL || strcmp(got, want) != 0) {
        printf("FAIL %s:\n  got  %s\n  want %s\n", what,
               got != NULL ? got : "(null)", want);
        ++failures;
    }
}

static void check_true(const char *what, int cond)
{
    if (!cond) {
        printf("FAIL %s\n", what);
        ++failures;
    }
}

/* ---- fake sources --------------------------------------------------------- */

/* A counted pattern source, with every weakness the interface allows
 * made switchable: a fill cap smaller than the sender asks for (a source
 * that reads in its own units), a failure at a chosen offset, and an
 * early or late end. */
typedef struct {
    long total;         /* what it will actually produce */
    long produced;
    long fill_cap;      /* 0 = whatever is asked for */
    long fail_at;       /* -1 = never */
    int  claim_done_at; /* -1 = only at total */
    int  closes;        /* how many times close() was called */
    int  over_by;       /* write this many bytes past cap, once */
} FakeSrc;

static unsigned char pattern_byte(long i)
{
    /* Deliberately not constant: a chunking bug that repeats or drops a
       run has to change the CRC, and a buffer of one repeated byte would
       hide exactly that. */
    return (unsigned char)((i * 31u + (i >> 8)) & 0xFF);
}

static long fake_fill(void *ctx, void *dst, long cap, int *done)
{
    FakeSrc *s = (FakeSrc *)ctx;
    unsigned char *out = (unsigned char *)dst;
    long n;
    long i;

    if (s->fail_at >= 0 && s->produced >= s->fail_at) {
        return -1;
    }
    n = s->total - s->produced;
    if (n > cap) {
        n = cap;
    }
    if (s->fill_cap > 0 && n > s->fill_cap) {
        n = s->fill_cap;
    }
    if (s->over_by > 0) {
        n += s->over_by;    /* the caller-bug case; see the test */
        s->over_by = 0;
    }
    for (i = 0; i < n; ++i) {
        out[i] = pattern_byte(s->produced + i);
    }
    s->produced += n;
    if (s->claim_done_at >= 0) {
        if (s->produced >= s->claim_done_at) {
            *done = 1;
        }
    } else if (s->produced >= s->total) {
        *done = 1;
    }
    return n;
}

static void fake_close(void *ctx)
{
    ((FakeSrc *)ctx)->closes += 1;
}

static const N68ByteSourceOps kFakeOps = { fake_fill, fake_close };

static void fake_init(FakeSrc *s, long total)
{
    memset(s, 0, sizeof *s);
    s->total = total;
    s->fail_at = -1;
    s->claim_done_at = -1;
}

static N68ByteSource fake_source(FakeSrc *s, long declared_total)
{
    N68ByteSource src;

    src.ops = &kFakeOps;
    src.ctx = s;
    src.total = declared_total;
    return src;
}

/* Runs a whole armed transfer to completion, accumulating what the wire
 * would have carried. Returns the number of bulk frames. */
static long drain_frames(N68SendTx *tx, unsigned long *payload_crc,
                         long *payload_bytes, int *saw_end_flag,
                         N68SendCode *why)
{
    unsigned char frame[kN68SendFrameCap];
    long frames = 0;
    long n;

    *payload_crc = 0;
    *payload_bytes = 0;
    *saw_end_flag = 0;
    *why = kN68SendOK;

    while ((n = n68_puttx_next_frame(tx, frame, (long)sizeof frame, why)) > 0) {
        Now68kFrameHeader hdr;
        long body = n - (long)NOW68K_FRAME_HEADER_BYTES;

        now68k_frame_unpack(frame, &hdr);
        check_long("frame length field matches the bytes written",
                   (long)hdr.length, body);
        check_long("bulk frames go on the bulk channel",
                   (long)hdr.channel, (long)NOW68K_CHANNEL_BULK);
        check_long("every bulk frame carries the transfer id",
                   (long)hdr.transfer, (long)tx->transfer);
        check_true("no frame exceeds the negotiated chunk",
                   body <= (long)kN68SendChunk);
        if (hdr.flags & NOW68K_FLAG_END) {
            *saw_end_flag = 1;
        }
        *payload_crc = now68k_crc32(*payload_crc,
                                    frame + NOW68K_FRAME_HEADER_BYTES, body);
        *payload_bytes += body;
        ++frames;
        if (frames > 4096) {
            printf("FAIL sender did not terminate\n");
            ++failures;
            break;
        }
    }
    return frames;
}

/* Arms a sender through the offer/accept handshake. */
static void arm(N68SendTx *tx, FakeSrc *s, long total, long declared)
{
    N68ByteSource src;

    fake_init(s, total);
    src = fake_source(s, declared);
    n68_puttx_init(tx);
    check_long("begin accepts a fresh sender",
               (long)n68_puttx_begin(tx, 7, "Report", &src, 0, "TEXT",
                                     "ttxt", 0),
               (long)kN68SendOK);
    check_true("accept moves it to sending",
               n68_puttx_accepted(tx, 7, 9) == 1);
}

/* ---- the messages --------------------------------------------------------- */

/* Pinned against the field names and the shapes the host decodes
 * (host/Sources/Host/ContractMessages.swift) and the PowerPC guest
 * already sends (guest/src/wire.c, send_offer). `path` being present and
 * empty is the one that cost a dropped connection when it was missing. */
static void test_offer_is_the_shape_the_host_decodes(void)
{
    N68SendTx tx;
    FakeSrc s;
    N68ByteSource src;
    char buf[512];

    fake_init(&s, 1000);
    src = fake_source(&s, 1000);
    n68_puttx_init(&tx);
    (void)n68_puttx_begin(&tx, 3, "Notes", &src, 0, "TEXT", "ttxt", 0);
    (void)n68_puttx_build_offer(&tx, buf, (long)sizeof buf);
    check_str("file.offer", buf,
              "{\"type\":\"file.offer\",\"id\":3,\"name\":\"Notes\","
              "\"path\":\"\",\"container\":\"data\",\"bytes\":1000,"
              "\"fileType\":\"TEXT\",\"creator\":\"ttxt\"}");
}

static void test_offer_carries_macbinary_and_modified(void)
{
    N68SendTx tx;
    FakeSrc s;
    N68ByteSource src;
    char buf[512];

    fake_init(&s, 4);
    src = fake_source(&s, 4);
    n68_puttx_init(&tx);
    (void)n68_puttx_begin(&tx, 4, "App", &src, 1, "APPL", "MACS",
                          0xB0000000UL);
    (void)n68_puttx_build_offer(&tx, buf, (long)sizeof buf);
    /* modified is a Mac epoch second past 2^31: it must not come out
       negative, which is exactly what append_long would have done. */
    check_str("macbinary offer", buf,
              "{\"type\":\"file.offer\",\"id\":4,\"name\":\"App\","
              "\"path\":\"\",\"container\":\"macbinary\",\"bytes\":4,"
              "\"fileType\":\"APPL\",\"creator\":\"MACS\","
              "\"modified\":2952790016}");
}

static void test_begin_and_end_are_the_shapes_the_host_decodes(void)
{
    N68SendTx tx;
    FakeSrc s;
    unsigned long crc;
    long bytes;
    int end_flag;
    N68SendCode why;
    char buf[512];

    arm(&tx, &s, 300, 300);
    (void)n68_puttx_build_begin(&tx, buf, (long)sizeof buf);
    check_str("file.begin", buf,
              "{\"type\":\"file.begin\",\"id\":7,\"transfer\":9,"
              "\"name\":\"Report\",\"container\":\"data\",\"bytes\":300}");

    (void)drain_frames(&tx, &crc, &bytes, &end_flag, &why);
    (void)n68_puttx_build_end(&tx, buf, (long)sizeof buf, 1, 42);
    {
        /* The CRC is spelled out from the bytes rather than pinned as a
           literal. A literal here would be a number I chose, and the
           thing worth asserting is that the message carries the checksum
           of what actually went out - test_crc32.c is what pins the
           algorithm against the published vectors. */
        char want[256];

        sprintf(want, "{\"type\":\"file.end\",\"id\":7,\"transfer\":9,"
                      "\"ok\":true,\"sendMs\":42,\"crc32\":%lu}", crc);
        check_str("file.end carries the crc of what it sent", buf, want);
    }
    check_long("and that crc is over all 300 payload bytes", bytes, 300);
}

/* A failed transfer sends no checksum. A CRC over a stream that stopped
 * early is arithmetically correct about bytes nobody wanted, and a
 * receiver comparing it would report corruption instead of truncation. */
static void test_a_failed_end_carries_no_crc(void)
{
    N68SendTx tx;
    FakeSrc s;
    char buf[512];

    arm(&tx, &s, 300, 300);
    (void)n68_puttx_build_end(&tx, buf, (long)sizeof buf, 0, -1);
    check_str("file.end ok:false", buf,
              "{\"type\":\"file.end\",\"id\":7,\"transfer\":9,"
              "\"ok\":false}");
}

/* ---- chunking ------------------------------------------------------------- */

/* The property that matters on a wire: whatever the frame boundaries
 * turn out to be, the bytes and their CRC are those of the whole
 * stream. Sizes chosen around the chunk boundary, because off-by-one at
 * the last frame is the bug this shape has. */
static void test_every_size_streams_exactly_once(void)
{
    static const long sizes[] = {
        0, 1, 2, 4095, 4096, 4097, 8191, 8192, 8193, 100000
    };
    unsigned long expected = 0;
    long i;
    long k;

    for (i = 0; i < (long)(sizeof sizes / sizeof sizes[0]); ++i) {
        N68SendTx tx;
        FakeSrc s;
        unsigned long crc;
        long bytes;
        int end_flag;
        long frames;
        N68SendCode why;
        long total = sizes[i];

        arm(&tx, &s, total, total);
        frames = drain_frames(&tx, &crc, &bytes, &end_flag, &why);

        check_long("every declared byte was framed", bytes, total);
        /* Zero bytes is zero frames - see
           test_an_empty_source_sends_no_bulk_frame for why that is the
           decision and not an oversight. */
        check_true("the last frame carries END", end_flag == (total > 0));
        check_long("frame count is ceil(total/chunk)", frames,
                   (total + kN68SendChunk - 1) / kN68SendChunk);
        check_true("the sender reports all sent", n68_puttx_all_sent(&tx));

        /* The CRC the sender accumulated must equal the CRC of the
           source's bytes computed independently of any framing. */
        expected = 0;
        for (k = 0; k < total; ++k) {
            unsigned char b = pattern_byte(k);
            expected = now68k_crc32(expected, &b, 1);
        }
        check_long("crc matches the unframed stream", (long)crc,
                   (long)expected);
        check_long("crc the sender will report", (long)tx.crc, (long)crc);
    }
}

/* A zero-length source sends NO bulk frame at all: file.begin then
 * file.end, both control messages, and the bulk channel never carries
 * anything. Frame sync is a property of the headers on the wire, so an
 * absent bulk frame desyncs nothing - and the receiver (n68_putrx_end,
 * and the host's InboundFileSink with expectedBytes 0) closes out on the
 * file.end exactly as it would after a stream. An empty frame would be
 * legal too; it would just be a frame nobody needs. */
static void test_an_empty_source_sends_no_bulk_frame(void)
{
    N68SendTx tx;
    FakeSrc s;
    unsigned long crc;
    long bytes;
    int end_flag;
    N68SendCode why;
    long frames;

    arm(&tx, &s, 0, 0);
    check_true("nothing to send is immediately all sent",
               n68_puttx_all_sent(&tx));
    frames = drain_frames(&tx, &crc, &bytes, &end_flag, &why);
    check_long("no frames", frames, 0);
    check_long("no payload", bytes, 0);
    check_long("and no failure", (long)why, (long)kN68SendOK);
    check_long("the source is closed anyway", (long)s.closes, 0);
}

/* A source that reads in its own small units is honouring the interface,
 * not failing it - and the sender must still produce full chunks rather
 * than one frame per dribble, or a 4 MB file becomes 4000 frames. */
static void test_a_short_filling_source_still_fills_frames(void)
{
    N68SendTx tx;
    FakeSrc s;
    N68ByteSource src;
    unsigned char frame[kN68SendFrameCap];
    N68SendCode why;
    long n;

    fake_init(&s, 10000);
    s.fill_cap = 300;           /* 300 bytes per fill, come what may */
    src = fake_source(&s, 10000);
    n68_puttx_init(&tx);
    (void)n68_puttx_begin(&tx, 1, "Slow", &src, 0, NULL, NULL, 0);
    (void)n68_puttx_accepted(&tx, 1, 2);

    n = n68_puttx_next_frame(&tx, frame, (long)sizeof frame, &why);
    /* THE ASSERTION THIS TEST EXISTS FOR. One fill, one frame is the
       lazy implementation and it is wrong: the source promised only
       promptness, not a full buffer, so the sender must keep asking
       until the chunk is full or the stream ends. */
    check_long("a chunk is filled from as many fills as it takes",
               n - (long)NOW68K_FRAME_HEADER_BYTES, (long)kN68SendChunk);
}

/* ---- the failures --------------------------------------------------------- */

/* `total` is what the receiver sized its staging from, so a source that
 * ends early is a defect to name, not a length to renegotiate. Left
 * unchecked the receiver waits forever for bytes that will never come. */
static void test_a_source_that_ends_early_fails_the_transfer(void)
{
    N68SendTx tx;
    FakeSrc s;
    unsigned long crc;
    long bytes;
    int end_flag;
    N68SendCode why;

    /* declares 10000, produces 5000 */
    arm(&tx, &s, 5000, 10000);
    (void)drain_frames(&tx, &crc, &bytes, &end_flag, &why);
    check_long("named as short", (long)why, (long)kN68SendShort);
    check_true("no END was ever framed", !end_flag);
    check_long("the source was closed exactly once", (long)s.closes, 1);
    check_str("and the outcome is remembered", tx.last_code, "io-error");
}

static void test_a_source_that_fails_partway_fails_the_transfer(void)
{
    N68SendTx tx;
    FakeSrc s;
    N68ByteSource src;
    unsigned long crc;
    long bytes;
    int end_flag;
    N68SendCode why;

    fake_init(&s, 20000);
    s.fail_at = 8192;
    src = fake_source(&s, 20000);
    n68_puttx_init(&tx);
    (void)n68_puttx_begin(&tx, 5, "Broken", &src, 0, NULL, NULL, 0);
    (void)n68_puttx_accepted(&tx, 5, 6);

    (void)drain_frames(&tx, &crc, &bytes, &end_flag, &why);
    check_long("named as a source failure", (long)why,
               (long)kN68SendSourceFailed);
    check_long("the source was closed exactly once", (long)s.closes, 1);
    check_true("and the sender is idle again", tx.state == kN68SendIdle);
}

/* A source that writes past the buffer it was given has already done the
 * damage, but the sender must not then frame a length its header would
 * be lying about. */
static void test_a_source_that_overruns_is_refused(void)
{
    N68SendTx tx;
    FakeSrc s;
    N68ByteSource src;
    unsigned char frame[kN68SendFrameCap + 64];
    N68SendCode why;

    fake_init(&s, 100);
    s.over_by = 8;
    src = fake_source(&s, 100);
    n68_puttx_init(&tx);
    (void)n68_puttx_begin(&tx, 1, "Over", &src, 0, NULL, NULL, 0);
    (void)n68_puttx_accepted(&tx, 1, 1);

    check_long("no frame is produced",
               n68_puttx_next_frame(&tx, frame, (long)sizeof frame, &why), 0);
    check_long("named as long", (long)why, (long)kN68SendLong);
    check_long("the source was closed exactly once", (long)s.closes, 1);
}

/* ---- the state machine ---------------------------------------------------- */

/* One transfer at a time is the contract's rule. The answer to a second
 * request mid-flight is a refusal, and - this is the part worth pinning -
 * the second caller keeps its own source, because a begin that refuses
 * must not have taken anything. */
static void test_a_second_transfer_is_refused_and_takes_nothing(void)
{
    N68SendTx tx;
    FakeSrc first, second;
    N68ByteSource a, b;

    fake_init(&first, 100);
    fake_init(&second, 100);
    a = fake_source(&first, 100);
    b = fake_source(&second, 100);

    n68_puttx_init(&tx);
    check_long("the first is armed", (long)n68_puttx_begin(&tx, 1, "A", &a,
                                                           0, NULL, NULL, 0),
               (long)kN68SendOK);
    check_long("the second is refused as busy",
               (long)n68_puttx_begin(&tx, 2, "B", &b, 0, NULL, NULL, 0),
               (long)kN68SendBusy);
    check_long("and its source was NOT taken or closed",
               (long)second.closes, 0);

    n68_puttx_cancel(&tx, kN68SendGone);
    check_long("cancelling closes only the one it took",
               (long)first.closes, 1);
    check_long("second source still untouched", (long)second.closes, 0);
}

/* Promise (5) in n68_bytesrc.h: close is called exactly once, on every
 * ending there is. A source holding an open fork relies on it. */
static void test_the_source_is_closed_on_every_ending(void)
{
    struct { const char *what; int ending; } cases[] = {
        { "refusal",   0 },
        { "cancel",    1 },
        { "completion",2 },
    };
    long i;

    for (i = 0; i < 3; ++i) {
        N68SendTx tx;
        FakeSrc s;

        arm(&tx, &s, 100, 100);
        if (cases[i].ending == 0) {
            n68_puttx_cancel(&tx, kN68SendRefused);
        } else if (cases[i].ending == 1) {
            n68_puttx_cancel(&tx, kN68SendGone);
        } else {
            unsigned long crc;
            long bytes;
            int end_flag;
            N68SendCode why;
            char buf[256];

            (void)drain_frames(&tx, &crc, &bytes, &end_flag, &why);
            (void)n68_puttx_build_end(&tx, buf, (long)sizeof buf, 1, 1);
            /* AT file.end, not at file.done. Every byte is framed by
               now, and the host's reply waits on its own disk writing a
               file that may be megabytes; a fork held open across that
               is held for nothing. Asserted here because otherwise the
               close in n68_puttx_done covers for a build_end that
               forgot - which is exactly what it did until this line. */
            check_long("the fork goes at file.end, not at file.done",
                       (long)s.closes, 1);
            n68_puttx_done(&tx, 7, 1, NULL);
        }
        check_long(cases[i].what, (long)s.closes, 1);
        check_true("and it ends idle", tx.state == kN68SendIdle);
    }
}

/* THE ABANDONMENT CASE, and the one that cost the most to find.
 *
 * A receiver that gives up mid-stream says so with file.done - the host
 * does exactly that (GuestListener.swift, failInboundStream sends
 * file.cancel AND file.done before a single byte more arrives). Until
 * this test existed, n68_puttx_done() acted only in kN68SendEnded, so a
 * file.done that arrived while bytes were still going out was DROPPED,
 * the sender streamed the rest of the file into a receiver that had
 * stopped listening, and then parked in kN68SendEnded waiting for a
 * file.done that had already come and gone. The lane is one transfer
 * wide, so that park refused every future transfer in BOTH directions
 * for the life of the connection - and wire68.c's 65 s no-traffic
 * watchdog never fired to break it, because the guest's own keepalive
 * ping keeps the connection audibly alive.
 *
 * A receiver's file.done is FINAL whenever it arrives. Waiting for our
 * own file.end first is what wedged the lane. */
static void test_a_receiver_that_gives_up_midstream_frees_the_lane(void)
{
    N68SendTx tx;
    FakeSrc s;
    unsigned char frame[kN68SendFrameCap];
    N68SendCode why = kN68SendOK;

    arm(&tx, &s, 40000, 40000);
    check_true("a frame goes out before the receiver gives up",
               n68_puttx_next_frame(&tx, frame, (long)sizeof frame, &why) > 0);
    check_true("and the sender is mid-stream",
               tx.state == kN68SendSending);

    n68_puttx_done(&tx, 7, 0, "io-error");

    check_true("a file.done mid-stream ends the transfer",
               tx.state == kN68SendIdle);
    check_long("and closes the source", (long)s.closes, 1);
    check_true("the outcome is remembered as a failure", tx.last_ok == 0);
    check_str("with the receiver's own word", tx.last_code, "io-error");
}

/* The other half of the same case: the host cancels rather than reports.
 * Both have to leave the lane free, and the code has to say which one
 * happened - "the connection went away" was the only word available for
 * a cancellation before, and it is a lie in the log when the connection
 * is fine and the host simply stopped wanting the file. */
static void test_a_cancel_midstream_frees_the_lane(void)
{
    N68SendTx tx;
    FakeSrc s;
    unsigned char frame[kN68SendFrameCap];
    N68SendCode why = kN68SendOK;

    arm(&tx, &s, 40000, 40000);
    check_true("a frame goes out before the cancel",
               n68_puttx_next_frame(&tx, frame, (long)sizeof frame, &why) > 0);

    n68_puttx_cancel(&tx, kN68SendCancelled);

    check_true("a cancel mid-stream ends the transfer",
               tx.state == kN68SendIdle);
    check_long("and closes the source", (long)s.closes, 1);
    check_str("the contract's word for it", n68_puttx_code_word(kN68SendCancelled),
              "cancelled");
    check_str("and it is remembered as one", tx.last_code, "cancelled");
    /* Distinct from a dropped connection: same wire word, different
       reason, and the reason is what a human reads in the log. */
    check_true("a cancel does not read as a dead link",
               strcmp(n68_puttx_code_reason(kN68SendCancelled),
                      n68_puttx_code_reason(kN68SendGone)) != 0);
}

/* A reply that arrives for a transfer that is over is late, not wrong.
 * Acting on it would start a transfer with no source behind it. */
static void test_stale_replies_are_ignored(void)
{
    N68SendTx tx;
    FakeSrc s;
    N68ByteSource src;

    fake_init(&s, 100);
    src = fake_source(&s, 100);
    n68_puttx_init(&tx);
    (void)n68_puttx_begin(&tx, 10, "X", &src, 0, NULL, NULL, 0);

    check_long("an accept for another id is ignored",
               n68_puttx_accepted(&tx, 11, 1), 0);
    check_true("and the sender is still waiting",
               tx.state == kN68SendOffered);

    n68_puttx_cancel(&tx, kN68SendRefused);
    check_long("an accept after the end is ignored",
               n68_puttx_accepted(&tx, 10, 1), 0);
    check_true("and does not resurrect it", tx.state == kN68SendIdle);
}

/* The sender keeps the contract's promise about names rather than
 * checking someone else's work: the receiver is entitled to assume it
 * ran. A colon is HFS's own separator, so a leaf carrying one is a path
 * in disguise. */
static void test_names_that_cannot_go_on_a_wire(void)
{
    static const struct { const char *name; int ok; } cases[] = {
        { "Report",                          1 },
        { "Report.txt",                      1 },
        { "1234567890123456789012345678901", 1 },  /* exactly 31 */
        { "12345678901234567890123456789012",0 },  /* 32 */
        { "",                                0 },
        { "Lab:Secrets",                     0 },
        { ":Lab",                            0 },
        { "two\rlines",                      0 },
    };
    long i;

    for (i = 0; i < (long)(sizeof cases / sizeof cases[0]); ++i) {
        check_long(cases[i].name[0] != '\0' ? cases[i].name : "(empty)",
                   n68_puttx_name_ok(cases[i].name), cases[i].ok);
    }
}

static void test_a_bad_name_takes_no_source(void)
{
    N68SendTx tx;
    FakeSrc s;
    N68ByteSource src;

    fake_init(&s, 10);
    src = fake_source(&s, 10);
    n68_puttx_init(&tx);
    check_long("refused", (long)n68_puttx_begin(&tx, 1, "a:b", &src, 0,
                                                NULL, NULL, 0),
               (long)kN68SendBadName);
    check_long("and nothing was taken", (long)s.closes, 0);
    check_true("and it stayed idle", tx.state == kN68SendIdle);
}

/* Truncation must not leave a half-escaped or half-built message on the
 * wire: a frame the host cannot decode costs the whole connection, which
 * is a worse outcome than the message not going at all. */
static void test_a_message_that_does_not_fit_builds_nothing(void)
{
    N68SendTx tx;
    FakeSrc s;
    N68ByteSource src;
    char small[20];

    fake_init(&s, 10);
    src = fake_source(&s, 10);
    n68_puttx_init(&tx);
    (void)n68_puttx_begin(&tx, 1, "Name", &src, 0, NULL, NULL, 0);
    check_long("offer into too small a buffer",
               n68_puttx_build_offer(&tx, small, (long)sizeof small), 0);
}

int main(void)
{
    test_offer_is_the_shape_the_host_decodes();
    test_offer_carries_macbinary_and_modified();
    test_begin_and_end_are_the_shapes_the_host_decodes();
    test_a_failed_end_carries_no_crc();

    test_every_size_streams_exactly_once();
    test_an_empty_source_sends_no_bulk_frame();
    test_a_short_filling_source_still_fills_frames();

    test_a_source_that_ends_early_fails_the_transfer();
    test_a_source_that_fails_partway_fails_the_transfer();
    test_a_source_that_overruns_is_refused();

    test_a_second_transfer_is_refused_and_takes_nothing();
    test_the_source_is_closed_on_every_ending();
    test_a_receiver_that_gives_up_midstream_frees_the_lane();
    test_a_cancel_midstream_frees_the_lane();
    test_stale_replies_are_ignored();
    test_names_that_cannot_go_on_a_wire();
    test_a_bad_name_takes_no_source();
    test_a_message_that_does_not_fit_builds_nothing();

    if (failures != 0) {
        printf("%d failure(s)\n", failures);
        return 1;
    }
    printf("all puttx checks passed\n");
    return 0;
}
