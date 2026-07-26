/*
 * test_putrx.c - native test for n68_putrx.c, the host->guest receive
 * state machine.
 *
 *   cc -Wall -Wextra -Werror -I ../src test_putrx.c ../src/n68_putrx.c \
 *      ../src/n68_crc32.c ../src/json_scan.c -o /tmp/t
 *
 * (scripts/test-native runs this; the line above is for editing one file.)
 *
 * A 4 MB transfer is the thing this code exists to get right and the
 * thing that is most expensive to try: it needs a Macintosh, a host, a
 * link, several minutes, and when it goes wrong the evidence is a file
 * on a disk in another room. Behind n68_putrx.h's ops table the whole
 * sequence runs here in milliseconds, so this file does the runs nobody
 * would do by hand - every arrival split, every failure point, and the
 * 4 MB baseline itself.
 *
 * THE ONE THAT IS NOT A UNIT TEST is testTheHostsSenderNeverParksForever
 * below. It re-implements the HOST's flow control - frame size, window,
 * park-until-acked - from GuestListener.swift and runs the real receiver
 * against it. docs/large-transfers.md records what that pairing costs
 * when it is wrong: a window smaller than the receiver's acknowledgement
 * step deadlocks, the transfer stops dead, and the guest looks healthy
 * throughout because it IS healthy - it is waiting for bytes the sender
 * has decided not to send. That failure cannot be found by testing
 * either side alone, which is the whole of finding
 * two-halves-never-met-in-a-test.
 */

#include "n68_putrx.h"
#include "n68_crc32.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;

static void fail_msg(const char *what)
{
    printf("FAIL %s\n", what);
    ++failures;
}

static void check(const char *what, int ok)
{
    if (!ok) {
        fail_msg(what);
    }
}

static void check_code(const char *what, N68PutCode got, N68PutCode want)
{
    if (got != want) {
        printf("FAIL %s: got %s, wanted %s\n", what,
               n68_putrx_code_word(got), n68_putrx_code_word(want));
        ++failures;
    }
}

/* ---- a disk that is not a disk ---------------------------------------
 *
 * Records what the receiver did rather than simulating HFS: what landed,
 * whether the staging file ever took its final name, and whether it was
 * cleaned up. The two questions this fake is really here to answer are
 * "are the bytes on disk exactly the bytes that were sent" and "did
 * anything ever appear under the final name that should not have".
 */
typedef struct {
    unsigned char *bytes;
    long len, cap;

    int created;
    int finished;          /* took its final name */
    int discarded;
    long free_bytes;       /* what free_bytes() reports; -1 = cannot say */

    N68PutCode create_rc;  /* forced failure for create() */
    N68PutCode write_rc;   /* forced failure for write() */
    N68PutCode finish_rc;
    long fail_write_after; /* write() starts failing past this many bytes */

    long writes;
} FakeDisk;

static long fake_free(void *ctx, const N68PutOffer *offer)
{
    (void)offer;
    return ((FakeDisk *)ctx)->free_bytes;
}

static N68PutCode fake_create(void *ctx, const N68PutOffer *offer)
{
    FakeDisk *d = (FakeDisk *)ctx;

    (void)offer;
    if (d->create_rc != kN68PutOK) {
        return d->create_rc;
    }
    d->created = 1;
    d->len = 0;
    return kN68PutOK;
}

static N68PutCode fake_write(void *ctx, const void *bytes, long len)
{
    FakeDisk *d = (FakeDisk *)ctx;

    if (d->write_rc != kN68PutOK && d->len >= d->fail_write_after) {
        return d->write_rc;
    }
    if (d->len + len > d->cap) {
        fail_msg("the fake disk overflowed - test bug, not a code bug");
        return kN68PutIOError;
    }
    memcpy(d->bytes + d->len, bytes, (size_t)len);
    d->len += len;
    d->writes++;
    return kN68PutOK;
}

static N68PutCode fake_finish(void *ctx)
{
    FakeDisk *d = (FakeDisk *)ctx;

    if (d->finish_rc != kN68PutOK) {
        return d->finish_rc;
    }
    d->finished = 1;
    return kN68PutOK;
}

static void fake_discard(void *ctx)
{
    FakeDisk *d = (FakeDisk *)ctx;

    d->discarded = 1;
    d->len = 0;
}

