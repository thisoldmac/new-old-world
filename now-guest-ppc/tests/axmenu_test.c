/* Native test for the ported Menu Manager walk.

       cc -Wall -Wextra -Werror -I ../src/axwalk -I ../src/peek -I . \
          axmenu_test.c ../src/axwalk/axmenu.c ../src/axwalk/axwalk.c \
          ../src/peek/peek_validate.c -o axmenu_test && ./axmenu_test

   THIS IS THE ONE THAT MATTERS. The MenuList's header size and entry
   stride appear in no header in this toolchain; they are measurements
   carried over from mirror/guest/app/src/axmenu.c, and until now the
   only thing that could have caught a wrong one was a Macintosh.

   The fixture is built the way the walk reads it - a 6-byte header
   whose first word divided by the entry stride is the menu count,
   6-byte entries, and a MenuInfo whose title is variable-length so the
   item list starts wherever that title ends. Any of the three constants
   being wrong moves a field that a named check reads back. The Apple-menu NUL
   prefix and the enable-flag rules are covered too, because those are
   the parts a reader is most tempted to "clean up".

   Deliberately included: an off-by-one stride is checked to FAIL, not
   merely to differ. A parser that silently produced garbage titles from
   a wrong stride would be worse than one that refused. */

#include <stdio.h>
#include <string.h>

#include "axfixture.h"
#include "axmenu.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

enum {
    kListH = 0x00101000,          /* the MenuHandle-list handle */
    kList = 0x00101100,           /* the MenuList itself */
    kMenuH0 = 0x00102000,         /* MenuHandle for menu 0 */
    kMenu0 = 0x00102100,          /* its MenuInfo */
    kMenuH1 = 0x00103000,
    kMenu1 = 0x00103100
};

/* A MenuInfo: menuID, width, height, defProc, reserved, enableFlags,
   then a Str255 title, then the packed item list. */
static unsigned long build_menu(AxFixture *f, unsigned long handle,
                                unsigned long record, int id,
                                const char *title, unsigned long flags)
{
    size_t n = strlen(title);

    axfix_put_handle(f, handle, record);
    axfix_put16(f, record + 0, id);       /* menuID */
    axfix_put16(f, record + 2, 60);       /* menuWidth */
    axfix_put16(f, record + 4, 100);      /* menuHeight */
    axfix_put32(f, record + 6, 0);        /* menuProc */
    axfix_put32(f, record + 10, flags);   /* enableFlags */
    axfix_put_pstr(f, record + 14, title);
    return record + 14 + 1 + n;           /* where the items begin */
}

/* One packed item: length byte, text, then icon/cmd/mark/style. */
static unsigned long put_item(AxFixture *f, unsigned long at,
                              const char *text, size_t len,
                              unsigned cmd)
{
    size_t i;

    axfix_put8(f, at, (unsigned)len);
    for (i = 0; i < len; i++) {
        axfix_put8(f, at + 1 + i, (unsigned char)text[i]);
    }
    axfix_put8(f, at + 1 + len, 0);          /* icon */
    axfix_put8(f, at + 2 + len, cmd);        /* command key */
    axfix_put8(f, at + 3 + len, 0);          /* mark */
    axfix_put8(f, at + 4 + len, 0);          /* style */
    return at + 5 + len;
}

static void put_terminator(AxFixture *f, unsigned long at)
{
    axfix_put8(f, at, 0);
}

/* A two-menu bar: "File" (id 129) and "Edit" (id 130). */
static void build_bar(AxFixture *f, int menus)
{
    unsigned long items;

    axfix_put_handle(f, kListH, kList);
    /* The header's first word, divided by the entry stride, IS the
       count - upstream's arithmetic, kept exactly. So N menus means
       N * stride here, and a word that does not divide by the stride is
       not a MenuList at all (checked below). */
    axfix_put16(f, kList, menus * 6);
    axfix_put32(f, kList + 6, kMenuH0);   /* entry 0: handle */
    axfix_put16(f, kList + 10, 0);        /* entry 0: left edge */
    axfix_put32(f, kList + 12, kMenuH1);  /* entry 1 */
    axfix_put16(f, kList + 16, 44);

    items = build_menu(f, kMenuH0, kMenu0, 129, "File", 0xFFFFFFFFUL);
    items = put_item(f, items, "New", 3, 'N');
    items = put_item(f, items, "Open", 4, 'O');
    put_terminator(f, items);

    items = build_menu(f, kMenuH1, kMenu1, 130, "Edit", 0xFFFFFFFFUL);
    items = put_item(f, items, "Undo", 4, 'Z');
    put_terminator(f, items);
}

