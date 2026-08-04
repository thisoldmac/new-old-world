#include <ControlDefinitions.h>
#include <Controls.h>
#include <Lists.h>
#include <LowMem.h>
#include <MacWindows.h>
#include <Menus.h>
#include <Resources.h>

#include "now_semantic_guard.h"
#include "now_semantic_logic.h"

enum { kSemanticWalkMax = 64 };

static int live_window(WindowRef want)
{
    WindowPeek window = (WindowPeek)LMGetWindowList();
    short n;
    for (n = 0; window != NULL && n < kSemanticWalkMax; ++n) {
        if ((WindowRef)window == want) return 1;
        window = window->nextWindow;
    }
    return 0;
}

static int control_below(ControlRef root, ControlRef want)
{
    ControlRef work[kSemanticWalkMax];
    short head = 0, tail = 0;
    work[tail++] = root;
    while (head < tail) {
        ControlRef node = work[head++];
        UInt16 count = 0, i;
        if (node == want) return 1;
        if (CountSubControls(node, &count) != noErr) continue;
        for (i = 1; i <= count && tail < kSemanticWalkMax; ++i) {
            ControlRef child = NULL;
            if (GetIndexedSubControl(node, i, &child) == noErr
                && child != NULL) work[tail++] = child;
        }
    }
    return 0;
}

static int live_control(NowPeekU32 window_word, NowPeekU32 control_word)
{
    WindowRef window = (WindowRef)window_word;
    ControlRef root = NULL, control = (ControlRef)control_word;
    if (!live_window(window) || GetRootControl(window, &root) != noErr
        || root == NULL || !control_below(root, control)) return 0;
    return (*control)->contrlOwner == window;
}

static NowPeekU32 list_for_control(NowPeekU32 window, NowPeekU32 control,
                                   ListHandle *list)
{
    SInt16 ldef = -1;
    Size actual = 0;
    OSErr err;
    if (!live_control(window, control)) return kNowPeekSemanticStatusInvalid;
    err = GetControlData((ControlRef)control, kControlEntireControl,
                         kControlListBoxLDEFTag, sizeof(ldef), &ldef, &actual);
    if (err != noErr || actual != sizeof(ldef))
        return kNowPeekSemanticStatusUnsupportedCustom;
    if (ldef != 0) return kNowPeekSemanticStatusUnsupportedCustom;
    actual = 0; *list = NULL;
    err = GetControlData((ControlRef)control, kControlEntireControl,
                         kControlListBoxListHandleTag, sizeof(*list),
                         list, &actual);
    if (err != noErr || actual != sizeof(*list) || *list == NULL)
        return kNowPeekSemanticStatusInvalid;
    return kNowPeekSemanticStatusOk;
}

static NowPeekU32 classify(void *ctx, NowPeekU32 window, NowPeekU32 control,
                           NowPeekU16 *kind)
{
    ListHandle list;
    NowPeekU32 status;
    (void)ctx;
    status = list_for_control(window, control, &list);
    if (status == kNowPeekSemanticStatusOk) {
        *kind = kNowPeekSemanticControlStandard;
        return status;
    }
    if (status == kNowPeekSemanticStatusUnsupportedCustom) {
        *kind = kNowPeekSemanticControlCustom;
        return status;
    }
    *kind = kNowPeekSemanticControlUnknown;
    return status;
}

typedef struct {
    MenuRef resolved_menu;
    NowPeekU32 list_control;
    short list_top, list_left;
} SemanticContext;

static NowPeekU32 bounds(void *ctx, NowPeekU32 window, NowPeekU32 control,
                         NowPeekU16 *rows, NowPeekU16 *cols)
{
    SemanticContext *semantic = (SemanticContext *)ctx;
    ListHandle list;
    ListBounds b;
    NowPeekU32 status;
    (void)ctx;
    status = list_for_control(window, control, &list);
    if (status != kNowPeekSemanticStatusOk) return status;
    b = (*list)->dataBounds;
    if (b.bottom < b.top || b.right < b.left)
        return kNowPeekSemanticStatusInvalid;
    *rows = (NowPeekU16)(b.bottom - b.top);
    *cols = (NowPeekU16)(b.right - b.left);
    semantic->list_control = control;
    semantic->list_top = b.top;
    semantic->list_left = b.left;
    return kNowPeekSemanticStatusOk;
}