static const N68PutFileOps kFakeOps = {
    fake_free, fake_create, fake_write, fake_finish, fake_discard
};

/* ---- fixtures --------------------------------------------------------- */

static unsigned char g_batch[kN68PutProgressStep];

static void disk_init(FakeDisk *d, long cap)
{
    memset(d, 0, sizeof *d);
    d->bytes = (unsigned char *)malloc((size_t)cap);
    d->cap = cap;
    d->free_bytes = -1;   /* "cannot say" unless a test sets it */
    if (d->bytes == NULL) {
        fail_msg("out of memory setting up the fake disk");
        exit(1);
    }
}

static void disk_free(FakeDisk *d)
{
    free(d->bytes);
    d->bytes = NULL;
}

static void offer_init(N68PutOffer *o, long bytes)
{
    memset(o, 0, sizeof *o);
    o->id = 7;
    o->bytes = bytes;
    strcpy(o->name, "Report");
    o->create_parents = 1;
}

/* A pattern with no period that divides any frame or batch size, so a
 * batching bug that swaps two runs still shows up as a byte difference
 * rather than landing back on itself. */
static unsigned char pattern_byte(long i)
{
    return (unsigned char)((i * 31 + (i >> 11) * 7 + 13) & 0xFF);
}

static void fill_pattern(unsigned char *buf, long from, long n)
{
    long i;

    for (i = 0; i < n; ++i) {
        buf[i] = pattern_byte(from + i);
    }
}

static int bytes_match_pattern(const unsigned char *buf, long n)
{
    long i;

    for (i = 0; i < n; ++i) {
        if (buf[i] != pattern_byte(i)) {
            printf("  first difference at byte %ld: got %02X, wanted %02X\n",
                   i, buf[i], pattern_byte(i));
            return 0;
        }
    }
    return 1;
}

/* ---- the baseline: 4 MB, arriving in awkward runs --------------------- */

/* 4 MB is the size this spike is meant to survive, and the runs are
 * deliberately not frame-sized: MacTCP hands over whatever it happens to
 * hold, so a receiver that only works on tidy boundaries works on a
 * loopback and nowhere else. */
static void test_four_megabytes_arrive_byte_identical(void)
{
    enum { kTotal = 4 * 1024 * 1024 };
    static unsigned char run[3000];
    FakeDisk disk;
    N68PutRx rx;
    N68PutOffer offer;
    long sent = 0;
    long reports = 0;
    /* Coprime-ish run lengths so every batch boundary is crossed at a
     * different offset over the course of the transfer. */
    static const long sizes[] = { 1, 1448, 2920, 7, 536, 2048, 1, 999 };
    int si = 0;

    disk_init(&disk, kTotal);
    n68_putrx_init(&rx, g_batch, (long)sizeof g_batch, &kFakeOps, &disk);
    offer_init(&offer, kTotal);
    check_code("4 MB offer accepted",
               n68_putrx_offer(&rx, &offer), kN68PutOK);

    while (sent < kTotal) {
        long n = sizes[si++ % (int)(sizeof sizes / sizeof sizes[0])];

        if (n > kTotal - sent) {
            n = kTotal - sent;
        }
        fill_pattern(run, sent, n);
        if (n68_putrx_data(&rx, run, n) != kN68PutOK) {
            fail_msg("4 MB stream failed mid-transfer");
            break;
        }
        sent += n;
        if (n68_putrx_due_report(&rx)) {
            n68_putrx_noted_report(&rx);
            reports++;
        }
    }

    check("nothing took its final name mid-transfer", !disk.finished);
    check_code("4 MB stream closed ok",
               n68_putrx_end(&rx, 1, 0, 0), kN68PutOK);
    check("the file took its final name", disk.finished != 0);
    check("nothing was discarded", !disk.discarded);
    check("4 MB landed", disk.len == kTotal);
    check("4 MB is byte-identical", bytes_match_pattern(disk.bytes, kTotal));

    /* Batching is the reason this is here at all: without it a 4 MB
     * transfer is one File Manager trap per arriving run. */
    check("writes were batched", disk.writes <= (kTotal / (long)sizeof g_batch) + 2);
    /* Reports are due AFTER an arriving run, so their spacing is the
     * step plus however much that run carried past it - never exactly
     * the step, and a test that assumed so would be asserting a cadence
     * MacTCP never produces. The load-bearing check on the spacing is
     * testTheHostsSenderNeverParksForever below; here it is enough that
     * reports kept coming at roughly the step's cadence rather than
     * stopping partway, which is what a `reported` that failed to
     * advance would look like. */
    {
        long longest_run = 2920;   /* the largest of `sizes` above */
        long fewest = kTotal / (kN68PutProgressStep + longest_run);

        check("progress was reported throughout", reports >= fewest);
    }

    printf("  4 MB: %ld writes, %ld reports, crc %08lX\n",
           disk.writes, reports, rx.crc);
    disk_free(&disk);
}

