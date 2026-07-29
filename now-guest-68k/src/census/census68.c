/*
 * census68.c - implementation of census68.h: the Toolbox gatherers and the
 * probe registry.
 *
 * No malloc/NewPtr/NewHandle: every buffer here is a fixed local, and the
 * one page a probe fills belongs to the caller. No printf family
 * (numfmt.h only, matching wire68.c and commands68.c) - snprintf drags
 * newlib's float formatting into a 384 KB partition for conversions this
 * file never performs.
 *
 * STATIC BUDGET (stack per call): the widest gatherer is gather_volumes,
 * whose HParamBlockRec (~100 B) plus Str63 plus three row buffers comes to
 * ~330 B. No two are on the stack at once, no recursion. This file owns no
 * BSS - the page lives in the caller (wire68.c's g_census_page).
 *
 * WHAT IS NOT HERE, and why each one is a decision rather than a to-do:
 *
 *   selectors  refused. The PowerPC guest walks a snapshotted table of
 *              documented Gestalt selectors; that table is 32 KB of names
 *              in census_selectors.h, which is a tenth of this
 *              application's whole partition for a probe whose useful
 *              rows `identity` already carries. The note says exactly
 *              that, so a host reads a REASON rather than a silence.
 *   scsi       refused. The contract calls it "THE DECLARED EXCEPTION to
 *              passive-by-rule - an INQUIRY bus scan, active bus I/O" and
 *              says attended first runs on real hardware are the expected
 *              discipline. This machine's internal disk is on that bus, it
 *              has never been attended, and a wedged target on a
 *              cooperatively-scheduled 68030 is a power cycle. `drives`
 *              and `volumes` answer what is mounted without touching it.
 *   ata        absent, gated on Gestalt. A PowerBook 180c's internal disk
 *              is SCSI; there is no ATA bus to enumerate. Gated rather
 *              than assumed, because this build also runs on a Quadra and
 *              on emulators, and "the machine said no" has to be the
 *              MACHINE saying it.
 *   pccard     absent, gated on Gestalt, same reasoning - PCMCIA arrived
 *              with the 190/5300, after this machine.
 *   pci        absent, gated on Gestalt. No 68K Mac has a Name Registry.
 *   pram       partial. GetSysPPtr's 20-byte SysParm copy is what this
 *              build reads; the 256-byte XPRAM behind _ReadXPRam is a
 *              register-based trap these Universal Interfaces do not
 *              declare, so reaching it means hand-written inline assembly
 *              that could not be tested anywhere but on the machine
 *              itself. The 20 bytes carry the fact this Mac most needs
 *              (see gather_pram).
 *
 * NOTHING IN THIS FILE HAS EVER RUN ON A MACINTOSH. Every gatherer is
 * Toolbox calls no gate in this repository can reach - the native tests
 * cover n68_census.c, and that is the whole of the automated cover. Read
 * docs/contract-coverage.md before quoting any of it as working.
 */
#include "census68.h"

#include "health.h"
#include "numfmt.h"
#include "screen68.h"

#include <DeskBus.h>
#include <Devices.h>
#include <Files.h>
#include <Gestalt.h>
#include <LowMem.h>
#include <MacMemory.h>
#include <OSUtils.h>
#include <Power.h>
#include <Quickdraw.h>

#include <string.h>

/* MacTCP's Gestalt selector, declared here for the same reason health.c
 * declares it: it is documented by Inside Macintosh: Networking and not by
 * these Universal Interfaces, and a silent assumption that an upstream
 * name exists is the grep-blindness trap (the CIncludes are CR-terminated,
 * so a failed grep reads as "not defined" rather than "not searched
 * right"). */
#define kCensusGestaltMacTCP FOUR_CHAR_CODE('mtcp')

/* The machine's own name for itself. Documented, and equally absent from
 * these headers' selector list - same rule as above: declared locally
 * rather than assumed to exist upstream. */
#define kCensusGestaltMachineName FOUR_CHAR_CODE('mnam')

/* ---- small bounded formatters ----------------------------------------- */

/* Every one of these ends with a NUL and never reports failure: a census
 * row whose value did not format is still a row, and "?" in the raw column
 * is a truthful answer where a dropped row is not. */
static void fin(char *buf, long cap, long pos, int ok)
{
    if (ok && pos >= 0 && pos < cap) {
        buf[pos] = '\0';
        return;
    }
    if (cap > 0) {
        buf[0] = '?';
        buf[(cap > 1) ? 1 : 0] = '\0';
    }
}

static void fmt_long(char *buf, long cap, long v)
{
    long pos = 0;

    fin(buf, cap, pos, now68k_fmt_append_long(buf, cap, &pos, v));
}

/* "$0000A8B0" - the raw column's default shape for anything the meaning
 * column decodes. Hand-rolled because numfmt has no hex append and this is
 * the only file that wants one. */
static void fmt_hex32(char *buf, long cap, unsigned long v)
{
    static const char kDigits[] = "0123456789ABCDEF";
    int i;

    if (cap < 11) {
        fin(buf, cap, -1, 0);
        return;
    }
    buf[0] = '$';
    for (i = 0; i < 8; ++i) {
        buf[1 + i] = kDigits[(v >> ((7 - i) * 4)) & 0xF];
    }
    buf[9] = '\0';
}

static void fmt_hex8(char *buf, long cap, unsigned long v)
{
    static const char kDigits[] = "0123456789ABCDEF";

    if (cap < 4) {
        fin(buf, cap, -1, 0);
        return;
    }
    buf[0] = '$';
    buf[1] = kDigits[(v >> 4) & 0xF];
    buf[2] = kDigits[v & 0xF];
    buf[3] = '\0';
}

/* Bytes as a human size. Whole MB when it divides, otherwise KB - a
 * PowerBook's 4 MB and a volume's 78,912 KB both want to read as
 * themselves rather than as a long decimal number. */
