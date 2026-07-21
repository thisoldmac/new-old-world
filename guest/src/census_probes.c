/* census_probes.c - the Toolbox side of the hardware census.
 *
 * Slice 1 probes, all Carbon-clean or low-memory reads (no InterfaceLib
 * symbols): the Gestalt selector-table walk, the GDevice video walk,
 * mounted volumes via indexed PBHGetVInfo, and the drive queue. Each is a
 * read-only walk of a table the OS maintains; failures are data (an empty
 * surface is `absent`, never an error), and every value keeps its raw form
 * beside the decoded meaning.
 *
 * Paging discipline (contract: censusExchange): now_census_gather fills at
 * most kCensusPageMax rows per call and reports whether more follow, so a
 * request never does more than a page of work. The cursor is a probe-
 * private index; 0 starts the probe over.
 *
 * The wire encoding lives entirely in census_report.c (pure, native-
 * tested). This file only fills CensusRow structs. */

#include "census.h"
#include "census_selectors.h"

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

/* Printable ASCII in place of; controls and quotes become '.'. Keeps a raw
   fourcc or name greppable without breaking the JSON string. */
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

/* A Gestalt selector is a four-char code; show it as text when printable,
   else as hex. */
static void fourcc_text(unsigned long code, char *out, long cap)
{
    char raw[5];

    raw[0] = (char)((code >> 24) & 0xFF);
    raw[1] = (char)((code >> 16) & 0xFF);
    raw[2] = (char)((code >> 8) & 0xFF);
    raw[3] = (char)(code & 0xFF);
    raw[4] = '\0';
    sanitize(raw, out, cap);
}

/* --- gestalt: the documented selector-table walk ------------------------ */

/* Decode meaning by selector kind; raw is always the untouched response. */
static void decode_selector(const NowCensusSelector *sel, long response,
                            char *meaning, long cap)
{
    int i;

    switch (sel->kind) {
    case kCensusSelVersion: {
        /* BCD MMmp in the low word - the shape gestaltSystemVersion uses. */
        long maj = (response >> 8) & 0xFF;
        long min = (response >> 4) & 0x0F;
        long bug = response & 0x0F;
        if (maj > 0 && maj < 0x30) {
            snprintf(meaning, cap, "version %ld.%ld.%ld", maj, min, bug);
            return;
        }
        snprintf(meaning, cap, "%ld", response);
        return;
    }
    case kCensusSelSize:
        if (response >= 1024L * 1024L) {
            snprintf(meaning, cap, "%ld MB", response / (1024L * 1024L));
        } else if (response >= 1024L) {
            snprintf(meaning, cap, "%ld KB", response / 1024L);
        } else {
            snprintf(meaning, cap, "%ld bytes", response);
        }
        return;
    case kCensusSelCount:
        snprintf(meaning, cap, "%ld", response);
        return;
    case kCensusSelAddr:
        snprintf(meaning, cap, "$%08lX", (unsigned long)response);
        return;
    case kCensusSelAttr: {
        /* Name the known bits; call out unknown set bits by number rather
           than dropping them - the unresolved bin the corpus grows from. */
        char part[kCensusRowMeaningCap];
        long pos = 0;
        int bit;
        int named = 0;

        meaning[0] = '\0';
        for (bit = 0; bit < 32; bit++) {
            const char *label = NULL;
            char fallback[16];

            if (((response >> bit) & 1L) == 0) {
                continue;
            }
            for (i = 0; i < kNowCensusAttrBitCount; i++) {
                if (kNowCensusAttrBits[i].selector == sel->selector
                    && kNowCensusAttrBits[i].bit == bit) {
                    label = kNowCensusAttrBits[i].name;
                    break;
                }
            }
            if (label == NULL) {
                snprintf(fallback, sizeof fallback, "bit %d?", bit);
                label = fallback;
            }
            snprintf(part, sizeof part, "%s%s", named ? ", " : "", label);
            if (pos + (long)strlen(part) >= cap) {
                break;
            }
            strcpy(meaning + pos, part);
            pos += (long)strlen(part);
            named = 1;
        }
        if (!named) {
            snprintf(meaning, cap, "no bits set");
        }
        return;
    }
    default:
        /* Plain number, but a value that reads as a fourcc is worth showing
           as one (many selectors answer with a signature code). */
        if (response > 0x20202020 && response <= 0x7E7E7E7E) {
            char text[8];
            fourcc_text((unsigned long)response, text, sizeof text);
            snprintf(meaning, cap, "'%s'", text);
        } else {
            snprintf(meaning, cap, "%ld", response);
        }
        return;
    }
}