/* ---- the two halves meeting ------------------------------------------ */

/* The HOST's flow control, re-implemented here from GuestListener.swift:
 * it sends `outboundFrameBytes` at a time and parks once it is
 * `outboundWindowBytes` ahead of the last file.progress it received.
 *
 * If the receiver's acknowledgement step is coarser than the window, the
 * sender parks and never restarts. That is not a hypothetical: it is the
 * measured 12 KB-window deadlock in docs/large-transfers.md. This test
 * is what makes kN68PutProgressStep a checked number rather than a
 * comment.
 */
static void run_windowed_sender(const char *label, long total,
                                long frame, long window)
{
    static unsigned char run[32768];
    FakeDisk disk;
    N68PutRx rx;
    N68PutOffer offer;
    long sent = 0, acked = 0;
    int acking = 0;
    long parked_passes = 0;

    disk_init(&disk, total);
    n68_putrx_init(&rx, g_batch, (long)sizeof g_batch, &kFakeOps, &disk);
    offer_init(&offer, total);
    if (n68_putrx_offer(&rx, &offer) != kN68PutOK) {
        fail_msg("windowed sender: offer refused");
        disk_free(&disk);
        return;
    }

    while (sent < total) {
        long n;

        /* The sender's park rule, verbatim in shape: it only applies
         * once the guest has reported at least once, so a guest that
         * never reports keeps its old unbounded behaviour rather than
         * deadlocking against a peer that cannot clock it. */
        if (acking && sent - acked >= window) {
            /* Parked. Nothing more will be sent until a report lands -
             * and no report can land, because reports are produced by
             * bytes arriving. If we get here, the transfer is dead. */
            if (++parked_passes > 1) {
                printf("FAIL %s: sender deadlocked at %ld/%ld "
                       "(acked %ld, window %ld, step %d)\n",
                       label, sent, total, acked, window,
                       kN68PutProgressStep);
                ++failures;
                break;
            }
            continue;
        }
        parked_passes = 0;

        n = (frame < total - sent) ? frame : total - sent;
        fill_pattern(run, sent, n);
        if (n68_putrx_data(&rx, run, n) != kN68PutOK) {
            fail_msg("windowed sender: stream failed");
            break;
        }
        sent += n;
        if (n68_putrx_due_report(&rx)) {
            n68_putrx_noted_report(&rx);
            acked = rx.received;   /* the report the host would receive */
            acking = 1;
        }
    }

    if (sent == total) {
        check_code("windowed sender completed",
                   n68_putrx_end(&rx, 1, 0, 0), kN68PutOK);
        check("windowed sender: bytes identical",
              bytes_match_pattern(disk.bytes, total));
    }
    disk_free(&disk);
}

static void test_the_hosts_sender_never_parks_forever(void)
{
    /* The shipping geometry: 8 KB frames under a 24 KB in-flight bound
     * (GuestListener.swift outboundFrameBytes / outboundWindowBytes). */
    run_windowed_sender("8 KB frames, 24 KB window",
                        1024 * 1024, 8192, 24576);

    /* The tighter pairing the host can be pushed to with NOW_FRAME /
     * NOW_WINDOW. A receiver that only survives the default is a
     * receiver nobody can tune. */
    run_windowed_sender("4 KB frames, 12 KB window",
                        512 * 1024, 4096, 12288);

    /* And the loose end: 32 KB frames, the contract's maximum payload. */
    run_windowed_sender("32 KB frames, 96 KB window",
                        1024 * 1024, 32768, 98304);
}

/* The claim the number rests on, stated as an assertion rather than a
 * comment: a report must be due before the host's frame size has
 * accumulated unreported, or the window arithmetic above cannot close. */
