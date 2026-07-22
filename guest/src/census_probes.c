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
