#ifndef N68_READER_H
#define N68_READER_H

/*
 * The inbound frame read state machine, lifted out of wire68.c unchanged.
 *
 * This is the highest-consequence and least-observable code in the guest:
 * MacTCP hands back whatever bytes it happens to have, so every frame
 * boundary can land mid-header or mid-body, and a reader that loses frame
 * sync does not fail loudly - the connection silently becomes garbage.
 * Several of its branches (an oversized-but-legal control frame, a bulk
 * frame, a length past NOW68K_MAX_PAYLOAD) had never executed anywhere,
 * on metal or in an emulator, because reaching them meant a host that
 * sends something no host sends.
 *
 * So the state machine takes its world through this struct of callbacks
 * rather than calling net_take/TickCount/now68k_log/teardown_and_retry
 * directly - the same shape frame.c, n68_console_ring.c, connfields.c and
 * json_scan.c already use to stay testable off-metal. wire68.c supplies
 * the real ones; now-guest-68k/tests/test_reader.c supplies a scripted fake
 * transport that can deliver one byte at a time.
 *
 * No Toolbox call, no allocation: both buffers belong to the caller.
 */

#include "frame.h"

typedef enum {
    N68_RS_HEADER = 0,  /* accumulating the 8-byte frame header */
    N68_RS_SKIP,        /* discarding a control frame too big for the
                           control buffer - and, when nothing is willing
                           to take it, a bulk frame too: "throw away N
                           bytes, then read the next header" */
    N68_RS_BODY,        /* accumulating a control payload into ctrl_buf */
    N68_RS_BULK         /* handing a bulk frame's payload to bulk_data in
                           whatever runs the transport produces */
} N68ReaderState;

/* Every dependency the state machine has on the rest of the guest. All of
 * them are required; the reader does not test a pointer before calling it,
 * because a half-wired reader that silently drops half its events is worse
 * than the crash that names the missing one. `ctx` is the caller's, passed
 * back untouched. */
typedef struct N68ReaderOps {
    /* net_take: copy up to `cap` bytes of already-buffered inbound data,
       returning how many (never blocks, may return 0). */
    long (*take)(void *ctx, void *dst, long cap);

    /* `got` bytes just arrived, in any state - where the byte counter and
       the last-inbound-tick watchdog get fed. */
    void (*took)(void *ctx, long got);

    /* A complete, protocol-legal header was decoded (counts frames in). */
    void (*frame_started)(void *ctx);

    /* length > NOW68K_MAX_PAYLOAD: the ONE fatal case. The sender broke
       the wire format itself, so the connection cannot be trusted past
       this point (frame.h). The reader stops draining after this call and
       expects the callee to have torn the connection down. */
    void (*oversized_frame)(void *ctx, unsigned long length);

    /* Legal on the wire, too big for ctrl_buf. Skipping it costs one
       message, not the connection (frame.h). Notification only - the
       reader has already arranged to skip it. */
    void (*oversized_control)(void *ctx, unsigned long length);

    /* A control frame with a zero-length payload arrived. */
    void (*empty_control)(void *ctx);

    /* A bulk frame is starting. Return 1 to have its payload delivered
       to bulk_data below, 0 to have it DISCARDED - which is what this
       reader did with every bulk frame before there was anything to
       receive one, and still does when a frame arrives with no transfer
       expecting it.
       Either way the reader stays in frame sync: consuming and dropping
       is not an error and never costs the connection. */
    int (*bulk_wanted)(void *ctx, unsigned long length);

    /* One run of a wanted bulk frame's payload, in whatever sizes the
       transport happens to produce - never a whole frame, and never
       aligned to anything. Called repeatedly until the frame is
       consumed. The callee may fail internally; it does not tell the
       reader, because a failed WRITE is not a failed FRAME and the
       stream must still be drained to stay in sync. */
    void (*bulk_data)(void *ctx, const unsigned char *bytes, long len);

    /* One fully-received control payload, in ctrl_buf. May tear the
       connection down, which is what still_reading() is asked about
       immediately afterwards. */
    void (*control_message)(void *ctx, const char *json, long len);

    /* 0 if the connection is no longer in a state that should keep
       draining - asked only after control_message(). */
    int (*still_reading)(void *ctx);
} N68ReaderOps;

typedef struct N68Reader {
    N68ReaderState state;
    unsigned char hdr[NOW68K_FRAME_HEADER_BYTES];
    long have;               /* header bytes buffered so far (RS_HEADER) */
    unsigned long remaining; /* bytes left to discard (RS_SKIP) */
    long body_len;           /* control payload length (RS_BODY) */
    long body_have;          /* control payload bytes buffered so far */

    /* Caller-owned. ctrl_buf must hold NOW68K_CONTROL_BUFFER_CAP bytes -
       that constant is what now68k_control_frame_fits() answers against,
       and a buffer smaller than it would overrun on a frame the reader
       has already decided fits. sink is scratch of any size >= 1. */
    char *ctrl_buf;
    unsigned char *sink;
    long sink_cap;

    const N68ReaderOps *ops;
    void *ctx;
} N68Reader;

/* Wires a reader to its buffers and ops and puts it at a frame boundary. */
void n68_reader_init(N68Reader *r, char *ctrl_buf,
                     unsigned char *sink, long sink_cap,
                     const N68ReaderOps *ops, void *ctx);

/* Back to "expecting a header", discarding any partial frame. Called on
 * every connection teardown: a half-read frame from a dead connection has
 * nothing to do with the next one. */
void n68_reader_reset(N68Reader *r);

/* Drains whatever the transport has already buffered, one frame step at a
 * time, until nothing more is available right now (take() never blocks) or
 * the connection has been torn down by something control_message() did. */
void n68_reader_drain(N68Reader *r);

#endif