static void test_progress_is_never_coarser_than_a_host_frame(void)
{
    FakeDisk disk;
    N68PutRx rx;
    N68PutOffer offer;
    static unsigned char run[8192];
    long sent = 0;
    long worst_gap = 0, last_report = 0;

    disk_init(&disk, 256 * 1024);
    n68_putrx_init(&rx, g_batch, (long)sizeof g_batch, &kFakeOps, &disk);
    offer_init(&offer, 256 * 1024);
    (void)n68_putrx_offer(&rx, &offer);

    while (sent < 256 * 1024) {
        /* One byte at a time is the pathological arrival pattern, and it
         * is the one that finds an off-by-one in a >= step test. */
        fill_pattern(run, sent, 1);
        (void)n68_putrx_data(&rx, run, 1);
        sent++;
        if (n68_putrx_due_report(&rx)) {
            n68_putrx_noted_report(&rx);
            if (sent - last_report > worst_gap) {
                worst_gap = sent - last_report;
            }
            last_report = sent;
        }
    }
    check("no gap between reports exceeds the progress step",
          worst_gap <= kN68PutProgressStep);
    n68_putrx_cancel(&rx);
    disk_free(&disk);
}

/* ---- refusals: nothing is created, nothing is left behind ------------- */

static void test_an_offer_is_refused_before_anything_is_created(void)
{
    FakeDisk disk;
    N68PutRx rx;
    N68PutOffer offer;

    /* MacBinary: not decoded yet, and writing it out verbatim would
     * produce a file that looks right and opens wrong. */
    disk_init(&disk, 1024);
    n68_putrx_init(&rx, g_batch, (long)sizeof g_batch, &kFakeOps, &disk);
    offer_init(&offer, 512);
    offer.macbinary = 1;
    check_code("macbinary refused",
               n68_putrx_offer(&rx, &offer), kN68PutUnsupported);
    check("macbinary created nothing", !disk.created);
    check("the refusal borrows io-error, per the contract gap",
          strcmp(n68_putrx_code_word(kN68PutUnsupported), "io-error") == 0);
    check("...and says what actually happened",
          strstr(n68_putrx_code_reason(kN68PutUnsupported),
                 "MacBinary") != NULL);
    disk_free(&disk);

    /* Not enough room. Asked before creating, so a 4 MB offer onto a
     * full disk costs one message rather than a partial. */
    disk_init(&disk, 1024);
    n68_putrx_init(&rx, g_batch, (long)sizeof g_batch, &kFakeOps, &disk);
    offer_init(&offer, 4 * 1024 * 1024);
    disk.free_bytes = 1024 * 1024;
    check_code("too big refused",
               n68_putrx_offer(&rx, &offer), kN68PutTooBig);
    check("too big created nothing", !disk.created);
    disk_free(&disk);

    /* A volume that cannot report free space must not refuse everything:
     * -1 is "cannot say", not "zero". */
    disk_init(&disk, 4096);
    n68_putrx_init(&rx, g_batch, (long)sizeof g_batch, &kFakeOps, &disk);
    offer_init(&offer, 4096);
    disk.free_bytes = -1;
    check_code("unknown free space still accepts",
               n68_putrx_offer(&rx, &offer), kN68PutOK);
    n68_putrx_cancel(&rx);
    disk_free(&disk);

    /* A name HFS cannot hold. The sender is supposed to have sanitized,
     * so this is a disagreement between the two sides about what a legal
     * name is - worth refusing rather than truncating onto a file
     * nobody asked for. */
    disk_init(&disk, 1024);
    n68_putrx_init(&rx, g_batch, (long)sizeof g_batch, &kFakeOps, &disk);
    offer_init(&offer, 16);
    memset(offer.name, 'x', 40);
    offer.name[40] = '\0';
    check_code("over-long name refused",
               n68_putrx_offer(&rx, &offer), kN68PutBadPath);
    check("over-long name created nothing", !disk.created);

    offer_init(&offer, 16);
    strcpy(offer.name, "Lab:Report");
    check_code("a colon in the name refused",
               n68_putrx_offer(&rx, &offer), kN68PutBadPath);
    disk_free(&disk);

    /* The File Manager's own refusal is passed through unchanged. */
    disk_init(&disk, 1024);
    n68_putrx_init(&rx, g_batch, (long)sizeof g_batch, &kFakeOps, &disk);
    offer_init(&offer, 16);
    disk.create_rc = kN68PutExists;
    check_code("an existing file refuses exists",
               n68_putrx_offer(&rx, &offer), kN68PutExists);
    disk_free(&disk);
}