static void fmt_size(char *buf, long cap, unsigned long bytes)
{
    long pos = 0;
    unsigned long kb = bytes / 1024UL;
    int ok;

    if (kb != 0 && (kb % 1024UL) == 0) {
        ok = now68k_fmt_append_long(buf, cap, &pos, (long)(kb / 1024UL))
             && now68k_fmt_append_str(buf, cap, &pos, " MB");
    } else {
        ok = now68k_fmt_append_long(buf, cap, &pos, (long)kb)
             && now68k_fmt_append_str(buf, cap, &pos, " KB");
    }
    fin(buf, cap, pos, ok);
}

/* The standard Mac OS decode for gestaltSystemVersion and its siblings:
 * high byte is the major version as a plain decimal number, the low byte
 * is minor and bug-fix as two BCD nibbles. health.c decodes it the same
 * way, and this file deliberately does not call into that one - health.c
 * caches formatted DISPLAY strings for a panel, and a census row wants the
 * number beside the words. */
static void fmt_version(char *buf, long cap, long v)
{
    long pos = 0;
    int ok = now68k_fmt_append_long(buf, cap, &pos, (v >> 8) & 0xFF)
             && now68k_fmt_append_str(buf, cap, &pos, ".")
             && now68k_fmt_append_long(buf, cap, &pos, (v >> 4) & 0xF)
             && now68k_fmt_append_str(buf, cap, &pos, ".")
             && now68k_fmt_append_long(buf, cap, &pos, v & 0xF);

    fin(buf, cap, pos, ok);
}

/* A Pascal string into a C buffer, truncating at cap-1. The census page
 * sanitizes what it stores, so nothing here has to worry about a high
 * MacRoman byte in a volume name. */
static void p2c(const unsigned char *p, char *out, long cap)
{
    long n;
    long i;

    if (cap <= 0) {
        return;
    }
    if (p == NULL) {
        out[0] = '\0';
        return;
    }
    n = (long)p[0];
    if (n > cap - 1) {
        n = cap - 1;
    }
    for (i = 0; i < n; ++i) {
        out[i] = (char)p[1 + i];
    }
    out[n] = '\0';
}

static int gest(unsigned long selector, long *out)
{
    return Gestalt((OSType)selector, out) == noErr;
}

static long gest_or(unsigned long selector, long fallback)
{
    long v;

    return gest(selector, &v) ? v : fallback;
}

/* Adds a row whose raw form is a number this build could not decode into
 * words - the shape most Gestalt answers take. */
static void row_num(N68CensusPage *page, const char *name, long value,
                    const char *meaning)
{
    char raw[kN68CensusRawCap];

    fmt_long(raw, (long)sizeof raw, value);
    n68_census_page_add(page, name, raw, meaning);
}

/* A selector this machine does not answer is still a row: "the machine has
 * no opinion" is a fact about the machine, and a row that vanishes reads
 * as a probe that forgot to look. */
static void row_gestalt_version(N68CensusPage *page, const char *name,
                                unsigned long selector)
{
    long v;
    char raw[kN68CensusRawCap];
    char meaning[kN68CensusMeaningCap];

    if (!gest(selector, &v)) {
        n68_census_page_add(page, name, "-", "this machine does not answer");
        return;
    }
    fmt_hex32(raw, (long)sizeof raw, (unsigned long)v);
    fmt_version(meaning, (long)sizeof meaning, v);
    n68_census_page_add(page, name, raw, meaning);
}

static void row_gestalt_size(N68CensusPage *page, const char *name,
                             unsigned long selector)
{
    long v;
    char raw[kN68CensusRawCap];
    char meaning[kN68CensusMeaningCap];

    if (!gest(selector, &v)) {
        n68_census_page_add(page, name, "-", "this machine does not answer");
        return;
    }
    fmt_long(raw, (long)sizeof raw, v);
    fmt_size(meaning, (long)sizeof meaning, (unsigned long)v);
    n68_census_page_add(page, name, raw, meaning);
}

/* ---- what machine is this ---------------------------------------------- */

/* A SHORT table, on purpose. The PowerPC guest carries every model Apple
 * shipped because it runs on machines this one never will; here the useful
 * set is the 68K Macs a build of NOW-68K can plausibly be running on - the
 * PowerBook it was written for, its siblings, and the Quadra the emulator
 * gate boots. An id outside it reports its NUMBER rather than a guess,
 * which is what the raw column is for. */
typedef struct {
    short id;
    const char *name;
} CensusMachineName;

static const CensusMachineName k_machines[] = {
    { gestaltMacSE030,       "Macintosh SE/30" },
    { gestaltMacIIci,        "Macintosh IIci" },
    { gestaltMacIIfx,        "Macintosh IIfx" },
    { gestaltMacIIsi,        "Macintosh IIsi" },
    { gestaltPortable,       "Macintosh Portable" },
    { gestaltPowerBook100,   "PowerBook 100" },
    { gestaltPowerBook140,   "PowerBook 140" },
    { gestaltPowerBook145,   "PowerBook 145" },
    { gestaltPowerBook160,   "PowerBook 160" },
    { gestaltPowerBook165,   "PowerBook 165" },
    { gestaltPowerBook165c,  "PowerBook 165c" },
    { gestaltPowerBook170,   "PowerBook 170" },
    { gestaltPowerBook180,   "PowerBook 180" },
    { gestaltPowerBook180c,  "PowerBook 180c" },
    { gestaltPowerBook150,   "PowerBook 150" },
    { gestaltPowerBook520,   "PowerBook 500 series" },
    { gestaltPowerBookDuo210, "PowerBook Duo 210" },
    { gestaltPowerBookDuo230, "PowerBook Duo 230" },
    { gestaltPowerBookDuo250, "PowerBook Duo 250" },
    { gestaltPowerBookDuo270c, "PowerBook Duo 270c" },
    { gestaltMacQuadra700,   "Macintosh Quadra 700" },
    { gestaltMacQuadra800,   "Macintosh Quadra 800" },
    { gestaltMacQuadra900,   "Macintosh Quadra 900" },
    { gestaltMacQuadra950,   "Macintosh Quadra 950" },
    { gestaltMacQuadra610,   "Macintosh Quadra 610" },
    { gestaltMacQuadra650,   "Macintosh Quadra 650" },
    { gestaltMacCentris610,  "Macintosh Centris 610" },
    { gestaltMacCentris650,  "Macintosh Centris 650" },
    { gestaltMacLC,          "Macintosh LC" },
    { gestaltMacLCII,        "Macintosh LC II" },
    { gestaltMacLCIII,       "Macintosh LC III" }
};

