/* Host-side test for the outbound-queue back-pressure NOW-68K applies to
 * its inbound frame reader (src/n68_reader.c driven by wire68.c's policy).
 *
 * WHAT THIS DOES AND DOES NOT PROVE. wire68.c cannot be compiled here - it
 * is MacTCP and Toolbox all the way down - so the predicate under test is
 * a MODEL of its two policy points, written to the same shape:
 *
 *     drain_frames()       refuses to start when every slot is occupied
 *     read_still_reading() stops the drain after a message when the last
 *                          slot has just been taken
 *
 * The thing being verified is not those two lines (they are three
 * comparisons, verified by reading them and by the build). It is the
 * property they depend on and that nobody had checked: that stopping the
 * reader mid-stream, on purpose, at an arbitrary frame boundary, loses
 * NOTHING - no bytes, no frame sync, no ordering - so that "do not read a
 * request you cannot answer" is a deferral rather than a new way to drop
 * messages. n68_reader.c was written to stop only for a teardown, after
 * which nothing resumed; back-pressure is the first caller that stops it
 * and then comes back.
 *
 * The queue below is a model too - depth, one reply per request, flushed
 * by the test rather than by MacTCP. That is the point: it lets the test
 * ask what happens when the queue is full at exactly the wrong moment,
 * which on real hardware needs a host that pipelines faster than a
 * PowerBook 180c can send, and which is why the "all slots busy" branch
 * had never executed anywhere.
 */

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

/* wire68.c's kWireOutQueueDepth. Restated here on purpose rather than
 * included: wire68.h drags in net.h and MacTCP, and the property under
 * test holds at every depth >= 1 - test_at_depth() runs it at several. */
#define MODEL_DEPTH 4

#define FEED_CAP  8192
#define MSG_CAP   64
#define MAX_MSGS  64

typedef struct {
    unsigned char feed[FEED_CAP];
    long feed_len;
    long feed_pos;
    long chunk;             /* 0 = give everything; 1 = the MacTCP worst case */

    int  connected;

    /* The outbound queue model. */
    long depth;
    long queued;            /* occupied slots */
    int  backpressure;      /* 0 reproduces the pre-fix behaviour */

    /* One reply per request, in the order the requests were answered. */
    int  answered[MAX_MSGS];
    int  answer_count;
    int  dropped;           /* replies that found no slot - must stay 0 */

    int  msg_count;
} Model;

/* ---- the reader's world ------------------------------------------------ */

static long m_take(void *ctx, void *dst, long cap)
{
    Model *m = (Model *)ctx;
    long avail = m->feed_len - m->feed_pos;
    long n;

    if (avail <= 0 || cap <= 0) {
        return 0;
    }
    n = (cap < avail) ? cap : avail;
    if (m->chunk > 0 && n > m->chunk) {
        n = m->chunk;
    }
    memcpy(dst, m->feed + m->feed_pos, (size_t)n);
    m->feed_pos += n;
    return n;
}

static void m_took(void *ctx, long got) { (void)ctx; (void)got; }
static void m_frame_started(void *ctx) { (void)ctx; }

static void m_oversized_frame(void *ctx, unsigned long length)
{
    (void)length;
    ((Model *)ctx)->connected = 0;
}

static void m_oversized_control(void *ctx, unsigned long length)
{
    (void)ctx; (void)length;
}

static void m_empty_control(void *ctx) { (void)ctx; }

/* Every control message is a request, and every request is answered - the
 * contract's rule 4, which is the whole reason back-pressure exists. The
 * payload is "<n>", the request's ordinal, so ordering is checkable. */
static void m_control_message(void *ctx, const char *json, long len)
{
    Model *m = (Model *)ctx;
    char text[MSG_CAP];
    long n = (len < MSG_CAP - 1) ? len : MSG_CAP - 1;
    int ordinal = 0;
    long i;

    ++m->msg_count;
    memcpy(text, json, (size_t)n);
    text[n] = '\0';
    for (i = 0; text[i] >= '0' && text[i] <= '9'; ++i) {
        ordinal = ordinal * 10 + (text[i] - '0');
    }

    if (m->queued >= m->depth) {
        ++m->dropped;       /* the branch back-pressure exists to prevent */
        return;
    }
    ++m->queued;
    if (m->answer_count < MAX_MSGS) {
        m->answered[m->answer_count++] = ordinal;
    }
}

