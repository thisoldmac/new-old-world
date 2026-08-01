/*
 * axmenu.c - passive parser for the standard Menu Manager data structures.
 *
 * MenuList and MenuInfo are public classic Mac OS layouts. Every handle and
 * byte range still crosses axwalk's selected partition/SysZone boundary.
 */
#include "axmenu.h"

#include <string.h>

#define AX_MENU_LIST_HEADER 6UL
#define AX_MENU_LIST_ENTRY  6UL
#define AX_MENU_INFO_HEADER 14UL

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

int ax_open_menu_list(const ax_memory *memory, unsigned long handle,
                      ax_menu_list *out)
{
    unsigned char raw[AX_MENU_LIST_HEADER];
    unsigned long data;
    short         last_menu;
    unsigned int  count;
    int           rc;

    if (out == NULL) {
        return AX_INVALID;
    }
    memset(out, 0, sizeof(*out));
    if (handle == 0) {
        return AX_OK;
    }
    rc = ax_read_handle(memory, handle, &data);
    if (rc != AX_OK) {
        return rc;
    }
    rc = ax_read_bytes(memory, data, raw, sizeof(raw));
    if (rc != AX_OK) {
        return rc;
    }
    last_menu = bes16(raw);
    if (last_menu < 0
        || (last_menu % (short)AX_MENU_LIST_ENTRY) != 0) {
        return AX_INVALID;
    }
    count = (unsigned int)(last_menu / (short)AX_MENU_LIST_ENTRY);
    out->data = data;
    out->count = count > AX_MENU_MAX ? AX_MENU_MAX : count;
    out->truncated = count > AX_MENU_MAX;
    return AX_OK;
}

int ax_read_menu(const ax_memory *memory, const ax_menu_list *list,
                 unsigned int index, ax_menu_info *out)
{
    unsigned char entry[AX_MENU_LIST_ENTRY];
    unsigned char header[AX_MENU_INFO_HEADER + 1];
    unsigned long handle;
    unsigned long record;
    unsigned int  title_len;
    int           rc;

    if (list == NULL || out == NULL || index >= list->count) {
        return AX_INVALID;
    }
    memset(out, 0, sizeof(*out));
    rc = ax_read_bytes(memory,
                       list->data + AX_MENU_LIST_HEADER
                       + (unsigned long)index * AX_MENU_LIST_ENTRY,
                       entry, sizeof(entry));
    if (rc != AX_OK) {
        return rc;
    }
    handle = be32(entry);
    rc = ax_read_handle(memory, handle, &record);
    if (rc != AX_OK) {
        return rc;
    }
    rc = ax_read_bytes(memory, record, header, sizeof(header));
    if (rc != AX_OK) {
        return rc;
    }
    title_len = header[AX_MENU_INFO_HEADER];
    if (title_len != 0) {
        rc = ax_read_bytes(memory, record + AX_MENU_INFO_HEADER + 1,
                           out->title, title_len);
        if (rc != AX_OK) {
            return rc;
        }
    }
    out->title[title_len] = '\0';
    out->record = record;
    out->items = record + AX_MENU_INFO_HEADER + 1 + title_len;
    out->enable_flags = be32(header + 10);
    out->id = bes16(header);
    out->left = bes16(entry + 4);
    out->title_len = (unsigned char)title_len;
    return AX_OK;
}

void ax_menu_cursor_init(const ax_menu_info *menu, ax_menu_cursor *cursor)
{
    memset(cursor, 0, sizeof(*cursor));
    if (menu != NULL) {
        cursor->next = menu->items;
        cursor->enable_flags = menu->enable_flags;
    } else {
        cursor->done = 1;
    }
}

int ax_menu_next(const ax_memory *memory, ax_menu_cursor *cursor,
                 ax_menu_item *out)
{
    unsigned char length;
    unsigned char metadata[4];
    unsigned int  index;
    int           rc;

    if (cursor == NULL || out == NULL || cursor->done
        || cursor->next == 0) {
        return AX_NOT_FOUND;
    }
    if (cursor->index >= AX_MENU_ITEM_MAX) {
        cursor->done = 1;
        return AX_AMBIGUOUS;
    }
    rc = ax_read_bytes(memory, cursor->next, &length, 1);
    if (rc != AX_OK) {
        return rc;
    }
    if (length == 0) {
        cursor->done = 1;
        return AX_NOT_FOUND;
    }
    memset(out, 0, sizeof(*out));
    if (length != 0) {
        rc = ax_read_bytes(memory, cursor->next + 1, out->title, length);
        if (rc != AX_OK) {
            return rc;
        }
    }
    rc = ax_read_bytes(memory, cursor->next + 1 + length,
                       metadata, sizeof(metadata));
    if (rc != AX_OK) {
        return rc;
    }
    index = cursor->index + 1;
    out->index = index;
    out->title_len = length;
    out->title[length] = '\0';
    out->icon = metadata[0];
    out->command = metadata[1];
    out->mark = metadata[2];
    out->style = metadata[3];
    out->enabled = (cursor->enable_flags & 1UL) != 0
        && (index > 31
            || (cursor->enable_flags & (1UL << index)) != 0);
    cursor->next += 1UL + (unsigned long)length + sizeof(metadata);
    cursor->index = index;
    return AX_OK;
}