#define kMachineCount ((int)(sizeof k_machines / sizeof k_machines[0]))

/* Gestalt 'mnam' first - it is the machine's OWN name for itself, which
 * beats any table this file could carry - then the table, then the number.
 * 'mnam' answers on Macs from the mid-nineties on; a System 7.1 PowerBook
 * is likely to fall through to the table, which is why the table exists at
 * all. */
static void machine_model(char *out, long cap)
{
    long response = 0;
    long id;
    int i;

    if (gest(kCensusGestaltMachineName, &response) && response != 0) {
        const unsigned char *name = (const unsigned char *)response;

        if (name[0] > 0) {
            p2c(name, out, cap);
            return;
        }
    }
    if (!gest(gestaltMachineType, &id)) {
        long pos = 0;

        fin(out, cap, pos,
            now68k_fmt_append_str(out, cap, &pos, "unnamed machine"));
        return;
    }
    for (i = 0; i < kMachineCount; ++i) {
        if ((long)k_machines[i].id == id) {
            long pos = 0;

            fin(out, cap, pos,
                now68k_fmt_append_str(out, cap, &pos, k_machines[i].name));
            return;
        }
    }
    {
        long pos = 0;
        int ok = now68k_fmt_append_str(out, cap, &pos, "machine id ")
                 && now68k_fmt_append_long(out, cap, &pos, id);

        fin(out, cap, pos, ok);
    }
}

static const char *cpu_name(long type)
{
    switch (type) {
    case gestalt68000: return "68000";
    case gestalt68010: return "68010";
    case gestalt68020: return "68020";
    case gestalt68030: return "68030";
    case gestalt68040: return "68040";
    default:           return NULL;
    }
}

/* The addressing mode, which on this machine is a first-class fact rather
 * than a detail.
 *
 * A 68K Mac's 32-bit addressing switch lives in Parameter RAM, and this
 * PowerBook's PRAM battery is dead - so it comes up in 24-BIT mode every
 * power cycle whatever anyone set last week, and every raw framebuffer
 * read goes to main RAM instead of to VRAM (docs/vram-readout-68k.md).
 * That cost a full investigation before `shotdiag` was written to ask the
 * machine directly. It belongs in the census because it is a fact ABOUT
 * THE MACHINE that changes between boots, which is exactly what a census
 * row is for; it appears in `identity` (what this machine is right now)
 * and again in `pram` (the reason it will not stay that way). */
static void addressing_words(char *out, long cap)
{
    long pos = 0;
    int now32 = screen68_mode_is_32bit();
    long attr = gest_or(gestaltAddressingModeAttr, 0);
    int capable = (attr & (1L << gestalt32BitCapable)) != 0;
    int ok;

    ok = now68k_fmt_append_str(out, cap, &pos,
                                now32 ? "32-bit now" : "24-bit now");
    ok = ok && now68k_fmt_append_str(out, cap, &pos,
                                      capable ? ", 32-bit capable"
                                              : ", not 32-bit capable");
    fin(out, cap, pos, ok);
}

/* ---- identity ---------------------------------------------------------- */

static void gather_identity(N68CensusPage *page)
{
    char raw[kN68CensusRawCap];
    char meaning[kN68CensusMeaningCap];
    long v;

    machine_model(meaning, (long)sizeof meaning);
    fmt_long(raw, (long)sizeof raw, gest_or(gestaltMachineType, 0));
    n68_census_page_add(page, "Model", raw, meaning);

    v = gest_or(gestaltProcessorType, 0);
    fmt_long(raw, (long)sizeof raw, v);
    n68_census_page_add(page, "Processor", raw,
                        cpu_name(v) != NULL ? cpu_name(v)
                                            : "a 68K this build cannot name");

    v = gest_or(gestaltFPUType, 0);
    fmt_long(raw, (long)sizeof raw, v);
    n68_census_page_add(page, "FPU", raw,
                        v == gestaltNoFPU ? "none" : "present");

    v = gest_or(gestaltMMUType, 0);
    fmt_long(raw, (long)sizeof raw, v);
    n68_census_page_add(page, "MMU", raw,
                        v == gestaltNoMMU ? "none" : "present");

    row_gestalt_size(page, "Physical RAM", gestaltPhysicalRAMSize);
    row_gestalt_size(page, "Logical RAM", gestaltLogicalRAMSize);
    row_gestalt_size(page, "ROM size", gestaltROMSize);
    row_gestalt_version(page, "ROM version", gestaltROMVersion);
    row_gestalt_version(page, "System", gestaltSystemVersion);
    row_gestalt_version(page, "QuickDraw", gestaltQuickdrawVersion);
    row_num(page, "Keyboard", gest_or(gestaltKeyboardType, 0), "keyboard type");

    if (gest(kCensusGestaltMacTCP, &v)) {
        fmt_hex32(raw, (long)sizeof raw, (unsigned long)v);
        /* NOT decoded to major.minor: unlike gestaltSystemVersion, nothing
         * in these headers or in any measurement here backs a particular
         * byte layout for 'mtcp'. health.c makes the same refusal. */
        n68_census_page_add(page, "MacTCP", raw, "installed; raw version");
    } else {
        n68_census_page_add(page, "MacTCP", "-",
                            "not installed, or no such selector");
    }

    v = gest_or(gestaltVMAttr, 0);
    n68_census_page_add(page, "Virtual Memory", "",
                        (v & (1L << gestaltVMPresent)) ? "on" : "off");

    addressing_words(meaning, (long)sizeof meaning);
    n68_census_page_add(page, "Addressing", "", meaning);
}

