#ifndef NOW68K_FRAME_H
#define NOW68K_FRAME_H

#include "wire_limits.h"

/* Frame header layout, contract/asyncapi.yaml lines 16-22 (prose, not a
 * schema -- no schema standard expresses binary framing):
 *
 *   offset  size  field     meaning
 *   0       u8    channel   0 = control, 1 = bulk
 *   1       u8    flags     bit0 END: last frame of this transfer
 *   2       u16   transfer  bulk correlation id; 0 on control frames
 *   4       u32   length    payload bytes that follow (max 32768)
 *
 * Big-endian on the wire. The 68K is big-endian natively, so a struct
 * overlay would happen to work here -- but the host test build is
 * little-endian, and "happens to work on one side" is exactly the bug
 * this project keeps shipping. Pack/unpack are explicit byte-wise code
 * so the codec is provably correct on both.
 */

#define NOW68K_FRAME_HEADER_BYTES ((unsigned)NOW_WIRE_FRAME_HEADER_BYTES)

#define NOW68K_CHANNEL_CONTROL ((unsigned)NOW_WIRE_CHANNEL_CONTROL)
#define NOW68K_CHANNEL_BULK    ((unsigned)NOW_WIRE_CHANNEL_BULK)

#define NOW68K_FLAG_END ((unsigned)NOW_WIRE_FLAG_END)

/* Max payload bytes of ANY frame, control or bulk -- the ONE bound the
 * contract states normatively. A length over this is a PROTOCOL
 * VIOLATION on either channel: the sender broke the wire format itself,
 * and the connection cannot be trusted past that point. There is no
 * smaller protocol-level cap for control frames -- see
 * NOW68K_CONTROL_BUFFER_CAP below for why an earlier version of this
 * file believed otherwise.
 *
 * The number itself is contract/wire_limits.h now. This comment used to
 * record that it had been "cross-checked against FrameCodec.swift's
 * maxPayloadLength and the PPC guest's kNowMaxPayload, both 32768" --
 * which is exactly the hand-maintained agreement between three copies
 * that AGENTS.md names as this project's costliest defect. Two of the
 * three are aliases of one number now, and the Swift one is asserted
 * against it by FrameCodecTests. */
#define NOW68K_MAX_PAYLOAD ((unsigned long)NOW_WIRE_MAX_PAYLOAD)

/* Bytes our OWN control receive buffer can hold. This is a BUFFER SIZE,
 * not a protocol bound: nothing on the wire is illegal above this
 * number, it stays legal up to NOW68K_MAX_PAYLOAD. The contract's prose
 * ("control frames cap at 4 KB", repeated at four operations: file
 * listings, census reports, process listings, software listings) was
 * mistaken for a protocol limit here once; it names a PAGINATION
 * convention those operations follow, not a wire-legality bound, and the
 * PPC guest treats a control frame past its own equivalent buffer size
 * as recoverable, not fatal -- see now68k_control_frame_fits() below and
 * now/guest/src/wire.c's on_frame_ready(), "Bigger than we can hold":
 * "Skipping it costs one message; dropping the connection costs
 * everything in flight and looks like a network fault instead of a
 * message we could not read." Keep this in sync with whatever buffer
 * actually backs the control channel at the call site -- a sender and a
 * receiver reading two different copies of this number is a documented
 * failure mode (the PPC guest's contract.h carries the same warning).
 */
#define NOW68K_CONTROL_BUFFER_CAP 4096UL

typedef struct {
    unsigned char channel;
    unsigned char flags;
    unsigned short transfer;
    unsigned long length;
} Now68kFrameHeader;

/* Encodes hdr into out as the 8 big-endian bytes above. Purely mechanical:
 * it does not clamp or validate length against either limit above -- call
 * now68k_frame_length_ok() first if that matters at the call site. */
void now68k_frame_pack(const Now68kFrameHeader *hdr,
                        unsigned char out[NOW68K_FRAME_HEADER_BYTES]);

/* Decodes the 8 big-endian bytes in into hdr. Also purely mechanical. */
void now68k_frame_unpack(const unsigned char in[NOW68K_FRAME_HEADER_BYTES],
                          Now68kFrameHeader *hdr);

/* Returns 1 if `length` is a PROTOCOL-LEGAL frame length (bound only by
 * NOW68K_MAX_PAYLOAD, the same on every channel), 0 if the sender
 * violated the wire format itself -- the one case where the connection
 * cannot be trusted and dropping it is the right call. This says
 * NOTHING about whether a legal frame fits any particular receive
 * buffer; see now68k_control_frame_fits() for that question, which is
 * ours to answer, not the protocol's. */
int now68k_frame_length_ok(unsigned long length);

/* Returns 1 if a (protocol-legal) control frame of `length` bytes fits
 * in our NOW68K_CONTROL_BUFFER_CAP-byte control receive buffer, 0 if it
 * does not. A 0 here is NOT a protocol violation -- the caller must
 * SKIP the frame and keep the connection (one lost message), never treat
 * it as fatal. Meaningless for the bulk channel, which streams into its
 * own buffer without this constraint; call it only for control frames. */
int now68k_control_frame_fits(unsigned long length);

#endif
