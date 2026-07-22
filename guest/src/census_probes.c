/* census_probes.c - the Toolbox side of the hardware census.
 *
 * The Carbon-clean probes: Overview (a synthesis, in plain words), Identity
 * (the machine in a curated dozen rows), Selectors (the full Gestalt walk),
 * Video (the GDevice walk) and Volumes (indexed PBHGetVInfo). Each is a
 * read-only walk of a table the OS maintains; failures are data (an empty
 * surface is `absent`, never an error), and every value keeps its raw form
 * beside the decoded meaning.
 *
 * Overview holds no truth of its own - it arranges what the other probes
 * find, so its rows carry provenance the detail pane shows: the actual
 * selectors a fact was read from. Nothing here is a guess.
 *
 * Paging discipline (contract: censusExchange): now_census_gather fills at
 * most kCensusPageMax rows per call and reports whether more follow, so a
 * request never does more than a page of work. The reading of raw values
 * lives in census_decode.c (pure, native-tested); this file gathers and
 * arranges. */

#include "census.h"
#include "census_decode.h"
#include "census_selectors.h"
#include "machine_names.h"

#include <Carbon.h>
#include <SCSI.h>              /* SCSIInstr + sc* opcodes; funcs resolved */

#include <stdio.h>
#include <string.h>

/* --- row helpers -------------------------------------------------------- */

static void set_row(CensusRow *row, const char *name, const char *raw,
                    const char *meaning)
{
    strncpy(row->name, name, sizeof row->name - 1);
    row->name[sizeof row->name - 1] = '\0';
    strncpy(row->raw, raw, sizeof row->raw - 1);
    row->raw[sizeof row->raw - 1] = '\0';
    strncpy(row->meaning, meaning, sizeof row->meaning - 1);
    row->meaning[sizeof row->meaning - 1] = '\0';
}

static void page_init(CensusPage *page)
{
    page->count = 0;
    page->outcome = kCensusPresent;
    page->more = 0;
    page->next_cursor = 0;
    page->total = -1;
    page->note[0] = '\0';
}

/* Printable ASCII in place of; controls and quotes become '.'. */
static void sanitize(const char *in, char *out, long cap)
{
    long i, n = (long)strlen(in);

    if (n >= cap) {
        n = cap - 1;
    }
    for (i = 0; i < n; i++) {
        unsigned char c = (unsigned char)in[i];
        out[i] = (c >= 32 && c < 127 && c != '"') ? (char)c : '.';
    }
    out[n] = '\0';
}

/* --- shared resolution the Overview and Identity share ------------------- */

static void machine_model(char *out, long cap)
{
    long response = 0;
    long v;

    if (Gestalt('mnam', &response) == noErr && response != 0) {
        StringPtr name = (StringPtr)response;
        if (name[0] > 0) {
            long n = name[0] < cap - 1 ? name[0] : cap - 1;
            memcpy(out, name + 1, (size_t)n);
            out[n] = '\0';
            return;
        }
    }
    if (Gestalt(gestaltMachineType, &v) == noErr) {
        int i;
        for (i = 0; i < kNowMachineNameCount; ++i) {
            if (kNowMachineNames[i].id == v) {
                snprintf(out, cap, "%s", kNowMachineNames[i].name);
                return;
            }
        }
        snprintf(out, cap, "Unknown (id %ld)", v);
        return;
    }
    snprintf(out, cap, "Unknown");
}

static long gestalt_or(unsigned long sel, long fallback)
{
    long v;

    return (Gestalt((OSType)sel, &v) == noErr) ? v : fallback;
}

/* --- selectors: the documented Gestalt walk ----------------------------- */

static void gather_selectors(long cursor, CensusPage *page)
{
    int filled = 0;
    long i = (cursor < 0) ? 0 : cursor;

    page->total = kNowCensusSelectorCount;
    while (i < kNowCensusSelectorCount && filled < kCensusPageMax) {
        const NowCensusSelector *sel = &kNowCensusSelectors[i];
        long response = 0;

        i++;
        if (Gestalt((OSType)sel->selector, &response) == noErr) {
            char raw[24];
            char meaning[kCensusRowMeaningCap];

            snprintf(raw, sizeof raw, "$%08lX", (unsigned long)response);
            census_summarize(sel->kind, sel->selector,
                             (unsigned long)response, kNowCensusAttrBits,
                             kNowCensusAttrBitCount, meaning, sizeof meaning);
            set_row(&page->rows[filled], sel->name, raw, meaning);
            filled++;
        }
    }
    page->count = filled;
    if (i < kNowCensusSelectorCount) {
        page->more = 1;
        page->next_cursor = i;
    }
    if (filled == 0 && cursor == 0) {
        page->outcome = kCensusFailed;
        snprintf(page->note, sizeof page->note,
                 "the Gestalt Manager answered nothing");
    }
}