/* ---- overview: the synthesis, in plain words --------------------------- */

/* Overview holds no truth of its own - it arranges what the other probes
 * read. On this guest that is literally true: every row below is a value
 * one of the probes further down this file also reports, said in words a
 * person would use. */
static void gather_overview(N68CensusPage *page)
{
    const HealthStatic *hs = health_static();
    const char *cpu = cpu_name(gest_or(gestaltProcessorType, 0));
    char text[kN68CensusMeaningCap];
    char raw[kN68CensusRawCap];
    long pos;
    int ok;

    machine_model(text, (long)sizeof text);
    n68_census_page_add(page, "Model", "", text);

    n68_census_page_add(page, "Processor", "",
                        cpu != NULL ? cpu : "a 68K this build cannot name");

    fmt_size(text, (long)sizeof text,
             (unsigned long)gest_or(gestaltPhysicalRAMSize, 0));
    n68_census_page_add(page, "Memory", "", text);

    fmt_version(text, (long)sizeof text, gest_or(gestaltSystemVersion, 0));
    n68_census_page_add(page, "System", "", text);

    /* Geometry from the same sample health.c takes for the panel, so the
     * screen a person reads about is the screen the guest draws on. */
    pos = 0;
    ok = now68k_fmt_append_long(text, (long)sizeof text, &pos,
                                 hs->screen_width)
         && now68k_fmt_append_str(text, (long)sizeof text, &pos, "x")
         && now68k_fmt_append_long(text, (long)sizeof text, &pos,
                                    hs->screen_height)
         && now68k_fmt_append_str(text, (long)sizeof text, &pos, ", ")
         && now68k_fmt_append_long(text, (long)sizeof text, &pos,
                                    hs->screen_depth)
         && now68k_fmt_append_str(text, (long)sizeof text, &pos, "-bit");
    fin(text, (long)sizeof text, pos, ok);
    n68_census_page_add(page, "Display", "", text);

    addressing_words(text, (long)sizeof text);
    n68_census_page_add(page, "Addressing", "", text);

    /* Free memory is the number that decides whether anything else on this
     * machine will run, and it is the one fact here that changes minute to
     * minute. TempFreeMem/MaxBlock rather than FreeMem, for health.h's
     * reasons. */
    fmt_size(raw, (long)sizeof raw, (unsigned long)TempFreeMem());
    pos = 0;
    ok = now68k_fmt_append_str(text, (long)sizeof text, &pos, raw)
         && now68k_fmt_append_str(text, (long)sizeof text, &pos, " free, ");
    fmt_size(raw, (long)sizeof raw, (unsigned long)MaxBlock());
    ok = ok && now68k_fmt_append_str(text, (long)sizeof text, &pos, raw)
         && now68k_fmt_append_str(text, (long)sizeof text, &pos,
                                   " largest block");
    fin(text, (long)sizeof text, pos, ok);
    n68_census_page_add(page, "Memory free", "", text);
}

/* ---- video: the GDevice walk ------------------------------------------- */

static void gather_video(N68CensusPage *page)
{
    GDHandle gd;
    int index = 0;
    long qd = gest_or(gestaltQuickdrawVersion, 0);

    if (qd < gestalt8BitQD) {
        /* Original QuickDraw: no GDevice list to walk at all. The machine
         * said no; the screen is still there, and health.c's panel reads
         * it a different way. */
        n68_census_page_say(page, kN68CensusAbsent,
                            "original QuickDraw - no GDevice list on this "
                            "Mac");
        return;
    }
    for (gd = GetDeviceList(); gd != NULL; gd = GetNextDevice(gd)) {
        PixMapHandle pm;
        char label[kN68CensusNameCap];
        char raw[kN68CensusRawCap];
        char meaning[kN68CensusMeaningCap];
        long pos;
        int ok;

        ++index;
        if (*gd == NULL) {
            continue;
        }
        pos = 0;
        ok = now68k_fmt_append_str(label, (long)sizeof label, &pos, "Display ")
             && now68k_fmt_append_long(label, (long)sizeof label, &pos, index);
        fin(label, (long)sizeof label, pos, ok);

        pos = 0;
        ok = now68k_fmt_append_long(raw, (long)sizeof raw, &pos,
                                     (**gd).gdRect.right - (**gd).gdRect.left)
             && now68k_fmt_append_str(raw, (long)sizeof raw, &pos, "x")
             && now68k_fmt_append_long(raw, (long)sizeof raw, &pos,
                                        (**gd).gdRect.bottom - (**gd).gdRect.top);
        fin(raw, (long)sizeof raw, pos, ok);

        pm = (**gd).gdPMap;
        if (pm == NULL || *pm == NULL) {
            n68_census_page_add(page, label, raw,
                                "no PixMap - cannot read its depth");
            continue;
        }
        pos = 0;
        ok = now68k_fmt_append_long(meaning, (long)sizeof meaning, &pos,
                                     (**pm).pixelSize)
             && now68k_fmt_append_str(meaning, (long)sizeof meaning, &pos,
                                       "-bit, row ")
             /* rowBytes' top two bits are the PixMap flag and a reserved
              * bit, not part of the byte count - mask them off or a
              * monochrome screen reads as a huge negative number. */
             && now68k_fmt_append_long(meaning, (long)sizeof meaning, &pos,
                                        (long)((unsigned short)(**pm).rowBytes
                                               & 0x3FFF))
             && now68k_fmt_append_str(meaning, (long)sizeof meaning, &pos,
                                       (gd == GetMainDevice()) ? " (main)" : "");
        fin(meaning, (long)sizeof meaning, pos, ok);
        n68_census_page_add(page, label, raw, meaning);
    }
    if (page->seen == 0) {
        n68_census_page_say(page, kN68CensusFailed,
                            "the device list is empty, which it should never "
                            "be");
    }
}

/* ---- volumes: indexed PBHGetVInfo -------------------------------------- */

