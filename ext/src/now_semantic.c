#include <ControlDefinitions.h>
#include <Controls.h>
#include <DateTimeUtils.h>
#include <Lists.h>
#include <LowMem.h>
#include <MacWindows.h>
#include <Menus.h>
#include <Resources.h>

#include "now_semantic_guard.h"
#include "now_semantic_logic.h"

/* The ceiling is the contract's, not this file's: the application pages
   against the same number and the guard refuses a start ordinal beyond
   it. See kNowPeekSemanticBatchWalkMax in peek_table.h. */
enum { kSemanticWalkMax = kNowPeekSemanticBatchWalkMax };

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

/* The bounded breadth-first hierarchy walk, with its result KEPT.
   It used to be spent proving one control's membership and then thrown
   away, which is why classifying a window cost one walk per control. The
   walk is the expensive half; the controls it enumerates are the answer
   to the batched question. Returns how many it found, never more than
   `cap`, and the root is deliberately included - a window's root control
   is a control a person can see.

   The queue is the CALLER'S buffer and holds control words rather than
   ControlRefs, so the batch path does not carry a second 64-entry frame
   on top of the one it already fills. This code runs from a system-wide
   event filter, on whatever stack the interrupted application had; 256
   bytes is a bound worth keeping rather than doubling for tidiness. The
   casts are scalar, per element - the array is never aliased as two
   pointer types. */
static short collect_below(ControlRef root, NowPeekU32 *out, short cap)
{
    short head = 0, tail = 0;
    if (cap <= 0) return 0;
    out[tail++] = (NowPeekU32)root;
    while (head < tail) {
        ControlRef node = (ControlRef)out[head++];
        UInt16 count = 0, i;
        if (CountSubControls(node, &count) != noErr) continue;
        for (i = 1; i <= count && tail < cap; ++i) {
            ControlRef child = NULL;
            if (GetIndexedSubControl(node, i, &child) == noErr
                && child != NULL) out[tail++] = (NowPeekU32)child;
        }
    }
    return tail;
}

