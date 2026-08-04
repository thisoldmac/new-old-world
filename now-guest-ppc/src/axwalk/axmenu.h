#ifndef NOW_AXMENU_H
#define NOW_AXMENU_H

/* The Menu Manager walk - the piece NOW was blocked on.

   THE BLOCKER, AND WHY IT IS GONE. docs/scene-producer.md and the M5
   section of the integration plan recorded the menu walk as blocked:
   `MenuInfo` is citable (Universal Interfaces 3.4 `Menus.h` puts
   `menuData` at offset 14, and that was verified here independently),
   but the structure `LMGetMenuList()` actually returns - the header
   plus the entry array - appears in NO header in this toolchain. Not
   the universal `Menus.h`, not the multiversal one, not `LowMem.h`. So
   the stride was going to be a phantom constant in code that
   dereferences another process's heap, which is the worst possible
   place for one, and a named TODO was the correct answer.

   It is no longer a guess. `timbottu/mirror`, `guest/app/src/axmenu.c`
   has carried the layout all along, measured against a live Mac OS 9.1
   Finder: a 6-byte header, 6-byte entries, and MenuInfo's title at 14 -
   that last one being the number this project had already confirmed
   from published documentation, which is what makes the other two
   credible rather than assumed.

   The three constants are in axmenu.c beside the code that uses them.
   They are measurements. Correct them with a document or a machine, and
   with nothing else. */

#include "axwalk.h"

enum {
    /* Bounds, not beliefs: a menu bar wider than this is either a real
       oddity or a misparse, and either way the honest answer is a
       truncation flag rather than an unbounded walk over foreign
       memory. */
    kNowAxMenuMax = 16,
    kNowAxMenuItemMax = 32
};

typedef struct {
    unsigned long data;           /* the dereferenced MenuList */
    unsigned int  count;          /* menus, already clamped to the cap */
    unsigned char truncated;      /* the real count was above the cap */
} NowAxMenuList;

typedef struct {
    unsigned long handle;         /* exact MenuHandle from the MenuList */
    unsigned long record;         /* the dereferenced MenuInfo */
    unsigned long items;          /* first item, just past the title */
    unsigned long enable_flags;   /* bit 0 = the menu, bits 1..31 = items */
    short         id;
    short         left;           /* the title's left edge in the menu bar */
    unsigned char title_len;
    char          title[kNowAxTitleMax + 1];
} NowAxMenu;

/* An item cursor. Menu items are a packed variable-length list with no
   index, so the only way to reach item N is to have walked N-1 - which
   is why this is a cursor rather than an accessor. */
typedef struct {
    unsigned long next;
    unsigned long enable_flags;
    unsigned int  index;          /* 1-based, matching MenuSelect */
    unsigned char done;
} NowAxMenuCursor;

typedef struct {
    unsigned int  index;          /* 1-based */
    unsigned char enabled;
    unsigned char icon;
    unsigned char command;        /* command-key char, or a marker byte */
    unsigned char mark;
    unsigned char style;
    unsigned char title_len;      /* AFTER any leading NULs are dropped */
    unsigned char title_nul_prefix;  /* how many were dropped (0 for most) */
    char          title[kNowAxTitleMax + 1];
} NowAxMenuItem;

int now_ax_open_menu_list(const NowAxMemory *memory, unsigned long handle,
                          NowAxMenuList *out);
int now_ax_read_menu(const NowAxMemory *memory, const NowAxMenuList *list,
                     unsigned int index, NowAxMenu *out);
void now_ax_menu_cursor_init(const NowAxMenu *menu, NowAxMenuCursor *cursor);
int now_ax_menu_next(const NowAxMemory *memory, NowAxMenuCursor *cursor,
                     NowAxMenuItem *out);

#endif /* NOW_AXMENU_H */
