/* Native test for the DITL item walk — the first automated coverage it has
   had, and the layout in it is measured rather than assumed.

       cc -Wall -Wextra -Werror -I ../src/axwalk -I ../src/peek -I . \
          axditl_test.c ../src/axwalk/axwalk.c ../src/peek/peek_validate.c \
          -o axditl_test && ./axditl_test

   Every constant below was read out of a LIVE guest on 2026-08-06 with the
   QEMU oracle, off Internet Explorer's `Error` alert, and checked against
   what the machine's own screen showed:

       items handle 0x1e03c55c  editField -1  editOpen 0  aDefItem 1
       item 1 type=0x04 len=2 rect=(336,84,404,104)   data='OK'
       item 4 type=0x88 len=0 rect=(78,10,405,76)     data=''
       item 5 type=0xa0 len=2 rect=(23,13,55,45)      data='\0\0'

   So: `aDefItem` really is at offset 168 and really did name item 1, whose
   ring the machine really did draw; the high bit of the type byte is the
   disable flag (0x88 = statText disabled, 0xa0 = iconItem disabled), which
   is where a dialog item's `enabled: false` comes from; and a BUTTON's
   title is in the DITL while a TEXT item's is not — item 4's message,
   "Security failure.  The server reply is invalid.", lived in the item's
   handle and reached the Mirror only once the walk asked the Dialog
   Manager for it (src/scene/dialog_text.h). */

#include <stdio.h>
#include <string.h>

#include "axfixture.h"
#include "axwalk.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

enum {
    kWin = 0x00101000,          /* the DialogRecord */
    kItemsH = 0x00102000,       /* its item-list handle */
    kItems = 0x00102100,        /* the item list itself */
    kTextH = 0x00103000,
    kBtnCtl = 0x00104000
};

/* The alert above, in miniature: a disabled statText with no template text,
   a disabled icon, and an enabled push button that the DialogRecord names
   as its default. */
static void build(AxFixture *f, int default_item)
{
    unsigned long p;

    axfix_put32(f, kWin + 156, kItemsH);      /* DialogRecord.items */
    axfix_put16(f, kWin + 164, -1);           /* editField: none */
    axfix_put16(f, kWin + 166, 0);            /* editOpen */
    axfix_put16(f, kWin + 168, default_item); /* aDefItem */
    axfix_put_handle(f, kItemsH, kItems);
    axfix_put16(f, kItems, 2);                /* count - 1 */
    p = kItems + 2;

    /* item 1: the push button, title in the DITL */
    axfix_put32(f, p, kBtnCtl);
    axfix_put16(f, p + 4, 84);
    axfix_put16(f, p + 6, 336);
    axfix_put16(f, p + 8, 104);
    axfix_put16(f, p + 10, 404);
    axfix_put8(f, p + 12, 0x04);              /* ctrlItem + btnCtrl */
    axfix_put8(f, p + 13, 2);
    axfix_put8(f, p + 14, 'O');
    axfix_put8(f, p + 15, 'K');
    p += 16;

    /* item 2: the message, disabled, and EMPTY in the resource */
    axfix_put32(f, p, kTextH);
    axfix_put16(f, p + 4, 10);
    axfix_put16(f, p + 6, 78);
    axfix_put16(f, p + 8, 76);
    axfix_put16(f, p + 10, 405);
    axfix_put8(f, p + 12, 0x88);              /* statText | disabled */
    axfix_put8(f, p + 13, 0);
    p += 14;

    /* item 3: the icon, disabled */
    axfix_put32(f, p, 0UL);
    axfix_put16(f, p + 4, 13);
    axfix_put16(f, p + 6, 23);
    axfix_put16(f, p + 8, 45);
    axfix_put16(f, p + 10, 55);
    axfix_put8(f, p + 12, 0xa0);              /* iconItem | disabled */
    axfix_put8(f, p + 13, 2);
    axfix_put8(f, p + 14, 0);
    axfix_put8(f, p + 15, 0);
}

int main(void)
{
    AxFixture f;
    NowAxMemory m;
    NowAxDialogCursor cursor;
    NowAxDialogItem item;

    axfix_init(&f, &m);
    build(&f, 1);
    check(now_ax_open_dialog_items(&m, kWin, &cursor) == kNowAxOk,
          "the item list opens through DialogRecord.items at 156");
    check(cursor.remaining == 3, "count is the stored value plus one");
    check(cursor.default_item == 1, "aDefItem sits at offset 168");
    check(cursor.edit_item == 0, "editField -1 at offset 164 means none");

    check(now_ax_dialog_next(&m, &cursor, &item) == kNowAxOk, "item 1");
    check(item.number == 1, "items are numbered from one");
    check(item.kind == kNowAxDialogPushButton, "0x04 is a push button");
    check(item.enabled == 1, "and its disable bit is clear");
    check(strcmp(item.title, "OK") == 0, "a button's title IS in the DITL");
    check(item.left == 336 && item.top == 84 && item.right == 404
              && item.bottom == 104, "the rect is top,left,bottom,right");
    check(item.handle == kBtnCtl,
          "the item's handle is the live control, which is how a DITL row "
          "and a ControlRecord are joined");

    check(now_ax_dialog_next(&m, &cursor, &item) == kNowAxOk, "item 2");
    check(item.kind == kNowAxDialogStaticText, "0x88 is static text...");
    check(item.enabled == 0, "...with the high bit meaning DISABLED");
    check(item.title[0] == '\0',
          "and no text: an alert's message is not in its DITL");

    check(now_ax_dialog_next(&m, &cursor, &item) == kNowAxOk, "item 3");
    check(item.kind == kNowAxDialogIcon, "0xa0 is a disabled icon item");
    check(item.enabled == 0, "same disable bit, different type");

    check(now_ax_dialog_next(&m, &cursor, &item) == kNowAxNotFound,
          "and the list ends where the count said it would");

    /* A default item past the end of the list is not a default item. */
    axfix_init(&f, &m);
    build(&f, 9);
    check(now_ax_open_dialog_items(&m, kWin, &cursor) == kNowAxInvalid,
          "an aDefItem outside the list is refused, not reported");

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("axditl_test: ok\n");
    return 0;
}