/* --- identity: the machine in a curated dozen --------------------------- */

static void identity_row(CensusPage *page, const char *label,
                         unsigned long sel, short kind)
{
    long v;
    char raw[24];
    char meaning[kCensusRowMeaningCap];

    if (Gestalt((OSType)sel, &v) != noErr) {
        return;
    }
    snprintf(raw, sizeof raw, "$%08lX", (unsigned long)v);
    census_summarize(kind, sel, (unsigned long)v, kNowCensusAttrBits,
                     kNowCensusAttrBitCount, meaning, sizeof meaning);
    set_row(&page->rows[page->count++], label, raw, meaning);
}

static void gather_identity(long cursor, CensusPage *page)
{
    char model[56];
    char clean[56];
    long ct;

    (void)cursor;                       /* identity is a single page */
    machine_model(model, sizeof model);
    sanitize(model, clean, sizeof clean);
    set_row(&page->rows[page->count++], "Model", clean, "this machine");

    ct = gestalt_or(gestaltNativeCPUtype, gestalt_or(gestaltProcessorType, 0));
    {
        char raw[24];
        char meaning[kCensusRowMeaningCap];
        snprintf(raw, sizeof raw, "$%08lX", (unsigned long)ct);
        snprintf(meaning, sizeof meaning, "CPU type %ld", ct);
        set_row(&page->rows[page->count++], "Processor", raw, meaning);
    }

    identity_row(page, "Clock", gestaltProcClkSpeed, kCensusSelHz);
    identity_row(page, "Physical RAM", gestaltPhysicalRAMSize, kCensusSelSize);
    identity_row(page, "Logical RAM", gestaltLogicalRAMSize, kCensusSelSize);
    identity_row(page, "ROM size", gestaltROMSize, kCensusSelSize);
    identity_row(page, "ROM version", gestaltROMVersion, kCensusSelNum);
    identity_row(page, "Mac OS", gestaltSystemVersion, kCensusSelVersion);
    identity_row(page, "CarbonLib", 'cbon', kCensusSelVersion);
    identity_row(page, "QuickDraw", gestaltQuickdrawVersion, kCensusSelVersion);
    identity_row(page, "Keyboard", gestaltKeyboardType, kCensusSelNum);
    identity_row(page, "AppleTalk", gestaltAppleTalkVersion, kCensusSelVersion);
    identity_row(page, "Open Transport", gestaltOpenTpt, kCensusSelNum);

    if (page->count == 0) {
        page->outcome = kCensusFailed;
        snprintf(page->note, sizeof page->note, "Gestalt answered nothing");
    }
}

/* --- overview: the synthesis, in plain words ---------------------------- */

static void caption(CensusPage *page, const char *title)
{
    set_row(&page->rows[page->count++], title, "", "");   /* empty = caption */
}

static void fact(CensusPage *page, const char *label, const char *value)
{
    set_row(&page->rows[page->count++], label, "", value);
}