static NowPeekU32 cell(void *ctx, NowPeekU32 control, NowPeekU16 row,
                       NowPeekU16 col, unsigned char *text, NowPeekU16 cap,
                       NowPeekU16 *true_length, NowPeekU32 *flags)
{
    SemanticContext *semantic = (SemanticContext *)ctx;
    ListHandle list = NULL;
    Size actual = 0;
    Cell at;
    short offset = 0, len = 0, copied;
    if (semantic->list_control != control)
        return kNowPeekSemanticStatusWrongTarget;
    if (GetControlData((ControlRef)control, kControlEntireControl,
                       kControlListBoxListHandleTag, sizeof(list), &list,
                       &actual) != noErr || list == NULL) return kNowPeekSemanticStatusInvalid;
    at.v = (short)(semantic->list_top + row);
    at.h = (short)(semantic->list_left + col);
    LGetCellDataLocation(&offset, &len, at, list);
    if (len < 0) return kNowPeekSemanticStatusInvalid;
    *true_length = (NowPeekU16)len;
    copied = len > (short)cap ? (short)cap : len;
    if (copied > 0) LGetCell(text, &copied, at, list);
    if (LGetSelect(false, &at, list)) *flags |= kNowPeekSemanticRecordSelected;
    return kNowPeekSemanticStatusOk;
}

static MenuRef resolve_menu(MenuRef shell, MenuID wanted)
{
    MenuRef installed = GetMenuHandle(wanted);
    if (installed != shell) return NULL;
    if (CountMenuItems(shell) > 0) return shell;
    /* CarbonLib's root-menu APIs are external CFM symbols. This flat 68K
       INIT cannot import them; an empty system shell is therefore explicit
       unsupported, never reported as an empty menu or guessed by position. */
    return NULL;
}

static NowPeekU32 menu_count(void *ctx, NowPeekU32 word, NowPeekI32 id,
                             NowPeekU16 *count)
{
    SemanticContext *semantic = (SemanticContext *)ctx;
    MenuRef menu = (MenuRef)word;
    MenuRef resolved;
    short n;
    if (GetMenuHandle((MenuID)id) != menu || (*menu)->menuID != (MenuID)id)
        return kNowPeekSemanticStatusWrongTarget;
    resolved = resolve_menu(menu, (MenuID)id);
    if (resolved == NULL) return kNowPeekSemanticStatusUnsupported;
    semantic->resolved_menu = resolved;
    n = CountMenuItems(resolved);
    if (n < 0) return kNowPeekSemanticStatusInvalid;
    *count = (NowPeekU16)n;
    return kNowPeekSemanticStatusOk;
}

static NowPeekU32 menu_item(void *ctx, NowPeekU32 word, NowPeekU16 item,
                            unsigned char *text, NowPeekU16 cap,
                            NowPeekU16 *true_length, NowPeekU32 *flags)
{
    Str255 title;
    CharParameter mark = 0;
    short copied;
    SemanticContext *semantic = (SemanticContext *)ctx;
    MenuRef menu = semantic->resolved_menu;
    (void)word;
    if (menu == NULL) return kNowPeekSemanticStatusInvalid;
    GetMenuItemText(menu, item, title);
    *true_length = title[0];
    copied = title[0] > cap ? cap : title[0];
    if (copied > 0) BlockMoveData(title + 1, text, copied);
    if (item > 31 || (((*menu)->enableFlags >> item) & 1UL) != 0)
        *flags |= kNowPeekSemanticRecordEnabled;
    GetItemMark(menu, item, &mark);
    if (mark != 0) *flags |= kNowPeekSemanticRecordChecked;
    if (title[0] == 1 && title[1] == '-')
        *flags |= kNowPeekSemanticRecordSeparator;
    return kNowPeekSemanticStatusOk;
}

void now_semantic_apply(NowPeekTable *table, NowPeekU32 ticks)
{
    NowSemanticSource source;
    SemanticContext context;
    NowSemanticRequestVerdict verdict = now_semantic_request_verdict(
        table, (NowPeekU32)LMGetCurrentA5(), ticks);
    if (table->semantic.response_request_generation
            == table->semantic.request_generation
        && table->semantic.response_writer_epoch
            == table->semantic.request_writer_epoch
        && table->semantic.response_generation != 0
        && (table->semantic.response_generation & 1U) == 0) return;
    if (verdict == kNowSemanticWrongTarget || verdict == kNowSemanticNoPlane)
        return;
    context.resolved_menu = NULL; context.list_control = 0;
    context.list_top = 0; context.list_left = 0;
    source.ctx = &context; source.classify_control = classify;
    source.list_bounds = bounds; source.list_cell = cell;
    source.menu_count = menu_count; source.menu_item = menu_item;
    if (verdict == kNowSemanticStale)
        now_semantic_refuse(&table->semantic, ticks, kNowPeekSemanticStatusStale);
    else if (verdict == kNowSemanticBadRequest)
        now_semantic_refuse(&table->semantic, ticks, kNowPeekSemanticStatusInvalid);
    else now_semantic_resolve(&table->semantic, ticks, &source);
}
