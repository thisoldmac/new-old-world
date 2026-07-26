/*
 * n68_puttx.c - the guest->host send state machine. See n68_puttx.h for
 * the wire-sharing rule and for what the byte source promises.
 *
 * No Toolbox call, no allocation, no wire call: everything here runs
 * unchanged under the host cc for guest68k/tests/test_puttx.c, which is
 * the only way the 4 MB path gets exercised more than once a day.
 */

#include "n68_puttx.h"

#include "n68_cmdresult.h"   /* now68k_json_append_escaped */
#include "n68_crc32.h"
#include "numfmt.h"

#include <string.h>

/* ---- small helpers ------------------------------------------------------- */

static void copy_bounded(char *dst, long cap, const char *src)
{
    long n = 0;

    if (cap <= 0) {
        return;
    }
    if (src != NULL) {
        while (src[n] != '\0' && n < cap - 1) {
            dst[n] = src[n];
            ++n;
        }
    }
    dst[n] = '\0';
}

/* Closes the source if one is still owed a close, and never twice.
 * Promise (5) in n68_bytesrc.h is the whole reason this is one function
 * rather than a call at each ending: there are six endings. */
static void release_source(N68SendTx *tx)
{
    if (tx->src_open) {
        tx->src_open = 0;
        tx->src.ops->close(tx->src.ctx);
    }
}

/* Records how a transfer ended, for whoever asks afterwards. */
static void remember(N68SendTx *tx, int ok, N68SendCode why)
{
    tx->had_one = 1;
    tx->last_ok = ok;
    tx->last_bytes = tx->sent;
    memcpy(tx->last_name, tx->name, sizeof tx->last_name);
    copy_bounded(tx->last_code, (long)sizeof tx->last_code,
                 ok ? "" : n68_puttx_code_word(why));
}

/* ---- lifecycle ----------------------------------------------------------- */

void n68_puttx_init(N68SendTx *tx)
{
    memset(tx, 0, sizeof *tx);
    tx->state = kN68SendIdle;
}

int n68_puttx_name_ok(const char *name)
{
    long n = 0;

    if (name == NULL || name[0] == '\0') {
        return 0;
    }
    for (; name[n] != '\0'; ++n) {
        unsigned char c = (unsigned char)name[n];

        /* A colon is HFS's own separator, so a leaf carrying one is a
           path pretending to be a name - the same reason
           n68_putrx_path_ok refuses an empty segment. A control byte
           would corrupt the control frame itself, not merely the JSON,
           since the frame is text and newline-sensitive. */
        if (c == ':' || c < 0x20 || c == 0x7F) {
            return 0;
        }
        if (n >= 31) {
            return 0;   /* HFS stops at 31; the contract says so too */
        }
    }
    return 1;
}

N68SendCode n68_puttx_begin(N68SendTx *tx, long id, const char *name,
                            const N68ByteSource *src, int macbinary,
                            const char *file_type, const char *creator,
                            unsigned long modified)
{
    if (tx->state != kN68SendIdle) {
        return kN68SendBusy;
    }
    if (src == NULL || src->ops == NULL || src->total < 0) {
        return kN68SendNoSource;
    }
    if (!n68_puttx_name_ok(name)) {
        return kN68SendBadName;
    }

    /* Deliberately not memset: had_one and the last_* fields survive a
       new transfer, because "how did the last one go" outlives the
       transfer it describes. */
    tx->id = id;
    tx->transfer = 0;
    copy_bounded(tx->name, (long)sizeof tx->name, name);
    tx->total = src->total;
    tx->macbinary = macbinary ? 1 : 0;
    copy_bounded(tx->file_type, (long)sizeof tx->file_type, file_type);
    copy_bounded(tx->creator, (long)sizeof tx->creator, creator);
    tx->modified = modified;

    tx->src = *src;
    tx->src_open = 1;      /* we own the close from here - promise (5) */
    tx->sent = 0;
    tx->crc = 0;
    tx->src_done = 0;
    tx->state = kN68SendOffered;
    return kN68SendOK;
}

