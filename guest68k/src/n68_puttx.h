#ifndef NOW68K_PUTTX_H
#define NOW68K_PUTTX_H

/*
 * Sending bytes guest->host: the decisions, with no Toolbox in them.
 *
 * The mirror of n68_putrx.h. That file receives a push; this one sends
 * one. The contract's shape is the same sequence read from the other
 * end - file.offer -> file.accept/file.refuse -> file.begin -> bulk
 * frames -> file.end -> file.done - and every message in it already
 * exists in contract/asyncapi.yaml, already has a schema, and is already
 * served by the host (GuestListener.swift, onAcceptOffer/finishInbound)
 * and sent by the PowerPC guest (guest/src/wire.c, send_offer /
 * send_accepted). This direction is ADDITIVE: it needed no new message
 * and no new field.
 *
 * What it does need is stated here rather than in wire68.c, because
 * these are the parts a test can reach.
 *
 * ---- The source is an interface, and that is the point ----------------
 *
 * n68_bytesrc.h. Read its promises before writing an implementation.
 * This module never opens, reads, seeks or closes a file; it asks a
 * source to fill a buffer and it frames whatever it gets. The first
 * source is a file (n68_filesrc.h). The one this shape exists for is a
 * screen capture, which cannot be buffered on this machine at all.
 *
 * ---- How bulk and control share the wire ------------------------------
 *
 * THE RULE, stated once, here, because getting it wrong drops a
 * command.result and that is a contract violation the ledger already
 * records the cost of:
 *
 *   1. BULK NEVER TOUCHES THE CONTROL QUEUE. wire68.c's four slots x
 *      1024 bytes (NOW68K_CONTROL_SEND_CAP) stay reserved for control
 *      messages. Bulk gets ONE dedicated slot of its own, sized for a
 *      chunk, so no volume of bulk can ever consume a slot a reply
 *      needs.
 *
 *   2. A FRAME ALREADY BEING HANDED TO net_queue_send FINISHES FIRST.
 *      net.h stages bytes in order, so two frames whose bytes interleave
 *      are two corrupt frames. Whichever frame is partly out goes out
 *      completely before any other frame's first byte.
 *
 *   3. OTHERWISE, CONTROL DRAINS BEFORE BULK. A reply queued during a
 *      transfer waits at most for the chunk currently in flight - 4096
 *      bytes, about 12 ms at the ~340 KB/s this link has measured -
 *      and never for the transfer.
 *
 *   4. BACK-PRESSURE IS net_queue_send's SHORT ACCEPT, and nothing else.
 *      The next chunk is produced only once the previous one has been
 *      fully accepted. There is no window, no timer, and no dependence
 *      on the host's file.progress.
 *
 * Rule 4 is the one that looks like a bug later, so: this side does NOT
 * need the receiver's progress reports to clock itself, and the host
 * DOES (docs/large-transfers.md). That asymmetry is real. MacTCP's
 * staging buffer is small and net_queue_send reports synchronously and
 * truthfully how much of it is free, so the local buffer IS the flow
 * control. The host writes into Network.framework, which accepts
 * essentially unbounded writes and therefore tells it nothing - so it
 * has to be paced by the far end's confirmations instead. Two senders,
 * two mechanisms, same purpose, and neither one is the other's bug.
 *
 * ---- Nothing here loops ------------------------------------------------
 *
 * One chunk per wire_idle() pass. This module has no loop that runs
 * longer than a single fill-and-frame, so unlike proc68.c's catalog
 * search and vprobe68.c's measurement it needs no pump of its own: the
 * event loop that already runs is the thing that advances it. A sender
 * written as a loop with a pump inside would be deaf between its pumps
 * and would re-enter this state machine through them.
 */

#include "n68_bytesrc.h"
#include "frame.h"
#include "hello.h"   /* NOW68K_HELLO_CHUNK - the negotiated chunk, stated once */

