/* The Chat page's geometry, run where a debugger exists:
     cc -Wall -Wextra -Werror -I ../src -I ../src/chat \
        chat_layout_test.c ../src/chat/chat_layout.c -o /tmp/t && /tmp/t
   Worth proving off-metal: nothing overlaps at the minimum and the
   standard size, the scrollbar abuts the pane, and every rect stays
   inside the body - click and draw read these same numbers. */

#include <assert.h>
#include <stdio.h>

#include "chat_layout.h"

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

static ChatLayoutSpec spec_of(int prompt_lines, int sidebar_shown)
{
    ChatLayoutSpec spec;

    spec.sidebar_shown = (Boolean)sidebar_shown;
    spec.prompt_lines = prompt_lines;
    return spec;
}

static void check_lines(const Rect *body, int prompt_lines)
{
    ChatLayoutRects r;
    ChatLayoutSpec spec = spec_of(prompt_lines, 1);

    chat_layout_compute(body, &spec, &r);
    inside(&r.provider_popup, body);
    inside(&r.model_popup, body);
    inside(&r.new_button, body);
    inside(&r.transcript, body);
    inside(&r.scrollbar, body);
    inside(&r.status, body);
    inside(&r.input, body);
    inside(&r.send_button, body);

    inside(&r.sidebar, body);
    inside(&r.sidebar_toggle, body);
    inside(&r.mode_popup, body);
    inside(&r.project_popup, body);

    no_overlap(&r.provider_popup, &r.model_popup);
    no_overlap(&r.model_popup, &r.new_button);
    no_overlap(&r.provider_popup, &r.mode_popup);
    no_overlap(&r.sidebar_toggle, &r.mode_popup);
    no_overlap(&r.mode_popup, &r.project_popup);
    /* The list and the text it sits beside, which is the whole point of
       giving the transcript a left edge that moves. */
    no_overlap(&r.sidebar, &r.transcript);
    no_overlap(&r.sidebar, &r.status);
    no_overlap(&r.sidebar, &r.project_popup);
    no_overlap(&r.transcript, &r.status);
    no_overlap(&r.status, &r.input);
    no_overlap(&r.input, &r.send_button);

    /* The classic one-pixel frame overlap, exactly. */
    assert(r.scrollbar.left == r.transcript.right - 1);
    assert(r.scrollbar.top == r.transcript.top);
    assert(r.scrollbar.bottom == r.transcript.bottom);

    /* The pane must hold a useful number of rows even at minimum -
       including with the prompt grown to its full height. */
    assert(chat_layout_visible_lines(&r) >= 8);
}

/* Collapsing gives the text the list's width back, and leaves NOTHING
   behind to click: an empty rect is unhittable, where an off-screen one
   is a click that does something invisible. */
static void check_collapse(const Rect *body)
{
    ChatLayoutRects open;
    ChatLayoutRects shut;
    ChatLayoutSpec open_spec = spec_of(1, 1);
    ChatLayoutSpec shut_spec = spec_of(1, 0);
    int i;

    chat_layout_compute(body, &open_spec, &open);
    chat_layout_compute(body, &shut_spec, &shut);

    assert(open.sidebar_visible > 4);
    assert(shut.sidebar_visible == 0);
    assert(shut.transcript.left < open.transcript.left);
    assert(shut.transcript.right == open.transcript.right);
    assert(shut.sidebar.right == shut.sidebar.left);
    for (i = 0; i < kChatSidebarRows; ++i) {
        assert(shut.sidebar_rows[i].right == shut.sidebar_rows[i].left);
    }

    /* Every visible row inside the panel, in order, no gaps or overlaps. */
    for (i = 0; i < open.sidebar_visible; ++i) {
        assert(open.sidebar_rows[i].top >= open.sidebar.top);
        assert(open.sidebar_rows[i].bottom <= open.sidebar.bottom);
        if (i > 0) {
            assert(open.sidebar_rows[i].top
                   == open.sidebar_rows[i - 1].bottom);
        }
    }
}

/* The click and the draw read ONE answer. A row that highlights as
   itself and acts as its neighbour is the defect this exists to stop. */
static void check_hit_test(const Rect *body)
{
    ChatLayoutRects r;
    ChatLayoutSpec spec = spec_of(1, 1);
    int i;

    chat_layout_compute(body, &spec, &r);
    for (i = 0; i < r.sidebar_visible; ++i) {
        short mid_v = (short)((r.sidebar_rows[i].top
                               + r.sidebar_rows[i].bottom) / 2);
        short mid_h = (short)((r.sidebar_rows[i].left
                               + r.sidebar_rows[i].right) / 2);

        assert(chat_layout_sidebar_row_at(&r, mid_h, mid_v) == i);
        assert(chat_layout_sidebar_row_at(&r, mid_h,
                                          r.sidebar_rows[i].top) == i);
    }
    /* Outside the panel, and inside the transcript, is not a row. */
    assert(chat_layout_sidebar_row_at(&r, (short)(r.transcript.left + 4),
                                     (short)(r.transcript.top + 4)) == -1);
    assert(chat_layout_sidebar_row_at(&r, (short)(r.sidebar.left + 4),
                                     (short)(r.sidebar.bottom + 2)) == -1);

    /* Collapsed, nothing hits at all. */
    spec = spec_of(1, 0);
    chat_layout_compute(body, &spec, &r);
    assert(chat_layout_sidebar_row_at(&r, (short)(body->left + 10),
                                     (short)(body->top + 60)) == -1);
}

static void check(const Rect *body)
{
    ChatLayoutRects one;
    ChatLayoutRects three;
    ChatLayoutRects capped;
    int lines;

    for (lines = 1; lines <= kChatPromptMaxLines; ++lines) {
        check_lines(body, lines);
    }
    check_collapse(body);
    check_hit_test(body);

    /* The well grows by exactly one transcript row per prompt line,
       upward - the bottom edge and the Send button never move. */
    {
        ChatLayoutSpec one_spec = spec_of(1, 1);
        ChatLayoutSpec three_spec = spec_of(3, 1);

        chat_layout_compute(body, &one_spec, &one);
        chat_layout_compute(body, &three_spec, &three);
    }
    assert(three.input.bottom == one.input.bottom);
    assert(three.send_button.top == one.send_button.top);
    assert(one.input.top - three.input.top == 2 * kChatLineHeight);
    assert(three.transcript.bottom < one.transcript.bottom);

    /* Out-of-range counts clamp instead of walking off the page. */
    {
        ChatLayoutSpec spec = spec_of(99, 1);

        chat_layout_compute(body, &spec, &capped);
    }
    assert(capped.input.top
           == one.input.top - (kChatPromptMaxLines - 1) * kChatLineHeight);
    {
        ChatLayoutSpec spec = spec_of(0, 1);

        chat_layout_compute(body, &spec, &capped);
    }
    assert(capped.input.top == one.input.top);
}

int main(void)
{
    Rect body;

    /* The Workshop's body at the window minimum (620x430 content less
       rail and chrome - the narrow case worth checking). */
    body.top = 38;
    body.left = 128;
    body.bottom = 407;
    body.right = 620;
    check(&body);

    /* The standard size. */
    body.top = 38;
    body.left = 160;
    body.bottom = 455;
    body.right = 744;
    check(&body);

    puts("chat_layout_test: all passed");
    return 0;
}