static void gather_overview(long cursor, CensusPage *page)
{
    char model[56], clean[56], buf[80];
    long v;

    (void)cursor;

    caption(page, "Machine");
    machine_model(model, sizeof model);
    sanitize(model, clean, sizeof clean);
    fact(page, "   Model", clean);
    v = gestalt_or(gestaltProcClkSpeed, 0);
    if (v > 0) {
        snprintf(buf, sizeof buf, "%ld MHz", (v + 500000L) / 1000000L);
    } else {
        strcpy(buf, "unknown speed");
    }
    fact(page, "   Processor", buf);
    v = gestalt_or(gestaltROMSize, 0);
    snprintf(buf, sizeof buf, "%ld MB ROM", v / (1024L * 1024L));
    fact(page, "   ROM", buf);

    caption(page, "Memory");
    v = gestalt_or(gestaltPhysicalRAMSize, 0);
    snprintf(buf, sizeof buf, "%ld MB", v / (1024L * 1024L));
    fact(page, "   Installed RAM", buf);
    {
        long vm = gestalt_or(gestaltVMAttr, 0);
        fact(page, "   Virtual memory",
             (vm & (1L << gestaltVMPresent)) ? "on" : "off");
    }

    caption(page, "System");
    if (Gestalt(gestaltSystemVersion, &v) == noErr) {
        char reading[48];
        census_summarize(kCensusSelVersion, gestaltSystemVersion,
                         (unsigned long)v, kNowCensusAttrBits,
                         kNowCensusAttrBitCount, reading, sizeof reading);
        /* strip the leading "version " for the plain reading */
        fact(page, "   Mac OS",
             strncmp(reading, "version ", 8) == 0 ? reading + 8 : reading);
    }
    if (Gestalt('cbon', &v) == noErr) {
        char reading[48];
        census_summarize(kCensusSelVersion, 'cbon', (unsigned long)v,
                         kNowCensusAttrBits, kNowCensusAttrBitCount,
                         reading, sizeof reading);
        fact(page, "   CarbonLib",
             strncmp(reading, "version ", 8) == 0 ? reading + 8 : reading);
    }

    caption(page, "Display");
    {
        GDHandle gd = GetMainDevice();
        if (gd != NULL) {
            Rect r = (**gd).gdRect;
            PixMapHandle pm = (**gd).gdPMap;
            short depth = pm ? (**pm).pixelSize : 0;
            const char *colors = depth <= 8 ? "colors"
                : (depth == 16 ? "thousands of colors" : "millions of colors");
            if (depth <= 8) {
                snprintf(buf, sizeof buf, "%d x %d, %ld %s",
                         r.right - r.left, r.bottom - r.top, 1L << depth,
                         colors);
            } else {
                snprintf(buf, sizeof buf, "%d x %d, %s",
                         r.right - r.left, r.bottom - r.top, colors);
            }
            fact(page, "   Screen", buf);
        }
    }

    caption(page, "Storage");
    {
        long index = 1;
        while (page->count < kCensusPageMax) {
            HParamBlockRec pb;
            Str63 name;

            memset(&pb, 0, sizeof pb);
            name[0] = 0;
            pb.volumeParam.ioNamePtr = name;
            pb.volumeParam.ioVolIndex = (short)index;
            if (PBHGetVInfoSync(&pb) != noErr) {
                break;
            }
            {
                char vname[32], vlabel[kCensusRowNameCap];
                unsigned long total =
                    (unsigned long)pb.volumeParam.ioVNmAlBlks
                    * (unsigned long)pb.volumeParam.ioVAlBlkSiz;
                unsigned long freeb =
                    (unsigned long)pb.volumeParam.ioVFrBlk
                    * (unsigned long)pb.volumeParam.ioVAlBlkSiz;
                long n = name[0] < 31 ? name[0] : 31;

                memcpy(vname, name + 1, (size_t)n);
                vname[n] = '\0';
                sanitize(vname, clean, sizeof clean);
                snprintf(vlabel, sizeof vlabel, "   %.28s", clean);
                snprintf(buf, sizeof buf, "%lu MB, %lu MB free",
                         total / (1024UL * 1024UL),
                         freeb / (1024UL * 1024UL));
                fact(page, vlabel, buf);
            }
            index++;
        }
    }
    page->total = page->count;
}

/* --- video: the GDevice walk -------------------------------------------- */

static void gather_video(long cursor, CensusPage *page)
{
    GDHandle gd = GetDeviceList();
    GDHandle main_dev = GetMainDevice();
    long ordinal = 0;
    long target = (cursor < 0) ? 0 : cursor;

    while (gd != NULL && ordinal < target) {
        gd = GetNextDevice(gd);
        ordinal++;
    }
    if (gd == NULL) {
        if (cursor == 0) {
            page->outcome = kCensusAbsent;
            snprintf(page->note, sizeof page->note, "no graphics devices");
        }
        return;
    }
    {
        PixMapHandle pm = (**gd).gdPMap;
        Rect r = (**gd).gdRect;
        char name[24];
        char raw[kCensusRowRawCap];
        char meaning[kCensusRowMeaningCap];
        short depth = pm ? (**pm).pixelSize : 0;
        short rowbytes = pm ? (short)((**pm).rowBytes & 0x3FFF) : 0;

        snprintf(name, sizeof name, "Display %ld", ordinal + 1);
        set_row(&page->rows[page->count++], name,
                (gd == main_dev) ? "main" : "aux",
                (gd == main_dev) ? "main screen" : "secondary screen");

        snprintf(raw, sizeof raw, "%d,%d,%d,%d", r.top, r.left, r.bottom,
                 r.right);
        snprintf(meaning, sizeof meaning, "%d x %d pixels", r.right - r.left,
                 r.bottom - r.top);
        set_row(&page->rows[page->count++], "Bounds", raw, meaning);

        snprintf(raw, sizeof raw, "%d", depth);
        if (depth <= 8) {
            snprintf(meaning, sizeof meaning, "%ld colors", 1L << depth);
        } else if (depth == 16) {
            snprintf(meaning, sizeof meaning, "thousands (RGB555)");
        } else {
            snprintf(meaning, sizeof meaning, "millions (RGB888)");
        }
        set_row(&page->rows[page->count++], "Pixel size", raw, meaning);

        snprintf(raw, sizeof raw, "%d", rowbytes);
        snprintf(meaning, sizeof meaning, "%d bytes per row", rowbytes);
        set_row(&page->rows[page->count++], "Row bytes", raw, meaning);

        snprintf(raw, sizeof raw, "%d", (**gd).gdRefNum);
        set_row(&page->rows[page->count++], "Driver", raw, "driver refNum");
    }
    if (GetNextDevice(gd) != NULL) {
        page->more = 1;
        page->next_cursor = ordinal + 1;
    }
}

