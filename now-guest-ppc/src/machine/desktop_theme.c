#include "desktop.h"

#include <Carbon.h>

#include <stdio.h>
#include <string.h>

/* Asking the running machine what its desktop is.
 *
 * The route, and the two that are not available:
 *
 *   - LMGetDeskCPat / SetDeskCPat are NOT in Carbon. Low-memory desk
 *     pattern accessors did not survive the transition, and there is no
 *     Carbon replacement that hands back the bits.
 *   - The `ppat` 16 resource is a shipped DEFAULT. Under Appearance the
 *     desktop is chosen elsewhere, so that resource never moves off its
 *     factory value - reading it answers a question nobody asked.
 *
 * What IS available is the Appearance Manager's theme collection.
 * GetTheme() fills a Collection with the theme's settings, and the four
 * desktop tags in it say what the desktop is drawn from. They are in the
 * headers' SECOND tag group, which the comment there marks as Mac OS 9
 * only - which is this guest's whole world, but it is also why every one
 * of them is read as "may be absent" rather than assumed present.
 *
 * Everything below records the RAW value beside the decoded one. This
 * project has decoded an OSType wrongly before and shipped the result as
 * a fact; a four-char tag and a byte count survive being misunderstood,
 * a sentence does not. */

enum { kThemeTagScratch = 1024 };

static void fourcc_text(OSType code, char *out, long cap)
{
    unsigned char c[4];

    c[0] = (unsigned char)((code >> 24) & 0xFF);
    c[1] = (unsigned char)((code >> 16) & 0xFF);
    c[2] = (unsigned char)((code >> 8) & 0xFF);
    c[3] = (unsigned char)(code & 0xFF);
    /* A tag whose bytes are not printable is shown as its number. The
       alternative - drawing control bytes into a JSON string - is the
       defect class this guest already validates titles against. */
    if (c[0] >= 0x20 && c[0] < 0x7F && c[1] >= 0x20 && c[1] < 0x7F &&
        c[2] >= 0x20 && c[2] < 0x7F && c[3] >= 0x20 && c[3] < 0x7F) {
        snprintf(out, cap, "%c%c%c%c", c[0], c[1], c[2], c[3]);
    } else {
        snprintf(out, cap, "0x%08lx", (unsigned long)code);
    }
}

/* A Str255 out of a collection item. The item's stored size is the truth
   about how many bytes there are; the length byte is the truth about how
   many of them are text, and the two disagreeing is a real possibility we
   clamp rather than trust. */
static void pstring_text(const unsigned char *data, long size,
                         char *out, long cap)
{
    long len;
    long i;
    long pos = 0;

    if (size <= 0) {
        out[0] = '\0';
        return;
    }
    len = data[0];
    if (len > size - 1) {
        len = size - 1;
    }
    for (i = 0; i < len && pos < cap - 1; i++) {
        unsigned char ch = data[1 + i];

        /* Drawable-or-omitted, same rule as the scene walk's titles. */
        out[pos++] = (ch >= 0x20 && ch < 0x7F) ? (char)ch : '?';
    }
    out[pos] = '\0';
}

/* Read one tag's first item. Returns the item size, or -1 when the tag is
   absent (which is an answer, not a failure). */
static long read_tag(Collection c, OSType tag, unsigned char *buf, long cap,
                     OSErr *err_out)
{
    SInt32 size = 0;
    OSErr err;

    *err_out = noErr;
    if (CountTaggedCollectionItems(c, (CollectionTag)tag) < 1) {
        return -1;
    }
    err = GetTaggedCollectionItem(c, (CollectionTag)tag, 1, &size, NULL);
    if (err != noErr) {
        *err_out = err;
        return -1;
    }
    if (size > cap) {
        /* Read what fits; the caller reports the TRUE size either way. */
        SInt32 want = (SInt32)cap;
        OSErr err2 = GetTaggedCollectionItem(c, (CollectionTag)tag, 1, &want, buf);

        if (err2 != noErr) {
            *err_out = err2;
        }
        return (long)size;
    }
    err = GetTaggedCollectionItem(c, (CollectionTag)tag, 1, &size, buf);
    if (err != noErr) {
        *err_out = err;
        return -1;
    }
    return (long)size;
}

