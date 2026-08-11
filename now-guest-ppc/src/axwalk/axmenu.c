/* The Menu Manager walk. See axmenu.h for the provenance of the three
   constants below - they are measurements, and this file is the reason
   the menu walk is no longer blocked.

   Every handle and every byte range still crosses axwalk's partition /
   SysZone boundary, exactly as the window walk does. The Menu Manager's
   structures are no safer to trust than the Window Manager's. */

#include "axmenu.h"

#include <string.h>

/* MEASURED, not derived. archive/mirror-standalone-2026-08-09/guest/app/src/axmenu.c, against a live
   Mac OS 9.1 Finder:
     - the MenuList begins with a 6-byte header whose first word is the
       LAST menu's byte offset (so count = lastMenu / entry stride),
     - each entry is 6 bytes: a 4-byte MenuHandle plus the title's
       2-byte left edge,
     - MenuInfo's menuData (a Str255) starts at 14, which Universal
       Interfaces 3.4 Menus.h independently confirms.
   The middle two appear in no header this toolchain ships. */
#define kNowAxMenuListHeader 6UL
#define kNowAxMenuListEntry  6UL
#define kNowAxMenuInfoHeader 14UL

static unsigned short be16(const unsigned char *p)
{
    return (unsigned short)(((unsigned short)p[0] << 8) | p[1]);
}

static short bes16(const unsigned char *p)
{
    return (short)be16(p);
}

static unsigned long be32(const unsigned char *p)
{
    return ((unsigned long)p[0] << 24)
         | ((unsigned long)p[1] << 16)
         | ((unsigned long)p[2] << 8)
         | (unsigned long)p[3];
}

int now_ax_open_menu_list(const NowAxMemory *memory, unsigned long handle,
                          NowAxMenuList *out)
{
    unsigned char raw[kNowAxMenuListHeader];
    unsigned long data;
    short         last_menu;
    unsigned int  count;
    int           rc;

    if (out == NULL) {
        return kNowAxInvalid;
    }
    memset(out, 0, sizeof(*out));
    /* A process with no menu bar has a null MenuList. That is an empty
       answer, not a failure - count stays 0. */
    if (handle == 0) {
        return kNowAxOk;
    }
    rc = now_ax_read_handle(memory, handle, &data);
    if (rc != kNowAxOk) {
        return rc;
    }
    rc = now_ax_read_bytes(memory, data, raw, sizeof(raw));
    if (rc != kNowAxOk) {
        return rc;
    }
    last_menu = bes16(raw);
    /* The header word is a byte offset into the entry array, so it must
       be non-negative and an exact multiple of the stride. That single
       test is what would catch a wrong stride: a real MenuList divides
       evenly by 6 and by very little else. */
    if (last_menu < 0
        || (last_menu % (short)kNowAxMenuListEntry) != 0) {
        return kNowAxInvalid;
    }
    count = (unsigned int)(last_menu / (short)kNowAxMenuListEntry);
    out->data = data;
    out->count = count > kNowAxMenuMax ? kNowAxMenuMax : count;
    out->truncated = count > kNowAxMenuMax;
    return kNowAxOk;
}

int now_ax_read_menu(const NowAxMemory *memory, const NowAxMenuList *list,
                     unsigned int index, NowAxMenu *out)
{
    unsigned char entry[kNowAxMenuListEntry];
    unsigned char header[kNowAxMenuInfoHeader + 1];
    unsigned long handle;
    unsigned long record;
    unsigned int  title_len;
    int           rc;

    if (list == NULL || out == NULL || index >= list->count) {
        return kNowAxInvalid;
    }
    memset(out, 0, sizeof(*out));
    rc = now_ax_read_bytes(memory,
                           list->data + kNowAxMenuListHeader
                           + (unsigned long)index * kNowAxMenuListEntry,
                           entry, sizeof(entry));
    if (rc != kNowAxOk) {
        return rc;
    }
    handle = be32(entry);
    out->handle = handle;
    rc = now_ax_read_handle(memory, handle, &record);
    if (rc != kNowAxOk) {
        return rc;
    }
    /* One byte past the header: menuData's length byte. */
    rc = now_ax_read_bytes(memory, record, header, sizeof(header));
    if (rc != kNowAxOk) {
        return rc;
    }
    title_len = header[kNowAxMenuInfoHeader];
    if (title_len != 0) {
        rc = now_ax_read_bytes(memory, record + kNowAxMenuInfoHeader + 1,
                               out->title, title_len);
        if (rc != kNowAxOk) {
            return rc;
        }
    }
    out->title[title_len] = '\0';
    out->record = record;
    /* The item list starts immediately after the variable-length title.
       There is no pointer to it; its address IS this arithmetic. */
    out->items = record + kNowAxMenuInfoHeader + 1 + title_len;
    out->enable_flags = be32(header + 10);
    out->id = bes16(header);
    out->left = bes16(entry + 4);
    out->title_len = (unsigned char)title_len;
    return kNowAxOk;
}

