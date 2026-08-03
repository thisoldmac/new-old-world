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

static void check_lines(const Rect *body, int prompt_lines)
{
    ChatLayoutRects r;

    chat_layout_compute(body, prompt_lines, &r);
    inside(&r.provider_popup, body);
    inside(&r.model_popup, body);
    inside(&r.new_button, body);
    inside(&r.transcript, body);
    inside(&r.scrollbar, body);
    inside(&r.status, body);
    inside(&r.input, body);
    inside(&r.send_button, body);

    no_overlap(&r.provider_popup, &r.model_popup);
    no_overlap(&r.model_popup, &r.new_button);
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

static void check(const Rect *body)
{
    ChatLayoutRects one;
    ChatLayoutRects three;
    ChatLayoutRects capped;
    int lines;

    for (lines = 1; lines <= kChatPromptMaxLines; ++lines) {
        check_lines(body, lines);
    }

    /* The well grows by exactly one transcript row per prompt line,
       upward - the bottom edge and the Send button never move. */
    chat_layout_compute(body, 1, &one);
    chat_layout_compute(body, 3, &three);
    assert(three.input.bottom == one.input.bottom);
    assert(three.send_button.top == one.send_button.top);
    assert(one.input.top - three.input.top == 2 * kChatLineHeight);
    assert(three.transcript.bottom < one.transcript.bottom);

    /* Out-of-range counts clamp instead of walking off the page. */
    chat_layout_compute(body, 99, &capped);
    assert(capped.input.top
           == one.input.top - (kChatPromptMaxLines - 1) * kChatLineHeight);
    chat_layout_compute(body, 0, &capped);
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
