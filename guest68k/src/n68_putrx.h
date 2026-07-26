#ifndef NOW68K_PUTRX_H
#define NOW68K_PUTRX_H

/*
 * Receiving a host->guest file push: the decisions, with no Toolbox in
 * them.
 *
 * The contract's shape (hostPutsFiles, contract/asyncapi.yaml) is
 * file.offer -> file.accept/file.refuse -> file.begin -> bulk frames ->
 * file.end -> file.done. This module owns everything in that sequence
 * that is a JUDGEMENT - is there room, does it fit, has the whole stream
 * arrived, does the checksum agree - and nothing that is a File Manager
 * call. The File Manager half is n68_putfile.h, reached through the ops
 * table below, exactly the seam n68_reader.h uses for the transport.
 *
 * That split is not tidiness. A 4 MB transfer is the thing this code has
 * to get right and the thing that is most expensive to try: it needs a
 * Macintosh, a host, a link, and several minutes, and when it goes wrong
 * the evidence is a file on a disk in another room. Behind these
 * callbacks the whole sequence runs under the host cc in milliseconds,
 * including the splits a real MacTCP produces and the failures a real
 * disk produces, which is how guest68k/tests/test_putrx.c can exercise a
 * 4 MB stream at all.
 *
 * ---- Never in memory ---------------------------------------------------
 *
 * Bytes go to disk as they arrive. The application partition is 384 KB
 * (guest68k.r) on a 4 MB machine, so there is no version of "stage it in
 * RAM and write it at the end" that works for a file anyone would send.
 * The only buffer here is a caller-owned write batch, and its job is to
 * turn one File Manager trap per arriving run of bytes into one per
 * batch - MacTCP hands over whatever it happens to hold, often under a
 * kilobyte, and a trap per those is a trap per those too many.
 *
 * ---- MacBinary is decoded as it arrives -------------------------------
 *
 * A `macbinary` offer carries one envelope holding both forks: a
 * 128-byte header, the data fork padded up to a multiple of 128, then
 * the resource fork padded the same way. It is decoded IN FLIGHT, for
 * the same reason nothing else is staged - an application worth sending
 * is far larger than this partition - so the header may itself arrive
 * split across three MacTCP reads and every section boundary can land
 * mid-run.
 *
 * The header WINS on type, creator and date. The offer describes the
 * envelope; the header describes the file inside it, and a MacBinary
 * stream that disagreed with its own offer would otherwise land with the
 * envelope's identity and be un-openable.
 *
 * ---- Bytes land under a temporary name --------------------------------
 *
 * n68_putfile.h creates the staging file; this module never lets it take
 * its final name until the last byte is written and, when the sender
 * offered one, the checksum agrees. A truncated file that appears under
 * the real name is something a human double-clicks.
 *
 * ---- The progress step is FLOW CONTROL, not a progress bar -------------
 *
 * The host clocks its sender on file.progress and parks once it is
 * `outboundWindowBytes` ahead of the last report it received
 * (GuestListener.swift; docs/large-transfers.md is the whole story).
 * That window is three 8 KB frames. A receiver that reports less often
 * than the host's frame size does not merely draw a coarse bar - it
 * DEADLOCKS the sender, which parks waiting for a report that needs
 * bytes it has decided not to send. kN68PutProgressStep below is 8192
 * for that reason and no other, and it matches the PowerPC guest's
 * kPutProgressStep (wire.c) because that pairing is the geometry
 * measured at ~340 KB/s on this link rather than a number chosen for
 * being small.
 */

#include <stddef.h>

/* One report per host frame. See the header comment: this is the
 * sender's acknowledgement granularity, and the sender's in-flight bound
 * cannot be tighter than it. */
#define kN68PutProgressStep 8192

/* Longest destination leaf this guest will accept. HFS stops at 31
 * characters and the contract says the sender has already sanitized to
 * that ("<= 31 characters, no colons, MacRoman-encodable", FileOffer);
 * the extra room is so an over-long name is DETECTED and refused rather
 * than silently truncated onto a file the sender did not name. */
#define kN68PutNameCap 64

/* Destination folder, relative to the share root. Sized to match the
 * PowerPC guest's g_put.path so the two guests refuse the same paths. */
#define kN68PutPathCap 224

/* Why an offer was refused, or a transfer failed.
 *
 * These are this module's vocabulary; n68_putrx_code_word() renders them
 * as the contract's own enum values. The mapping is NOT one-to-one and
 * the place where it is not is documented there - see the note on
 * kN68PutUnsupported, which is a real gap in the contract rather than a
 * shortcut taken here. */