static void gather_volumes(N68CensusPage *page)
{
    short index;

    for (index = 1; index < 32; ++index) {
        HParamBlockRec pb;
        Str63 name;
        char label[kN68CensusNameCap];
        char raw[kN68CensusRawCap];
        char meaning[kN68CensusMeaningCap];
        char size[24];
        unsigned long free_bytes;
        long pos;
        int ok;

        memset(&pb, 0, sizeof pb);
        name[0] = 0;
        pb.volumeParam.ioNamePtr = name;
        pb.volumeParam.ioVRefNum = 0;
        pb.volumeParam.ioVolIndex = index;
        if (PBHGetVInfoSync(&pb) != noErr) {
            break;              /* the end of the list, not a failure */
        }
        p2c(name, label, (long)sizeof label);

        /* Both operands widened before the multiply: ioVFrBlk is 16 bits
         * and the PRODUCT is not, so at an 8 KB allocation block a
         * half-full 512 MB volume would report megabytes as kilobytes.
         * n68_putfile.c carries the same widening for the same reason. */
        free_bytes = (unsigned long)pb.volumeParam.ioVFrBlk
                     * (unsigned long)pb.volumeParam.ioVAlBlkSiz;

        pos = 0;
        ok = now68k_fmt_append_str(raw, (long)sizeof raw, &pos, "vRefNum ")
             && now68k_fmt_append_long(raw, (long)sizeof raw, &pos,
                                        pb.volumeParam.ioVRefNum)
             && now68k_fmt_append_str(raw, (long)sizeof raw, &pos, " drive ")
             && now68k_fmt_append_long(raw, (long)sizeof raw, &pos,
                                        pb.volumeParam.ioVDrvInfo);
        fin(raw, (long)sizeof raw, pos, ok);

        fmt_size(size, (long)sizeof size,
                 (unsigned long)pb.volumeParam.ioVNmAlBlks
                     * (unsigned long)pb.volumeParam.ioVAlBlkSiz);
        pos = 0;
        ok = now68k_fmt_append_str(meaning, (long)sizeof meaning, &pos, size);
        fmt_size(size, (long)sizeof size, free_bytes);
        ok = ok && now68k_fmt_append_str(meaning, (long)sizeof meaning, &pos,
                                          ", ")
             && now68k_fmt_append_str(meaning, (long)sizeof meaning, &pos, size)
             && now68k_fmt_append_str(meaning, (long)sizeof meaning, &pos,
                                       " free");
        fin(meaning, (long)sizeof meaning, pos, ok);

        n68_census_page_add(page, label[0] != '\0' ? label : "(unnamed)",
                            raw, meaning);
    }
    if (page->seen == 0) {
        /* No mounted volume at all is a finding about the machine, not a
         * failure of the probe - and it is one a machine that booted from
         * somewhere cannot really produce. */
        n68_census_page_say(page, kN68CensusAbsent, "no mounted volumes");
    }
}

/* ---- drives: the drive queue, zero bus I/O ----------------------------- */

/* The queue the File Manager keeps of every mounted DRIVE (as opposed to
 * every mounted volume): it answers what hardware is attached without
 * asking any of it a question, which is the whole reason the census
 * prefers it to a SCSI scan. */
typedef struct {
    QElemPtr qLink;
    short qType;
    short dQDrive;
    short dQRefNum;
    short dQFSID;
    short dQDrvSz;
    short dQDrvSz2;
} CensusDrvQEl;

/* The drive queue header, reached through a volatile rather than through
 * LMGetDrvQHdr() directly.
 *
 * That macro expands to a cast of the literal 0x0308, and gcc's
 * -Warray-bounds sees the dereference that follows as an access outside a
 * QHdr object it can prove nothing about - which this build, compiled
 * -Werror, refuses. The volatile states what is actually true: the
 * Operating System maintains a structure at that address, and the compiler
 * knows nothing about it. Four bytes of data, and the only BSS this file
 * owns. */
static QHdrPtr drive_queue_header(void)
{
    static volatile unsigned long addr = 0x0308UL;

    return (QHdrPtr)addr;
}

static void gather_drives(N68CensusPage *page)
{
    QHdrPtr hdr = drive_queue_header();
    QElemPtr q;
    int guard = 0;

    if (hdr == NULL) {
        n68_census_page_say(page, kN68CensusFailed,
                            "no drive queue header");
        return;
    }
    for (q = hdr->qHead; q != NULL && guard < 32; q = q->qLink, ++guard) {
        const CensusDrvQEl *d = (const CensusDrvQEl *)q;
        char label[kN68CensusNameCap];
        char raw[kN68CensusRawCap];
        char meaning[kN68CensusMeaningCap];
        unsigned long blocks;
        long pos;
        int ok;

        pos = 0;
        ok = now68k_fmt_append_str(label, (long)sizeof label, &pos, "Drive ")
             && now68k_fmt_append_long(label, (long)sizeof label, &pos,
                                        d->dQDrive);
        fin(label, (long)sizeof label, pos, ok);

        pos = 0;
        ok = now68k_fmt_append_str(raw, (long)sizeof raw, &pos, "refNum ")
             && now68k_fmt_append_long(raw, (long)sizeof raw, &pos,
                                        d->dQRefNum)
             && now68k_fmt_append_str(raw, (long)sizeof raw, &pos, " fsid ")
             && now68k_fmt_append_long(raw, (long)sizeof raw, &pos, d->dQFSID);
        fin(raw, (long)sizeof raw, pos, ok);

        /* dQDrvSz/dQDrvSz2 are the low and high halves of a 32-bit block
         * count on a queue element the File Manager extended for volumes
         * past 32 MB. Read as one number; a drive that never filled the
         * high half reports the same value it always did. */
        blocks = ((unsigned long)(unsigned short)d->dQDrvSz2 << 16)
                 | (unsigned long)(unsigned short)d->dQDrvSz;
        fmt_size(meaning, (long)sizeof meaning, blocks * 512UL);
        n68_census_page_add(page, label, raw, meaning);
    }
    if (page->seen == 0) {
        n68_census_page_say(page, kN68CensusAbsent, "the drive queue is empty");
    }
}

