#include "census_decode.h"

#include <stdio.h>
#include <string.h>

/* Append into a fixed line, honestly truncating rather than overflowing. */
static void cat(char *dst, long cap, long *pos, const char *s)
{
    long n = (long)strlen(s);

    if (*pos + n >= cap) {
        n = cap - *pos - 1;
    }
    if (n > 0) {
        memcpy(dst + *pos, s, (size_t)n);
        *pos += n;
    }
    dst[*pos] = '\0';
}

/* A value that reads as printable ASCII fourcc, shown as 'abcd'. */
static int fourcc(unsigned long v, char *out)
{
    int i;
    unsigned char b[4];

    b[0] = (unsigned char)((v >> 24) & 0xFF);
    b[1] = (unsigned char)((v >> 16) & 0xFF);
    b[2] = (unsigned char)((v >> 8) & 0xFF);
    b[3] = (unsigned char)(v & 0xFF);
    for (i = 0; i < 4; i++) {
        if (b[i] < 32 || b[i] > 126) {
            return 0;
        }
    }
    out[0] = '\''; out[1] = (char)b[0]; out[2] = (char)b[1];
    out[3] = (char)b[2]; out[4] = (char)b[3]; out[5] = '\''; out[6] = '\0';
    return 1;
}

static void emit_version(unsigned long maj, unsigned long minor,
                         unsigned long bug, char *out, long cap)
{
    if (bug != 0) {
        snprintf(out, cap, "version %lu.%lu.%lu", maj, minor, bug);
    } else {
        snprintf(out, cap, "version %lu.%lu", maj, minor);
    }
}

/* Gestalt version words come three ways, and conflating them is the
   ATSUVersion-class bug. Distinguish by shape:
     <= 0xFFFF          BCD low word     0x0921 -> 9.2.1  (SystemVersion)
     high byte nonzero  NumVersion       0x06508000 -> 6.5 (QuickTime)
     else (0x00mm0000)  16.16 split      0x00060000 -> 6.0 (ATSU)
   The detail pane shows the raw so a fourth encoding is never silently
   wrong - it just reads oddly, and the number is right there. */
static void version_text(unsigned long raw, char *out, long cap)
{
    unsigned long hi = (raw >> 24) & 0xFF;

    if (raw <= 0xFFFF) {
        unsigned long hb = (raw >> 8) & 0xFF;             /* BCD major byte */
        unsigned long maj = ((hb >> 4) * 10) + (hb & 0x0F);
        if (maj == 0) {
            snprintf(out, cap, "%lu", raw);
            return;
        }
        emit_version(maj, (raw >> 4) & 0x0F, raw & 0x0F, out, cap);
        return;
    }
    if (hi != 0) {                                         /* NumVersion */
        unsigned long maj = ((hi >> 4) * 10) + (hi & 0x0F);
        unsigned long mb = (raw >> 16) & 0xFF;
        emit_version(maj, (mb >> 4) & 0x0F, mb & 0x0F, out, cap);
        return;
    }
    /* high byte zero but more than a low word: major.minor in 16-bit halves */
    emit_version((raw >> 16) & 0xFFFF, (raw >> 8) & 0xFF, 0, out, cap);
}

static void size_text(unsigned long raw, char *out, long cap)
{
    if (raw >= 1024UL * 1024UL) {
        snprintf(out, cap, "%lu MB", raw / (1024UL * 1024UL));
    } else if (raw >= 1024UL) {
        snprintf(out, cap, "%lu KB", raw / 1024UL);
    } else {
        snprintf(out, cap, "%lu bytes", raw);
    }
}

/* The bit name for (selector, bit), or NULL when the table has none. */
static const char *bit_name(unsigned long selector, int bit,
                            const NowCensusAttrBit *bits, int nbits)
{
    int i;

    for (i = 0; i < nbits; i++) {
        if (bits[i].selector == selector && bits[i].bit == bit) {
            return bits[i].name;
        }
    }
    return NULL;
}

void census_summarize(short kind, unsigned long selector, unsigned long raw,
                      const NowCensusAttrBit *bits, int nbits,
                      char *out, long cap)
{
    switch (kind) {
    case kCensusSelVersion:
        version_text(raw, out, cap);
        return;
    case kCensusSelSize:
        size_text(raw, out, cap);
        return;
    case kCensusSelCount:
        snprintf(out, cap, "%lu", raw);
        return;
    case kCensusSelHz:
        snprintf(out, cap, "%lu MHz", (raw + 500000UL) / 1000000UL);
        return;
    case kCensusSelAddr:
        snprintf(out, cap, "$%08lX", raw);
        return;
    case kCensusSelAttr: {
        /* Name the first couple of set bits, then "+ N more"; the pane
           lists them all. Unknown set bits still count toward the total,
           so nothing is hidden. */
        long pos = 0;
        int named = 0, total = 0, bit;
        char first[80];

        first[0] = '\0';
        for (bit = 0; bit < 32; bit++) {
            const char *nm;

            if (((raw >> bit) & 1UL) == 0) {
                continue;
            }
            total++;
            nm = bit_name(selector, bit, bits, nbits);
            if (named < 2) {
                long fp = (long)strlen(first);

                if (named > 0) {
                    cat(first, (long)sizeof first, &fp, ", ");
                }
                if (nm != NULL) {
                    cat(first, (long)sizeof first, &fp, nm);
                } else {
                    char b[16];
                    snprintf(b, sizeof b, "bit %d", bit);
                    cat(first, (long)sizeof first, &fp, b);
                }
                named++;
            }
        }
        if (total == 0) {
            snprintf(out, cap, "no bits set");
            return;
        }
        cat(out, cap, &pos, first);
        if (total > named) {
            char more[24];
            snprintf(more, sizeof more, " + %d more", total - named);
            cat(out, cap, &pos, more);
        }
        return;
    }
    default:
        if (fourcc(raw, out) && raw > 0x20202020UL) {
            return;
        }
        snprintf(out, cap, "%lu", raw);
        return;
    }
}