static void list_and_menus(void)
{
    AxFixture f;
    NowAxMemory m;
    NowAxMenuList list;
    NowAxMenu menu;

    axfix_init(&f, &m);
    build_bar(&f, 2);

    check(now_ax_open_menu_list(&m, kListH, &list) == kNowAxOk,
          "the menu list opens");
    check(list.data == kList, "the MenuList is the dereferenced handle");
    check(list.count == 2, "count = header word / 6, so a 6-byte stride");
    check(list.truncated == 0, "two menus is not a truncation");

    check(now_ax_read_menu(&m, &list, 0, &menu) == kNowAxOk, "menu 0 reads");
    check(menu.id == 129, "menuID @0");
    check(menu.left == 0, "entry left edge @4 of the entry");
    check(menu.title_len == 4 && strcmp(menu.title, "File") == 0,
          "menuData @14, so a 14-byte MenuInfo header");
    check(menu.enable_flags == 0xFFFFFFFFUL, "enableFlags @10");
    check(menu.items == kMenu0 + 14 + 1 + 4,
          "items begin just past the variable-length title");

    check(now_ax_read_menu(&m, &list, 1, &menu) == kNowAxOk, "menu 1 reads");
    check(menu.id == 130, "second entry is 6 bytes on from the first");
    check(menu.left == 44, "second entry's left edge");
    check(strcmp(menu.title, "Edit") == 0, "second menu's title");

    check(now_ax_read_menu(&m, &list, 2, &menu) == kNowAxInvalid,
          "an index past the count is refused");
}

static void items_walk(void)
{
    AxFixture f;
    NowAxMemory m;
    NowAxMenuList list;
    NowAxMenu menu;
    NowAxMenuCursor cur;
    NowAxMenuItem item;

    axfix_init(&f, &m);
    build_bar(&f, 2);
    (void)now_ax_open_menu_list(&m, kListH, &list);
    (void)now_ax_read_menu(&m, &list, 0, &menu);
    now_ax_menu_cursor_init(&menu, &cur);

    check(now_ax_menu_next(&m, &cur, &item) == kNowAxOk, "item 1 reads");
    check(item.index == 1, "item indices are 1-based, as MenuSelect's are");
    check(strcmp(item.title, "New") == 0, "item 1 title");
    check(item.command == 'N', "command key is the 2nd metadata byte");
    check(item.enabled == 1, "enabled by its flag bit");

    check(now_ax_menu_next(&m, &cur, &item) == kNowAxOk, "item 2 reads");
    check(strcmp(item.title, "Open") == 0,
          "the cursor advanced by 1 + len + 4");
    check(item.index == 2, "index 2");

    check(now_ax_menu_next(&m, &cur, &item) == kNowAxNotFound,
          "the zero-length sentinel ends the list");
    check(now_ax_menu_next(&m, &cur, &item) == kNowAxNotFound,
          "a finished cursor stays finished");
}

/* The Apple-menu observation: leading NULs are in the data. The title
   reported is the text after them; the count is kept rather than
   discarded, so nothing is invented and nothing is lost. */
static void nul_prefixed_titles(void)
{
    AxFixture f;
    NowAxMemory m;
    NowAxMenuList list;
    NowAxMenu menu;
    NowAxMenuCursor cur;
    NowAxMenuItem item;
    unsigned long items;

    axfix_init(&f, &m);
    axfix_put_handle(&f, kListH, kList);
    axfix_put16(&f, kList, 6);            /* exactly one menu */
    axfix_put32(&f, kList + 6, kMenuH0);
    axfix_put16(&f, kList + 10, 0);
    items = build_menu(&f, kMenuH0, kMenu0, 128, "\x14", 0xFFFFFFFFUL);
    items = put_item(&f, items, "\0\0SimpleText", 12, 0);
    items = put_item(&f, items, "\0Desktop", 8, 0);
    items = put_item(&f, items, "Plain", 5, 0);
    items = put_item(&f, items, "a\0b", 3, 0);
    put_terminator(&f, items);

    (void)now_ax_open_menu_list(&m, kListH, &list);
    (void)now_ax_read_menu(&m, &list, 0, &menu);
    now_ax_menu_cursor_init(&menu, &cur);

    check(now_ax_menu_next(&m, &cur, &item) == kNowAxOk, "item 1");
    check(strcmp(item.title, "SimpleText") == 0, "two NULs dropped");
    check(item.title_nul_prefix == 2, "and counted");
    check(item.title_len == 10, "length is of what remains");

    check(now_ax_menu_next(&m, &cur, &item) == kNowAxOk, "item 2");
    check(strcmp(item.title, "Desktop") == 0, "one NUL dropped");
    check(item.title_nul_prefix == 1, "and counted");

    check(now_ax_menu_next(&m, &cur, &item) == kNowAxOk, "item 3");
    check(strcmp(item.title, "Plain") == 0 && item.title_nul_prefix == 0,
          "an ordinary title is untouched");

    check(now_ax_menu_next(&m, &cur, &item) == kNowAxOk, "item 4");
    check(item.title_nul_prefix == 0 && item.title_len == 3
          && item.title[1] == '\0',
          "an EMBEDDED NUL is not the phenomenon and stays visible");
    /* The cursor still advanced past all 3 bytes, which is the check
       that the embedded NUL did not shorten the stride. */
    check(now_ax_menu_next(&m, &cur, &item) == kNowAxNotFound,
          "and the sentinel is still reached");
}