typedef enum {
    kN68PutOK = 0,
    kN68PutBusy,          /* a transfer is already in flight */
    kN68PutExists,        /* a file of that name is there, overwrite false */
    kN68PutBadPath,       /* the name or folder is not usable */
    kN68PutTooBig,        /* not enough room on the volume */
    kN68PutIOError,       /* the File Manager refused */
    kN68PutCancelled,     /* the sender stopped */
    kN68PutCorrupt,       /* the stream did not check out */
    kN68PutUnsupported    /* this guest cannot receive that container */
} N68PutCode;

/* Which fork a run of decoded bytes belongs to.
 *
 * A `data` container only ever names the data fork. A MacBinary
 * envelope carries both, one after the other, which is the whole reason
 * this parameter exists - and the reason the batch buffer has to be
 * flushed at the boundary between them rather than carried across it. */
typedef enum {
    kN68ForkData = 0,
    kN68ForkRsrc = 1
} N68PutFork;

/* Fixed by the format: a MacBinary header is 128 bytes and every section
 * is padded up to a multiple of 128. */
#define kN68MacBinaryHeader 128

/* What one file.offer asked for. */
typedef struct {
    long id;
    long bytes;                    /* exact size of the stream to follow */
    char name[kN68PutNameCap];     /* leaf name as it should land */
    char path[kN68PutPathCap];     /* destination FOLDER; "" is the root */
    int  macbinary;                /* container == "macbinary" */
    /* 0 when the offer named a container this guest does not know.
       NOT the same as "data": an unrecognized container written out as
       if it were a raw data fork produces a file that is the wrong
       length and the wrong shape, and blames the disk. The two the
       contract declares are `data` and `macbinary`; anything else is a
       future contract revision this build predates, and the honest
       answer to one is a refusal. */
    int  container_known;
    char file_type[8];             /* four chars, or "" */
    char creator[8];
    long modified;
    int  overwrite;
    int  create_parents;           /* absent or true per the schema */
} N68PutOffer;

/* 1 if `rel` is a destination folder this guest will resolve: colon
 * separated segments, each 1..31 characters, relative to the share root.
 * "" is the root itself and is fine.
 *
 * A LEADING OR DOUBLED COLON IS THE WHOLE POINT. On HFS an empty path
 * segment means "parent", so ":Lab" and "Lab::Secrets" are traversal out
 * of the share, and a share that can be escaped upward is not a share.
 * This is the same rule the PowerPC guest applies in rel_path_ok
 * (now/guest/src/fileshare.c) and it is stated in both places because
 * both guests are reached by the same host over the same verb - a guest
 * that resolved one of these would be the one that leaked.
 *
 * Published rather than static so guest68k/tests/test_putrx.c can walk
 * the traversal cases directly: this is the check that must not be
 * quietly relaxed, and a test that could only reach it through a File
 * Manager call could not run here at all. */
int n68_putrx_path_ok(const char *rel);

/* Everything this module needs from a disk. All of them are required;
 * like n68_reader.h's ops table, nothing is tested for NULL before being
 * called - a half-wired receiver that silently drops half its writes is
 * worse than the crash that names the missing one. `ctx` is the
 * caller's, passed back untouched. */
typedef struct N68PutFileOps {
    /* Free bytes on the volume the offer would land on, or -1 when the
       volume cannot say. Asked BEFORE anything is created, because a
       refusal costs the sender a message and a failure halfway costs it
       a transfer. */
    long (*free_bytes)(void *ctx, const N68PutOffer *offer);

    /* Create and open the staging file. kN68PutOK, or a code naming the
       refusal - and on anything but OK, nothing was left behind. */
    N68PutCode (*create)(void *ctx, const N68PutOffer *offer);

    /* Append `len` bytes to one of the staging file's two forks.
       kN68ForkRsrc is only ever asked for by a MacBinary transfer, and
       only after the data fork is complete - so an implementation may
       open the resource fork lazily on the first such call. */
    N68PutCode (*write)(void *ctx, N68PutFork fork,
                        const void *bytes, long len);


    /* Type, creator and modification date, once they are known.
       For a `data` container that is at create() time, from the offer.
       For MacBinary it is when the 128-byte header has been read, and
       the header WINS: the offer describes the envelope, the header
       describes the file inside it, and they are allowed to differ.
       Any of the three may be 0, meaning "the sender did not say". */
    void (*set_info)(void *ctx, unsigned long file_type,
                     unsigned long creator, unsigned long modified);

    /* Close the fork, stamp type/creator/modified, and rename the
       staging file to its final name. Only ever called once the stream
       is complete and checked. */
    N68PutCode (*finish)(void *ctx);

    /* Close and delete the staging file. Returns nothing on purpose:
       there is nothing useful to do about a failed cleanup, and
       reporting it would replace the real error with a worse one. */
    void (*discard)(void *ctx);
} N68PutFileOps;

