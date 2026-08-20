#include "chat_layout.h"

#include <stddef.h>

static void set_rect(Rect *r, short left, short top,
                     short right, short bottom)
{
    r->left = left;
    r->top = top;
    r->right = right;
    r->bottom = bottom;
}

void chat_layout_compute(const Rect *body, const ChatLayoutSpec *spec,
                         ChatLayoutRects *out)
{
    short left = (short)(body->left + kChatMargin);
    short right = (short)(body->right - kChatMargin);
    short top = (short)(body->top + kChatMargin);
    short bottom = (short)(body->bottom - kChatMargin);
    short input_h;
    short y;
    short pane_left;
    int prompt_lines = spec != NULL ? spec->prompt_lines : 1;
    int sidebar_shown = spec == NULL || spec->sidebar_shown;
    int i;

    if (prompt_lines < 1) {
        prompt_lines = 1;
    }
    if (prompt_lines > kChatPromptMaxLines) {
        prompt_lines = kChatPromptMaxLines;
    }
    input_h = (short)(kChatInputHeight
                      + (prompt_lines - 1) * kChatLineHeight);

    /* Top row: provider then model, the model list following the
       provider choice; New Chat at the right. */
    set_rect(&out->provider_popup, left, top,
             (short)(left + kChatProviderPopupWidth),
             (short)(top + kChatTopRowHeight));
    set_rect(&out->model_popup,
             (short)(out->provider_popup.right + kChatRowGap), top,
             (short)(out->provider_popup.right + kChatRowGap
                     + kChatModelPopupWidth),
             (short)(top + kChatTopRowHeight));
    set_rect(&out->new_button,
             (short)(right - kChatNewButtonWidth), top,
             right, (short)(top + kChatTopRowHeight));

    /* Bottom row: the prompt well with Send against the right edge.
       The well is the one rect that grows with its text. */
    set_rect(&out->send_button,
             (short)(right - kChatSendButtonWidth),
             (short)(bottom - kChatInputHeight),
             right, bottom);
    set_rect(&out->input, left,
             (short)(bottom - input_h),
             (short)(out->send_button.left - kChatRowGap), bottom);

    /* The status line sits just above the input row. */
    set_rect(&out->status, left,
             (short)(out->input.top - kChatRowGap - kChatStatusHeight),
             right, (short)(out->input.top - kChatRowGap));

    /* Second row: the sidebar's own toggle at the left edge it opens,
       then what the turn may do and where it is filed. */
    y = (short)(out->provider_popup.bottom + kChatRowGap);
    set_rect(&out->sidebar_toggle, left, y,
             (short)(left + kChatToggleWidth),
             (short)(y + kChatTopRowHeight));
    set_rect(&out->mode_popup,
             (short)(out->sidebar_toggle.right + kChatRowGap), y,
             (short)(out->sidebar_toggle.right + kChatRowGap
                     + kChatModePopupWidth),
             (short)(y + kChatTopRowHeight));
    set_rect(&out->project_popup,
             (short)(out->mode_popup.right + kChatRowGap), y,
             (short)(out->mode_popup.right + kChatRowGap
                     + kChatProjectPopupWidth),
             (short)(y + kChatTopRowHeight));
    set_rect(&out->skills_popup,
             (short)(out->project_popup.right + kChatRowGap), y,
             (short)(out->project_popup.right + kChatRowGap
                     + kChatSkillsPopupWidth),
             (short)(y + kChatTopRowHeight));

    y = (short)(out->sidebar_toggle.bottom + kChatRowGap);
    pane_left = left;
    /* The sidebar, and the transcript starting where it ends. Collapsed,
       every one of its rects is EMPTY rather than off-screen: a draw or
       a hit test that reads a stale slot then lands nowhere, which is
       the failure that shows up as a click doing something invisible. */
    out->sidebar.left = 0;
    out->sidebar.top = 0;
    out->sidebar.right = 0;
    out->sidebar.bottom = 0;
    out->sidebar_visible = 0;
    for (i = 0; i < kChatSidebarRows; ++i) {
        out->sidebar_rows[i].left = 0;
        out->sidebar_rows[i].top = 0;
        out->sidebar_rows[i].right = 0;
        out->sidebar_rows[i].bottom = 0;
    }
    if (sidebar_shown) {
        short list_bottom = (short)(out->status.top - kChatRowGap);
        int fits;

        set_rect(&out->sidebar, left, y,
                 (short)(left + kChatSidebarWidth), list_bottom);
        pane_left = (short)(out->sidebar.right + kChatRowGap);
        /* One row of inset at each end, so the frame is not a row's
           top pixel — the rail's own arithmetic. */
        fits = (list_bottom - y - 4) / kChatSidebarRowHeight;
        if (fits < 0) {
            fits = 0;
        }
        if (fits > kChatSidebarRows) {
            fits = kChatSidebarRows;
        }
        out->sidebar_visible = fits;
        for (i = 0; i < fits; ++i) {
            set_rect(&out->sidebar_rows[i],
                     (short)(out->sidebar.left + 1),
                     (short)(y + 2 + i * kChatSidebarRowHeight),
                     (short)(out->sidebar.right - 1),
                     (short)(y + 2 + (i + 1) * kChatSidebarRowHeight));
        }
    }

    /* The transcript takes what remains, scrollbar flush right. The
       classic inset: the bar overlaps the pane frame by one pixel. */
    set_rect(&out->transcript, pane_left, y,
             (short)(right - kChatScrollBarWidth + 1),
             (short)(out->status.top - kChatRowGap));
    set_rect(&out->scrollbar,
             (short)(out->transcript.right - 1), y,
             right, out->transcript.bottom);
}

int chat_layout_sidebar_row_at(const ChatLayoutRects *r, short h, short v)
{
    int i;

    if (r == NULL) {
        return -1;
    }
    for (i = 0; i < r->sidebar_visible && i < kChatSidebarRows; ++i) {
        const Rect *row = &r->sidebar_rows[i];

        if (h >= row->left && h < row->right
            && v >= row->top && v < row->bottom) {
            return i;
        }
    }
    return -1;
}

int chat_layout_visible_lines(const ChatLayoutRects *r)
{
    int height = r->transcript.bottom - r->transcript.top - 8;

    if (height < kChatLineHeight) {
        return 1;
    }
    return height / kChatLineHeight;
}