/* ---- the control messages ------------------------------------------------ */

static const char *container_word(const N68SendTx *tx)
{
    return tx->macbinary ? "macbinary" : "data";
}

long n68_puttx_build_offer(const N68SendTx *tx, char *buf, long cap)
{
    long pos = 0;
    int ok;

    if (buf == NULL || cap <= 0) {
        return 0;
    }
    /* One byte of cap is the NUL, exactly as n68_cmdresult.c reserves
       one: the append helpers fill right up to what they are given. */
    --cap;

    ok = now68k_fmt_append_str(buf, cap, &pos,
                               "{\"type\":\"file.offer\",\"id\":")
         && now68k_fmt_append_long(buf, cap, &pos, tx->id)
         && now68k_fmt_append_str(buf, cap, &pos, ",\"name\":\"")
         && now68k_json_append_escaped(buf, cap, &pos, tx->name)
         /* `path` is REQUIRED and "" means the root of the receiver's
            share. The PowerPC guest learned this the expensive way:
            leaving it out cost a dropped connection, because the host
            could not decode the frame at all (guest/src/wire.c). */
         && now68k_fmt_append_str(buf, cap, &pos, "\",\"path\":\"\","
                                                  "\"container\":\"")
         && now68k_fmt_append_str(buf, cap, &pos, container_word(tx))
         && now68k_fmt_append_str(buf, cap, &pos, "\",\"bytes\":")
         && now68k_fmt_append_long(buf, cap, &pos, tx->total);

    if (ok && tx->file_type[0] != '\0') {
        ok = now68k_fmt_append_str(buf, cap, &pos, ",\"fileType\":\"")
             && now68k_json_append_escaped(buf, cap, &pos, tx->file_type)
             && now68k_fmt_append_str(buf, cap, &pos, "\"");
    }
    if (ok && tx->creator[0] != '\0') {
        ok = now68k_fmt_append_str(buf, cap, &pos, ",\"creator\":\"")
             && now68k_json_append_escaped(buf, cap, &pos, tx->creator)
             && now68k_fmt_append_str(buf, cap, &pos, "\"");
    }
    if (ok && tx->modified != 0) {
        ok = now68k_fmt_append_str(buf, cap, &pos, ",\"modified\":")
             && now68k_fmt_append_u32(buf, cap, &pos, tx->modified);
    }
    ok = ok && now68k_fmt_append_str(buf, cap, &pos, "}");

    if (!ok) {
        return 0;
    }
    buf[pos] = '\0';
    return pos;
}

int n68_puttx_accepted(N68SendTx *tx, long id, unsigned short transfer)
{
    /* A late accept for a transfer that has already ended is not an
       error; it is a message that arrived after the fact. Acting on it
       would start a transfer with no source behind it. */
    if (tx->state != kN68SendOffered || tx->id != id) {
        return 0;
    }
    tx->transfer = transfer;
    tx->state = kN68SendSending;
    return 1;
}

long n68_puttx_build_begin(const N68SendTx *tx, char *buf, long cap)
{
    long pos = 0;
    int ok;

    if (buf == NULL || cap <= 0) {
        return 0;
    }
    --cap;

    /* name and container are REQUIRED here as well as in the offer - the
       same lesson, the same cost if they are missing. */
    ok = now68k_fmt_append_str(buf, cap, &pos,
                               "{\"type\":\"file.begin\",\"id\":")
         && now68k_fmt_append_long(buf, cap, &pos, tx->id)
         && now68k_fmt_append_str(buf, cap, &pos, ",\"transfer\":")
         && now68k_fmt_append_long(buf, cap, &pos, (long)tx->transfer)
         && now68k_fmt_append_str(buf, cap, &pos, ",\"name\":\"")
         && now68k_json_append_escaped(buf, cap, &pos, tx->name)
         && now68k_fmt_append_str(buf, cap, &pos, "\",\"container\":\"")
         && now68k_fmt_append_str(buf, cap, &pos, container_word(tx))
         && now68k_fmt_append_str(buf, cap, &pos, "\",\"bytes\":")
         && now68k_fmt_append_long(buf, cap, &pos, tx->total)
         && now68k_fmt_append_str(buf, cap, &pos, "}");

    if (!ok) {
        return 0;
    }
    buf[pos] = '\0';
    return pos;
}