static void test_a_second_offer_is_refused_busy(void)
{
    FakeDisk disk;
    N68PutRx rx;
    N68PutOffer offer;

    disk_init(&disk, 4096);
    n68_putrx_init(&rx, g_batch, (long)sizeof g_batch, &kFakeOps, &disk);
    offer_init(&offer, 4096);
    check_code("first offer accepted",
               n68_putrx_offer(&rx, &offer), kN68PutOK);
    offer.id = 8;
    check_code("second offer refused busy",
               n68_putrx_offer(&rx, &offer), kN68PutBusy);
    /* And the refusal must not have disturbed the transfer in flight. */
    check("the live transfer survived the refusal", rx.active != 0);
    check("the live transfer kept its own id", rx.offer.id == 7);
    n68_putrx_cancel(&rx);
    disk_free(&disk);
}

/* ---- failures mid-stream: the partial never survives ------------------ */

static void test_a_failed_transfer_leaves_nothing_behind(void)
{
    FakeDisk disk;
    N68PutRx rx;
    N68PutOffer offer;
    static unsigned char run[8192];
    unsigned long good_crc;

    /* A checksum that does not match. The bytes are DELETED rather than
     * kept: a file that cannot prove it is correct is not a retry
     * candidate, it is garbage. */
    disk_init(&disk, 8192);
    n68_putrx_init(&rx, g_batch, (long)sizeof g_batch, &kFakeOps, &disk);
    offer_init(&offer, 8192);
    (void)n68_putrx_offer(&rx, &offer);
    fill_pattern(run, 0, 8192);
    check_code("stream accepted", n68_putrx_data(&rx, run, 8192), kN68PutOK);
    /* Computed INDEPENDENTLY rather than read out of rx.crc. Reading the
     * receiver's own running value would make this test agree with the
     * receiver by construction, and it would also be wrong whenever the
     * batch buffer has not flushed yet - which is a property of the
     * buffer size, not of the transfer. */
    good_crc = now68k_crc32(0, run, 8192);
    check_code("a wrong checksum fails the transfer",
               n68_putrx_end(&rx, 1, 1, good_crc ^ 0xFFFFUL), kN68PutCorrupt);
    check("corrupt bytes were discarded", disk.discarded != 0);
    check("corrupt bytes never took the final name", !disk.finished);
    disk_free(&disk);

    /* The same stream with the RIGHT checksum must complete - otherwise
     * the test above proves only that the receiver rejects everything. */
    disk_init(&disk, 8192);
    n68_putrx_init(&rx, g_batch, (long)sizeof g_batch, &kFakeOps, &disk);
    offer_init(&offer, 8192);
    (void)n68_putrx_offer(&rx, &offer);
    (void)n68_putrx_data(&rx, run, 8192);
    check("the same bytes produce the same checksum", rx.crc == good_crc);
    check_code("the right checksum completes",
               n68_putrx_end(&rx, 1, 1, good_crc), kN68PutOK);
    check("the file took its final name", disk.finished != 0);
    disk_free(&disk);

    /* A short stream. file.end ok:true says the sender finished, so
     * fewer bytes than offered means bytes were lost. */
    disk_init(&disk, 8192);
    n68_putrx_init(&rx, g_batch, (long)sizeof g_batch, &kFakeOps, &disk);
    offer_init(&offer, 8192);
    (void)n68_putrx_offer(&rx, &offer);
    (void)n68_putrx_data(&rx, run, 4096);
    check_code("a short stream fails",
               n68_putrx_end(&rx, 1, 0, 0), kN68PutCorrupt);
    check("a short stream is discarded", disk.discarded != 0);
    check("a short stream never took the final name", !disk.finished);
    disk_free(&disk);

    /* More bytes than were offered. Cannot be recovered by writing the
     * surplus somewhere and must not be recovered by dropping it. */
    disk_init(&disk, 16384);
    n68_putrx_init(&rx, g_batch, (long)sizeof g_batch, &kFakeOps, &disk);
    offer_init(&offer, 4096);
    (void)n68_putrx_offer(&rx, &offer);
    check_code("an over-long stream fails",
               n68_putrx_data(&rx, run, 8192), kN68PutCorrupt);
    check("an over-long stream is discarded", disk.discarded != 0);
    disk_free(&disk);

    /* The disk failing halfway. */
    disk_init(&disk, 65536);
    n68_putrx_init(&rx, g_batch, (long)sizeof g_batch, &kFakeOps, &disk);
    offer_init(&offer, 65536);
    (void)n68_putrx_offer(&rx, &offer);
    disk.write_rc = kN68PutIOError;
    disk.fail_write_after = 16384;
    {
        N68PutCode rc = kN68PutOK;
        long sent = 0;

        while (sent < 65536 && rc == kN68PutOK) {
            fill_pattern(run, sent, 8192);
            rc = n68_putrx_data(&rx, run, 8192);
            sent += 8192;
        }
        check_code("a failing disk fails the transfer", rc, kN68PutIOError);
    }
    check("a failed write discards the partial", disk.discarded != 0);
    check("a failed write never reaches the final name", !disk.finished);
    disk_free(&disk);

    /* The sender cancelling. */
    disk_init(&disk, 8192);
    n68_putrx_init(&rx, g_batch, (long)sizeof g_batch, &kFakeOps, &disk);
    offer_init(&offer, 8192);
    (void)n68_putrx_offer(&rx, &offer);
    (void)n68_putrx_data(&rx, run, 2048);
    check_code("file.end ok:false is a cancellation",
               n68_putrx_end(&rx, 0, 0, 0), kN68PutCancelled);
    check("a cancellation discards the partial", disk.discarded != 0);
    disk_free(&disk);

    /* A dropped connection, which arrives as no message at all. */
    disk_init(&disk, 8192);
    n68_putrx_init(&rx, g_batch, (long)sizeof g_batch, &kFakeOps, &disk);
    offer_init(&offer, 8192);
    (void)n68_putrx_offer(&rx, &offer);
    (void)n68_putrx_data(&rx, run, 2048);
    n68_putrx_cancel(&rx);
    check("a dropped connection discards the partial", disk.discarded != 0);
    check("...and leaves nothing active", rx.active == 0);
    /* Cancelling twice must not discard twice or crash. */
    disk.discarded = 0;
    n68_putrx_cancel(&rx);
    check("cancelling an idle receiver does nothing", !disk.discarded);
    disk_free(&disk);
}