int census_detail(const NowCensusSelector *sel, unsigned long raw,
                  const NowCensusAttrBit *bits, int nbits,
                  char *out, int max_lines, long line_cap)
{
    int n = 0;
    char four[8];

#define LINE(i) (out + (long)(i) * line_cap)
#define EMIT(fmt, ...)                                              \
    do {                                                           \
        if (n < max_lines) {                                       \
            snprintf(LINE(n), (size_t)line_cap, fmt, __VA_ARGS__); \
            n++;                                                   \
        }                                                          \
    } while (0)

    if (fourcc(sel->selector, four)) {
        EMIT("%s  %s", four, sel->name);
    } else {
        EMIT("$%08lX  %s", sel->selector, sel->name);
    }
    if (sel->comment != NULL && sel->comment[0] != '\0') {
        EMIT("%s", sel->comment);
    }
    EMIT("Raw  $%08lX   (%lu)", raw, raw);

    if (sel->kind == kCensusSelAttr) {
        int bit, total = 0, unknown = 0;

        for (bit = 0; bit < 32; bit++) {
            const char *nm;

            if (((raw >> bit) & 1UL) == 0) {
                continue;
            }
            total++;
            nm = bit_name(sel->selector, bit, bits, nbits);
            if (nm != NULL) {
                EMIT("bit %-2d  %s", bit, nm);
            } else {
                EMIT("bit %-2d  unrecognized (candidate)", bit);
                unknown++;
            }
        }
        if (total == 0) {
            EMIT("%s", "no bits set");
        } else if (unknown == 0) {
            EMIT("%d bits clear - every set bit recognized", 32 - total);
        } else {
            EMIT("%d set, %d unrecognized - kept as candidates",
                 total, unknown);
        }
    } else {
        char reading[80];

        census_summarize(sel->kind, sel->selector, raw, bits, nbits,
                         reading, (long)sizeof reading);
        EMIT("Reading  %s", reading);
    }
#undef EMIT
#undef LINE
    return n;
}

/* --- slice-2 probe decoders --------------------------------------------- */

void census_dctl_flags(unsigned short flags, char *out, long cap)
{
    static const struct { unsigned short mask; const char *name; } k[] = {
        { 0x0020, "open" },
        { 0x0040, "RAM-based" },
        { 0x0080, "active" },
        { 0x0100, "reads" },
        { 0x0200, "writes" },
        { 0x0400, "controls" },
        { 0x0800, "status" },
        { 0x2000, "needs time" },
        { 0x4000, "needs lock" }
    };
    long pos = 0;
    int i, first = 1;

    out[0] = '\0';
    for (i = 0; i < (int)(sizeof k / sizeof k[0]); i++) {
        if ((flags & k[i].mask) == 0) {
            continue;
        }
        if (!first) {
            cat(out, cap, &pos, ", ");
        }
        cat(out, cap, &pos, k[i].name);
        first = 0;
    }
    if (first) {
        cat(out, cap, &pos, "closed");
    }
}

void census_adb_device(int default_address, int handler_id, char *out,
                       long cap)
{
    const char *kind;

    switch (default_address) {
    case 1: kind = "protocol adapter"; break;
    case 2: kind = "keyboard"; break;
    case 3: kind = "mouse (relative)"; break;
    case 4: kind = "tablet (absolute)"; break;
    case 5: kind = "modem"; break;
    case 7: kind = "misc device"; break;
    default: kind = NULL; break;
    }
    if (kind != NULL) {
        snprintf(out, cap, "%s, handler %d", kind, handler_id);
    } else {
        snprintf(out, cap, "address %d, handler %d", default_address,
                 handler_id);
    }
}

void census_ata_string(const unsigned char *id, int word_start,
                       int word_count, char *out, long cap)
{
    long n = 0;
    int i, last;

    for (i = 0; i < word_count && n + 2 < cap; i++) {
        int b = (word_start + i) * 2;
        /* the two chars of a word are stored swapped */
        out[n++] = (char)id[b + 1];
        out[n++] = (char)id[b];
    }
    out[n] = '\0';
    /* printable-only, then trim trailing spaces */
    for (i = 0; i < n; i++) {
        unsigned char c = (unsigned char)out[i];
        if (c < 32 || c > 126) {
            out[i] = ' ';
        }
    }
    last = (int)n - 1;
    while (last >= 0 && out[last] == ' ') {
        out[last--] = '\0';
    }
}

void census_battery_flags(unsigned char flags, char *out, long cap)
{
    int installed = (flags & (1 << 7)) != 0;
    int charging = (flags & (1 << 6)) != 0;
    int charger = (flags & (1 << 5)) != 0;

    if (!installed) {
        snprintf(out, cap, "no battery");
        return;
    }
    if (charging) {
        snprintf(out, cap, "charging");
    } else if (charger) {
        snprintf(out, cap, "on charger");
    } else {
        snprintf(out, cap, "on battery");
    }
}

const char *census_pram_meaning(int offset)
{
    /* The well-known bytes of the classic 20-byte SysParm block. */
    switch (offset) {
    case 0:  return "valid marker";
    case 1:  return "AppleTalk node hint, port A";
    case 2:  return "AppleTalk node hint, port B";
    case 3:  return "serial port use";
    case 4:  return "port A configuration";
    case 6:  return "port B configuration";
    case 8:  return "alarm setting";
    case 12: return "application font";
    case 14: return "keyboard and print flags";
    case 16: return "volume, click, caret";
    case 18: return "misc flags";
    default: return "";
    }
}