/* ---- drivers: the Device Manager unit table ---------------------------- */

static void gather_drivers(N68CensusPage *page)
{
    DCtlHandle *table = (DCtlHandle *)LMGetUTableBase();
    short count = LMGetUnitTableEntryCount();
    short i;

    if (table == NULL || count <= 0) {
        n68_census_page_say(page, kN68CensusFailed,
                            "no unit table on this Mac");
        return;
    }
    for (i = 0; i < count; ++i) {
        DCtlHandle dce = table[i];
        const unsigned char *name;
        char label[kN68CensusNameCap];
        char raw[kN68CensusRawCap];
        char meaning[kN68CensusMeaningCap];
        long pos;
        int ok;

        if (dce == NULL || *dce == NULL) {
            continue;           /* an empty slot is not a driver */
        }
        pos = 0;
        ok = now68k_fmt_append_str(label, (long)sizeof label, &pos, "Unit ")
             && now68k_fmt_append_long(label, (long)sizeof label, &pos, i);
        fin(label, (long)sizeof label, pos, ok);

        pos = 0;
        ok = now68k_fmt_append_str(raw, (long)sizeof raw, &pos, "refNum ")
             && now68k_fmt_append_long(raw, (long)sizeof raw, &pos,
                                        (**dce).dCtlRefNum);
        fin(raw, (long)sizeof raw, pos, ok);

        /* A RAM-based driver's dCtlDriver is a HANDLE and a ROM-based
         * one's is a POINTER (dRAMBasedMask), and the driver's name is the
         * Pascal string at offset 18 of the driver header either way. Get
         * that distinction wrong and this walks a master pointer as if it
         * were code - so the flag is checked, not assumed, and a driver
         * whose storage this cannot resolve reports its refNum alone. */
        name = NULL;
        if ((**dce).dCtlDriver != NULL) {
            if (((**dce).dCtlFlags & dRAMBasedMask) != 0) {
                Handle h = (Handle)(**dce).dCtlDriver;

                if (*h != NULL) {
                    name = (const unsigned char *)(*h) + 18;
                }
            } else {
                name = (const unsigned char *)(**dce).dCtlDriver + 18;
            }
        }
        if (name != NULL && name[0] > 0 && name[0] < 32) {
            p2c(name, meaning, (long)sizeof meaning);
        } else {
            meaning[0] = '\0';
        }
        n68_census_page_add(page, label, raw,
                            meaning[0] != '\0' ? meaning
                                               : "installed; no readable name");
    }
    if (page->seen == 0) {
        n68_census_page_say(page, kN68CensusFailed,
                            "the unit table has no live entries");
    }
}

/* ---- adb: the ADB device table ----------------------------------------- */

/* Easier here than on the PowerPC guest, which has to resolve CountADBs
 * from InterfaceLib by name because Carbon gates the ADB Manager out.
 * These are plain traps on a 68K Mac. */
static void gather_adb(N68CensusPage *page)
{
    short count;
    short i;

    count = CountADBs();
    if (count <= 0) {
        n68_census_page_say(page, kN68CensusAbsent,
                            "no ADB devices - is this an emulator?");
        return;
    }
    for (i = 1; i <= count; ++i) {
        ADBDataBlock blk;
        short addr;
        char label[kN68CensusNameCap];
        char raw[kN68CensusRawCap];
        const char *meaning;
        long pos;
        int ok;

        memset(&blk, 0, sizeof blk);
        addr = GetIndADB(&blk, i);
        pos = 0;
        ok = now68k_fmt_append_str(label, (long)sizeof label, &pos, "Device ")
             && now68k_fmt_append_long(label, (long)sizeof label, &pos, i);
        fin(label, (long)sizeof label, pos, ok);

        pos = 0;
        ok = now68k_fmt_append_str(raw, (long)sizeof raw, &pos, "addr ")
             && now68k_fmt_append_long(raw, (long)sizeof raw, &pos, addr)
             && now68k_fmt_append_str(raw, (long)sizeof raw, &pos, " handler ")
             && now68k_fmt_append_long(raw, (long)sizeof raw, &pos,
                                        (long)blk.devType);
        fin(raw, (long)sizeof raw, pos, ok);

        /* The DEFAULT address is what says what kind of device this is;
         * the current one can have been moved by the ADB Manager to
         * resolve a collision. */
        switch (blk.origADBAddr) {
        case 2:  meaning = "keyboard"; break;
        case 3:  meaning = "mouse or trackball"; break;
        case 4:  meaning = "absolute pointing device"; break;
        case 7:  meaning = "other"; break;
        default: meaning = "unknown default address"; break;
        }
        n68_census_page_add(page, label, raw, meaning);
    }
}

/* ---- pram: 20 bytes, and the one this machine most needs --------------- */

/* THE PROBE WORTH THE MOST ON THIS PARTICULAR MAC.
 *
 * The PowerBook 180c's PRAM battery is dead. That is not a detail: the
 * 32-bit addressing switch lives in PRAM, so the machine resets to 24-bit
 * addressing on every power cycle, and every raw framebuffer read then
 * lands in main RAM. The capture arrived as noise, and it took an
 * investigation and a purpose-built diagnostic (`shotdiag`) to find out
 * why. A census that can say "PRAM is not being retained" turns that from
 * an investigation into a row.
 *
 * `valid` is the byte the Operating System writes ($A8) when it has
 * written a good copy of Parameter RAM. A machine whose battery cannot
 * hold it comes up with defaults, and this row says so. Reported as
 * `partial` because 20 bytes is not the 256 the contract's probe describes
 * - see the note at the top of this file for why the rest is out of reach
 * in this build. */