/* --- volumes: indexed PBHGetVInfo --------------------------------------- */

static void gather_volumes(long cursor, CensusPage *page)
{
    long index = (cursor <= 0) ? 1 : cursor;

    while (page->count < kCensusPageMax) {
        HParamBlockRec pb;
        Str63 name;

        memset(&pb, 0, sizeof pb);
        name[0] = 0;
        pb.volumeParam.ioNamePtr = name;
        pb.volumeParam.ioVRefNum = 0;
        pb.volumeParam.ioVolIndex = (short)index;
        if (PBHGetVInfoSync(&pb) != noErr) {
            break;
        }
        {
            char cname[32], clean[32];
            char label[kCensusRowNameCap];
            char raw[kCensusRowRawCap];
            char meaning[kCensusRowMeaningCap];
            unsigned long total = (unsigned long)pb.volumeParam.ioVNmAlBlks
                                  * (unsigned long)pb.volumeParam.ioVAlBlkSiz;
            unsigned long freeb = (unsigned long)pb.volumeParam.ioVFrBlk
                                  * (unsigned long)pb.volumeParam.ioVAlBlkSiz;
            long n = name[0] < 31 ? name[0] : 31;

            memcpy(cname, name + 1, (size_t)n);
            cname[n] = '\0';
            sanitize(cname, clean, sizeof clean);
            snprintf(label, sizeof label, "Volume %ld", index);
            snprintf(raw, sizeof raw, "%s", clean);
            snprintf(meaning, sizeof meaning, "%lu MB, %lu MB free",
                     total / (1024UL * 1024UL), freeb / (1024UL * 1024UL));
            set_row(&page->rows[page->count++], label, raw, meaning);
        }
        index++;
    }
    if (page->count == 0 && cursor <= 0) {
        page->outcome = kCensusAbsent;
        snprintf(page->note, sizeof page->note, "no mounted volumes");
        return;
    }
    {
        HParamBlockRec pb;
        Str63 name;
        memset(&pb, 0, sizeof pb);
        name[0] = 0;
        pb.volumeParam.ioNamePtr = name;
        pb.volumeParam.ioVolIndex = (short)index;
        if (PBHGetVInfoSync(&pb) == noErr) {
            page->more = 1;
            page->next_cursor = index;
        }
    }
}

/* --- drives: the low-memory drive queue --------------------------------- *
 * This toolchain's Carbon headers define QHdr but not DrvQEl, so the
 * element is laid out by hand. The QHdr at 0x0308 is qFlags(2), qHead(4),
 * qTail(4); the head pointer to the first element lives at 0x030A. Fields
 * past qLink are what a census reads. (Metal-confirmed reachable, spike
 * 2026-07-21.) */

typedef struct CensusDrvQEl {
    struct CensusDrvQEl *qLink;   /* 0 */
    short qType;                  /* 4 */
    short dQDrive;                /* 6 */
    short dQRefNum;               /* 8 */
    short dQFSID;                 /* 10 */
} CensusDrvQEl;

static void gather_drives(long cursor, CensusPage *page)
{
    CensusDrvQEl *el = *(CensusDrvQEl **)0x030A;
    long ordinal = 0;
    long target = (cursor < 0) ? 0 : cursor;

    while (el != NULL && ordinal < target) {
        el = el->qLink;
        ordinal++;
    }
    while (el != NULL && page->count < kCensusPageMax) {
        char label[kCensusRowNameCap];
        char raw[kCensusRowRawCap];
        char meaning[kCensusRowMeaningCap];

        snprintf(label, sizeof label, "Drive %d", el->dQDrive);
        snprintf(raw, sizeof raw, "ref %d fsid %d", el->dQRefNum,
                 el->dQFSID);
        snprintf(meaning, sizeof meaning, el->dQFSID == 0
                 ? "local HFS drive" : "external file system");
        set_row(&page->rows[page->count++], label, raw, meaning);
        el = el->qLink;
        ordinal++;
    }
    if (el != NULL) {
        page->more = 1;
        page->next_cursor = ordinal;
    }
    if (page->count == 0 && cursor == 0) {
        page->outcome = kCensusAbsent;
        snprintf(page->note, sizeof page->note, "the drive queue is empty");
    }
}

/* --- drivers: the Device Manager unit table ----------------------------- *
 * UTableBase (a DCtlHandle array) at 0x011C, count at 0x01D2. Each loaded
 * unit's DCtlEntry gives its flags and its DRVR; the driver name is a
 * Pascal string at offset 18 of the DRVR header. Read-only. */