static void enable_flags(void)
{
    AxFixture f;
    NowAxMemory m;
    NowAxMenuList list;
    NowAxMenu menu;
    NowAxMenuCursor cur;
    NowAxMenuItem item;
    unsigned long items;

    axfix_init(&f, &m);
    axfix_put_handle(&f, kListH, kList);
    axfix_put16(&f, kList, 6);
    axfix_put32(&f, kList + 6, kMenuH0);
    axfix_put16(&f, kList + 10, 0);
    /* bit 0 (the menu) and bit 2 (item 2) set; item 1's bit clear. */
    items = build_menu(&f, kMenuH0, kMenu0, 131, "M", 0x00000005UL);
    items = put_item(&f, items, "One", 3, 0);
    items = put_item(&f, items, "Two", 3, 0);
    put_terminator(&f, items);

    (void)now_ax_open_menu_list(&m, kListH, &list);
    (void)now_ax_read_menu(&m, &list, 0, &menu);
    now_ax_menu_cursor_init(&menu, &cur);
    check(now_ax_menu_next(&m, &cur, &item) == kNowAxOk && item.enabled == 0,
          "item 1's bit is clear: disabled");
    check(now_ax_menu_next(&m, &cur, &item) == kNowAxOk && item.enabled == 1,
          "item 2's bit is set: enabled");

    /* Bit 0 clear disables everything below it. */
    axfix_put32(&f, kMenu0 + 10, 0xFFFFFFFEUL);
    (void)now_ax_read_menu(&m, &list, 0, &menu);
    now_ax_menu_cursor_init(&menu, &cur);
    check(now_ax_menu_next(&m, &cur, &item) == kNowAxOk && item.enabled == 0,
          "bit 0 clear disables the whole menu");
}

static void refusals_and_bounds(void)
{
    AxFixture f;
    NowAxMemory m;
    NowAxMenuList list;
    NowAxMenu menu;
    NowAxMenuCursor cur;
    NowAxMenuItem item;
    unsigned long items;
    int i;

    axfix_init(&f, &m);
    check(now_ax_open_menu_list(&m, 0, &list) == kNowAxOk && list.count == 0,
          "a null MenuList is an empty answer, not a failure");

    build_bar(&f, 2);
    /* A header word that is not a multiple of the stride cannot be a
       MenuList - and this is exactly what a WRONG stride would make a
       real machine's header look like. */
    axfix_put16(&f, kList, 7);
    check(now_ax_open_menu_list(&m, kListH, &list) == kNowAxInvalid,
          "a header not divisible by the entry stride is refused");
    axfix_put16(&f, kList, -6);
    check(now_ax_open_menu_list(&m, kListH, &list) == kNowAxInvalid,
          "a negative last-menu offset is refused");

    axfix_init(&f, &m);
    build_bar(&f, 2);
    axfix_put_handle(&f, kListH, 0x00900000UL);
    check(now_ax_open_menu_list(&m, kListH, &list) == kNowAxInvalid,
          "a MenuList outside both zones is refused");
    check(f.refused == 0, "refused before the seam was entered");

    /* The item cap: a list longer than the bound stops AND says so,
       rather than walking foreign memory without a limit. */
    axfix_init(&f, &m);
    axfix_put_handle(&f, kListH, kList);
    axfix_put16(&f, kList, 6);
    axfix_put32(&f, kList + 6, kMenuH0);
    axfix_put16(&f, kList + 10, 0);
    items = build_menu(&f, kMenuH0, kMenu0, 132, "Long", 0xFFFFFFFFUL);
    for (i = 0; i < kNowAxMenuItemMax + 4; i++) {
        items = put_item(&f, items, "x", 1, 0);
    }
    put_terminator(&f, items);
    (void)now_ax_open_menu_list(&m, kListH, &list);
    (void)now_ax_read_menu(&m, &list, 0, &menu);
    now_ax_menu_cursor_init(&menu, &cur);
    for (i = 0; i < kNowAxMenuItemMax; i++) {
        check(now_ax_menu_next(&m, &cur, &item) == kNowAxOk, "capped item");
    }
    check(now_ax_menu_next(&m, &cur, &item) == kNowAxTruncated,
          "the item cap reports truncation rather than stopping silently");

    now_ax_menu_cursor_init(NULL, &cur);
    check(now_ax_menu_next(&m, &cur, &item) == kNowAxNotFound,
          "a cursor with no menu yields nothing");
}

/* The menu cap: more menus than the bound are clamped and flagged. */
static void menu_cap(void)
{
    AxFixture f;
    NowAxMemory m;
    NowAxMenuList list;

    axfix_init(&f, &m);
    axfix_put_handle(&f, kListH, kList);
    axfix_put16(&f, kList, (kNowAxMenuMax + 3) * 6);
    check(now_ax_open_menu_list(&m, kListH, &list) == kNowAxOk,
          "an over-long bar still opens");
    check(list.count == kNowAxMenuMax, "clamped to the cap");
    check(list.truncated == 1, "and says so");
}

int main(void)
{
    list_and_menus();
    items_walk();
    nul_prefixed_titles();
    enable_flags();
    refusals_and_bounds();
    menu_cap();

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("axmenu_test: ok\n");
    return 0;
}
