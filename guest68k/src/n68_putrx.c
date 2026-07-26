/* n68_putrx.c - implementation of n68_putrx.h. No Toolbox call and no
 * allocation: every disk touch goes through the ops table. */

#include "n68_putrx.h"

#include "json_scan.h"
#include "n68_crc32.h"

#include <string.h>

/* Fails the transfer: discard whatever is staged, go inactive, and hand
 * the caller the code to report. Every failure path funnels here so that
 * "the partial is gone" is a property of the module rather than
 * something each branch has to remember - the PowerPC guest's put_abort
 * exists for the same reason. */
static N68PutCode fail(N68PutRx *rx, N68PutCode code)
{
    rx->ops->discard(rx->ctx);
    rx->active = 0;
    return code;
}

/* Empties the batch buffer into whichever fork it was filled for.
 *
 * The CRC is NOT accumulated here. It used to be - which was correct
 * while every arriving byte was also a written byte, and became wrong
 * the moment MacBinary arrived: the contract checksums "the WHOLE file's
 * wire bytes" (FileEnd.crc32), and a MacBinary envelope's header and
 * padding are wire bytes that are never written to either fork. A CRC
 * over the written bytes would disagree with the sender's on every
 * MacBinary transfer, reporting `corrupt` for files that arrived
 * perfectly. It is accumulated on arrival instead - see
 * n68_putrx_data - which is also what the PowerPC guest does, and its
 * comment gives the same reason. */
static N68PutCode flush(N68PutRx *rx)
{
    N68PutCode rc;

    if (rx->buf_len == 0) {
        return kN68PutOK;
    }
    rc = rx->ops->write(rx->ctx, rx->buf_fork, rx->buf, rx->buf_len);
    if (rc != kN68PutOK) {
        return rc;
    }
    rx->writes++;
    rx->buf_len = 0;
    return kN68PutOK;
}

/* Buffers `len` bytes for `fork`, flushing whenever the batch fills or
 * the fork changes. The fork change is the subtle one: the batch is a
 * single buffer shared by both forks, so carrying bytes across the
 * boundary would write the head of the resource fork onto the end of the
 * data fork. The PowerPC guest flushes at exactly the same point and for
 * exactly this reason. */
static N68PutCode stage(N68PutRx *rx, N68PutFork fork,
                        const unsigned char *p, long len)
{
    if (rx->buf_len > 0 && rx->buf_fork != fork) {
        N68PutCode rc = flush(rx);

        if (rc != kN68PutOK) {
            return rc;
        }
    }
    rx->buf_fork = fork;
    while (len > 0) {
        long room = rx->buf_cap - rx->buf_len;
        long take = (len < room) ? len : room;

        memcpy(rx->buf + rx->buf_len, p, (size_t)take);
        rx->buf_len += take;
        p += take;
        len -= take;
        if (rx->buf_len == rx->buf_cap) {
            N68PutCode rc = flush(rx);

            if (rc != kN68PutOK) {
                return rc;
            }
        }
    }
    return kN68PutOK;
}

/* CRC-16/XMODEM over the header's first 124 bytes, which is what
 * MacBinary II stores at offset 124. Nothing to do with the CRC-32 the
 * contract carries; this one only says whether the header is a header. */
static unsigned short macbinary_crc16(const unsigned char *bytes, long len)
{
    unsigned short crc = 0;
    long i;

    for (i = 0; i < len; ++i) {
        int bit;

        crc ^= (unsigned short)((unsigned short)bytes[i] << 8);
        for (bit = 0; bit < 8; ++bit) {
            crc = (crc & 0x8000) != 0
                ? (unsigned short)((unsigned short)(crc << 1) ^ 0x1021)
                : (unsigned short)(crc << 1);
        }
    }
    return crc;
}

static long be32(const unsigned char *p)
{
    return ((long)p[0] << 24) | ((long)p[1] << 16)
         | ((long)p[2] << 8) | (long)p[3];
}

/* Padding to the next 128-byte boundary. */
static long padded(long n)
{
    return (n + 127L) & ~127L;
}