/* wire68.c's read_still_reading(), modelled. */
static int m_still_reading(void *ctx)
{
    Model *m = (Model *)ctx;

    if (!m->connected) {
        return 0;
    }
    if (!m->backpressure) {
        return 1;
    }
    return m->queued < m->depth;
}

static const N68ReaderOps kOps = {
    m_take, m_took, m_frame_started, m_oversized_frame,
    m_oversized_control, m_empty_control, m_control_message, m_still_reading
};

static char g_ctrl_buf[NOW68K_CONTROL_BUFFER_CAP];
static unsigned char g_sink[256];

/* wire68.c's drain_frames(): the entry half of the same policy. */
static void model_drain(Model *m, N68Reader *r)
{
    if (m->backpressure && m->queued >= m->depth) {
        return;
    }
    n68_reader_drain(r);
}

/* One slot's worth of MacTCP progress. */
static void model_flush_one(Model *m)
{
    if (m->queued > 0) {
        --m->queued;
    }
}

/* ---- feeding ----------------------------------------------------------- */

static void feed_frame(Model *m, unsigned char channel, const char *payload)
{
    Now68kFrameHeader hdr;
    unsigned long len = (unsigned long)strlen(payload);

    hdr.channel = channel;
    hdr.flags = 0;
    hdr.transfer = 0;
    hdr.length = len;
    now68k_frame_pack(&hdr, m->feed + m->feed_len);
    m->feed_len += NOW68K_FRAME_HEADER_BYTES;
    memcpy(m->feed + m->feed_len, payload, (size_t)len);
    m->feed_len += (long)len;
}

static void model_reset(Model *m, N68Reader *r, long depth, long chunk,
                        int backpressure)
{
    memset(m, 0, sizeof *m);
    m->connected = 1;
    m->depth = depth;
    m->chunk = chunk;
    m->backpressure = backpressure;
    n68_reader_init(r, g_ctrl_buf, g_sink, (long)sizeof g_sink, &kOps, m);
}

/* ---- the property ------------------------------------------------------ */

/* `count` pipelined requests arrive faster than the queue drains. Every
 * one must be answered exactly once, in order, with nothing dropped -
 * however many passes that takes. This is wire_idle()'s shape: flush,
 * then drain, forever. */
static void run_pipeline(long depth, long chunk, int count, int backpressure,
                         const char *what)
{
    Model m;
    N68Reader r;
    char msg[160];
    int i;
    int passes = 0;

    model_reset(&m, &r, depth, chunk, backpressure);
    for (i = 1; i <= count; ++i) {
        char body[MSG_CAP];

        snprintf(body, sizeof body, "%d-request", i);
        feed_frame(&m, NOW68K_CHANNEL_CONTROL, body);
    }

    /* Flush one slot per pass, exactly as a busy wire would. Stop when a
       pass changes nothing. */
    for (;;) {
        long before_pos = m.feed_pos;
        int before_answers = m.answer_count;

        model_flush_one(&m);
        model_drain(&m, &r);
        ++passes;
        if (m.feed_pos == before_pos && m.answer_count == before_answers) {
            break;
        }
        snprintf(msg, sizeof msg, "%s: the pump terminates", what);
        CHECK(passes < 500, msg);
        if (passes >= 500) {
            return;
        }
    }

    snprintf(msg, sizeof msg, "%s: every request was read", what);
    CHECK(m.msg_count == count, msg);
    snprintf(msg, sizeof msg, "%s: every request was answered", what);
    CHECK(m.answer_count == count, msg);
    snprintf(msg, sizeof msg, "%s: no reply was dropped", what);
    CHECK(m.dropped == 0, msg);
    snprintf(msg, sizeof msg, "%s: the whole feed was consumed", what);
    CHECK(m.feed_pos == m.feed_len, msg);

    for (i = 0; i < m.answer_count && i < count; ++i) {
        snprintf(msg, sizeof msg, "%s: reply %d answers request %d", what,
                 i + 1, i + 1);
        CHECK(m.answered[i] == i + 1, msg);
    }
}

