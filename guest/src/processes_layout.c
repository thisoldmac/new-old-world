#include "processes_layout.h"

#include <stdio.h>
#include <string.h>

/* Multi-character constants spelled out so the host cc never warns;
   the values are the big-endian 4CCs the Process Manager reports. */
#define PROC_4CC(a, b, c, d)                                          \
    (((unsigned long)(a) << 24) | ((unsigned long)(b) << 16)          \
     | ((unsigned long)(c) << 8) | (unsigned long)(d))

enum {
    kTypeApplication = PROC_4CC('A', 'P', 'P', 'L'),
    kTypeBackground = PROC_4CC('a', 'p', 'p', 'e'),
    kTypeFinder = PROC_4CC('F', 'N', 'D', 'R')
};

static void set_rect(Rect *r, short left, short top, short right,
                     short bottom)
{
    r->left = left;
    r->top = top;
    r->right = right;
    r->bottom = bottom;
}

void processes_layout_compute(const Rect *body, ProcessesLayout *out)
{
    short width = (short)(body->right - body->left);
    short list_w = (short)(width < kProcListNarrowBelow ? kProcListNarrow
                                                        : kProcListWide);
    short inner_left;
    short value_x;
    short y;
    short group_top;
    short btn_y;

    set_rect(&out->list, (short)(body->left + kProcMargin),
             (short)(body->top + 8),
             (short)(body->left + kProcMargin + list_w),
             (short)(body->bottom - 8));
    set_rect(&out->detail, (short)(out->list.right + kProcPaneGap),
             out->list.top, (short)(body->right - kProcMargin),
             out->list.bottom);

    inner_left = (short)(out->detail.left + 12);
    value_x = (short)(inner_left + kProcFactLabelWidth + 8);
    y = (short)(out->detail.top + 8);

    set_rect(&out->title_line, inner_left, y,
             (short)(out->detail.right - 12), (short)(y + 18));
    y = (short)(out->title_line.bottom + 8);

    set_rect(&out->kind_line, inner_left, y,
             (short)(out->detail.right - 12),
             (short)(y + kProcFactLineHeight));
    y = out->kind_line.bottom;
    set_rect(&out->type_line, inner_left, y,
             (short)(out->detail.right - 12),
             (short)(y + kProcFactLineHeight));
    y = out->type_line.bottom;
    set_rect(&out->mem_line, inner_left, y,
             (short)(out->detail.right - 12),
             (short)(y + kProcFactLineHeight));
    y = out->mem_line.bottom;

    {
        short bar_w = (short)(out->detail.right - 12 - value_x);

        if (bar_w > kProcMemBarMaxWidth) {
            bar_w = kProcMemBarMaxWidth;
        }
        if (bar_w < 40) {
            bar_w = 40;
        }
        set_rect(&out->mem_bar, value_x, (short)(y + 2),
                 (short)(value_x + bar_w),
                 (short)(y + 2 + kProcMemBarHeight));
    }
    y = (short)(out->mem_bar.bottom + 6);
    set_rect(&out->launched_line, inner_left, y,
             (short)(out->detail.right - 12),
             (short)(y + kProcFactLineHeight));

    /* The extension group pins to the pane's bottom; the buttons float
       above it rather than under the facts, so a short pane squeezes
       the empty middle instead of the controls. */
    group_top = (short)(out->detail.bottom - 10 - 74);
    if (group_top < out->launched_line.bottom + 40) {
        group_top = (short)(out->launched_line.bottom + 40);
    }
    if (out->detail.bottom - 10 - group_top < kProcGroupMinHeight) {
        group_top = (short)(out->detail.bottom - 10 - kProcGroupMinHeight);
    }
    set_rect(&out->group, (short)(out->detail.left + 10), group_top,
             (short)(out->detail.right - 10),
             (short)(out->detail.bottom - 10));
    set_rect(&out->peek_line, (short)(out->group.left + 12),
             (short)(out->group.top + 14),
             (short)(out->group.right - 12),
             (short)(out->group.top + 14 + 14));

    btn_y = (short)(out->group.top - 12 - kProcButtonHeight);
    set_rect(&out->front_btn, inner_left, btn_y,
             (short)(inner_left + 110), (short)(btn_y + kProcButtonHeight));
    set_rect(&out->quit_btn, (short)(out->front_btn.right + 10), btn_y,
             (short)(out->front_btn.right + 10 + 100),
             (short)(btn_y + kProcButtonHeight));
}

void proc_fourcc_text(unsigned long code, char out[5])
{
    int i;

    for (i = 0; i < 4; ++i) {
        char c = (char)((code >> (24 - i * 8)) & 0xFF);

        out[i] = (c >= 0x20 && c <= 0x7E) ? c : '.';
    }
    out[4] = '\0';
}

void proc_kind_text(unsigned long type, char *out, long cap)
{
    if (type == kTypeApplication) {
        snprintf(out, (size_t)cap, "application");
    } else if (type == kTypeBackground) {
        snprintf(out, (size_t)cap, "background only");
    } else if (type == kTypeFinder) {
        snprintf(out, (size_t)cap, "the Finder");
    } else {
        char four[5];

        proc_fourcc_text(type, four);
        snprintf(out, (size_t)cap, "%s", four);
    }
}

/* 1,024 rather than 1024: the classic Memory control panel groups
   thousands, and the string stays ASCII. Only sizes wear this; counts
   do not. */
static void group_thousands(long value, char *out, long cap)
{
    if (value < 0) {
        value = 0;
    }
    if (value >= 1000000L) {
        snprintf(out, (size_t)cap, "%ld,%03ld,%03ld", value / 1000000L,
                 (value / 1000L) % 1000L, value % 1000L);
    } else if (value >= 1000L) {
        snprintf(out, (size_t)cap, "%ld,%03ld", value / 1000L,
                 value % 1000L);
    } else {
        snprintf(out, (size_t)cap, "%ld", value);
    }
}

void proc_mem_text(long used_kb, long size_kb, char *out, long cap)
{
    char used[16];
    char size[16];

    group_thousands(used_kb, used, sizeof used);
    group_thousands(size_kb, size, sizeof size);
    snprintf(out, (size_t)cap, "%sK used of %sK", used, size);
}

long proc_mem_fill(long used_kb, long size_kb, long bar_width)
{
    long fill;

    if (size_kb <= 0 || bar_width <= 0 || used_kb <= 0) {
        return 0;
    }
    fill = bar_width * used_kb / size_kb;
    if (fill > bar_width) {
        fill = bar_width;
    }
    return fill;
}

void proc_status_text(int count, long free_kb, char *out, long cap)
{
    snprintf(out, (size_t)cap, "%d process%s - %ld.%ld MB free", count,
             count == 1 ? "" : "es", free_kb / 1024,
             (free_kb % 1024) * 10 / 1024);
}