/* Is the completed header a MacBinary header at all, and does it
 * describe a file that fits the stream the sender offered?
 *
 * Checked the moment the 128 bytes are in hand rather than at the end,
 * because everything after depends on the two lengths in it: a garbage
 * mb_data_len would otherwise be used to decide where the resource fork
 * starts, and the transfer would write megabytes into the wrong fork
 * before anything noticed. Mirrors valid_macbinary_receive in the
 * PowerPC guest (now/guest/src/fileshare.c) - the two guests are reached
 * by the same host and must refuse the same envelopes. */
static int header_is_macbinary(const N68PutRx *rx)
{
    long data_padded, rsrc_padded;

    /* The three bytes MacBinary reserves as zero, and the name length
       field, are the cheap structural check every implementation makes. */
    if (rx->header[0] != 0 || rx->header[74] != 0 || rx->header[82] != 0
        || rx->header[1] < 1 || rx->header[1] > 63) {
        return 0;
    }
    if (rx->mb_data_len < 0 || rx->mb_rsrc_len < 0) {
        return 0;
    }
    /* MacBinary II and III both stamp a version and a header CRC. A
       MacBinary I header has neither, so the CRC is checked only when
       the version says there is one to check. */
    if (rx->header[122] == 129 || rx->header[122] == 130) {
        unsigned short stored = (unsigned short)
            (((unsigned short)rx->header[124] << 8) | rx->header[125]);

        if (stored != macbinary_crc16(rx->header, 124)) {
            return 0;
        }
    }
    /* The envelope has to fit inside the size the sender offered. Both
       comparisons are written as subtractions from `expected` so that
       neither side can overflow on a header claiming a huge fork. */
    data_padded = padded(rx->mb_data_len);
    rsrc_padded = padded(rx->mb_rsrc_len);
    if (rx->offer.bytes < kN68MacBinaryHeader
        || data_padded > rx->offer.bytes - kN68MacBinaryHeader
        || rsrc_padded > rx->offer.bytes - kN68MacBinaryHeader - data_padded) {
        return 0;
    }
    return 1;
}

/* Routes one run of arriving bytes into the header, a fork, or the
 * padding between them. Any run may straddle any number of those
 * boundaries, including all of them, which is why this is a loop and not
 * a switch. */
static N68PutCode take_macbinary(N68PutRx *rx, const unsigned char *p,
                                 long len)
{
    while (len > 0) {
        long take;

        if (rx->header_have < kN68MacBinaryHeader) {
            take = kN68MacBinaryHeader - rx->header_have;
            if (take > len) {
                take = len;
            }
            memcpy(rx->header + rx->header_have, p, (size_t)take);
            rx->header_have += take;
            p += take;
            len -= take;
            if (rx->header_have == kN68MacBinaryHeader) {
                rx->mb_data_len = be32(rx->header + 83);
                rx->mb_rsrc_len = be32(rx->header + 87);
                if (!header_is_macbinary(rx)) {
                    return kN68PutCorrupt;
                }
                /* The header wins over the offer: it describes the file,
                   the offer describes the envelope around it. */
                rx->ops->set_info(rx->ctx,
                                  (unsigned long)be32(rx->header + 65),
                                  (unsigned long)be32(rx->header + 69),
                                  (unsigned long)be32(rx->header + 95));
            }
            continue;
        }

        if (rx->mb_data_done < rx->mb_data_len) {
            N68PutCode rc;

            take = rx->mb_data_len - rx->mb_data_done;
            if (take > len) {
                take = len;
            }
            rc = stage(rx, kN68ForkData, p, take);
            if (rc != kN68PutOK) {
                return rc;
            }
            rx->mb_data_done += take;
            p += take;
            len -= take;
            continue;
        }

        /* The padding after the data fork carries nothing; it is counted
           into mb_data_done so this branch closes. */
        if (rx->mb_data_done < padded(rx->mb_data_len)) {
            take = padded(rx->mb_data_len) - rx->mb_data_done;
            if (take > len) {
                take = len;
            }
            rx->mb_data_done += take;
            p += take;
            len -= take;
            continue;
        }

        if (rx->mb_rsrc_done < rx->mb_rsrc_len) {
            N68PutCode rc;

            take = rx->mb_rsrc_len - rx->mb_rsrc_done;
            if (take > len) {
                take = len;
            }
            rc = stage(rx, kN68ForkRsrc, p, take);
            if (rc != kN68PutOK) {
                return rc;
            }
            rx->mb_rsrc_done += take;
            p += take;
            len -= take;
            continue;
        }

        /* Trailing padding, and anything a packer appended past it. The
           bytes are still COUNTED (rx->received, and the CRC) - they are
           part of the stream the sender checksummed - they simply belong
           to no fork. */
        break;
    }
    return kN68PutOK;
}