typedef struct {
    int active;
    N68PutOffer offer;

    long received;          /* stream bytes accounted for so far */
    long reported;          /* `received` at the last file.progress */
    unsigned long crc;      /* running CRC-32 of the whole stream */

    /* Caller-owned write batch. Kept out of this struct so the receiver
       itself stays small enough to sit beside wire68.c's other file-scope
       state, and so a test can drive a deliberately tiny one. */
    unsigned char *buf;
    long buf_cap;
    long buf_len;
    N68PutFork buf_fork;    /* which fork the buffered bytes belong to */

    /* ---- MacBinary decode, all zero for a `data` container ----------
       The envelope is decoded as it arrives rather than parsed from a
       staged copy, because there is nothing to stage it in: an
       application big enough to be worth sending is far larger than
       this whole partition. */
    unsigned char header[kN68MacBinaryHeader];
    long header_have;
    long mb_data_len, mb_rsrc_len;
    long mb_data_done;      /* data fork bytes AND their padding */
    long mb_rsrc_done;

    /* Counters, for the console's own face on this capability. Timing
       where the work happens beats inferring it from the far end of a
       wire (the PowerPC guest's FileReceiveStats exists for the same
       reason). */
    long chunks;            /* calls into n68_putrx_data */
    long writes;            /* calls into ops->write */

    const N68PutFileOps *ops;
    void *ctx;
} N68PutRx;

/* Wires a receiver to its batch buffer and ops. buf_cap must be >= 1;
 * kN68PutProgressStep is the size that makes one write per host frame. */
void n68_putrx_init(N68PutRx *rx, unsigned char *buf, long buf_cap,
                    const N68PutFileOps *ops, void *ctx);

/* Reads one file.offer control payload into `out`, which is zeroed
 * first. `json` need not be NUL-terminated; `len` bounds it, the same
 * contract json_scan.h takes and for the same reason.
 *
 * Returns 1 when the payload carried the fields an offer cannot be
 * answered without (an id, a name, and a byte count that is not
 * negative), 0 when it did not - and 0 means "this is not a usable
 * offer", not "refuse it": a caller with no id has nothing to address a
 * refusal to. */
int n68_putrx_parse_offer(const char *json, long len, N68PutOffer *out);

/* Answers an offer. kN68PutOK means accepted, the staging file is open,
 * and the caller should send file.accept; anything else is a refusal and
 * nothing was created or left behind.
 *
 * This guest never reports `have`: it does not implement resume, and the
 * contract's own reading of an absent `have` is "start from the
 * beginning" (FileAccept), so an older-and-simpler receiver is a
 * contract-legal receiver rather than a broken one. */
N68PutCode n68_putrx_offer(N68PutRx *rx, const N68PutOffer *offer);

/* Takes one run of bulk bytes off the wire. Any length, including runs
 * that straddle the batch boundary or exceed it outright.
 *
 * On anything but kN68PutOK the transfer is already over and the staging
 * file already discarded - the caller's job is to report it, not to
 * clean up. */
N68PutCode n68_putrx_data(N68PutRx *rx, const void *bytes, long len);

/* 1 when enough has landed since the last report that the sender's
 * window needs feeding. The first bytes of a transfer always report:
 * that is what tells the host this guest reports at all, so it can stop
 * trusting its own send counter immediately rather than after the first
 * step's worth. */
int n68_putrx_due_report(const N68PutRx *rx);

/* Records that a file.progress carrying rx->received has been sent. */
void n68_putrx_noted_report(N68PutRx *rx);

/* Closes the transfer on the sender's file.end.
 *
 * sender_ok is that message's `ok`; false is a cancellation and the
 * partial is discarded. has_crc/crc carry its optional checksum - an
 * ABSENT one means UNCHECKED, never correct (contract, FileEnd.crc32),
 * and a mismatch discards the bytes rather than keeping them.
 *
 * kN68PutOK means the file is written, stamped and named, and the caller
 * should send file.done ok:true. */
N68PutCode n68_putrx_end(N68PutRx *rx, int sender_ok,
                         int has_crc, unsigned long crc);

/* Abandons whatever is in flight and discards the partial. For a dropped
 * connection, a quit, or any other end that is not a file.end. Safe when
 * nothing is active. */
void n68_putrx_cancel(N68PutRx *rx);

/* The contract's own word for a code, for file.refuse.code and
 * file.done.code.
 *
 * CONTRACT GAP, stated here once rather than at each call site:
 * FileRefuse.code and FileDone.code have no value meaning "this receiver
 * cannot handle that", so kN68PutUnsupported renders as "io-error" and
 * relies on the human-readable `reason` to say what actually happened.
 * That is a lie of category - nothing failed, the request was never
 * serviceable - and the honest fix is an additive enum value in the
 * contract. Recorded in docs/open-issues.md rather than papered over. */
const char *n68_putrx_code_word(N68PutCode code);

/* A sentence for the same code, for the `reason` field. Always short
 * enough to sit inside a control frame beside the rest of the message. */
const char *n68_putrx_code_reason(N68PutCode code);

#endif /* NOW68K_PUTRX_H */