/* Bulk arriving with nothing expecting it is an ordinary event, not an
 * error: a frame already in flight when a transfer was abandoned has to
 * land somewhere, and the reader stays in frame sync regardless. */
static void test_bulk_with_no_transfer_is_harmless(void)
{
    FakeDisk disk;
    N68PutRx rx;
    static unsigned char run[64];

    disk_init(&disk, 1024);
    n68_putrx_init(&rx, g_batch, (long)sizeof g_batch, &kFakeOps, &disk);
    check_code("stray bulk is ignored",
               n68_putrx_data(&rx, run, 64), kN68PutOK);
    check("stray bulk created nothing", !disk.created);
    check("stray bulk is not due a report", !n68_putrx_due_report(&rx));
    disk_free(&disk);
}

/* A zero-byte file is a real file and a legal offer. It exercises the
 * path where file.end arrives with an empty batch buffer. */
static void test_an_empty_file_completes(void)
{
    FakeDisk disk;
    N68PutRx rx;
    N68PutOffer offer;

    disk_init(&disk, 16);
    n68_putrx_init(&rx, g_batch, (long)sizeof g_batch, &kFakeOps, &disk);
    offer_init(&offer, 0);
    check_code("a zero-byte offer is accepted",
               n68_putrx_offer(&rx, &offer), kN68PutOK);
    check_code("a zero-byte stream completes",
               n68_putrx_end(&rx, 1, 1, 0), kN68PutOK);
    check("the empty file took its final name", disk.finished != 0);
    check("no write was made for no bytes", disk.writes == 0);
    disk_free(&disk);
}

/* The batch buffer's size is the caller's choice and is INDEPENDENT of
 * the progress step - one is a File Manager economy, the other is the
 * sender's flow control, and coupling them would mean a smaller write
 * buffer silently loosening the acknowledgement the host is clocking
 * itself on. A deliberately awkward buffer (not a power of two, smaller
 * than every arriving run) has to produce the same file. */