void n68_putrx_init(N68PutRx *rx, unsigned char *buf, long buf_cap,
                    const N68PutFileOps *ops, void *ctx)
{
    memset(rx, 0, sizeof *rx);
    rx->buf = buf;
    rx->buf_cap = buf_cap;
    rx->ops = ops;
    rx->ctx = ctx;
}

int n68_putrx_parse_offer(const char *json, long len, N68PutOffer *out)
{
    char container[16];
    const char *v;
    long n;

    if (out == NULL || json == NULL || len <= 0) {
        return 0;
    }
    memset(out, 0, sizeof *out);
    /* Absent or true, per FileOffer.createParents. Set before the early
     * returns below so a rejected offer still has a coherent struct. */
    out->create_parents = 1;

    if (!now68k_json_find_int(json, (size_t)len, "id", &out->id)) {
        return 0;   /* nothing to address an answer to */
    }
    if (!now68k_json_find_string(json, (size_t)len, "name",
                                 out->name, (long)sizeof out->name)) {
        return 0;
    }
    if (out->name[0] == '\0') {
        return 0;
    }
    if (!now68k_json_find_int(json, (size_t)len, "bytes", &n) || n < 0) {
        return 0;
    }
    out->bytes = n;

    /* Everything below is optional in the schema or has a stated
     * default, so a missing one is an ordinary offer rather than a
     * malformed one. */
    (void)now68k_json_find_string(json, (size_t)len, "path",
                                  out->path, (long)sizeof out->path);
    /* Absent means `data` (the contract's default), which is known. */
    out->container_known = 1;
    if (now68k_json_find_string(json, (size_t)len, "container",
                                container, (long)sizeof container)) {
        out->macbinary = (strcmp(container, "macbinary") == 0);
        out->container_known = out->macbinary
            || strcmp(container, "data") == 0;
    }
    (void)now68k_json_find_string(json, (size_t)len, "fileType",
                                  out->file_type,
                                  (long)sizeof out->file_type);
    (void)now68k_json_find_string(json, (size_t)len, "creator",
                                  out->creator, (long)sizeof out->creator);
    (void)now68k_json_find_int(json, (size_t)len, "modified",
                               &out->modified);

    /* Booleans: json_scan.h has no bool reader, and the two callers here
     * need only "is it literally true". Reading the first character of
     * the value is what the PowerPC guest's serve_file_offer does
     * (wire.c), and it is enough - the contract's booleans are JSON
     * literals, so anything but 't' is false either way. */
    v = now68k_json_value(json, (size_t)len, "overwrite");
    out->overwrite = (v != NULL && v < json + len && *v == 't');
    v = now68k_json_value(json, (size_t)len, "createParents");
    if (v != NULL && v < json + len) {
        out->create_parents = (*v == 't');
    }
    return 1;
}

int n68_putrx_path_ok(const char *rel)
{
    long seg = 0;

    if (rel == NULL) {
        return 0;
    }
    if (rel[0] == ':') {
        return 0;             /* leading colon = "start at the parent" */
    }
    for (; *rel != '\0'; ++rel) {
        if (*rel == ':') {
            if (seg == 0) {
                return 0;     /* empty segment = traversal */
            }
            seg = 0;
        } else if (++seg > 31) {
            return 0;         /* longer than HFS can name */
        }
    }
    return 1;
}

