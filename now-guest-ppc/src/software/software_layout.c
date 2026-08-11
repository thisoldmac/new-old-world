#include "software_layout.h"

#include <stdio.h>
#include <string.h>

static void set_rect(Rect *r, short left, short top, short right,
                     short bottom)
{
    r->left = left;
    r->top = top;
    r->right = right;
    r->bottom = bottom;
}

void software_layout_compute(const Rect *body, SoftwareLayout *out)
{
    software_layout_compute_split(body, 0, out);
}

void software_layout_compute_split(const Rect *body, short want_list_w,
                                   SoftwareLayout *out)
{
    short width = (short)(body->right - body->left);
    short list_w = (short)(width < kSwListNarrowBelow ? kSwListNarrow
                                                      : kSwListWide);
    short toolbar_top = (short)(body->top + 6);
    short content_top;
    short btn_y;
    short inner_left;
    short y;
    short x;

    /* A person-chosen width wins over the default, clamped so neither
       pane can be dragged shut. */
    if (want_list_w > 0) {
        short max_w = (short)(width - 2 * kSwMargin - kSwPaneGap
                              - kSwDetailMin);

        list_w = want_list_w;
        if (list_w > max_w) {
            list_w = max_w;
        }
        if (list_w < kSwListMin) {
            list_w = kSwListMin;
        }
    }

    /* Toolbar: popup pinned left, the search field pinned right so it
       stays put as the window grows. */
    set_rect(&out->toolbar_popup, (short)(body->left + kSwMargin),
             toolbar_top, (short)(body->left + kSwMargin + kSwPopupWidth),
             (short)(toolbar_top + kSwToolbarHeight));
    set_rect(&out->toolbar_search,
             (short)(body->right - kSwMargin - kSwSearchWidth),
             (short)(toolbar_top + 1),
             (short)(body->right - kSwMargin),
             (short)(toolbar_top + 1 + (kSwToolbarHeight - 3)));

    content_top = (short)(out->toolbar_popup.bottom + kSwToolbarGap);
    btn_y = (short)(body->bottom - kSwMargin - kSwButtonHeight);

    /* The panes fill the gap between the toolbar and the button row. */
    set_rect(&out->list, (short)(body->left + kSwMargin), content_top,
             (short)(body->left + kSwMargin + list_w),
             (short)(btn_y - kSwButtonGap));
    set_rect(&out->detail, (short)(out->list.right + kSwPaneGap),
             content_top, (short)(body->right - kSwMargin),
             out->list.bottom);
    /* The gap between the panes is the splitter's grab zone. */
    set_rect(&out->splitter, out->list.right, content_top,
             out->detail.left, out->list.bottom);

    /* Left row, under the list: Rescan then Show in Finder. Both act on
       the list / the selection rather than on a running process, so they
       group here and leave the narrow detail pane to the lifecycle
       actions, which otherwise would not all fit on one row. */
    set_rect(&out->rescan_btn, out->list.left, btn_y,
             (short)(out->list.left + kSwRescanWidth),
             (short)(btn_y + kSwButtonHeight));
    x = (short)(out->rescan_btn.right + kSwButtonGap);
    set_rect(&out->reveal_btn, x, btn_y, (short)(x + kSwRevealWidth),
             (short)(btn_y + kSwButtonHeight));

    /* Detail facts stack from the pane's top. */
    inner_left = (short)(out->detail.left + 12);
    y = (short)(out->detail.top + 6);
    set_rect(&out->d_title, inner_left, y,
             (short)(out->detail.right - 12), (short)(y + 18));
    y = (short)(out->d_title.bottom + 8);
    set_rect(&out->d_kind, inner_left, y, (short)(out->detail.right - 12),
             (short)(y + kSwLineHeight));
    y = out->d_kind.bottom;
    set_rect(&out->d_size, inner_left, y, (short)(out->detail.right - 12),
             (short)(y + kSwLineHeight));
    y = out->d_size.bottom;
    set_rect(&out->d_where, inner_left, y, (short)(out->detail.right - 12),
             (short)(y + kSwLineHeight));
    y = out->d_where.bottom;
    set_rect(&out->d_where2, inner_left, y,
             (short)(out->detail.right - 12), (short)(y + kSwLineHeight));
    y = out->d_where2.bottom;
    set_rect(&out->d_modified, inner_left, y,
             (short)(out->detail.right - 12), (short)(y + kSwLineHeight));

    /* Right row, under the detail: the lifecycle actions. Launch is
       mutually exclusive with Bring to Front / Quit (an app is either
       dead or running), so Launch shares Front's slot - the layout
       reserves the wider one and the Workshop shows whichever applies,
       so nothing jumps as the selection's state changes. Quit follows. */
    set_rect(&out->launch_btn, out->detail.left, btn_y,
             (short)(out->detail.left + kSwLaunchWidth),
             (short)(btn_y + kSwButtonHeight));
    set_rect(&out->front_btn, out->detail.left, btn_y,
             (short)(out->detail.left + kSwFrontWidth),
             (short)(btn_y + kSwButtonHeight));
    x = (short)(out->front_btn.right + kSwButtonGap);
    set_rect(&out->quit_btn, x, btn_y, (short)(x + kSwQuitWidth),
             (short)(btn_y + kSwButtonHeight));
}