static void driver_name(Ptr drvr, char *out, long cap)
{
    unsigned char *name;
    long n, i;

    if (drvr == NULL) {
        snprintf(out, cap, "(no name)");
        return;
    }
    name = (unsigned char *)drvr + 18;   /* drvrName in the DRVR header */
    n = name[0];
    if (n <= 0 || n > 40) {
        snprintf(out, cap, "(unnamed)");
        return;
    }
    if (n > cap - 1) {
        n = cap - 1;
    }
    for (i = 0; i < n; i++) {
        unsigned char c = name[1 + i];
        out[i] = (c >= 32 && c < 127) ? (char)c : '.';
    }
    out[n] = '\0';
}

static void gather_drivers(long cursor, CensusPage *page)
{
    DCtlHandle *base = *(DCtlHandle **)0x011C;
    short count = *(short *)0x01D2;
    long unit = (cursor < 0) ? 0 : cursor;

    if (base == NULL || count <= 0 || count > 512) {
        if (cursor == 0) {
            page->outcome = kCensusFailed;
            snprintf(page->note, sizeof page->note,
                     "unit table unreadable (count %d)", count);
        }
        return;
    }
    page->total = count;
    while (unit < count && page->count < kCensusPageMax) {
        DCtlHandle h = base[unit];
        long u = unit;

        unit++;
        if (h == NULL || *h == NULL) {
            continue;                 /* an empty unit-table slot */
        }
        {
            DCtlEntry *e = *h;
            char label[kCensusRowNameCap];
            char raw[kCensusRowRawCap];
            char meaning[kCensusRowMeaningCap];
            char name[32];
            unsigned short flags = (unsigned short)e->dCtlFlags;

            driver_name(e->dCtlDriver, name, sizeof name);
            snprintf(label, sizeof label, "%.24s", name);
            snprintf(raw, sizeof raw, "unit %ld ref %d", u, e->dCtlRefNum);
            {
                char words[48];
                census_dctl_flags(flags, words, sizeof words);
                snprintf(meaning, sizeof meaning, "%s%s",
                         (flags & 0x0040) ? "RAM: " : "ROM: ", words);
            }
            set_row(&page->rows[page->count++], label, raw, meaning);
        }
    }
    if (unit < count) {
        page->more = 1;
        page->next_cursor = unit;
    }
    if (page->count == 0 && cursor == 0) {
        page->outcome = kCensusAbsent;
        snprintf(page->note, sizeof page->note, "no loaded drivers");
    }
}

/* --- pram: the 20-byte SysParm copy ------------------------------------- *
 * On PowerPC there is no ReadXPRam trap, so the 20-byte low-memory SysParm
 * copy at 0x01F8 is all a census can reach: the outcome is `partial`. The
 * decoded spans come first, then the raw hex. (Spike-confirmed.) */

static void gather_pram(long cursor, CensusPage *page)
{
    const unsigned char *sp = (const unsigned char *)0x01F8;
    int off;

    (void)cursor;                       /* 20 bytes fit one page */
    for (off = 0; off < 20; off++) {
        const char *meaning = census_pram_meaning(off);
        char label[kCensusRowNameCap];
        char raw[kCensusRowRawCap];

        if (meaning[0] == '\0') {
            continue;                   /* only the named spans, decoded */
        }
        snprintf(label, sizeof label, "$%02X", off);
        snprintf(raw, sizeof raw, "%02X", sp[off]);
        set_row(&page->rows[page->count++], label, raw, meaning);
    }
    /* Then the raw bytes, eight per row, so nothing is hidden. */
    for (off = 0; off < 20 && page->count < kCensusPageMax; off += 8) {
        char label[kCensusRowNameCap];
        char raw[kCensusRowRawCap];
        char *p = raw;
        int i;

        snprintf(label, sizeof label, "raw $%02X", off);
        for (i = 0; i < 8 && off + i < 20; i++) {
            p += snprintf(p, 4, "%02X ", sp[off + i]);
        }
        set_row(&page->rows[page->count++], label, raw, "");
    }
    page->outcome = kCensusPartial;
    snprintf(page->note, sizeof page->note,
             "20 of 256 bytes - no XPRAM trap on this PowerPC");
}

/* --- adb: the ADB device table (resolved from InterfaceLib) -------------- *
 * The ADB Manager is Carbon-unavailable: GetIndADB is declared only as a
 * 68K trap, so it is resolved from InterfaceLib by name and called through
 * a pointer - a runtime call, never a strong import that would abort
 * launch. The spike proved CountADBs answers this way (2 devices, metal
 * 2026-07-21). ADBDataBlock is hand-defined because DeskBus.h is gated out
 * under Carbon. */

typedef struct {
    signed char devType;            /* handler id */
    signed char origADBAddr;        /* default address */
    Ptr serviceRtPtr;
    Ptr dataAreaAddr;
} CensusADBDataBlock;