/* Bulk payload bytes per frame. This is `chunk` from the hello handshake
 * (hello.h, NOW68K_HELLO_CHUNK) and it is 4096 for a measured reason
 * that is not "4096 is a nice number": MacTCP advertises a ~8K receive
 * window regardless of rcvBuff, and an 8K chunk stalls about 220 ms per
 * write waiting on a delayed-ACK window update. Read hello.h before
 * changing anything about it.
 *
 * The contract says the connection uses the SMALLER of the two sides'
 * preferences, and this guest's is already the smaller of any pair it
 * has met, so it sends at its own. If a host ever offers less, this is
 * where that would have to be honoured - and it is not, today. */
#define kN68SendChunk NOW68K_HELLO_CHUNK

/* Bytes a caller's frame buffer must hold: one header plus one chunk. */
#define kN68SendFrameCap (NOW68K_FRAME_HEADER_BYTES + kN68SendChunk)

/* Longest leaf name this guest will send, matching n68_putrx.h's cap so
 * the two directions refuse the same names. */
#define kN68SendNameCap 64

typedef enum {
    kN68SendIdle = 0,
    kN68SendOffered,    /* file.offer sent; waiting for accept or refuse */
    kN68SendSending,    /* file.begin sent; bulk frames going out */
    kN68SendEnded       /* file.end sent; waiting for the host's file.done */
} N68SendState;

/* Why a send did not happen, or stopped happening. Rendered for the
 * contract's `code` fields by n68_puttx_code_word(). */
typedef enum {
    kN68SendOK = 0,
    kN68SendBusy,         /* one transfer at a time - the contract's rule */
    kN68SendNoSource,     /* the source could not be opened at all */
    kN68SendSourceFailed, /* fill() returned -1 partway through */
    kN68SendShort,        /* the source ended before `total` bytes */
    kN68SendLong,         /* the source offered more than `total` bytes */
    kN68SendBadName,      /* the leaf name is not one we will put on a wire */
    kN68SendRefused,      /* the host said file.refuse */
    kN68SendGone          /* the connection went away mid-transfer */
} N68SendCode;

typedef struct {
    N68SendState state;

    long id;                    /* our own transfer id, echoed by the host */
    unsigned short transfer;    /* the bulk correlation id */
    char name[kN68SendNameCap];
    long total;                 /* the source's declared length */
    int  macbinary;             /* container == "macbinary" */
    char file_type[8];          /* four chars, or "" */
    char creator[8];
    unsigned long modified;     /* Mac epoch seconds, or 0 */

    N68ByteSource src;
    int  src_open;              /* close() still owed - see promise (5) */

    long sent;                  /* payload bytes framed so far */
    unsigned long crc;          /* running CRC-32 of everything framed */
    int  src_done;              /* the source has said it has no more */

    /* What happened to the last one, kept after it ends. "How did that
       go" is the question a person actually has, and it becomes
       unanswerable the moment the transfer finishes if nothing
       remembers - the same reasoning as wire68.h's N68PutStatus. */
    int  had_one;
    int  last_ok;
    long last_bytes;
    char last_name[kN68SendNameCap];
    char last_code[16];
} N68SendTx;

/* Puts a sender at "nothing in flight". Call once at startup. */
void n68_puttx_init(N68SendTx *tx);

/* 1 if `name` is a leaf this guest will offer: 1..31 characters, no
 * colon, no control bytes. The contract asks the SENDER to have
 * sanitized to that already (FileOffer), so this is where that promise
 * is kept rather than a check on someone else's work.
 *
 * Published so a test can walk the cases directly: it is the check that
 * gets quietly relaxed, and the receiver on the other side is entitled
 * to assume it ran. */
int n68_puttx_name_ok(const char *name);

/* Arms a transfer and TAKES the source: on kN68SendOK the sender owes
 * close() and the caller must not touch `src` again. On anything else
 * nothing was taken and the caller still owns it - including the source
 * it just opened, which it must close itself.
 *
 * `file_type` and `creator` may be NULL or "" when unknown. `modified`
 * may be 0. `id` is the caller's correlation id; the host echoes it in
 * every reply. */