static int control_below(ControlRef root, ControlRef want)
{
    NowPeekU32 work[kSemanticWalkMax];
    short found = collect_below(root, work, kSemanticWalkMax);
    short i;
    for (i = 0; i < found; ++i) {
        if (work[i] == (NowPeekU32)want) return 1;
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
    ControlKind kind;
    Size actual = 0;
    OSErr err;
    int apple_list;
    if (!live_control(window, control)) return kNowPeekSemanticStatusInvalid;
    err = GetControlData((ControlRef)control, kControlEntireControl,
                         kControlKindTag, sizeof(kind), &kind, &actual);
    if (err == noErr && actual == sizeof(kind)
        && kind.signature == kControlKindSignatureApple
        && kind.kind != kControlKindListBox)
        return kNowPeekSemanticStatusUnsupported;
    apple_list = err == noErr && actual == sizeof(kind)
        && kind.signature == kControlKindSignatureApple
        && kind.kind == kControlKindListBox;
    actual = 0; *list = NULL;
    err = GetControlData((ControlRef)control, kControlEntireControl,
                         kControlListBoxListHandleTag, sizeof(*list),
                         list, &actual);
    if (err != noErr || actual != sizeof(*list) || *list == NULL) {
        /* An Apple list which withholds its documented ListHandle is
           internally inconsistent. A custom control which simply declines
           the tag remains explicitly custom instead. */
        return err == noErr || apple_list
                ? kNowPeekSemanticStatusInvalid
                : kNowPeekSemanticStatusUnsupportedCustom;
    }
    return kNowPeekSemanticStatusOk;
}

static void copy_text(const unsigned char *source, NowPeekU16 length,
                      unsigned char *text, NowPeekU16 cap,
                      NowPeekU16 *true_length)
{
    NowPeekU16 copied = length < cap ? length : cap;
    if (copied != 0) BlockMoveData(source, text, copied);
    *true_length = length;
}

static NowPeekU32 control_text(ControlRef control, ResType tag,
                               unsigned char *text, NowPeekU16 cap,
                               NowPeekU16 *true_length)
{
    unsigned char value[256];
    Size size = 0, actual = 0;
    OSErr err = GetControlDataSize(control, kControlEntireControl,
                                   tag, &size);
    if (err != noErr || size < 0) return kNowPeekSemanticStatusUnsupported;
    *true_length = size > 0xffffL ? 0xffff : (NowPeekU16)size;
    if (size > (Size)sizeof value) return kNowPeekSemanticStatusTruncated;
    err = GetControlData(control, kControlEntireControl, tag, size,
                         value, &actual);
    if (err != noErr || actual != size)
        return kNowPeekSemanticStatusUnsupported;
    copy_text(value, (NowPeekU16)size, text, cap, true_length);
    return size > cap ? kNowPeekSemanticStatusTruncated
                      : kNowPeekSemanticStatusOk;
}

static NowPeekU32 clock_text(ControlRef control, unsigned char *text,
                             NowPeekU16 cap, NowPeekU16 *true_length)
{
    LongDateRec date;
    LongDateTime seconds;
    Str255 value;
    Size actual = 0;
    ControlVariant variant;
    OSErr err = GetControlData(control, kControlEntireControl,
                               kControlClockLongDateTag, sizeof(date),
                               &date, &actual);
    if (err != noErr || actual != sizeof(date))
        return kNowPeekSemanticStatusUnsupported;
    LongDateToSeconds(&date, &seconds);
    variant = GetControlVariant(control);
    if (variant == (kControlClockTimeProc & 0x0f)
        || variant == (kControlClockTimeSecondsProc & 0x0f)) {
        LongTimeString(&seconds,
                       variant == (kControlClockTimeSecondsProc & 0x0f),
                       value, NULL);
    } else {
        LongDateString(&seconds, shortDate, value, NULL);
    }
    copy_text(value + 1, value[0], text, cap, true_length);
    return value[0] > cap ? kNowPeekSemanticStatusTruncated
                          : kNowPeekSemanticStatusOk;
}

static NowPeekU16 compact_kind(OSType kind)
{
    if (kind == kControlKindListBox) return kNowPeekSemanticControlListBox;
    if (kind == kControlKindClock) return kNowPeekSemanticControlClock;
    if (kind == kControlKindGroupBox) return kNowPeekSemanticControlGroupBox;
    if (kind == kControlKindEditText) return kNowPeekSemanticControlEditText;
    if (kind == kControlKindStaticText) return kNowPeekSemanticControlStaticText;
    if (kind == kControlKindWindowHeader)
        return kNowPeekSemanticControlWindowHeader;
    if (kind == kControlKindPushButton)
        return kNowPeekSemanticControlPushButton;
    if (kind == kControlKindCheckBox) return kNowPeekSemanticControlCheckBox;
    if (kind == kControlKindRadioButton)
        return kNowPeekSemanticControlRadioButton;
    if (kind == kControlKindPopupButton)
        return kNowPeekSemanticControlPopupButton;
    if (kind == kControlKindScrollBar) return kNowPeekSemanticControlScrollBar;
    if (kind == kControlKindDataBrowser)
        return kNowPeekSemanticControlDataBrowser;
    if (kind == kControlKindUserPane) return kNowPeekSemanticControlUserPane;
    if (kind == kControlKindImageWell) return kNowPeekSemanticControlImageWell;
    return kNowPeekSemanticControlOtherSystem;
}

/* Type a control whose membership is ALREADY PROVEN - either by the
   caller's live_control, or by the batch walk that produced it. Nothing
   here re-validates: doing so per control is precisely the cost that made
   batching worth building. */
static NowPeekU32 classify_member(void *ctx, NowPeekU32 window,
                                  NowPeekU32 control, NowPeekU16 *kind,
                                  unsigned char *text, NowPeekU16 cap,
                                  NowPeekU16 *true_length, NowPeekU32 *flags)
{
    ControlKind system_kind;
    Size actual = 0;
    OSErr err;
    (void)ctx;
    (void)window;
    *true_length = 0;
    *flags = 0;
    err = GetControlData((ControlRef)control, kControlEntireControl,
                         kControlKindTag, sizeof(system_kind), &system_kind,
                         &actual);
    if (err != noErr || actual != sizeof(system_kind)
        || system_kind.signature != kControlKindSignatureApple) {
        ListHandle list = NULL;
        Size list_actual = 0;
        OSErr list_err = GetControlData(
            (ControlRef)control, kControlEntireControl,
            kControlListBoxListHandleTag, sizeof(list), &list, &list_actual);

        /* Some Appearance-era controls use an application/CDEF signature
           while still publishing the standard List Manager handle through
           the public Control Manager tag. The capability is the evidence:
           exact success, exact size, non-null handle. No resource ID or
           private contrlData layout participates. */
        if (list_err == noErr && list_actual == sizeof(list) && list != NULL) {
            *kind = kNowPeekSemanticControlListBox;
            return kNowPeekSemanticStatusOk;
        }
        *kind = kNowPeekSemanticControlCustom;
        return kNowPeekSemanticStatusUnsupportedCustom;
    }
    *kind = compact_kind(system_kind.kind);
    if (*kind == kNowPeekSemanticControlClock)
        return clock_text((ControlRef)control, text, cap, true_length);
    if (*kind == kNowPeekSemanticControlEditText)
        return control_text((ControlRef)control, kControlEditTextTextTag,
                            text, cap, true_length);
    if (*kind == kNowPeekSemanticControlStaticText)
        return control_text((ControlRef)control, kControlStaticTextTextTag,
                            text, cap, true_length);
    return kNowPeekSemanticStatusOk;
}

static NowPeekU32 classify(void *ctx, NowPeekU32 window, NowPeekU32 control,
                           NowPeekU16 *kind, unsigned char *text,
                           NowPeekU16 cap, NowPeekU16 *true_length,
                           NowPeekU32 *flags)
{
    *true_length = 0;
    *flags = 0;
    if (!live_control(window, control)) return kNowPeekSemanticStatusInvalid;
    return classify_member(ctx, window, control, kind, text, cap,
                           true_length, flags);
}

/* The batch's walk. It proves the window is live exactly once, then hands
   back everything under its root - the membership proof and the answer
   are the same traversal. */
static NowPeekU16 collect_controls(void *ctx, NowPeekU32 window,
                                   NowPeekU32 *out, NowPeekU16 cap)
{
    ControlRef root = NULL;
    short found, i, kept = 0;
    (void)ctx;

    if (!live_window((WindowRef)window)
        || GetRootControl((WindowRef)window, &root) != noErr
        || root == NULL) return 0;
    /* Straight into the caller's buffer - see collect_below on why there
       is no second frame here. */
    found = collect_below(root, out,
                          cap < kSemanticWalkMax ? (short)cap
                                                 : kSemanticWalkMax);
    for (i = 0; i < found; ++i) {
        ControlRef control = (ControlRef)out[i];

        /* The same ownership check the single-control path makes, kept
           per control rather than dropped because the walk was bounded:
           a control reached through this root must still say it belongs
           to this window. Filtering in place is safe - kept never runs
           ahead of i. */
        if (control != NULL
            && (*control)->contrlOwner == (WindowRef)window) {
            out[kept++] = (NowPeekU32)control;
        }
    }
    return (NowPeekU16)kept;
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

/* P2's second cell, served on the same pass and under the same rules.
   It is a separate entry point because it is a separate lease: the two
   cells no longer compete, which is the transport half of why 121
   controls never carried a kind. */
void now_semantic_batch_apply(NowPeekTable *table, NowPeekU32 ticks)
{
    NowSemanticBatchSource source;
    NowSemanticRequestVerdict verdict;

    if (!now_semantic_batch_ready(table)) return;
    verdict = now_semantic_batch_verdict(
        table, (NowPeekU32)LMGetCurrentA5(), ticks);
    if (table->semantic_batch.response_request_generation
            == table->semantic_batch.request_generation
        && table->semantic_batch.response_writer_epoch
            == table->semantic_batch.request_writer_epoch
        && table->semantic_batch.response_generation != 0
        && (table->semantic_batch.response_generation & 1U) == 0) return;
    if (verdict == kNowSemanticWrongTarget || verdict == kNowSemanticNoPlane)
        return;
    source.ctx = NULL;
    source.collect = collect_controls;
    source.classify_member = classify_member;
    if (verdict == kNowSemanticStale)
        now_semantic_batch_refuse(&table->semantic_batch, ticks,
                                  kNowPeekSemanticStatusStale);
    else if (verdict == kNowSemanticBadRequest)
        now_semantic_batch_refuse(&table->semantic_batch, ticks,
                                  kNowPeekSemanticStatusInvalid);
    else
        now_semantic_batch_resolve(&table->semantic_batch, ticks, &source);
}