N68PutCode n68_putrx_offer(N68PutRx *rx, const N68PutOffer *offer)
{
    long free_bytes;
    N68PutCode rc;

    if (!offer->container_known) {
        return kN68PutUnsupported;
    }
    if (rx->active) {
        /* One transfer at a time. The shared lane is one transfer wide,
         * and refusing is honest where queueing would mean holding a
         * second offer open against a 384 KB partition. */
        return kN68PutBusy;
    }
    /* HFS stops at 31 characters. The sender is supposed to have
     * sanitized already (FileOffer.name), so this is a check on the
     * SENDER rather than on the human - and a name that arrives longer
     * means the two sides disagree about what a legal name is, which is
     * worth a refusal rather than a silent truncation onto a file
     * nobody asked for. */
    if (strlen(offer->name) > 31 || strchr(offer->name, ':') != NULL) {
        return kN68PutBadPath;
    }
    /* Refused BEFORE the disk is asked anything, so a path that walks
     * out of the share is never resolved even far enough to learn
     * whether it exists. */
    if (!n68_putrx_path_ok(offer->path)) {
        return kN68PutBadPath;
    }

    /* Room first, creation second. A refusal costs the sender one
     * message; a failure at 3.9 MB of 4 MB costs it the transfer, and
     * costs the disk a partial it has to clean up. */
    free_bytes = rx->ops->free_bytes(rx->ctx, offer);
    if (free_bytes >= 0 && free_bytes < offer->bytes) {
        return kN68PutTooBig;
    }

    rc = rx->ops->create(rx->ctx, offer);
    if (rc != kN68PutOK) {
        return rc;
    }

    /* Only now does this become a live transfer. Zeroing here rather
     * than in init is what makes a second transfer on one connection
     * start clean without the caller having to re-init. */
    rx->offer = *offer;
    rx->received = 0;
    rx->reported = 0;
    rx->crc = 0;
    rx->buf_len = 0;
    rx->buf_fork = kN68ForkData;
    rx->chunks = 0;
    rx->writes = 0;
    rx->header_have = 0;
    rx->mb_data_len = 0;
    rx->mb_rsrc_len = 0;
    rx->mb_data_done = 0;
    rx->mb_rsrc_done = 0;
    rx->active = 1;
    return kN68PutOK;
}

N68PutCode n68_putrx_data(N68PutRx *rx, const void *bytes, long len)
{
    const unsigned char *p = (const unsigned char *)bytes;

    if (!rx->active) {
        /* Bulk with nothing expecting it. Not an error: the reader stays
         * in frame sync whatever happens, and a frame in flight when a
         * transfer was abandoned has to land somewhere. */
        return kN68PutOK;
    }
    if (len <= 0) {
        return kN68PutOK;
    }
    rx->chunks++;

    /* More bytes than were offered. The sender named an exact size
     * (FileOffer.bytes) and the stream must be that size, so this is the
     * two sides disagreeing about the file - which cannot be recovered
     * by writing the surplus somewhere, and must not be recovered by
     * dropping it silently. */
    if (rx->received + len > rx->offer.bytes) {
        return fail(rx, kN68PutCorrupt);
    }

    /* Over the bytes AS THEY ARRIVE, before any container is decoded.
     * The contract checksums "the WHOLE file's wire bytes"
     * (FileEnd.crc32), and for a MacBinary transfer the header and the
     * padding are wire bytes that reach neither fork - so a CRC taken
     * where the writes happen would disagree with the sender's on every
     * MacBinary file and report `corrupt` for a perfect one. Doing it
     * here also means one pass and no re-reads, and it covers every
     * container the same way. */
    rx->crc = now68k_crc32(rx->crc, p, len);
    rx->received += len;

    {
        N68PutCode rc = rx->offer.macbinary
            ? take_macbinary(rx, p, len)
            : stage(rx, kN68ForkData, p, len);

        if (rc != kN68PutOK) {
            return fail(rx, rc);
        }
    }
    return kN68PutOK;
}

int n68_putrx_due_report(const N68PutRx *rx)
{
    if (!rx->active || rx->received == 0) {
        return 0;
    }
    /* The first report goes out as soon as anything lands. That is what
     * tells the host this guest acks at all, so it can start clocking
     * its sender immediately instead of running a whole step ahead on
     * its own send counter - which on this link is a lie by minutes. */
    if (rx->reported == 0) {
        return 1;
    }
    return (rx->received - rx->reported) >= kN68PutProgressStep;
}