static void test_pipeline_at_several_depths(void)
{
    /* Whole reads are where the pressure actually happens: the drain
       consumes every buffered frame in one call, so the queue fills inside
       a single pass. A transport that hands back one byte at a time never
       fills it - the reader returns as soon as a partial header leaves it
       with nothing to do - so those runs are testing something else worth
       testing (that the SAME pipeline still completes when the reader is
       stopping for the other reason) and not back-pressure. Measured, not
       assumed: mutating the queue check out of m_still_reading fails the
       whole-read runs and leaves the one-byte runs green. */
    run_pipeline(MODEL_DEPTH, 0, 20, 1, "depth 4, whole reads");
    run_pipeline(MODEL_DEPTH, 64, 20, 1, "depth 4, frame-sized reads");
    run_pipeline(MODEL_DEPTH, 1, 20, 1, "depth 4, one byte at a time");
    run_pipeline(1, 0, 12, 1, "depth 1, whole reads");
    run_pipeline(1, 1, 12, 1, "depth 1, one byte at a time");
    run_pipeline(2, 0, 20, 1, "depth 2, whole reads");
    run_pipeline(MODEL_DEPTH, 0, 1, 1, "a single request");
}

/* The mutation, run as a test: WITHOUT back-pressure the same pipeline
 * drops replies. This is the branch the fix removes, asserted rather than
 * described - if a later change makes back-pressure a no-op, this test
 * fails and says the queue is no longer the thing that stops the reader. */
static void test_without_backpressure_replies_are_lost(void)
{
    Model m;
    N68Reader r;
    int i;

    model_reset(&m, &r, MODEL_DEPTH, 0, 0);
    for (i = 1; i <= 20; ++i) {
        char body[MSG_CAP];

        snprintf(body, sizeof body, "%d-request", i);
        feed_frame(&m, NOW68K_CHANNEL_CONTROL, body);
    }
    n68_reader_drain(&r);

    CHECK(m.msg_count == 20, "without back-pressure every request is read");
    CHECK(m.dropped == 20 - MODEL_DEPTH,
          "and every request past the queue's depth goes unanswered - which "
          "is the contract violation back-pressure exists to prevent");
}

/* Stopping for back-pressure must not cost frame sync, including across
 * the frame shapes that are not plain control messages: a bulk frame the
 * guest discards, and an empty control frame. */
static void test_frame_sync_survives_a_stop(void)
{
    Model m;
    N68Reader r;
    int passes = 0;

    model_reset(&m, &r, 1, 1, 1);       /* depth 1: it stops constantly */
    feed_frame(&m, NOW68K_CHANNEL_CONTROL, "1-request");
    feed_frame(&m, (unsigned char)(NOW68K_CHANNEL_CONTROL + 1),
               "bulk bytes the guest discards");
    feed_frame(&m, NOW68K_CHANNEL_CONTROL, "2-request");
    feed_frame(&m, NOW68K_CHANNEL_CONTROL, "");
    feed_frame(&m, NOW68K_CHANNEL_CONTROL, "3-request");

    for (;;) {
        long before = m.feed_pos;
        int before_answers = m.answer_count;

        model_flush_one(&m);
        model_drain(&m, &r);
        if (++passes > 500) {
            break;
        }
        if (m.feed_pos == before && m.answer_count == before_answers) {
            break;
        }
    }

    /* Four control frames, one of them empty (which is not a message). */
    CHECK(m.msg_count == 3, "the three real requests arrived");
    CHECK(m.answer_count == 3, "and all three were answered");
    CHECK(m.dropped == 0, "with nothing dropped");
    CHECK(m.answered[0] == 1 && m.answered[1] == 2 && m.answered[2] == 3,
          "in order, across a bulk frame and an empty one");
    CHECK(m.feed_pos == m.feed_len, "frame sync held to the last byte");
}

/* The entry half: a pass that begins with a full queue must not consume a
 * single byte. Without it, one more request is read per pass than can be
 * answered - the exact leak the after-the-message hook cannot close,
 * because it is only asked after a message. */
static void test_full_queue_reads_nothing(void)
{
    Model m;
    N68Reader r;

    model_reset(&m, &r, MODEL_DEPTH, 0, 1);
    feed_frame(&m, NOW68K_CHANNEL_CONTROL, "1-request");
    m.queued = MODEL_DEPTH;

    model_drain(&m, &r);
    CHECK(m.feed_pos == 0, "a full queue reads nothing at all");
    CHECK(m.msg_count == 0, "so no request is read that cannot be answered");

    model_flush_one(&m);
    model_drain(&m, &r);
    CHECK(m.msg_count == 1, "and the request is still there once a slot "
                            "frees up");
    CHECK(m.dropped == 0, "answered, not dropped");
}

int main(void)
{
    test_pipeline_at_several_depths();
    test_without_backpressure_replies_are_lost();
    test_frame_sync_survives_a_stop();
    test_full_queue_reads_nothing();

    printf("%s: %d checks, %d failures\n",
           g_failures == 0 ? "PASS" : "FAIL", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