static void add_str_tag(Collection c, OSType tag, const char *row_name,
                        DesktopAnswer *answer, char *value_out, long value_cap)
{
    unsigned char buf[256];
    char raw[kDesktopRowRawCap];
    char note[kDesktopRowNoteCap];
    OSErr err = noErr;
    long size;

    if (value_out != NULL) {
        value_out[0] = '\0';
    }
    size = read_tag(c, tag, buf, (long)sizeof buf, &err);
    if (size < 0) {
        snprintf(note, sizeof note, err == noErr ? "tag absent" : "err %d",
                 (int)err);
        now_desktop_add_row(answer, row_name, "", note);
        return;
    }
    pstring_text(buf, size, raw, (long)sizeof raw);
    if (value_out != NULL) {
        snprintf(value_out, value_cap, "%s", raw);
    }
    snprintf(note, sizeof note, "Str255, %ld bytes stored", size);
    now_desktop_add_row(answer, row_name, raw, note);
}

/* Every tag GetTheme returned, as four-char codes across as many rows as
   it takes. This is the RAW evidence every other row is read out of - a
   count alone would leave "we did not read that tag" and "the machine
   does not have it" indistinguishable, which is the distinction this
   whole verb is about. */
static void add_tag_inventory(Collection c, DesktopAnswer *answer)
{
    char list[kDesktopRowRawCap];
    char raw[kDesktopRowRawCap];
    char note[kDesktopRowNoteCap];
    SInt32 tag_count = CountCollectionTags(c);
    SInt32 i;
    long pos = 0;
    int listed = 0;
    int row = 0;

    snprintf(raw, sizeof raw, "%ld", (long)tag_count);
    now_desktop_add_row(answer, "tags", raw, "tags GetTheme returned");

    list[0] = '\0';
    for (i = 1; i <= tag_count; i++) {
        CollectionTag tag = 0;
        char text[16];
        char name[kDesktopRowNameCap];
        long n;

        if (GetIndexedCollectionTag(c, i, &tag) != noErr) {
            continue;
        }
        fourcc_text((OSType)tag, text, (long)sizeof text);
        n = (long)strlen(text);
        if (pos + n + 1 >= (long)sizeof list) {
            if (row + 1 >= kDesktopTagListRows) {
                break;          /* the count row carries the whole truth */
            }
            snprintf(name, sizeof name, "tagList.%d", row);
            now_desktop_add_row(answer, name, list, "four-char codes, continued");
            row++;
            pos = 0;
            list[0] = '\0';
        }
        if (pos > 0) {
            list[pos++] = ' ';
        }
        memcpy(list + pos, text, (size_t)n);
        pos += n;
        list[pos] = '\0';
        listed++;
    }
    if (pos > 0) {
        char name[kDesktopRowNameCap];

        snprintf(name, sizeof name, "tagList.%d", row);
        snprintf(note, sizeof note, "%d of %ld listed", listed, (long)tag_count);
        now_desktop_add_row(answer, name, list, note);
    }
}

static void add_pattern(Collection c, DesktopAnswer *answer)
{
    unsigned char buf[kDesktopHexBytesPerRow * kDesktopHexRows];
    char raw[kDesktopRowRawCap];
    char note[kDesktopRowNoteCap];
    OSErr err = noErr;
    long size;
    long carried;
    long offset;
    int row = 0;

    answer->pattern_bytes = -1;
    answer->pattern_carried = 0;
    answer->has_pattern = 0;

    size = read_tag(c, (OSType)kThemeDesktopPatternTag, buf, (long)sizeof buf,
                    &err);
    if (size < 0) {
        snprintf(note, sizeof note, err == noErr ? "tag absent" : "err %d",
                 (int)err);
        now_desktop_add_row(answer, "patternBytes", "", note);
        return;
    }
    answer->has_pattern = 1;
    answer->pattern_bytes = size;
    carried = size < (long)sizeof buf ? size : (long)sizeof buf;
    answer->pattern_carried = carried;

    snprintf(raw, sizeof raw, "%ld", size);
    if (carried < size) {
        snprintf(note, sizeof note, "flattened; %ld carried", carried);
    } else {
        snprintf(note, sizeof note, "flattened; all carried");
    }
    now_desktop_add_row(answer, "patternBytes", raw, note);

    for (offset = 0; offset < carried && row < kDesktopHexRows; row++) {
        long chunk = carried - offset;
        char name[kDesktopRowNameCap];

        if (chunk > kDesktopHexBytesPerRow) {
            chunk = kDesktopHexBytesPerRow;
        }
        now_desktop_hex(buf + offset, chunk, raw, (long)sizeof raw);
        snprintf(name, sizeof name, "pattern.%ld", offset);
        snprintf(note, sizeof note, "%ld bytes, hex", chunk);
        now_desktop_add_row(answer, name, raw, note);
        offset += chunk;
    }
}

