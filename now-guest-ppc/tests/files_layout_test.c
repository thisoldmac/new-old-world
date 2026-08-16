/* The Files page's geometry, run where a debugger exists:
     cc -Wall -Wextra -Werror -I ../src -I ../src/files \
        files_layout_test.c ../src/files/files_layout.c -o /tmp/t && /tmp/t

   The page is two named halves with a listing between them, and the
   properties worth proving off-metal are the ones that decide whether a
   person can USE it on the smallest Macintosh this application runs on:

     - nothing overlaps and nothing leaves the body, at the minimum size
       and the standard one;
     - the listing keeps a useful height at the minimum - the whole
       argument for measuring the bottom half from the bottom edge is
       that the listing is what grows, and a page whose list is twelve
       pixels tall on a 640x480 screen has lost the argument;
     - the transfer line and the item count share one slot, so the Stop
       button never moves out from under a pointer mid-transfer;
     - the path gives way before that slot does, and never past a floor.

   Watched failing (mutations, 2026-08-15): measuring the bottom half
   downward from the top rather than upward from the bottom (caught by
   the bottom-anchor assert), and giving the listing a FIXED height -
   the change that would quietly stop it growing with the window, and
   the one the last assert in this file exists for. Both aborted on an
   assertion after building and running, not on a compiler error. */

#include <assert.h>
#include <stdio.h>

#include "files_layout.h"

static void no_overlap(const Rect *a, const Rect *b)
{
    assert(a->right <= b->left || b->right <= a->left
           || a->bottom <= b->top || b->bottom <= a->top);
}

static void inside(const Rect *r, const Rect *body)
{
    assert(r->left >= body->left && r->right <= body->right);
    assert(r->top >= body->top && r->bottom <= body->bottom);
    assert(r->left < r->right && r->top < r->bottom);
}

static void check(const Rect *body)
{
    FilesLayoutRects r;

    files_layout_compute(body, &r);

    inside(&r.their_heading, body);
    inside(&r.up_btn, body);
    inside(&r.path, body);
    inside(&r.path_busy, body);
    inside(&r.count, body);
    inside(&r.xfer, body);
    inside(&r.stop_btn, body);
    inside(&r.browser, body);
    inside(&r.divider, body);
    inside(&r.mine_heading, body);
    inside(&r.mine_caption, body);
    inside(&r.sharing_label, body);
    inside(&r.sharing_value, body);
    inside(&r.folder_radio, body);
    inside(&r.disk_radio, body);
    inside(&r.choose_btn, body);
    inside(&r.send_btn, body);
    inside(&r.progress, body);
    inside(&r.into_label, body);
    inside(&r.into_value, body);
    inside(&r.change_btn, body);
    inside(&r.open_btn, body);

    /* Their half, top to bottom, in that order. */
    assert(r.their_heading.bottom <= r.up_btn.top);
    assert(r.up_btn.bottom <= r.browser.top);
    assert(r.browser.bottom <= r.divider.top);
    assert(r.divider.bottom <= r.mine_heading.top);

    /* The path row, left to right. */
    no_overlap(&r.up_btn, &r.path);
    no_overlap(&r.path, &r.count);
    no_overlap(&r.path_busy, &r.xfer);
    no_overlap(&r.xfer, &r.stop_btn);

    /* One slot, two tenants: the count and the transfer line end at the
       same place, and Stop sits beyond both. A row that reflowed
       mid-transfer would move Stop under the pointer. */
    assert(r.count.right == body->right - kFilesMargin);
    assert(r.stop_btn.right == body->right - kFilesMargin);
    assert(r.xfer.right <= r.stop_btn.left);

    /* The path gives way to the transfer line, never the other way, and
       never past its floor. */
    assert(r.path_busy.right <= r.path.right);
    assert(r.path_busy.right - r.path_busy.left >= 0);
    assert(r.xfer.left >= r.up_btn.right + kFilesPathFloor);

    /* My half: heading, its caption beside it, then the sharing line,
       the two radios with Choose at the right, then the two verb rows. */
    no_overlap(&r.mine_heading, &r.mine_caption);
    assert(r.mine_heading.bottom <= r.sharing_label.top);
    no_overlap(&r.sharing_label, &r.sharing_value);
    assert(r.sharing_label.bottom <= r.folder_radio.top);
    no_overlap(&r.folder_radio, &r.disk_radio);
    no_overlap(&r.disk_radio, &r.choose_btn);
    assert(r.folder_radio.bottom <= r.send_btn.top);
    no_overlap(&r.send_btn, &r.progress);
    assert(r.send_btn.bottom <= r.into_label.top);
    no_overlap(&r.into_label, &r.into_value);
    no_overlap(&r.into_value, &r.change_btn);
    no_overlap(&r.change_btn, &r.open_btn);

    /* The bottom half is anchored to the bottom edge: the last row ends
       where the body does, less the margin it shares with the top. */
    assert(r.open_btn.bottom == body->bottom - 6);
    assert(r.into_label.bottom <= body->bottom - 6);
    assert(r.open_btn.right == body->right - kFilesMargin);

    /* And the listing is what is left, which must be worth having. */
    assert(r.browser.bottom - r.browser.top >= kFilesBrowserMinHeight);
}

int main(void)
{
    Rect body;
    FilesLayoutRects small;
    FilesLayoutRects big;
    Rect wide;

    /* The Workshop's body at the window minimum (620x444 content, less
       the narrow rail and the header/status placards) - the case that
       decides whether this page works on a 640x480 Mac at all. */
    body.top = 38;
    body.left = 128;
    body.bottom = 421;
    body.right = 620;
    check(&body);
    files_layout_compute(&body, &small);

    /* The standard size. */
    wide.top = 38;
    wide.left = 160;
    wide.bottom = 455;
    wide.right = 744;
    check(&wide);
    files_layout_compute(&wide, &big);

    /* THE point of measuring the bottom half upward: every extra pixel
       of window goes to the listing, and the two verb rows stay exactly
       as tall as they were. */
    assert(big.browser.bottom - big.browser.top
           > small.browser.bottom - small.browser.top);
    assert(big.open_btn.bottom - big.open_btn.top
           == small.open_btn.bottom - small.open_btn.top);
    assert(big.send_btn.bottom - big.send_btn.top
           == small.send_btn.bottom - small.send_btn.top);
    /* The bottom block's own height does not change with the window. */
    assert(big.open_btn.bottom - big.divider.top
           == small.open_btn.bottom - small.divider.top);

    puts("files_layout_test: all passed");
    return 0;
}
