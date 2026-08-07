#include "act_menu_probe.h"

#include <string.h>

#include "axprocess.h"

void now_act_menu_probe(const ProcessSerialNumber *psn, long menu, long item,
                        NowActMenuProbe *out)
{
    NowAxContext   ctx;
    NowAxMenuList  list;
    unsigned int   i;

    if (out == NULL) {
        return;
    }
    memset(out, 0, sizeof *out);
    out->verdict = kNowActMenuProbeUnknown;
    if (psn == NULL || item < 1) {
        return;
    }
    if (now_ax_bind_process(psn, &ctx) != kNowPeekReadOk
            || ctx.menu_list == 0
            || now_ax_open_menu_list(&ctx.memory, ctx.menu_list, &list)
               != kNowAxOk) {
        return;                       /* could not look; never a refusal */
    }
    for (i = 0; i < list.count; ++i) {
        NowAxMenu       row;
        NowAxMenuCursor cursor;
        NowAxMenuItem   entry;
        int             found = 0;

        if (now_ax_read_menu(&ctx.memory, &list, i, &row) != kNowAxOk) {
            continue;
        }
        if ((long)row.id != menu) {
            continue;
        }
        /* The item list is a packed variable-length walk with no index,
           so reaching item N means walking N-1 - and the same walk
           answers the marked-group question for free, which is why it
           runs to the end rather than stopping at the item. */
        now_ax_menu_cursor_init(&row, &cursor);
        for (;;) {
            int rc = now_ax_menu_next(&ctx.memory, &cursor, &entry);

            if (rc == kNowAxNotFound) {
                break;                /* the list's own sentinel */
            }
            if (rc != kNowAxOk) {
                /* A parse that stopped early cannot say the item is
                   absent - it can only say it did not reach it. */
                if (!found) {
                    out->verdict = kNowActMenuProbeUnknown;
                    return;
                }
                break;
            }
            out->item_count = entry.index;
            if (entry.mark != 0) {
                out->marked_group = 1;
            }
            if ((long)entry.index == item) {
                found = 1;
                memcpy(out->title, entry.title, sizeof out->title);
                out->item_marked = entry.mark != 0;
                /* A separator is reported as its own verdict rather than
                   folded into "disabled": the Menu Manager disables every
                   "-" row, and a caller told "disabled" would reasonably
                   retry once something is selected. */
                if (entry.title_len == 1 && entry.title[0] == '-') {
                    out->verdict = kNowActMenuProbeSeparator;
                } else {
                    out->verdict = entry.enabled
                                 ? kNowActMenuProbeEnabled
                                 : kNowActMenuProbeDisabled;
                }
            }
        }
        if (!found) {
            out->verdict = kNowActMenuProbeNoItem;
        }
        return;
    }
    out->verdict = kNowActMenuProbeNoMenu;
}

const char *now_act_menu_probe_code(const NowActMenuProbe *probe)
{
    if (probe == NULL) {
        return NULL;
    }
    switch (probe->verdict) {
    case kNowActMenuProbeNoMenu:    return "menu-absent";
    case kNowActMenuProbeNoItem:    return "menu-item-absent";
    case kNowActMenuProbeSeparator: return "menu-item-separator";
    case kNowActMenuProbeDisabled:  return "menu-item-disabled";
    default:                        return NULL;
    }
}

const char *now_act_menu_probe_message(const NowActMenuProbe *probe)
{
    if (probe == NULL) {
        return NULL;
    }
    switch (probe->verdict) {
    case kNowActMenuProbeNoMenu:
        return "that menu id is not in this application's menu bar, so "
               "answering its MenuSelect with the item would name a menu "
               "the application does not have";
    case kNowActMenuProbeNoItem:
        return "that menu holds fewer items than the one asked for";
    case kNowActMenuProbeSeparator:
        return "that item is a separator: the Menu Manager disables every "
               "one, and no application has a handler for it";
    case kNowActMenuProbeDisabled:
        return "that item is disabled, so the application's own command "
               "handler will ignore the press - the act would report "
               "success for something that did not happen";
    default:
        return NULL;
    }
}