static void add_picture(Collection c, DesktopAnswer *answer,
                        char *name_out, long name_cap)
{
    unsigned char buf[8];
    char raw[kDesktopRowRawCap];
    char note[kDesktopRowNoteCap];
    OSErr err = noErr;
    long size;

    add_str_tag(c, (OSType)kThemeDesktopPictureNameTag, "pictureName", answer,
                name_out, name_cap);

    size = read_tag(c, (OSType)kThemeDesktopPictureAlignmentTag, buf,
                    (long)sizeof buf, &err);
    if (size >= 4) {
        unsigned long value = ((unsigned long)buf[0] << 24) |
                              ((unsigned long)buf[1] << 16) |
                              ((unsigned long)buf[2] << 8) |
                              (unsigned long)buf[3];

        snprintf(raw, sizeof raw, "%lu", value);
        /* No named constants for this tag exist in this toolchain's
           headers, so the number is the answer and inventing a meaning
           for it would be exactly the confident wrong answer. */
        now_desktop_add_row(answer, "pictureAlign", raw,
                            "UInt32; no named constants in headers");
    } else {
        snprintf(note, sizeof note, err == noErr ? "tag absent" : "err %d",
                 (int)err);
        now_desktop_add_row(answer, "pictureAlign", "", note);
    }

    /* The alias is a handle to a file spec, and it is the tag that
       actually says whether a picture is set - see the note on
       DesktopSource for the measurement that settled that. Its bytes are
       a path on someone else's disk, so only the size is reported. */
    if (CountTaggedCollectionItems(c, (CollectionTag)kThemeDesktopPictureAliasTag)
        > 0) {
        SInt32 alias_size = 0;

        if (GetTaggedCollectionItem(c, (CollectionTag)kThemeDesktopPictureAliasTag,
                                    1, &alias_size, NULL) == noErr) {
            answer->has_picture = 1;
            snprintf(raw, sizeof raw, "%ld", (long)alias_size);
            now_desktop_add_row(answer, "pictureAlias", raw,
                                "alias, bytes; a picture IS set");
        }
    } else {
        now_desktop_add_row(answer, "pictureAlias", "", "tag absent");
    }
}

void now_desktop_gather(DesktopAnswer *out)
{
    Collection c;
    OSStatus err;
    char raw[kDesktopRowRawCap];
    char picture_name[kDesktopRowRawCap];

    memset(out, 0, sizeof *out);
    out->source = kDesktopSourceUnknown;
    out->pattern_bytes = -1;
    picture_name[0] = '\0';

    c = NewCollection();
    if (c == NULL) {
        now_desktop_add_row(out, "getTheme", "", "NewCollection returned NULL");
        snprintf(out->note, sizeof out->note, "no collection to fill");
        return;
    }
    err = GetTheme(c);
    snprintf(raw, sizeof raw, "%ld", (long)err);
    now_desktop_add_row(out, "getTheme", raw,
                        err == noErr ? "OSStatus" : "OSStatus; refused");
    if (err != noErr) {
        /* Unknown is a first-class answer: a desktop we cannot attribute
           renders as the marked unknown, never as a guessed pattern. */
        snprintf(out->note, sizeof out->note, "GetTheme refused");
        DisposeCollection(c);
        return;
    }

    add_tag_inventory(c, out);
    /* kThemeNameTag was ABSENT on the 9.1 runner image (2026-08-07) while
       kThemeAppearanceFileNameTag carried the answer, so both are asked
       and neither is assumed. */
    add_str_tag(c, (OSType)kThemeNameTag, "theme", out, NULL, 0);
    add_str_tag(c, (OSType)kThemeAppearanceFileNameTag, "appearanceFile", out,
                NULL, 0);
    add_str_tag(c, (OSType)kThemeDesktopPatternNameTag, "patternName", out,
                NULL, 0);
    add_pattern(c, out);
    add_picture(c, out, picture_name, (long)sizeof picture_name);

    /* A picture is drawn OVER the pattern layer, so a machine showing a
       picture still HAS a pattern - it is what shows wherever the picture
       does not reach. Both facts are reported; the source says which one
       a person is actually looking at. */
    if (out->has_picture || picture_name[0] != '\0') {
        out->source = kDesktopSourcePicture;
    } else if (out->has_pattern) {
        out->source = kDesktopSourcePattern;
    } else {
        out->source = kDesktopSourceUnknown;
    }

    DisposeCollection(c);
}

