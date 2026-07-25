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

/* Empties the batch buffer to disk. The CRC is accumulated HERE rather
 * than as bytes arrive, so it covers exactly the bytes that were handed
 * to the disk, in the order they were handed over - a checksum computed
 * over a different set of bytes than the file contains is worse than no
 * checksum, because it reports success. */
static N68PutCode flush(N68PutRx *rx)
{
    N68PutCode rc;

    if (rx->buf_len == 0) {
        return kN68PutOK;
    }
    rc = rx->ops->write(rx->ctx, rx->buf, rx->buf_len);
    if (rc != kN68PutOK) {
        return rc;
    }
    rx->writes++;
    rx->crc = now68k_crc32(rx->crc, rx->buf, rx->buf_len);
    rx->buf_len = 0;
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
    if (now68k_json_find_string(json, (size_t)len, "container",
                                container, (long)sizeof container)) {
        out->macbinary = (strcmp(container, "macbinary") == 0);
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

    if (rx->active) {
        /* One transfer at a time. The shared lane is one transfer wide,
         * and refusing is honest where queueing would mean holding a
         * second offer open against a 384 KB partition. */
        return kN68PutBusy;
    }
    /* MacBinary is a container this guest does not decode yet. Refusing
     * is the whole of the handling: an unsupported container that gets
     * written out verbatim produces a file that looks right, opens
     * wrong, and blames the disk. */
    if (offer->macbinary) {
        return kN68PutUnsupported;
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
    rx->chunks = 0;
    rx->writes = 0;
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

    while (len > 0) {
        long room = rx->buf_cap - rx->buf_len;
        long take = (len < room) ? len : room;

        memcpy(rx->buf + rx->buf_len, p, (size_t)take);
        rx->buf_len += take;
        p += take;
        len -= take;
        rx->received += take;

        if (rx->buf_len == rx->buf_cap) {
            N68PutCode rc = flush(rx);

            if (rc != kN68PutOK) {
                return fail(rx, rc);
            }
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
        return "this guest receives data-fork files only, not MacBinary";
    }
    return "could not write the file";
}