static void test_the_batch_size_is_independent_of_the_progress_step(void)
{
    enum { kTotal = 64 * 1024 };
    unsigned char tiny[37];
    static unsigned char run[1500];
    FakeDisk disk;
    N68PutRx rx;
    N68PutOffer offer;
    long sent = 0;
    /* Accumulated from what is SENT, not from what landed: reading the
     * expected value off the fake disk would check the bytes against
     * themselves, and would read past disk.len for the batch that has
     * not flushed yet. */
    unsigned long want_crc = 0;

    disk_init(&disk, kTotal);
    n68_putrx_init(&rx, tiny, (long)sizeof tiny, &kFakeOps, &disk);
    offer_init(&offer, kTotal);
    (void)n68_putrx_offer(&rx, &offer);

    while (sent < kTotal) {
        long n = (1500 < kTotal - sent) ? 1500 : kTotal - sent;

        fill_pattern(run, sent, n);
        want_crc = now68k_crc32(want_crc, run, n);
        if (n68_putrx_data(&rx, run, n) != kN68PutOK) {
            fail_msg("tiny batch: stream failed");
            break;
        }
        sent += n;
        if (n68_putrx_due_report(&rx)) {
            n68_putrx_noted_report(&rx);
        }
    }
    check_code("a 37-byte batch still completes",
               n68_putrx_end(&rx, 1, 1, want_crc), kN68PutOK);
    check("a 37-byte batch is byte-identical",
          bytes_match_pattern(disk.bytes, kTotal));
    disk_free(&disk);
}

/* The share boundary. An empty HFS path segment means "parent", so every
 * case below is an attempt to name a folder outside the share - and a
 * share that can be walked upward out of is not a share. These are
 * refused before the disk is asked anything at all. */
static void test_a_path_cannot_walk_out_of_the_share(void)
{
    FakeDisk disk;
    N68PutRx rx;
    N68PutOffer offer;
    static const char *escapes[] = {
        ":",            /* the parent */
        ":Lab",         /* the parent's Lab */
        "::",
        "Lab::Secrets", /* down, then back up */
        ":Lab:Notes",
        NULL
    };
    /* "Lab:" is NOT a traversal: a trailing colon is HFS's ordinary way
     * of saying "this names a directory", and the segment walk simply
     * runs out of path after "Lab". It resolves to the same folder as
     * "Lab", which is also what the PowerPC guest's rel_path_ok does -
     * and the two guests agreeing matters more here than either one's
     * taste, because one host drives both. */
    static const char *fine[] = { "", "Lab", "Lab:Notes", "Lab:", NULL };
    int i;

    for (i = 0; escapes[i] != NULL; ++i) {
        if (n68_putrx_path_ok(escapes[i])) {
            printf("FAIL path \"%s\" was accepted and walks out of the "
                   "share\n", escapes[i]);
            ++failures;
        }
    }
    for (i = 0; fine[i] != NULL; ++i) {
        if (!n68_putrx_path_ok(fine[i])) {
            printf("FAIL ordinary path \"%s\" was refused\n", fine[i]);
            ++failures;
        }
    }
    check("a NULL path is not a path", !n68_putrx_path_ok(NULL));

    /* A segment longer than HFS can name. */
    {
        char longseg[64];

        memset(longseg, 'x', 40);
        longseg[40] = '\0';
        check("an over-long segment is refused", !n68_putrx_path_ok(longseg));
    }

    /* And the refusal has to happen at the offer, before the disk is
     * touched - not later, when a resolve fails for some other reason. */
    disk_init(&disk, 1024);
    n68_putrx_init(&rx, g_batch, (long)sizeof g_batch, &kFakeOps, &disk);
    offer_init(&offer, 16);
    strcpy(offer.path, "Lab::Secrets");
    check_code("a traversal path refuses bad-path",
               n68_putrx_offer(&rx, &offer), kN68PutBadPath);
    check("a traversal path never reached the disk", !disk.created);
    disk_free(&disk);
}

/* ---- parsing an offer ------------------------------------------------- */