/* ---- the bulk stream ----------------------------------------------------- */

long n68_puttx_next_frame(N68SendTx *tx, unsigned char *buf, long cap,
                          N68SendCode *why)
{
    Now68kFrameHeader hdr;
    long want;
    long have = 0;
    int last;

    *why = kN68SendOK;

    if (tx->state != kN68SendSending || buf == NULL
        || cap < (long)kN68SendFrameCap) {
        return 0;
    }
    if (tx->sent >= tx->total) {
        return 0;       /* everything framed; the caller sends file.end */
    }

    want = tx->total - tx->sent;
    if (want > (long)kN68SendChunk) {
        want = (long)kN68SendChunk;
    }

    /* AS MANY FILLS AS IT TAKES, not one. The interface promises only
       promptness, never a full buffer (n68_bytesrc.h) - so a source that
       reads in its own small units is keeping its promise, and a sender
       that framed one fill per frame would turn a 4 MB file from ~1000
       frames into tens of thousands, each with its own 8-byte header and
       its own trip through MacTCP. The loop is bounded by the chunk, so
       it cannot become the long deaf stretch promise (2) exists to
       prevent. */
    while (have < want && !tx->src_done) {
        int done = 0;       /* 0 on entry, every time - the interface says so */
        long got = tx->src.ops->fill(tx->src.ctx,
                                     buf + NOW68K_FRAME_HEADER_BYTES + have,
                                     want - have, &done);

        if (got < 0) {
            *why = kN68SendSourceFailed;
            release_source(tx);
            tx->state = kN68SendIdle;
            remember(tx, 0, *why);
            return 0;
        }
        if (got > want - have) {
            /* The source wrote past the buffer it was given. Whatever it
               overran into is already damaged, so there is nothing here
               to salvage - but the transfer stops rather than framing a
               length the header would be lying about. */
            *why = kN68SendLong;
            release_source(tx);
            tx->state = kN68SendIdle;
            remember(tx, 0, *why);
            return 0;
        }
        have += got;
        if (done) {
            tx->src_done = 1;
        } else if (got == 0) {
            /* Legal but useless: nothing right now, and this sender has
               no way to wait for a source. Stop asking this pass. */
            break;
        }
    }

    /* `total` is the authority, not `done` - see the header. A source
       that finishes early has broken the number the receiver already
       sized its staging from, and continuing would hang the receiver
       waiting for bytes that will never come. */
    if (tx->src_done && tx->sent + have < tx->total) {
        *why = kN68SendShort;
        release_source(tx);
        tx->state = kN68SendIdle;
        remember(tx, 0, *why);
        return 0;
    }
    if (have == 0 && tx->total > 0) {
        return 0;   /* nothing to frame this pass; come back next one */
    }

    tx->crc = now68k_crc32(tx->crc, buf + NOW68K_FRAME_HEADER_BYTES, have);
    tx->sent += have;
    last = (tx->sent >= tx->total);

    hdr.channel = NOW68K_CHANNEL_BULK;
    hdr.flags = last ? NOW68K_FLAG_END : 0;
    hdr.transfer = tx->transfer;
    hdr.length = (unsigned long)have;
    now68k_frame_pack(&hdr, buf);

    return (long)NOW68K_FRAME_HEADER_BYTES + have;
}

int n68_puttx_all_sent(const N68SendTx *tx)
{
    return tx->state == kN68SendSending && tx->sent >= tx->total;
}