/* One tag's Str255 straight into a buffer, with no row written. The row
   writer above cannot serve this: it needs a DesktopAnswer to append to,
   and the whole point of the scene carrier is not to build one. */
static void read_str_tag(Collection c, OSType tag, char *out, long cap)
{
    unsigned char buf[256];
    OSErr err = noErr;
    long size;

    out[0] = '\0';
    size = read_tag(c, tag, buf, (long)sizeof buf, &err);
    if (size < 0) {
        return;
    }
    pstring_text(buf, size, out, cap);
}

void now_desktop_facts_ask(NowDesktopFacts *out)
{
    Collection c;
    OSErr err = noErr;
    unsigned char scratch[8];
    long size;

    if (out == NULL) {
        return;
    }
    memset(out, 0, sizeof *out);
    out->source = kDesktopSourceUnknown;
    out->pattern_bytes = -1;

    c = NewCollection();
    if (c == NULL) {
        /* Not asked: there was nothing to ask WITH. A consumer meeting no
           `meta.desktop` and a consumer meeting one that says `unknown`
           are owed different sentences, and this is the first. */
        return;
    }
    out->asked = 1;
    if (GetTheme(c) != noErr) {
        DisposeCollection(c);
        return;                 /* asked, refused, source stays unknown */
    }

    read_str_tag(c, (OSType)kThemeDesktopPatternNameTag, out->pattern_name,
                 (long)sizeof out->pattern_name);
    read_str_tag(c, (OSType)kThemeDesktopPictureNameTag, out->picture_name,
                 (long)sizeof out->picture_name);

    /* The pattern's TRUE length, without carrying any of it: an eight-byte
       scratch is enough for read_tag to report the item size, and the
       bytes themselves are not renderable art. */
    size = read_tag(c, (OSType)kThemeDesktopPatternTag, scratch,
                    (long)sizeof scratch, &err);
    if (size >= 0) {
        out->has_pattern = 1;
        out->pattern_bytes = size;
    }

    /* The ALIAS, not the name - see the note on DesktopSource for the
       measurement that settled which tag actually says a picture is set. */
    if (CountTaggedCollectionItems(c,
            (CollectionTag)kThemeDesktopPictureAliasTag) > 0) {
        out->has_picture = 1;
    }

    if (out->has_picture || out->picture_name[0] != '\0') {
        out->source = kDesktopSourcePicture;
    } else if (out->has_pattern) {
        out->source = kDesktopSourcePattern;
    }
    DisposeCollection(c);
}

void now_desktop_command(const char *request_json, long id,
                         char *out, long cap)
{
    DesktopAnswer answer;

    (void)request_json;         /* takes no arguments, on purpose */

    now_desktop_gather(&answer);
    while (now_desktop_result_json(id, &answer, out, cap) < 0) {
        if (answer.count <= 0) {
            snprintf(out, (size_t)cap,
                     "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
                     "\"error\":{\"code\":\"reply-too-large\","
                     "\"message\":\"the desktop answer did not fit\"}}", id);
            return;
        }
        /* Drop from the end and say so, rather than putting a truncated
           frame on the wire. The hex rows are last, which is the right
           thing to lose - the identity rows are the answer. */
        answer.count--;
        snprintf(answer.note, sizeof answer.note, "rows dropped - reply full");
    }
}