static void gather_pram(N68CensusPage *page)
{
    SysPPtr sp = GetSysPPtr();
    char raw[kN68CensusRawCap];
    char meaning[kN68CensusMeaningCap];
    const unsigned char *bytes;
    int off;

    if (sp == NULL) {
        n68_census_page_say(page, kN68CensusFailed,
                            "no SysParm copy at 0x01F8");
        return;
    }
    fmt_hex8(raw, (long)sizeof raw, sp->valid);
    n68_census_page_add(page, "valid", raw,
                        sp->valid == 0xA8
                            ? "$A8 - Parameter RAM is being retained"
                            : "NOT $A8 - PRAM was reset (flat battery?)");

    addressing_words(meaning, (long)sizeof meaning);
    n68_census_page_add(page, "Addressing", "", meaning);
    if (sp->valid != 0xA8) {
        /* The causal sentence, stated where someone reading a census will
         * meet it, rather than in a document they would have to already
         * suspect. */
        n68_census_page_add(page, "Consequence", "",
                            "the 32-bit switch lives here, so it resets "
                            "every boot");
    }

    fmt_hex8(raw, (long)sizeof raw, sp->aTalkA);
    n68_census_page_add(page, "aTalkA", raw, "AppleTalk node hint, port A");
    fmt_hex8(raw, (long)sizeof raw, sp->aTalkB);
    n68_census_page_add(page, "aTalkB", raw, "AppleTalk node hint, port B");
    fmt_hex8(raw, (long)sizeof raw, sp->config);
    n68_census_page_add(page, "config", raw, "serial port use");
    fmt_long(raw, (long)sizeof raw, sp->alarm);
    n68_census_page_add(page, "alarm", raw, "alarm clock setting");
    fmt_long(raw, (long)sizeof raw, sp->font);
    n68_census_page_add(page, "font", raw, "default application font id - 1");

    /* Then the raw bytes, so nothing the decoded rows skipped is hidden.
     * Four per row keeps a row inside the raw column's 32 characters. */
    bytes = (const unsigned char *)sp;
    for (off = 0; off < 20; off += 4) {
        char label[kN68CensusNameCap];
        long pos = 0;
        int ok;
        int i;

        ok = now68k_fmt_append_str(label, (long)sizeof label, &pos, "raw +")
             && now68k_fmt_append_long(label, (long)sizeof label, &pos, off);
        fin(label, (long)sizeof label, pos, ok);

        raw[0] = '\0';
        pos = 0;
        for (i = 0; i < 4 && off + i < 20; ++i) {
            char one[8];

            fmt_hex8(one, (long)sizeof one, bytes[off + i]);
            ok = ok && now68k_fmt_append_str(raw, (long)sizeof raw, &pos,
                                              one + 1)
                 && now68k_fmt_append_str(raw, (long)sizeof raw, &pos, " ");
        }
        fin(raw, (long)sizeof raw, pos, ok);
        n68_census_page_add(page, label, raw, "");
    }

    n68_census_page_say(page, kN68CensusPartial,
                        "20 of 256 bytes - the XPRAM trap is not declared in "
                        "these headers");
}

/* ---- power: it is a battery-powered laptop ----------------------------- */

/* The other probe worth more here than on a desktop. Gated on Gestalt
 * saying there is a Power Manager at all, so a Quadra (or an emulator
 * pretending to be one) answers `absent` - the machine said no - rather
 * than this build guessing.
 *
 * TWO CALLS, and which one is used is a capability question, not a
 * preference. GetScaledBatteryInfo is a _PowerMgrDispatch selector and is
 * only safe where Gestalt says that dispatcher exists
 * (gestaltPMgrDispatchExists); on an older Power Manager the classic
 * BatteryStatus is what there is. Calling a dispatch selector a Power
 * Manager does not implement is not a slow path, it is a crash. */
static void gather_power(N68CensusPage *page)
{
    long attr = 0;
    char raw[kN68CensusRawCap];
    char meaning[kN68CensusMeaningCap];
    long pos;
    int ok;

    if (!gest(gestaltPowerMgrAttr, &attr)
        || (attr & (1L << gestaltPMgrExists)) == 0) {
        n68_census_page_say(page, kN68CensusAbsent,
                            "no Power Manager - a desktop, or an emulator");
        return;
    }

    if ((attr & (1L << gestaltPMgrDispatchExists)) != 0) {
        BatteryInfo bi;
        int percent;

        memset(&bi, 0, sizeof bi);
        GetScaledBatteryInfo(1, &bi);
        percent = ((int)bi.batteryLevel * 100 + 127) / 255;

        pos = 0;
        ok = now68k_fmt_append_str(raw, (long)sizeof raw, &pos, "level ")
             && now68k_fmt_append_long(raw, (long)sizeof raw, &pos,
                                        (long)bi.batteryLevel)
             && now68k_fmt_append_str(raw, (long)sizeof raw, &pos, "/255");
        fin(raw, (long)sizeof raw, pos, ok);

        pos = 0;
        ok = now68k_fmt_append_long(meaning, (long)sizeof meaning, &pos,
                                     percent)
             && now68k_fmt_append_str(meaning, (long)sizeof meaning, &pos, "%")
             && now68k_fmt_append_str(
                    meaning, (long)sizeof meaning, &pos,
                    (bi.flags & (1 << batteryInstalled)) ? ", installed"
                                                         : ", no battery")
             && now68k_fmt_append_str(
                    meaning, (long)sizeof meaning, &pos,
                    (bi.flags & (1 << batteryCharging)) ? ", charging" : "");
        fin(meaning, (long)sizeof meaning, pos, ok);
        n68_census_page_add(page, "Battery 1", raw, meaning);

        fmt_hex8(raw, (long)sizeof raw, bi.flags);
        n68_census_page_add(page, "Flags", raw, "GetScaledBatteryInfo");
        fmt_long(raw, (long)sizeof raw, (long)bi.warningLevel);
        n68_census_page_add(page, "Warning level", raw, "scaled 0-255");
        return;
    }

    {
        Byte status = 0;
        Byte power = 0;
        OSErr err = BatteryStatus(&status, &power);

        if (err != noErr) {
            n68_census_page_say(page, kN68CensusFailed,
                                "the Power Manager refused BatteryStatus");
            return;
        }
        fmt_hex8(raw, (long)sizeof raw, status);
        pos = 0;
        ok = now68k_fmt_append_str(
                 meaning, (long)sizeof meaning, &pos,
                 (status & chargerConnMask) ? "charger connected"
                                            : "on battery")
             && now68k_fmt_append_str(
                    meaning, (long)sizeof meaning, &pos,
                    (status & batteryLowMask) ? ", LOW" : "")
             && now68k_fmt_append_str(
                    meaning, (long)sizeof meaning, &pos,
                    (status & batteryDeadMask) ? ", DEAD" : "")
             && now68k_fmt_append_str(
                    meaning, (long)sizeof meaning, &pos,
                    (status & hiChargeMask) ? ", high charge rate" : "");
        fin(meaning, (long)sizeof meaning, pos, ok);
        n68_census_page_add(page, "Battery", raw, meaning);

        /* The second byte is a level whose conversion to volts differs by
         * machine, and nothing in these headers or in any measurement here
         * backs a formula. It goes out RAW and says so, which is the
         * column's whole purpose. */
        fmt_long(raw, (long)sizeof raw, (long)power);
        n68_census_page_add(page, "Level", raw,
                            "raw Power Manager byte; not decoded to volts");
    }
}

