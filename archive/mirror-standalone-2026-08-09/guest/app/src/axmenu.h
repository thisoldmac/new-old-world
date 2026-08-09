/*
 * axmenu.h - bounded reader for the classic Menu Manager's MenuList.
 */
#ifndef TIMBOTTU_AXMENU_H
#define TIMBOTTU_AXMENU_H

#include "axwalk.h"

#define AX_MENU_MAX       16
#define AX_MENU_ITEM_MAX  32

typedef struct {
    unsigned long data;
    unsigned int  count;
    unsigned char truncated;
} ax_menu_list;

typedef struct {
    unsigned long record;
    unsigned long items;
    unsigned long enable_flags;
    short         id;
    short         left;
    unsigned char title_len;
    char          title[AX_TITLE_MAX + 1];
} ax_menu_info;

typedef struct {
    unsigned long next;
    unsigned long enable_flags;
    unsigned int  index;
    unsigned char done;
} ax_menu_cursor;

typedef struct {
    unsigned int  index;
    unsigned char enabled;
    unsigned char icon;
    unsigned char command;
    unsigned char mark;
    unsigned char style;
    unsigned char title_len;        /* AFTER any leading NULs are dropped */
    unsigned char title_nul_prefix; /* how many were dropped (0 for most) */
    char          title[AX_TITLE_MAX + 1];
} ax_menu_item;

int ax_open_menu_list(const ax_memory *memory, unsigned long handle,
                      ax_menu_list *out);
int ax_read_menu(const ax_memory *memory, const ax_menu_list *list,
                 unsigned int index, ax_menu_info *out);
void ax_menu_cursor_init(const ax_menu_info *menu, ax_menu_cursor *cursor);
int ax_menu_next(const ax_memory *memory, ax_menu_cursor *cursor,
                 ax_menu_item *out);

#endif /* TIMBOTTU_AXMENU_H */