typedef short (*CensusCountADBs)(void);
typedef short (*CensusGetIndADB)(CensusADBDataBlock *, short);

static CensusCountADBs g_count_adbs;
static CensusGetIndADB g_get_ind_adb;
static int g_adb_resolved;              /* 0 unknown, 1 yes, -1 no */

static void resolve_adb(void)
{
    CFragConnectionID conn = 0;
    Ptr mainAddr = NULL;
    Str255 err;
    Str255 pname;
    Ptr addr;
    CFragSymbolClass cls;

    if (g_adb_resolved != 0) {
        return;
    }
    g_adb_resolved = -1;
    CopyCStringToPascal("InterfaceLib", pname);
    if (GetSharedLibrary(pname, kPowerPCCFragArch, kReferenceCFrag,
                         &conn, &mainAddr, err) != noErr) {
        return;
    }
    CopyCStringToPascal("CountADBs", pname);
    if (FindSymbol(conn, pname, &addr, &cls) != noErr) {
        return;
    }
    g_count_adbs = (CensusCountADBs)addr;
    CopyCStringToPascal("GetIndADB", pname);
    if (FindSymbol(conn, pname, &addr, &cls) != noErr) {
        return;
    }
    g_get_ind_adb = (CensusGetIndADB)addr;
    g_adb_resolved = 1;
}

static void gather_adb(long cursor, CensusPage *page)
{
    short count, i;

    (void)cursor;
    resolve_adb();
    if (g_adb_resolved != 1) {
        page->outcome = kCensusRefused;
        snprintf(page->note, sizeof page->note,
                 "the ADB Manager is not exported here");
        return;
    }
    count = g_count_adbs();
    for (i = 1; i <= count && page->count < kCensusPageMax; i++) {
        CensusADBDataBlock blk;
        short addr;
        char label[kCensusRowNameCap];
        char raw[kCensusRowRawCap];
        char meaning[kCensusRowMeaningCap];

        memset(&blk, 0, sizeof blk);
        addr = g_get_ind_adb(&blk, i);
        snprintf(label, sizeof label, "Device %d", i);
        snprintf(raw, sizeof raw, "addr %d handler %d", addr,
                 (int)blk.devType);
        census_adb_device(blk.origADBAddr, blk.devType, meaning,
                          sizeof meaning);
        set_row(&page->rows[page->count++], label, raw, meaning);
    }
    if (page->count == 0) {
        page->outcome = kCensusAbsent;
        snprintf(page->note, sizeof page->note, "no ADB devices");
    }
}

/* --- scsi: the INQUIRY bus scan (SCSI Manager v1, resolved) -------------- *
 * THE ONE active-I/O probe. Gated on gestaltHardwareAttr saying a bus
 * exists (answering `absent` otherwise), it selects each target and issues
 * INQUIRY through v1 entry points resolved from InterfaceLib (SCSIBusReset
 * is absent on this machine and not used). One target per page, so a
 * wedged target stalls at most one frame turnaround. Builds-only until an
 * attended metal run - active bus I/O cannot be proven in the emulator.
 * gestalt bit 7 = gestaltHasSCSI. */

typedef OSErr (*CensusSCSIGet)(void);
typedef OSErr (*CensusSCSISelect)(short);
typedef OSErr (*CensusSCSICmd)(Ptr, short);
typedef OSErr (*CensusSCSIRead)(Ptr);
typedef OSErr (*CensusSCSIComplete)(short *, short *, unsigned long);

static CensusSCSIGet g_scsi_get;
static CensusSCSISelect g_scsi_select;
static CensusSCSICmd g_scsi_cmd;
static CensusSCSIRead g_scsi_read;
static CensusSCSIComplete g_scsi_complete;
static int g_scsi_resolved;

static Ptr resolve_one(CFragConnectionID conn, const char *sym)
{
    Str255 pname;
    Ptr addr = NULL;
    CFragSymbolClass cls;

    CopyCStringToPascal(sym, pname);
    if (FindSymbol(conn, pname, &addr, &cls) != noErr) {
        return NULL;
    }
    return addr;
}

static void resolve_scsi(void)
{
    CFragConnectionID conn = 0;
    Ptr mainAddr = NULL;
    Str255 err;
    Str255 pname;

    if (g_scsi_resolved != 0) {
        return;
    }
    g_scsi_resolved = -1;
    CopyCStringToPascal("InterfaceLib", pname);
    if (GetSharedLibrary(pname, kPowerPCCFragArch, kReferenceCFrag,
                         &conn, &mainAddr, err) != noErr) {
        return;
    }
    g_scsi_get = (CensusSCSIGet)resolve_one(conn, "SCSIGet");
    g_scsi_select = (CensusSCSISelect)resolve_one(conn, "SCSISelect");
    g_scsi_cmd = (CensusSCSICmd)resolve_one(conn, "SCSICmd");
    g_scsi_read = (CensusSCSIRead)resolve_one(conn, "SCSIRead");
    g_scsi_complete = (CensusSCSIComplete)resolve_one(conn, "SCSIComplete");
    if (g_scsi_get && g_scsi_select && g_scsi_cmd && g_scsi_read
        && g_scsi_complete) {
        g_scsi_resolved = 1;
    }
}