void now_ax_menu_cursor_init(const NowAxMenu *menu, NowAxMenuCursor *cursor)
{
    memset(cursor, 0, sizeof(*cursor));
    if (menu != NULL) {
        cursor->next = menu->items;
        cursor->enable_flags = menu->enable_flags;
    } else {
        cursor->done = 1;
    }
}

int now_ax_menu_next(const NowAxMemory *memory, NowAxMenuCursor *cursor,
                     NowAxMenuItem *out)
{
    unsigned char length;
    unsigned char metadata[4];
    unsigned int  index;
    int           rc;

    if (cursor == NULL || out == NULL || cursor->done
        || cursor->next == 0) {
        return kNowAxNotFound;
    }
    if (cursor->index >= kNowAxMenuItemMax) {
        cursor->done = 1;
        return kNowAxTruncated;
    }
    rc = now_ax_read_bytes(memory, cursor->next, &length, 1);
    if (rc != kNowAxOk) {
        return rc;
    }
    /* The list's own sentinel: a zero-length item ends it. Reaching this
       is what proves the cursor stayed aligned - an off-by-N stride
       would run past it into whatever follows. */
    if (length == 0) {
        cursor->done = 1;
        return kNowAxNotFound;
    }
    memset(out, 0, sizeof(*out));
    rc = now_ax_read_bytes(memory, cursor->next + 1, out->title, length);
    if (rc != kNowAxOk) {
        return rc;
    }
    rc = now_ax_read_bytes(memory, cursor->next + 1 + length,
                           metadata, sizeof(metadata));
    if (rc != kNowAxOk) {
        return rc;
    }
    index = cursor->index + 1;
    out->index = index;
    out->title_len = length;
    out->title[length] = '\0';

    /* Leading NUL bytes are IN THE DATA, and they are the system's, not
       a misread length byte.
     *
     * Measured upstream on mac99 / Mac OS 9.1, 2026-07-31, against the
     * Finder's menu bar: all 16 Apple-menu entries below the separator
     * read `\0\0` + a name, and those 16 names are byte-for-byte the 16
     * files in `System Folder:Apple Menu Items`, in the same order. The
     * Window menu carries `\0Desktop` - ONE NUL, not two. The same walk
     * parses File/Edit/View/Special with correct titles and correct
     * command keys, and terminates on the list's own zero-length
     * sentinel, which is what rules out a misaligned cursor: an off-by-N
     * would corrupt every menu, and a FIXED off-by-N cannot produce
     * prefixes of two AND of one in the same pass.
     *
     * Whatever writes them, they are non-printing, and the addressable
     * name - the one drawn in the menu, and the one an agent will ask
     * for - is the text after them. Report that as the title and keep
     * the count, so nothing is invented and nothing is silently
     * discarded. Leading only: an embedded NUL is not this phenomenon
     * and stays visible.
     *
     * TODO(provenance): the WRITER of the prefix is not identified.
     * Apple's published Menu Manager documentation describes no NUL
     * prefix, so this is an observation (P-OBS) awaiting a document, not
     * an explained mechanism. */
    {
        unsigned int skip = 0;

        while (skip < (unsigned int)length && out->title[skip] == '\0') {
            skip++;
        }
        if (skip != 0) {
            memmove(out->title, out->title + skip,
                    (size_t)(length - skip) + 1);
            out->title_len = (unsigned char)(length - skip);
            out->title_nul_prefix = (unsigned char)skip;
        }
    }
    out->icon = metadata[0];
    out->command = metadata[1];
    out->mark = metadata[2];
    out->style = metadata[3];
    /* Bit 0 gates the whole menu; bit N gates item N. Items past 31 have
       no bit and are reported enabled, which is the Menu Manager's own
       rule and not a fallback. */
    out->enabled = (cursor->enable_flags & 1UL) != 0
        && (index > 31
            || (cursor->enable_flags & (1UL << index)) != 0);
    cursor->next += 1UL + (unsigned long)length + sizeof(metadata);
    cursor->index = index;
    return kNowAxOk;
}
