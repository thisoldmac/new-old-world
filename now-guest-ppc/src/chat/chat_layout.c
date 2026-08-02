#include "chat_layout.h"

static void set_rect(Rect *r, short left, short top,
                     short right, short bottom)
{
    r->left = left;
    r->top = top;
    r->right = right;
    r->bottom = bottom;
}

void chat_layout_compute(const Rect *body, ChatLayoutRects *out)
{
    short left = (short)(body->left + kChatMargin);
    short right = (short)(body->right - kChatMargin);
    short top = (short)(body->top + kChatMargin);
    short bottom = (short)(body->bottom - kChatMargin);
    short y;

    /* Top row: the model popup left, New Chat right. */
    set_rect(&out->popup, left, top,
             (short)(left + kChatPopupWidth),
             (short)(top + kChatTopRowHeight));
    set_rect(&out->new_button,
             (short)(right - kChatNewButtonWidth), top,
             right, (short)(top + kChatTopRowHeight));

    /* Bottom row: the prompt well with Send against the right edge. */
    set_rect(&out->send_button,
             (short)(right - kChatSendButtonWidth),
             (short)(bottom - kChatInputHeight),
             right, bottom);
    set_rect(&out->input, left,
             (short)(bottom - kChatInputHeight),
             (short)(out->send_button.left - kChatRowGap), bottom);

    /* The status line sits just above the input row. */
    set_rect(&out->status, left,
             (short)(out->input.top - kChatRowGap - kChatStatusHeight),
             right, (short)(out->input.top - kChatRowGap));

    /* The transcript takes what remains, scrollbar flush right. The
       classic inset: the bar overlaps the pane frame by one pixel. */
    y = (short)(out->popup.bottom + kChatRowGap);
    set_rect(&out->transcript, left, y,
             (short)(right - kChatScrollBarWidth + 1),
             (short)(out->status.top - kChatRowGap));
    set_rect(&out->scrollbar,
             (short)(out->transcript.right - 1), y,
             right, out->transcript.bottom);
}

int chat_layout_visible_lines(const ChatLayoutRects *r)
{
    int height = r->transcript.bottom - r->transcript.top - 8;

    if (height < kChatLineHeight) {
        return 1;
    }
    return height / kChatLineHeight;
}