/* One target: select, INQUIRY, read 36 bytes. Returns 1 with a row filled,
   0 if the target did not respond (absent). Never resets the bus. */
/* Completion waits are a CAP, not a fixed delay - a live target answers in
   milliseconds. But an ABSENT target's select fails, and calling complete
   with a long wait then burns the whole timeout with nothing pending: at
   300 ticks x 7 targets that was the ~35 s freeze. The cleanup wait is
   short; the real read gets a modest cap. */
enum { kScsiReadWait = 60, kScsiCleanupWait = 2 };

static int scsi_inquire(short id, CensusRow *row)
{
    unsigned char cdb[6];
    unsigned char data[36];
    SCSIInstr tib[2];
    short stat = 0, msg = 0;
    char vendor[9], product[17], rev[5];
    int i;

    if (g_scsi_get() != noErr) {
        return 0;                     /* could not arbitrate for the bus */
    }
    if (g_scsi_select(id) != noErr) {
        g_scsi_complete(&stat, &msg, kScsiCleanupWait);
        return 0;                     /* no target at this id */
    }
    memset(cdb, 0, sizeof cdb);
    cdb[0] = 0x12;                    /* INQUIRY */
    cdb[4] = 36;                      /* allocation length */
    memset(data, 0, sizeof data);
    tib[0].scOpcode = scInc;
    tib[0].scParam1 = (long)data;
    tib[0].scParam2 = sizeof data;
    tib[1].scOpcode = scStop;
    tib[1].scParam1 = 0;
    tib[1].scParam2 = 0;
    if (g_scsi_cmd((Ptr)cdb, sizeof cdb) != noErr) {
        g_scsi_complete(&stat, &msg, kScsiCleanupWait);
        return 0;
    }
    g_scsi_read((Ptr)tib);
    g_scsi_complete(&stat, &msg, kScsiReadWait);

    for (i = 0; i < 8; i++) {
        unsigned char c = data[8 + i];
        vendor[i] = (c >= 32 && c < 127) ? (char)c : ' ';
    }
    vendor[8] = '\0';
    for (i = 0; i < 16; i++) {
        unsigned char c = data[16 + i];
        product[i] = (c >= 32 && c < 127) ? (char)c : ' ';
    }
    product[16] = '\0';
    for (i = 0; i < 4; i++) {
        unsigned char c = data[32 + i];
        rev[i] = (c >= 32 && c < 127) ? (char)c : ' ';
    }
    rev[4] = '\0';

    {
        static const char *const types[] = {
            "disk", "tape", "printer", "processor", "WORM", "CD-ROM",
            "scanner", "optical", "changer", "comms"
        };
        int t = data[0] & 0x1F;
        const char *tn = (t < 10) ? types[t] : "device";
        char raw[kCensusRowRawCap];
        char meaning[kCensusRowMeaningCap];

        snprintf(raw, sizeof raw, "id %d type %d", id, t);
        snprintf(meaning, sizeof meaning, "%s: %.8s %.16s %.4s", tn, vendor,
                 product, rev);
        {
            char label[kCensusRowNameCap];
            snprintf(label, sizeof label, "Target %d", id);
            strncpy(row->name, label, sizeof row->name - 1);
            row->name[sizeof row->name - 1] = '\0';
        }
        strncpy(row->raw, raw, sizeof row->raw - 1);
        row->raw[sizeof row->raw - 1] = '\0';
        strncpy(row->meaning, meaning, sizeof row->meaning - 1);
        row->meaning[sizeof row->meaning - 1] = '\0';
    }
    return 1;
}

static void gather_scsi(long cursor, CensusPage *page)
{
    long hw = 0;
    short id = (short)((cursor < 0) ? 0 : cursor);

    /* The machine's own answer first: no bus means absent, not an error,
       and never a select into hardware that is not there. */
    if (Gestalt(gestaltHardwareAttr, &hw) != noErr
        || (hw & (1L << 7)) == 0) {         /* gestaltHasSCSI */
        page->outcome = kCensusAbsent;
        snprintf(page->note, sizeof page->note, "no SCSI bus on this Mac");
        return;
    }
    resolve_scsi();
    if (g_scsi_resolved != 1) {
        page->outcome = kCensusRefused;
        snprintf(page->note, sizeof page->note,
                 "SCSI Manager v1 not exported here");
        return;
    }
    page->total = 7;
    if (id <= 6) {                            /* one target per page */
        if (scsi_inquire(id, &page->rows[page->count])) {
            page->count++;
        }
        if (id < 6) {
            page->more = 1;
            page->next_cursor = id + 1;
        }
    }
    if (page->count == 0 && !page->more && cursor == 0) {
        page->outcome = kCensusAbsent;
        snprintf(page->note, sizeof page->note, "bus present, no targets");
    }
}