static void gather_gestalt(long cursor, CensusPage *page)
{
    int filled = 0;
    long i = cursor;

    if (cursor < 0) {
        i = 0;
    }
    page->total = kNowCensusSelectorCount;
    /* Walk from the cursor, skipping selectors this machine does not
       answer, until the page is full or the table ends. */
    while (i < kNowCensusSelectorCount && filled < kCensusPageMax) {
        const NowCensusSelector *sel = &kNowCensusSelectors[i];
        long response = 0;
        i++;
        if (Gestalt((OSType)sel->selector, &response) == noErr) {
            char raw[24];
            char meaning[kCensusRowMeaningCap];
            snprintf(raw, sizeof raw, "$%08lX", (unsigned long)response);
            decode_selector(sel, response, meaning, sizeof meaning);
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

/* --- video: the GDevice walk -------------------------------------------- */

/* One display fills several rows; page by display, emitting a fixed set of
   fields each. cursor = next display ordinal. */
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
        snprintf(meaning, sizeof meaning, "driver refNum");
        set_row(&page->rows[page->count++], "Driver", raw, meaning);
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
        OSErr err;

        memset(&pb, 0, sizeof pb);
        name[0] = 0;
        pb.volumeParam.ioNamePtr = name;
        pb.volumeParam.ioVRefNum = 0;
        pb.volumeParam.ioVolIndex = (short)index;
        err = PBHGetVInfoSync(&pb);
        if (err != noErr) {
            break;              /* ran off the end of the mounted set */
        }
        {
            char cname[32];
            char label[kCensusRowNameCap];
            char raw[kCensusRowRawCap];
            char meaning[kCensusRowMeaningCap];
            unsigned long total = (unsigned long)pb.volumeParam.ioVNmAlBlks
                                  * (unsigned long)pb.volumeParam.ioVAlBlkSiz;
            unsigned long freeb = (unsigned long)pb.volumeParam.ioVFrBlk
                                  * (unsigned long)pb.volumeParam.ioVAlBlkSiz;
            long n = name[0];

            if (n > (long)sizeof cname - 1) {
                n = sizeof cname - 1;
            }
            memcpy(cname, name + 1, (size_t)n);
            cname[n] = '\0';
            snprintf(label, sizeof label, "Volume %ld", index);
            {
                char clean[32];
                sanitize(cname, clean, sizeof clean);
                snprintf(raw, sizeof raw, "%s", clean);
            }
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
    /* Probe one past to learn whether a full page has a successor. */
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

/* The drive queue (LMGetDrvQHdr / DrvQEl) is not exposed by this toolchain's
   Universal Interfaces - it is a raw low-memory read at 0x0308, which puts
   it with the InterfaceLib/low-memory probes (adb, drivers, pram, scsi) in
   the next slice rather than the Carbon-clean set here. */

/* --- dispatch ----------------------------------------------------------- */

static const struct {
    const char *name;
    void (*gather)(long cursor, CensusPage *page);
} k_probes[] = {
    { "gestalt", gather_gestalt },
    { "video",   gather_video },
    { "volumes", gather_volumes },
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
    return -1;                  /* caller answers refused / unknown probe */
}