void n68_putrx_noted_report(N68PutRx *rx)
{
    rx->reported = rx->received;
}

N68PutCode n68_putrx_end(N68PutRx *rx, int sender_ok,
                         int has_crc, unsigned long crc)
{
    N68PutCode rc;

    if (!rx->active) {
        return kN68PutOK;   /* nothing in flight; nothing to close */
    }
    if (!sender_ok) {
        return fail(rx, kN68PutCancelled);
    }

    rc = flush(rx);
    if (rc != kN68PutOK) {
        return fail(rx, rc);
    }

    /* A short stream. file.end ok:true says the sender finished, so a
     * count below the offered size means bytes were lost rather than
     * abandoned, and the file on disk is a truncation of the real one -
     * which is exactly the thing the staging name exists to keep a human
     * from double-clicking. */
    if (rx->received != rx->offer.bytes) {
        return fail(rx, kN68PutCorrupt);
    }

    /* DEFENSIVE, not load-bearing, and worth saying so rather than
     * letting it read as the check that catches a truncated envelope.
     *
     * It cannot currently fire: header_is_macbinary already refuses any
     * header whose forks do not fit the offered size, and the byte count
     * above already refuses a stream that did not deliver that size - so
     * by the time control reaches here the forks are complete by
     * arithmetic. It stays because both of those are conditions on
     * OTHER numbers, and a future change to either (a container that
     * allows trailing data, a resumed transfer) would make this the only
     * thing standing between a half-written resource fork and a file the
     * Finder will happily launch. A test cannot reach it; that is why
     * this comment exists instead of a claim in the test file. */
    if (rx->offer.macbinary
        && (rx->header_have != kN68MacBinaryHeader
            || rx->mb_data_done < padded(rx->mb_data_len)
            || rx->mb_rsrc_done != rx->mb_rsrc_len)) {
        return fail(rx, kN68PutCorrupt);
    }

    /* The one thing that can prove the bytes are the bytes. An ABSENT
     * crc32 is "unchecked", never "correct" (contract, FileEnd.crc32),
     * so an older host's transfer still completes - it just completes
     * without this proof. */
    if (has_crc && crc != rx->crc) {
        /* Discarded, not kept: bytes that failed their own checksum are
         * not a retry candidate, they are garbage. */
        return fail(rx, kN68PutCorrupt);
    }

    rc = rx->ops->finish(rx->ctx);
    if (rc != kN68PutOK) {
        return fail(rx, rc);
    }
    rx->active = 0;
    return kN68PutOK;
}

void n68_putrx_cancel(N68PutRx *rx)
{
    if (rx->active) {
        (void)fail(rx, kN68PutCancelled);
    }
}

const char *n68_putrx_code_word(N68PutCode code)
{
    switch (code) {
    case kN68PutOK:        return "ok";
    case kN68PutBusy:      return "busy";
    case kN68PutExists:    return "exists";
    case kN68PutBadPath:   return "bad-path";
    case kN68PutTooBig:    return "too-big";
    case kN68PutCancelled: return "cancelled";
    case kN68PutCorrupt:   return "corrupt";
    case kN68PutIOError:   return "io-error";
    /* See n68_putrx.h: the contract has no code for "not serviceable",
     * so this borrows io-error and leans on `reason`. */
    case kN68PutUnsupported: return "io-error";
    }
    return "io-error";
}

const char *n68_putrx_code_reason(N68PutCode code)
{
    switch (code) {
    case kN68PutOK:        return "";
    case kN68PutBusy:      return "a transfer is already in flight";
    case kN68PutExists:    return "a file of that name is already there";
    case kN68PutBadPath:   return "that name or folder is not usable";
    case kN68PutTooBig:    return "not enough room on that disk";
    case kN68PutCancelled: return "the sender stopped";
    case kN68PutCorrupt:   return "the bytes did not check out";
    case kN68PutIOError:   return "could not write the file";
    case kN68PutUnsupported:
        return "that container is not one this guest knows";
    }
    return "could not write the file";
}
