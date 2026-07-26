/* n68_reader.c - implementation of n68_reader.h.
 *
 * Moved verbatim out of wire68.c's drain_frames(); the only changes are
 * the injected seams named in the header. If you are tempted to improve
 * something here, do not: this code is metal-proven on a PowerBook 180c
 * for the paths a real host exercises, and a "cleanup" that changes
 * behaviour would not show up until it bit someone on hardware. */

#include "n68_reader.h"

void n68_reader_init(N68Reader *r, char *ctrl_buf,
                     unsigned char *sink, long sink_cap,
                     const N68ReaderOps *ops, void *ctx)
{
    r->ctrl_buf = ctrl_buf;
    r->sink = sink;
    r->sink_cap = sink_cap;
    r->ops = ops;
    r->ctx = ctx;
    n68_reader_reset(r);
}

void n68_reader_reset(N68Reader *r)
{
    r->state = N68_RS_HEADER;
    r->have = 0;
    r->remaining = 0;
    r->body_len = 0;
    r->body_have = 0;
}

void n68_reader_drain(N68Reader *r)
{
    const N68ReaderOps *ops = r->ops;

    for (;;) {
        switch (r->state) {
        case N68_RS_HEADER: {
            long need = (long)NOW68K_FRAME_HEADER_BYTES - r->have;
            long got = ops->take(r->ctx, r->hdr + r->have, need);

            if (got <= 0) {
                return;
            }
            r->have += got;
            ops->took(r->ctx, got);
            if (r->have < (long)NOW68K_FRAME_HEADER_BYTES) {
                return;
            }
            {
                Now68kFrameHeader hdr;

                now68k_frame_unpack(r->hdr, &hdr);
                r->have = 0;

                if (!now68k_frame_length_ok(hdr.length)) {
                    /* The ONE fatal case: the sender broke the wire format
                     * itself, so the connection cannot be trusted past this
                     * point (frame.h). */
                    ops->oversized_frame(r->ctx, hdr.length);
                    return;
                }
                ops->frame_started(r->ctx);

                if (hdr.channel != NOW68K_CHANNEL_CONTROL) {
                    /* Bulk. Whoever might receive it decides: delivered
                     * to bulk_data, or consumed and discarded when
                     * nothing is expecting bytes. Discarding stays the
                     * default and is never fatal - a frame still in
                     * flight when a transfer was abandoned has to land
                     * somewhere, and frame sync is what matters. */
                    r->remaining = hdr.length;
                    if (hdr.length == 0) {
                        r->state = N68_RS_HEADER;
                    } else {
                        r->state = ops->bulk_wanted(r->ctx, hdr.length)
                                       ? N68_RS_BULK : N68_RS_SKIP;
                    }
                    continue;
                }
                if (!now68k_control_frame_fits(hdr.length)) {
                    /* Legal on the wire, too big for ctrl_buf. Skipping it
                     * costs one message, not the connection (frame.h). */
                    ops->oversized_control(r->ctx, hdr.length);
                    r->remaining = hdr.length;
                    r->state = (hdr.length == 0) ? N68_RS_HEADER : N68_RS_SKIP;
                    continue;
                }
                r->body_len = (long)hdr.length;
                r->body_have = 0;
                if (r->body_len == 0) {
                    ops->empty_control(r->ctx);
                    r->state = N68_RS_HEADER;
                    continue;
                }
                r->state = N68_RS_BODY;
                continue;
            }
        }
        case N68_RS_SKIP: {
            long cap = (r->remaining > (unsigned long)r->sink_cap)
                           ? r->sink_cap
                           : (long)r->remaining;
            long got = ops->take(r->ctx, r->sink, cap);

            if (got <= 0) {
                return;
            }
            r->remaining -= (unsigned long)got;
            ops->took(r->ctx, got);
            if (r->remaining == 0) {
                r->state = N68_RS_HEADER;
            }
            continue;
        }
        case N68_RS_BULK: {
            /* Same shape as RS_SKIP - take what the transport has, up to
             * what is left of the frame - except the bytes are handed
             * on instead of dropped. Bounded by sink_cap, so a 32 KB
             * frame costs no buffer: this is what "streams bulk without
             * buffering a frame whole" means on this side. */
            long cap = (r->remaining > (unsigned long)r->sink_cap)
                           ? r->sink_cap
                           : (long)r->remaining;
            long got = ops->take(r->ctx, r->sink, cap);

            if (got <= 0) {
                return;
            }
            r->remaining -= (unsigned long)got;
            ops->took(r->ctx, got);
            ops->bulk_data(r->ctx, r->sink, got);
            if (r->remaining == 0) {
                r->state = N68_RS_HEADER;
            }
            continue;
        }
        case N68_RS_BODY: {
            long need = r->body_len - r->body_have;
            long got = ops->take(r->ctx, r->ctrl_buf + r->body_have, need);

            if (got <= 0) {
                return;
            }
            r->body_have += got;
            ops->took(r->ctx, got);
            if (r->body_have < r->body_len) {
                return;
            }
            ops->control_message(r->ctx, r->ctrl_buf, r->body_len);
            r->state = N68_RS_HEADER;
            if (!ops->still_reading(r->ctx)) {
                return;   /* handler tore the connection down */
            }
            continue;
        }
        }
    }
}
