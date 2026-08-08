/*
 * NOW ATA - does this Macintosh's drive introduce itself?
 *
 * AN INSTRUMENT, not part of the product. One question, asked on the
 * machine, carrying its own control.
 *
 * WHY
 * ---
 * `census_ata_identify` built a parameter block matching Apple's
 * ataIdentify field for field, with kAtaFnIdentify = 0x13 correct, and
 * left ataPBFlags ZERO. Without bATAFlagIORead the ATA Manager never
 * drives the data-in phase: the call returns noErr with an empty buffer
 * and leaves the device mid-command. (It also cost every shutdown its
 * final "volume unmounted" write, which is how it was found.)
 *
 * So now-guest-ppc/src/census/census_probes.c carries this, recorded
 * from metal on 2026-07-22:
 *
 *     on the 1400c the manager answers noErr with an EMPTY IDENTIFY
 *     buffer - the device is present but yields no model/serial
 *
 * That was never the drive having nothing to say. NOBODY HAD ASKED FOR
 * THE DATA. This asks again.
 *
 * WHY IT CARRIES ITS OWN CONTROL
 * ------------------------------
 * It runs IDENTIFY TWICE per device: once with flags zero (reproducing
 * the recorded behaviour) and once with the flag set. A single "it
 * answered" would be a claim about this build; the pair is a claim about
 * the FLAG, made on the machine, in one run. If the without-flag call
 * also returns data, the flag was never the cause and the 2026-07-22
 * note stands for some other reason - which is a result, not a failure.
 *
 * WHY 68K AND WHY NOT MIXED MODE
 * ------------------------------
 * The product reaches this manager from PowerPC through CallUniversalProc
 * and a hand-built thunk. A 68K application calls the trap directly, so
 * this instrument removes that entire layer - which makes it a cleaner
 * question about the DRIVE, and a cross-check on the dispatch path if the
 * two ever disagree. A 68K application runs fine on a PowerPC Mac.
 *
 * WHAT IT DOES NOT SHOW
 * ---------------------
 * One probe of fourteen, on one machine. Nothing about any other Mac, and
 * nothing about the other thirteen probes.
 *
 * VERIFICATION: this compiles. The trap call has NOT been run on
 * hardware - that is the whole point of shipping it to the PowerBook.
 */

#include <stdio.h>
#include <string.h>
#include <MacTypes.h>

/* _ATAMgr, $AAF1. Pascal calling convention: parameter block pushed,
   word result returned. The byte sequence this mirrors is the one
   census_trap.c thunks for the PowerPC side. */
pascal short ATAMgrTrap(void *pb) = {0xAAF1};

/* Laid out to match ATA.h, using the offsets census_trap.c verified
   rather than the Carbon-gated header. Copied deliberately: an
   instrument that shares a header with the code under test can be
   wrong in the same way. */
typedef struct {
    void *link; UInt16 qType; UInt8 vers; UInt8 rsvd; void *rsvd2;
    void *callback; OSErr result; UInt8 fn; UInt8 ioSpeed; UInt16 flags;
    SInt16 rsvd3; UInt32 deviceID; UInt32 timeout; void *c1; void *c2;
    UInt16 state; UInt16 sems; SInt32 rsvd4;
    UInt16 r1[4]; UInt8 *buffer; UInt16 r2[12]; SInt16 r3[6];
} AtaPB;

enum { kAtaFnIdentify = 0x13 };
/* ATA.h: bATAFlagIORead = 13. Checked against Universal Interfaces, not
   remembered - the same value and the same reasoning as census_trap.c. */
enum { kAtaFlagIORead = 1 << 13 };

static unsigned char gBuf[512];

/* ATA IDENTIFY strings are byte-swapped within each 16-bit word. */
static void ata_string(const unsigned char *buf, int firstWord, int words,
                       char *out)
{
    int i;
    for (i = 0; i < words; i++) {
        out[i * 2]     = (char)buf[(firstWord + i) * 2 + 1];
        out[i * 2 + 1] = (char)buf[(firstWord + i) * 2];
    }
    out[words * 2] = '\0';
    for (i = words * 2 - 1; i >= 0 && (out[i] == ' ' || out[i] == '\0'); i--) {
        out[i] = '\0';
    }
}

static int buf_empty(const unsigned char *b)
{
    int i;
    for (i = 0; i < 512; i++) { if (b[i]) return 0; }
    return 1;
}

/* Returns 1 if the buffer came back with anything in it. */
static int identify(unsigned long deviceID, UInt16 flags, short *rcOut,
                    OSErr *resultOut)
{
    AtaPB pb;

    memset(&pb, 0, sizeof pb);
    memset(gBuf, 0, sizeof gBuf);
    pb.vers = 1;
    pb.fn = kAtaFnIdentify;
    pb.deviceID = deviceID;
    pb.timeout = 1000;
    pb.buffer = gBuf;
    pb.flags = flags;

    *rcOut = ATAMgrTrap(&pb);
    *resultOut = pb.result;
    return !buf_empty(gBuf);
}

static void report(const char *label, unsigned long id, UInt16 flags)
{
    short rc; OSErr res; int got;
    char model[42], serial[22], fw[10];

    got = identify(id, flags, &rc, &res);
    printf("  %-14s trap=%d result=%d buffer=%s\n",
           label, (int)rc, (int)res, got ? "HAS DATA" : "empty");
    if (!got) return;

    ata_string(gBuf, 27, 20, model);
    ata_string(gBuf, 10, 10, serial);
    ata_string(gBuf, 23, 4, fw);
    printf("      model    : %s\n", model);
    printf("      serial   : %s\n", serial);
    printf("      firmware : %s\n", fw);
    printf("      sectors  : %lu (LBA28 words 60-61)\n",
           (unsigned long)gBuf[120] | ((unsigned long)gBuf[121] << 8)
           | ((unsigned long)gBuf[122] << 16) | ((unsigned long)gBuf[123] << 24));
}

int main(void)
{
    /* internal bus 0 master/slave, then bus 1. deviceID = (device << 8) | bus,
       the same candidates census_probes.c sweeps. */
    static const unsigned long kIds[] = { 0x0000, 0x0100, 0x0001, 0x0101 };
    int i;

    printf("NOW ATA - IDENTIFY, with and without bATAFlagIORead\n");
    printf("recorded 2026-07-22 (metal, 1400c): noErr, EMPTY buffer\n");
    printf("if 'without' is empty and 'with' has data, the flag was the cause.\n\n");

    for (i = 0; i < 4; i++) {
        printf("device 0x%04lx\n", kIds[i]);
        report("without flag", kIds[i], 0);
        report("WITH flag",    kIds[i], kAtaFlagIORead);
        printf("\n");
    }

    printf("done. One probe of fourteen, on one machine.\n");
    printf("Press return to quit.\n");
    (void)getchar();
    return 0;
}