/* ---- the four the machine, or this build, says no to -------------------- */

static void gather_ata(N68CensusPage *page)
{
    long attr = 0;

    /* Gated, not assumed. A PowerBook 180c's internal disk is SCSI and
     * there is no ATA Manager to ask - but this same build runs on a
     * Quadra and under emulators, and `absent` has to be the MACHINE
     * saying no, not this file deciding for it. */
    if (gest(gestaltATAAttr, &attr) && attr != 0) {
        char raw[kN68CensusRawCap];

        fmt_hex32(raw, (long)sizeof raw, (unsigned long)attr);
        n68_census_page_add(page, "ATA Manager", raw, "present, not walked");
        n68_census_page_say(page, kN68CensusRefused,
                            "an ATA Manager is here, but this build has no "
                            "IDENTIFY path");
        return;
    }
    n68_census_page_say(page, kN68CensusAbsent,
                        "no ATA bus - this Mac's internal disk is SCSI");
}

static void gather_pccard(N68CensusPage *page)
{
    long attr = 0;

    if (gest(gestaltPCCard, &attr) && attr != 0) {
        char raw[kN68CensusRawCap];

        fmt_hex32(raw, (long)sizeof raw, (unsigned long)attr);
        n68_census_page_add(page, "Card Services", raw,
                            "present, not walked");
        n68_census_page_say(page, kN68CensusRefused,
                            "Card Services is here, but this build asks it "
                            "nothing");
        return;
    }
    n68_census_page_say(page, kN68CensusAbsent,
                        "no PC Card sockets - PCMCIA arrived after this Mac");
}

static void gather_pci(N68CensusPage *page)
{
    long v = 0;

    if (gest(gestaltNameRegistryVersion, &v)) {
        char raw[kN68CensusRawCap];

        fmt_hex32(raw, (long)sizeof raw, (unsigned long)v);
        n68_census_page_add(page, "Name Registry", raw,
                            "present, not walked");
        n68_census_page_say(page, kN68CensusRefused,
                            "a Name Registry is here, but this build cannot "
                            "walk it");
        return;
    }
    n68_census_page_say(page, kN68CensusAbsent,
                        "no Name Registry - no 68K Mac has a PCI device "
                        "tree");
}

static void gather_scsi(N68CensusPage *page)
{
    long hw = 0;

    /* Even the GATE is reported, because "there is a bus and we did not
     * scan it" is a different sentence from "there is no bus", and a
     * refusal that cannot tell them apart is the conflation this whole
     * design is against. */
    if (gest(gestaltHardwareAttr, &hw)
        && (hw & (1L << gestaltHasSCSI)) == 0) {
        n68_census_page_say(page, kN68CensusAbsent, "no SCSI bus on this Mac");
        return;
    }
    n68_census_page_add(page, "SCSI bus", "present",
                        "not scanned - see the note");
    n68_census_page_say(page, kN68CensusRefused,
                        "an INQUIRY scan is active bus I/O and has never been "
                        "attended here; `drives` answers without touching it");
}

static void gather_selectors(N68CensusPage *page)
{
    n68_census_page_say(page, kN68CensusRefused,
                        "the documented-selector table is 32 KB of names in a "
                        "384 KB partition; `identity` carries the useful "
                        "rows");
}

/* ---- the registry ------------------------------------------------------ */

/* EVERY NAME IN THE CONTRACT'S x-census REGISTRY, in the PowerPC guest's
 * rail order so a host that draws both machines draws them the same way.
 * A name missing from here would answer "unknown probe", which tells a
 * caller the REGISTRY does not have it - a different and false statement
 * from "this machine does not". */
typedef struct {
    const char *name;
    void (*gather)(N68CensusPage *);
} CensusProbe68;

static const CensusProbe68 k_probes68[] = {
    { "overview",  gather_overview },
    { "identity",  gather_identity },
    { "selectors", gather_selectors },
    { "video",     gather_video },
    { "volumes",   gather_volumes },
    { "drives",    gather_drives },
    { "drivers",   gather_drivers },
    { "adb",       gather_adb },
    { "ata",       gather_ata },
    { "pccard",    gather_pccard },
    { "pram",      gather_pram },
    { "power",     gather_power },
    { "pci",       gather_pci },
    { "scsi",      gather_scsi }
};

#define kProbe68Count ((int)(sizeof k_probes68 / sizeof k_probes68[0]))

int now68k_census_gather(const char *probe, long cursor, N68CensusPage *page)
{
    const char *want = (probe != NULL && probe[0] != '\0') ? probe
                                                           : "overview";
    int i;

    if (page == NULL) {
        return 0;
    }
    for (i = 0; i < kProbe68Count; ++i) {
        if (strcmp(want, k_probes68[i].name) == 0) {
            n68_census_page_init(page, cursor);
            k_probes68[i].gather(page);
            return 1;
        }
    }
    return 0;
}