/* --- dispatch ----------------------------------------------------------- */

static const struct {
    const char *name;
    void (*gather)(long cursor, CensusPage *page);
} k_probes[] = {
    { "overview",  gather_overview },
    { "identity",  gather_identity },
    { "selectors", gather_selectors },
    { "video",     gather_video },
    { "volumes",   gather_volumes },
    { "drives",    gather_drives },
    { "drivers",   gather_drivers },
    { "adb",       gather_adb },
    { "pram",      gather_pram },
    { "scsi",      gather_scsi },
};

#define kProbeCount ((int)(sizeof k_probes / sizeof k_probes[0]))

int now_census_probe_count(void)
{
    return kProbeCount;
}

const char *now_census_probe_name(int index)
{
    if (index < 0 || index >= kProbeCount) {
        return NULL;
    }
    return k_probes[index].name;
}

int now_census_gather(const char *probe, long cursor, CensusPage *out)
{
    int i;

    page_init(out);
    for (i = 0; i < kProbeCount; i++) {
        if (strcmp(probe, k_probes[i].name) == 0) {
            k_probes[i].gather(cursor, out);
            return 0;
        }
    }
    return -1;
}

/* --- detail for the pane ------------------------------------------------ */

static const NowCensusSelector *find_selector(const char *name)
{
    int i;

    for (i = 0; i < kNowCensusSelectorCount; i++) {
        if (strcmp(kNowCensusSelectors[i].name, name) == 0) {
            return &kNowCensusSelectors[i];
        }
    }
    return NULL;
}

int now_census_row_detail(const char *probe, const char *row_name,
                          const char *raw, char *out, int max_lines,
                          long line_cap)
{
    if (strcmp(probe, "selectors") == 0 || strcmp(probe, "identity") == 0) {
        const NowCensusSelector *sel = find_selector(row_name);
        unsigned long value = 0;

        /* raw arrives as "$XXXXXXXX" for a selector row; parse it back. */
        if (raw != NULL && raw[0] == '$') {
            sscanf(raw + 1, "%lx", &value);
        }
        if (sel != NULL) {
            return census_detail(sel, value, kNowCensusAttrBits,
                                 kNowCensusAttrBitCount, out, max_lines,
                                 line_cap);
        }
        /* identity rows without a 1:1 selector (Model, Processor): show raw */
        if (raw != NULL && raw[0] != '\0') {
            snprintf(out, (size_t)line_cap, "Raw  %s", raw);
            return 1;
        }
        return 0;
    }
    if (strcmp(probe, "overview") == 0) {
        /* An Overview fact keeps its trail: name what it was read from. */
        int n = 0;
#define OUTLINE(s) do { if (n < max_lines) { \
        snprintf(out + (long)n * line_cap, (size_t)line_cap, "%s", s); n++; } \
    } while (0)
        if (row_name[0] != ' ') {
            return 0;                   /* a caption has no detail */
        }
        OUTLINE("A synthesized fact - the probes below are its source.");
        OUTLINE("");
        if (strstr(row_name, "Model")) {
            OUTLINE("From Gestalt 'mnam' (user-visible name), falling back");
            OUTLINE("to 'mach' against the machine-name table.");
        } else if (strstr(row_name, "Processor")) {
            OUTLINE("From 'cput' NativeCPUtype and 'pclk' ProcessorClkSpeed.");
        } else if (strstr(row_name, "RAM") || strstr(row_name, "ROM")) {
            OUTLINE("From the 'ram '/'rom ' size selectors.");
        } else if (strstr(row_name, "Mac OS")) {
            OUTLINE("From 'sysv' SystemVersion.");
        } else if (strstr(row_name, "CarbonLib")) {
            OUTLINE("From 'cbon' CarbonVersion.");
        } else if (strstr(row_name, "Screen")) {
            OUTLINE("From the main GDevice: gdRect and the PixMap depth.");
        } else if (strstr(row_name, "memory")) {
            OUTLINE("From 'vm  ' VMAttr, the VMPresent bit.");
        } else {
            OUTLINE("From the Volumes probe (indexed PBHGetVInfo).");
        }
#undef OUTLINE
        return n;
    }
    /* video / volumes: the row already shows raw and meaning; the pane can
       still restate the raw for a selected row. */
    if (raw != NULL && raw[0] != '\0') {
        snprintf(out, (size_t)line_cap, "Raw  %s", raw);
        return 1;
    }
    return 0;
}