N68SendCode n68_puttx_begin(N68SendTx *tx, long id, const char *name,
                            const N68ByteSource *src, int macbinary,
                            const char *file_type, const char *creator,
                            unsigned long modified);

/* file.offer, ready for a control frame. Returns the byte count written
 * (NUL-terminated), or 0 if it did not fit. */
long n68_puttx_build_offer(const N68SendTx *tx, char *buf, long cap);

/* The host said file.accept. `transfer` is the bulk correlation id the
 * caller allocated. Returns 1 if this sender was waiting for exactly
 * this accept, 0 if it was not - a stale accept for a transfer that has
 * already ended is not an error, it is a message that arrived late, and
 * acting on it would start a transfer nobody asked for. */
int n68_puttx_accepted(N68SendTx *tx, long id, unsigned short transfer);

/* file.begin, ready for a control frame. Same return convention as
 * n68_puttx_build_offer. */
long n68_puttx_build_begin(const N68SendTx *tx, char *buf, long cap);

/* Builds the NEXT bulk frame - header and payload together as one
 * contiguous run, because the wire rule is that a frame is written as a
 * single send and wire68.c's control queue keeps the same promise.
 *
 * `cap` must be at least kN68SendFrameCap. Returns the total bytes
 * written (always > NOW68K_FRAME_HEADER_BYTES, or exactly that for the
 * empty-payload END frame of a zero-length source), or 0 when there is
 * no frame to build - either because the stream is finished or because
 * something failed, which *why distinguishes.
 *
 * On a failure the transfer is already over and the source already
 * closed; the caller's job is to report it, not to clean up. That is
 * n68_putrx_data()'s convention, deliberately.
 *
 * `total` IS THE AUTHORITY on where the stream ends, not the source's
 * *done flag. The receiver was told that number twice before a byte
 * moved and has sized its staging from it, so a source that disagrees
 * with its own declared length is a defect to name (kN68SendShort /
 * kN68SendLong), not a length to renegotiate. */
long n68_puttx_next_frame(N68SendTx *tx, unsigned char *buf, long cap,
                          N68SendCode *why);

/* 1 once every byte has been framed and the caller should send file.end. */
int n68_puttx_all_sent(const N68SendTx *tx);

/* file.end, ready for a control frame. `ok` false ends a transfer the
 * sender abandoned. Moves the sender to kN68SendEnded and closes the
 * source: the bytes are all framed by now, and holding a fork open
 * across the host's write of a multi-megabyte file is a fork held open
 * for no reason.
 *
 * The crc32 goes out only when ok - a checksum over a partial stream is
 * a number that can only mislead. */
long n68_puttx_build_end(N68SendTx *tx, char *buf, long cap, int ok,
                         long send_ms);

/* The host's file.done closes it out. `ok` is that message's, `code` its
 * own word or NULL. After this the sender is idle and the outcome is in
 * the last_* fields. */
void n68_puttx_done(N68SendTx *tx, long id, int ok, const char *code);

/* Abandons whatever is in flight, closes the source, and records the
 * outcome. For a refusal, a dropped connection, a quit, or a person
 * changing their mind. Safe when nothing is active. */
void n68_puttx_cancel(N68SendTx *tx, N68SendCode why);

/* The contract's own word for a code, for reporting.
 *
 * The same CONTRACT GAP n68_putrx.h records applies from this side:
 * FileRefuse.code and FileDone.code have no value meaning "the sender
 * gave up on its own source", so kN68SendSourceFailed, kN68SendShort and
 * kN68SendLong all render as "io-error" and lean on the human-readable
 * reason. Recorded in docs/open-issues.md rather than papered over. */
const char *n68_puttx_code_word(N68SendCode code);

/* A short sentence for the same code, for a `reason` field or a console
 * line. Always short enough to sit inside a control frame beside the
 * rest of the message. */
const char *n68_puttx_code_reason(N68SendCode code);

#endif /* NOW68K_PUTTX_H */