static void test_parsing_a_file_offer(void)
{
    N68PutOffer o;
    static const char full[] =
        "{\"type\":\"file.offer\",\"id\":42,\"name\":\"Read Me\","
        "\"path\":\"Lab:Notes\",\"container\":\"data\",\"bytes\":4194304,"
        "\"fileType\":\"TEXT\",\"creator\":\"ttxt\",\"modified\":123456,"
        "\"overwrite\":true,\"createParents\":false}";
    static const char minimal[] =
        "{\"type\":\"file.offer\",\"id\":1,\"name\":\"x\",\"bytes\":0}";

    check("a full offer parses",
          n68_putrx_parse_offer(full, (long)strlen(full), &o) == 1);
    check("id", o.id == 42);
    check("name", strcmp(o.name, "Read Me") == 0);
    check("path", strcmp(o.path, "Lab:Notes") == 0);
    check("bytes", o.bytes == 4194304);
    check("container data is not macbinary", o.macbinary == 0);
    check("fileType", strcmp(o.file_type, "TEXT") == 0);
    check("creator", strcmp(o.creator, "ttxt") == 0);
    check("modified", o.modified == 123456);
    check("overwrite true", o.overwrite == 1);
    check("createParents false", o.create_parents == 0);

    check("a minimal offer parses",
          n68_putrx_parse_offer(minimal, (long)strlen(minimal), &o) == 1);
    check("path defaults to the share root", o.path[0] == '\0');
    /* Absent createParents is TRUE per the schema, and getting this
     * backwards would refuse every offer into a folder that is not there
     * - which is most of them, from a host that has not been told
     * otherwise. */
    check("absent createParents defaults to true", o.create_parents == 1);
    check("absent overwrite defaults to false", o.overwrite == 0);
    check("absent container is data", o.macbinary == 0);

    {
        static const char mb[] =
            "{\"id\":2,\"name\":\"App\",\"bytes\":10,"
            "\"container\":\"macbinary\"}";

        check("macbinary parses",
              n68_putrx_parse_offer(mb, (long)strlen(mb), &o) == 1);
        check("container macbinary is seen", o.macbinary == 1);
    }

    /* Missing what an answer cannot be built without. 0 means "not a
     * usable offer", NOT "refuse it" - a caller with no id has nothing
     * to address a refusal to. */
    {
        static const char no_id[] = "{\"name\":\"x\",\"bytes\":1}";
        static const char no_name[] = "{\"id\":1,\"bytes\":1}";
        static const char no_bytes[] = "{\"id\":1,\"name\":\"x\"}";
        static const char neg[] =
            "{\"id\":1,\"name\":\"x\",\"bytes\":-5}";
        static const char empty_name[] =
            "{\"id\":1,\"name\":\"\",\"bytes\":1}";

        check("no id is not an offer",
              n68_putrx_parse_offer(no_id, (long)strlen(no_id), &o) == 0);
        check("no name is not an offer",
              n68_putrx_parse_offer(no_name, (long)strlen(no_name), &o) == 0);
        check("no bytes is not an offer",
              n68_putrx_parse_offer(no_bytes, (long)strlen(no_bytes), &o) == 0);
        check("a negative size is not an offer",
              n68_putrx_parse_offer(neg, (long)strlen(neg), &o) == 0);
        check("an empty name is not an offer",
              n68_putrx_parse_offer(empty_name,
                                    (long)strlen(empty_name), &o) == 0);
    }

    /* The payload is not NUL-terminated on the wire - it is a length and
     * a buffer that may still hold a longer previous message's tail.
     * json_scan.h takes a length for exactly this reason, and an offer
     * parser that recovered the length with strlen would read a `bytes`
     * belonging to the message before it. */
    {
        char buf[128];
        long n;

        strcpy(buf, "{\"id\":3,\"name\":\"y\",\"bytes\":16}");
        n = (long)strlen(buf);
        strcpy(buf + n, "{\"bytes\":999999}");   /* stale tail */
        check("a length-bounded payload parses",
              n68_putrx_parse_offer(buf, n, &o) == 1);
        check("the stale tail past the length is not read", o.bytes == 16);
    }
}

int main(void)
{
    test_parsing_a_file_offer();
    test_an_offer_is_refused_before_anything_is_created();
    test_a_second_offer_is_refused_busy();
    test_a_path_cannot_walk_out_of_the_share();
    test_bulk_with_no_transfer_is_harmless();
    test_an_empty_file_completes();
    test_the_batch_size_is_independent_of_the_progress_step();
    test_a_failed_transfer_leaves_nothing_behind();
    test_progress_is_never_coarser_than_a_host_frame();
    test_the_hosts_sender_never_parks_forever();
    test_four_megabytes_arrive_byte_identical();

    if (failures != 0) {
        printf("%d failure(s)\n", failures);
        return 1;
    }
    printf("all putrx checks passed\n");
    return 0;
}