void sw_size_text(long bytes, char *out, long cap)
{
    unsigned long kb;

    if (bytes < 0) {
        bytes = 0;
    }
    kb = (unsigned long)bytes / 1024UL;
    if ((unsigned long)bytes % 1024UL != 0) {
        ++kb;
    }
    sw_size_k_text(kb, out, cap);
}

void sw_size_k_text(unsigned long kilobytes, char *out, long cap)
{
    if (kilobytes < 1024UL) {
        snprintf(out, (size_t)cap, "%luK", kilobytes);
    } else {
        unsigned long whole = kilobytes / 1024UL;
        unsigned long tenth = ((kilobytes % 1024UL) * 10UL + 512UL)
                              / 1024UL;

        if (tenth == 10UL) {
            ++whole;
            tenth = 0;
        }
        snprintf(out, (size_t)cap, "%lu.%luM", whole, tenth);
    }
}

long sw_fork_size_k(long data_bytes, long resource_bytes)
{
    unsigned long data_k;
    unsigned long resource_k;
    unsigned long remainder;

    if (data_bytes < 0 || resource_bytes < 0) {
        return -1;
    }
    data_k = (unsigned long)data_bytes / 1024UL;
    resource_k = (unsigned long)resource_bytes / 1024UL;
    remainder = (unsigned long)data_bytes % 1024UL
                + (unsigned long)resource_bytes % 1024UL;
    return (long)(data_k + resource_k + (remainder + 1023UL) / 1024UL);
}

static void fourcc(unsigned long code, char out[5])
{
    int i;

    for (i = 0; i < 4; ++i) {
        char c = (char)((code >> (24 - i * 8)) & 0xFF);

        out[i] = (c >= 0x20 && c <= 0x7E) ? c : '.';
    }
    out[4] = '\0';
}

void sw_kind_text(unsigned long type, unsigned long creator,
                  char *out, long cap)
{
    char t[5], c[5];

    fourcc(type, t);
    fourcc(creator, c);
    snprintf(out, (size_t)cap, "%s / %s", t, c);
}

void sw_status_text(const char *domain_label, int shown, int total,
                    int off, Boolean sweeping, char *out, long cap)
{
    if (sweeping) {
        snprintf(out, (size_t)cap,
                 "Indexing %s - %d so far, then reading versions...",
                 domain_label, total);
        return;
    }
    if (shown < total) {
        /* A live-search filter is narrowing the list. */
        snprintf(out, (size_t)cap, "%d of %d %s shown", shown, total,
                 domain_label);
        return;
    }
    if (off > 0) {
        snprintf(out, (size_t)cap, "%d %s - %d disabled", total,
                 domain_label, off);
        return;
    }
    snprintf(out, (size_t)cap, "%d %s", total, domain_label);
}