long n68_puttx_build_end(N68SendTx *tx, char *buf, long cap, int ok,
                         long send_ms)
{
    long pos = 0;
    int built;

    if (buf == NULL || cap <= 0) {
        return 0;
    }
    --cap;

    built = now68k_fmt_append_str(buf, cap, &pos,
                                  "{\"type\":\"file.end\",\"id\":")
            && now68k_fmt_append_long(buf, cap, &pos, tx->id)
            && now68k_fmt_append_str(buf, cap, &pos, ",\"transfer\":")
            && now68k_fmt_append_long(buf, cap, &pos, (long)tx->transfer)
            && now68k_fmt_append_str(buf, cap, &pos, ",\"ok\":")
            && now68k_fmt_append_str(buf, cap, &pos, ok ? "true" : "false");

    if (built && send_ms >= 0) {
        built = now68k_fmt_append_str(buf, cap, &pos, ",\"sendMs\":")
                && now68k_fmt_append_long(buf, cap, &pos, send_ms);
    }
    /* Only when ok. A checksum over a stream that stopped early is a
       number that can only mislead: it is arithmetically correct about
       bytes nobody wanted. */
    if (built && ok) {
        built = now68k_fmt_append_str(buf, cap, &pos, ",\"crc32\":")
                && now68k_fmt_append_u32(buf, cap, &pos, tx->crc);
    }
    built = built && now68k_fmt_append_str(buf, cap, &pos, "}");

    if (!built) {
        return 0;
    }
    buf[pos] = '\0';

    /* The bytes are all framed by the time this is sent, so the fork can
       go now rather than being held across the host's write of a
       multi-megabyte file. */
    release_source(tx);
    tx->state = kN68SendEnded;
    return pos;
}

void n68_puttx_done(N68SendTx *tx, long id, int ok, const char *code)
{
    if (tx->state != kN68SendEnded || tx->id != id) {
        return;
    }
    release_source(tx);   /* already closed by build_end; costs nothing */
    tx->had_one = 1;
    tx->last_ok = ok ? 1 : 0;
    tx->last_bytes = tx->sent;
    memcpy(tx->last_name, tx->name, sizeof tx->last_name);
    copy_bounded(tx->last_code, (long)sizeof tx->last_code,
                 ok ? "" : (code != NULL ? code : "io-error"));
    tx->state = kN68SendIdle;
}

void n68_puttx_cancel(N68SendTx *tx, N68SendCode why)
{
    if (tx->state == kN68SendIdle) {
        return;
    }
    release_source(tx);
    remember(tx, 0, why);
    tx->state = kN68SendIdle;
}

/* ---- rendering codes ----------------------------------------------------- */

const char *n68_puttx_code_word(N68SendCode code)
{
    switch (code) {
    case kN68SendOK:            return "";
    case kN68SendBusy:          return "busy";
    case kN68SendRefused:       return "refused";
    case kN68SendBadName:       return "bad-path";
    case kN68SendGone:          return "cancelled";
    /* The contract gap n68_puttx.h names: there is no code for "the
       sender's own source let it down", so these three land on io-error
       and the reason carries the truth. */
    case kN68SendNoSource:      return "io-error";
    case kN68SendSourceFailed:  return "io-error";
    case kN68SendShort:         return "io-error";
    case kN68SendLong:          return "io-error";
    default:                    return "io-error";
    }
}

const char *n68_puttx_code_reason(N68SendCode code)
{
    switch (code) {
    case kN68SendOK:            return "";
    case kN68SendBusy:          return "a transfer is already in flight";
    case kN68SendNoSource:      return "could not read that file";
    case kN68SendSourceFailed:  return "the read failed partway through";
    case kN68SendShort:         return "the file got shorter while sending";
    case kN68SendLong:          return "the file got longer while sending";
    case kN68SendBadName:       return "that name cannot go on the wire";
    case kN68SendRefused:       return "the host refused it";
    case kN68SendGone:          return "the connection went away";
    default:                    return "it did not finish";
    }
}
