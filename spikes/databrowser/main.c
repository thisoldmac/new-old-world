/* Data Browser spike — see README.md.
 *
 * Asks CarbonLib, by name, whether it exports what a native file list
 * would need. Resolving a symbol neither calls it nor lays out a
 * struct, so this cannot wedge the machine: the point is to find out
 * whether the expensive, uncheckable ABI work is worth starting. */

#include <Carbon.h>

#include <stdarg.h>

#include <stdio.h>
#include <string.h>

enum {
    kWinWidth = 460,
    kWinHeight = 460,
    kLineHeight = 12,
    kMaxLines = 64,
    kListTop = 250            /* report above, real control below */
};

static WindowRef g_window;
static char g_lines[kMaxLines][96];
static int g_count;

static void report(const char *fmt, ...)
{
    va_list args;

    if (g_count >= kMaxLines) {
        return;
    }
    va_start(args, fmt);
    vsnprintf(g_lines[g_count], sizeof g_lines[0], fmt, args);
    va_end(args);
    ++g_count;
}

/* --- the probe ---------------------------------------------------------- */

/* Groups so the report reads as an answer, not a list of symbols. */
typedef struct {
    const char *fragment;             /* CFM fragment to look in */
    const char *title;
    const char *const *symbols;
    int count;
} SymbolGroup;

static const char *const kDataBrowser[] = {
    /* Everything a sortable, icon-bearing, multi-selectable list needs. */
    "CreateDataBrowserControl",
    "InitDataBrowserCallbacks",
    "SetDataBrowserCallbacks",
    "AddDataBrowserListViewColumn",
    "AddDataBrowserItems",
    "RemoveDataBrowserItems",
    "UpdateDataBrowserItems",
    "SetDataBrowserItemDataText",
    "SetDataBrowserItemDataIcon",
    "NewDataBrowserItemDataUPP",
    "NewDataBrowserItemNotificationUPP",
    "GetDataBrowserItemDataText",
    "SetDataBrowserSelectionFlags",
    "GetDataBrowserSelectionAnchor",
    "IsDataBrowserItemSelected",
    "SetDataBrowserSortProperty",
    "SetDataBrowserSortOrder",
    "SetDataBrowserListViewHeaderBtnHeight",
    "SetDataBrowserTableViewNamedColumnWidth",
    "SetDataBrowserHasScrollBars",
    "SetDataBrowserTableViewRowHeight",
    "GetDataBrowserItems"
};

/* Two separate questions, because a file browser asks both. For the
   guest's OWN files there is an FSSpec and GetIconRefFromFile is the
   best answer - it picks up custom icons the Finder shows. For a
   listing that arrived over the WIRE there is no file, only a type and
   creator, so a type/creator lookup is the only way to draw anything.
   The first round found GetIconRefFromTypeInfo missing; these are the
   other doors into the same room. */
static const char *const kIconFromFile[] = {
    "GetIconRefFromFile",
    "PlotIconRef",
    "ReleaseIconRef",
    "AcquireIconRef",
    "PlotIconRefInContext"
};

static const char *const kIconFromType[] = {
    "GetIconRef",                     /* vRefNum + creator + type */
    "GetIconRefFromTypeInfo",         /* absent in CarbonLib 1.6.0 */
    "GetIconRefFromFolder",
    "RegisterIconRefFromResource",
    "GetIconRefFromComponent"
};

/* The pre-Icon-Services way, in case none of the above answers. */
static const char *const kIconSuites[] = {
    "GetIconSuite",
    "PlotIconSuite",
    "DisposeIconSuite",
    "PlotIconHandle",
    "GetIcon"
};

/* The fallback. Reported so it is CONFIRMED rather than assumed — a
   plan B nobody checked is not a plan B. */
static const char *const kListManager[] = {
    "LNew",
    "LAddRow",
    "LSetCell",
    "LUpdate",
    "LClick",
    "LGetSelect",
    "LSetSelect",
    "LDispose"
};

static int probe_group(const char *fragment, const char *title,
                       const char *const *symbols, int count)
{
    CFragConnectionID conn = 0;
    Ptr mainAddr = NULL;
    Str255 errName;
    Str255 pname;
    CFragSymbolClass cls;
    Ptr address;
    OSErr err;
    int found = 0;
    int i;

    pname[0] = (unsigned char)strlen(fragment);
    memcpy(pname + 1, fragment, pname[0]);
    err = GetSharedLibrary(pname, kPowerPCCFragArch, kReferenceCFrag,
                           &conn, &mainAddr, errName);
    if (err != noErr) {
        report("%s: fragment \"%s\" not found (%d)", title, fragment,
               (int)err);
        return 0;
    }

    report("%s  (in %s)", title, fragment);
    for (i = 0; i < count; ++i) {
        pname[0] = (unsigned char)strlen(symbols[i]);
        memcpy(pname + 1, symbols[i], pname[0]);
        address = NULL;
        err = FindSymbol(conn, pname, &address, &cls);
        if (err == noErr && address != NULL) {
            ++found;
        } else {
            report("   MISSING  %s (%d)", symbols[i], (int)err);
        }
    }
    report("   %d of %d present%s", found, count,
           found == count ? " - all of them" : "");
    return found == count;
}

static void probe_versions(void)
{
    long value = 0;

    if (Gestalt(gestaltSystemVersion, &value) == noErr) {
        report("System %ld.%ld.%ld", (value >> 8) & 0xF, (value >> 4) & 0xF,
               value & 0xF);
    }
    if (Gestalt('cbon', &value) == noErr) {
        report("CarbonLib %ld.%ld.%ld", (value >> 8) & 0xFF,
               (value >> 4) & 0xF, value & 0xF);
    } else {
        report("CarbonLib: no 'cbon' Gestalt (not installed?)");
    }
    if (Gestalt('apvr', &value) == noErr) {
        report("Appearance %ld.%ld.%ld", (value >> 8) & 0xFF,
               (value >> 4) & 0xF, value & 0xF);
    } else {
        report("Appearance: no 'apvr' Gestalt");
    }
}

static void run_probe(void)
{
    int browser, icons, list;

    probe_versions();
    report("");
    browser = probe_group("CarbonLib", "Data Browser", kDataBrowser,
                          (int)(sizeof kDataBrowser / sizeof kDataBrowser[0]));
    report("");
    icons = probe_group("CarbonLib", "Icons: from a file", kIconFromFile,
                        (int)(sizeof kIconFromFile / sizeof kIconFromFile[0]));
    report("");
    probe_group("CarbonLib", "Icons: from a type/creator", kIconFromType,
                (int)(sizeof kIconFromType / sizeof kIconFromType[0]));
    report("");
    probe_group("InterfaceLib", "Icons: the old suites", kIconSuites,
                (int)(sizeof kIconSuites / sizeof kIconSuites[0]));
    report("");
    list = probe_group("InterfaceLib", "List Manager (fallback)",
                       kListManager,
                       (int)(sizeof kListManager / sizeof kListManager[0]));
    report("");
    report("VERDICT");
    if (browser) {
        report("  Data Browser is available. The native list is possible;");
        report("  the cost is hand-declaring its ABI (no headers exist).");
        report(icons ? "  Icons for local files: yes."
                     : "  Icons for local files: NO.");
        report("  For a listing off the WIRE there is no file, so read the");
        report("  type/creator group above: that is what can draw an icon.");
    } else {
        report("  Data Browser is NOT available here. Phase 2 uses the");
        report(list ? "  List Manager, which is present."
                    : "  List Manager - WHICH IS ALSO INCOMPLETE. Investigate.");
    }
}

/* --- the control itself -------------------------------------------------
   The probe says the symbols are there and the headers declare them.
   What neither can say is whether the control BEHAVES: draws native,
   sorts when a header is clicked, reports selection and double-clicks.
   Three hardcoded rows answer that, and cost nothing if the answer is
   no. */

enum {
    kColName = 'name',
    kColKind = 'kind',
    kColSize = 'size'
};

typedef struct {
    const char *name;
    const char *kind;
    long size;
} SpikeRow;

static const SpikeRow kRows[] = {
    { "Read Me", "SimpleText document", 4096 },
    { "System Folder", "folder", 0 },
    { "Zebra.jpg", "JPEG image", 81920 }
};

static void step(const char *what);

static ControlRef g_browser;
static char g_events[4][80];
static int g_event_count;

static void note_event(const char *fmt, ...)
{
    va_list args;
    int i;

    if (g_event_count == 4) {         /* keep the last four */
        for (i = 0; i < 3; ++i) {
            memcpy(g_events[i], g_events[i + 1], sizeof g_events[0]);
        }
        --g_event_count;
    }
    va_start(args, fmt);
    vsnprintf(g_events[g_event_count], sizeof g_events[0], fmt, args);
    va_end(args);
    ++g_event_count;
    {
        Rect strip;

        SetRect(&strip, 12, kListTop - 46, kWinWidth - 12, kListTop - 4);
        InvalWindowRect(g_window, &strip);
    }
}

/* What the browser asks us for, one cell at a time. */
static OSStatus item_data(ControlRef browser, DataBrowserItemID item,
                          DataBrowserPropertyID property,
                          DataBrowserItemDataRef data, Boolean changeValue)
{
    const SpikeRow *row;
    CFStringRef text;
    char buf[32];

    (void)browser;
    if (changeValue || item < 1
        || item > (DataBrowserItemID)(sizeof kRows / sizeof kRows[0])) {
        return errDataBrowserPropertyNotSupported;
    }
    row = &kRows[item - 1];
    switch (property) {
    case kColName: text = CFStringCreateWithCString(NULL, row->name,
                                                    kCFStringEncodingMacRoman);
        break;
    case kColKind: text = CFStringCreateWithCString(NULL, row->kind,
                                                    kCFStringEncodingMacRoman);
        break;
    case kColSize:
        if (row->size == 0) {
            strcpy(buf, "--");
        } else {
            snprintf(buf, sizeof buf, "%ld K", row->size / 1024);
        }
        text = CFStringCreateWithCString(NULL, buf,
                                         kCFStringEncodingMacRoman);
        break;
    default:
        return errDataBrowserPropertyNotSupported;
    }
    if (text == NULL) {
        return memFullErr;
    }
    SetDataBrowserItemDataText(data, text);
    CFRelease(text);
    return noErr;
}

/* Selection and opening, which is what a file browser is made of. */
static void item_notify(ControlRef browser, DataBrowserItemID item,
                        DataBrowserItemNotification message)
{
    (void)browser;
    if (item < 1
        || item > (DataBrowserItemID)(sizeof kRows / sizeof kRows[0])) {
        return;
    }
    switch (message) {
    case kDataBrowserItemSelected:
        note_event("selected: %s", kRows[item - 1].name);
        break;
    case kDataBrowserItemDoubleClicked:
        note_event("opened: %s", kRows[item - 1].name);
        break;
    default:
        break;
    }
}

static OSStatus add_column(DataBrowserPropertyID id, const char *title,
                           UInt16 width, Boolean isName, DataBrowserTableViewColumnIndex at)
{
    DataBrowserListViewColumnDesc col;
    OSStatus err;

    memset(&col, 0, sizeof col);
    col.propertyDesc.propertyID = id;
    col.propertyDesc.propertyType = kDataBrowserTextType;
    col.propertyDesc.propertyFlags = kDataBrowserListViewSortableColumn
        | (isName ? kDataBrowserListViewSelectionColumn : 0);
    col.headerBtnDesc.version = kDataBrowserListViewLatestHeaderDesc;
    col.headerBtnDesc.minimumWidth = 40;
    col.headerBtnDesc.maximumWidth = 400;
    col.headerBtnDesc.titleOffset = 0;
    col.headerBtnDesc.initialOrder = kDataBrowserOrderIncreasing;
    col.headerBtnDesc.btnFontStyle.flags = 0;
    col.headerBtnDesc.btnContentInfo.contentType = kControlContentTextOnly;
    col.headerBtnDesc.titleString =
        CFStringCreateWithCString(NULL, title, kCFStringEncodingMacRoman);
    err = AddDataBrowserListViewColumn(g_browser, &col, at);
    if (col.headerBtnDesc.titleString != NULL) {
        CFRelease(col.headerBtnDesc.titleString);
    }
    if (err == noErr) {
        SetDataBrowserTableViewNamedColumnWidth(g_browser, id, width);
    }
    return err;
}

static void build_browser(void)
{
    Rect bounds;
    DataBrowserCallbacks callbacks;
    DataBrowserItemID ids[3];
    OSStatus err;
    int i;

    SetRect(&bounds, 12, kListTop, kWinWidth - 12, kWinHeight - 12);
    step("about to CreateDataBrowserControl");
    err = CreateDataBrowserControl(g_window, &bounds, kDataBrowserListView,
                                   &g_browser);
    if (err != noErr) {
        report("CreateDataBrowserControl FAILED (%d)", (int)err);
        return;
    }

    memset(&callbacks, 0, sizeof callbacks);
    callbacks.version = kDataBrowserLatestCallbacks;
    InitDataBrowserCallbacks(&callbacks);
    /* These MUST be real UPPs. This runtime is TARGET_RT_MAC_CFM, where
       MixedMode.h makes STACK_UPP_TYPE a UniversalProcPtr - a routine
       descriptor, not a bare pointer. Casting a C function to one and
       handing it to the Toolbox is how the first cut of this spike
       died: it jumps into what it expects to be a descriptor, finds
       function prologue, and executes it. Type 3, immediately.
       (A cast IS right on Mach-O, where STACK_UPP_TYPE is identity.
       Runtime, not architecture, decides.) */
    step("about to build the UPPs");
    callbacks.u.v1.itemDataCallback = NewDataBrowserItemDataUPP(item_data);
    callbacks.u.v1.itemNotificationCallback =
        NewDataBrowserItemNotificationUPP(item_notify);
    if (callbacks.u.v1.itemDataCallback == NULL
        || callbacks.u.v1.itemNotificationCallback == NULL) {
        report("NewDataBrowser*UPP returned NULL - cannot install callbacks");
        return;
    }
    step("about to SetDataBrowserCallbacks");
    err = SetDataBrowserCallbacks(g_browser, &callbacks);
    if (err != noErr) {
        report("SetDataBrowserCallbacks FAILED (%d)", (int)err);
        return;
    }

    step("about to add the Name column");
    err = add_column(kColName, "Name", 200, true, 0);
    if (err != noErr) {
        report("AddDataBrowserListViewColumn FAILED (%d)", (int)err);
        return;
    }
    add_column(kColKind, "Kind", 140, false, 1);
    add_column(kColSize, "Size", 60, false, 2);

    SetDataBrowserListViewHeaderBtnHeight(g_browser, 16);
    SetDataBrowserHasScrollBars(g_browser, false, true);
    SetDataBrowserSelectionFlags(g_browser, kDataBrowserCmdTogglesSelection);
    SetDataBrowserSortProperty(g_browser, kColName);

    for (i = 0; i < 3; ++i) {
        ids[i] = (DataBrowserItemID)(i + 1);
    }
    step("about to AddDataBrowserItems");
    err = AddDataBrowserItems(g_browser, kDataBrowserNoItem, 3, ids,
                              kDataBrowserItemNoProperty);
    if (err != noErr) {
        report("AddDataBrowserItems FAILED (%d)", (int)err);
        return;
    }
    step("control built");
    report("Control built. Click a row, double-click, click a header.");
}

/* --- getting the answer off the machine --------------------------------- */

static void write_report(void)
{
    FSSpec spec;
    short vref;
    long dir;
    short ref;
    Str255 name;
    int i;

    if (FindFolder(kOnSystemDisk, kDesktopFolderType, kDontCreateFolder,
                   &vref, &dir) != noErr) {
        return;
    }
    CopyCStringToPascal("Data Browser Spike Report", name);
    if (FSMakeFSSpec(vref, dir, name, &spec) == fnfErr) {
        FSpCreate(&spec, 'ttxt', 'TEXT', smSystemScript);
    }
    if (FSpOpenDF(&spec, fsWrPerm, &ref) != noErr) {
        return;
    }
    SetEOF(ref, 0);
    for (i = 0; i < g_count; ++i) {
        long len = (long)strlen(g_lines[i]);

        FSWrite(ref, &len, g_lines[i]);
        len = 1;
        FSWrite(ref, &len, "\r");     /* classic line endings, on purpose */
    }
    FSClose(ref);
}

/* A crash cannot report itself, so each risky step is written to disk
   BEFORE it is taken and the file is closed again immediately. After a
   Type 3 the last line on the desktop names what was being attempted.
   Slow and worth it: one run of a crashing program then answers the
   question instead of costing a deploy cycle to narrow. */
static void step(const char *what)
{
    FSSpec spec;
    short vref;
    long dir;
    short ref;
    Str255 name;
    long len;

    if (FindFolder(kOnSystemDisk, kDesktopFolderType, kDontCreateFolder,
                   &vref, &dir) != noErr) {
        return;
    }
    CopyCStringToPascal("Data Browser Spike Steps", name);
    if (FSMakeFSSpec(vref, dir, name, &spec) == fnfErr) {
        FSpCreate(&spec, 'ttxt', 'TEXT', smSystemScript);
    }
    if (FSpOpenDF(&spec, fsWrPerm, &ref) != noErr) {
        return;
    }
    SetFPos(ref, fsFromLEOF, 0);
    len = (long)strlen(what);
    FSWrite(ref, &len, what);
    len = 1;
    FSWrite(ref, &len, "\r");
    FSClose(ref);
}

/* --- window ------------------------------------------------------------- */

static void draw(void)
{
    Rect bounds;
    Str255 text;
    int i;

    SetPortWindowPort(g_window);
    GetWindowPortBounds(g_window, &bounds);
    EraseRect(&bounds);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    for (i = 0; i < g_count && 20 + i * kLineHeight < kListTop - 50; ++i) {
        MoveTo(12, 20 + i * kLineHeight);
        CopyCStringToPascal(g_lines[i], text);
        DrawString(text);
    }
    for (i = 0; i < g_event_count; ++i) {
        MoveTo(12, kListTop - 42 + i * kLineHeight);
        CopyCStringToPascal(g_events[i], text);
        DrawString(text);
    }
    {
        RgnHandle visible = NewRgn();

        if (visible != NULL) {
            GetPortVisibleRegion(GetWindowPort(g_window), visible);
            UpdateControls(g_window, visible);
            DisposeRgn(visible);
        }
    }
}

int main(void)
{
    EventRecord event;
    Rect bounds;
    Str255 title;
    Boolean running = true;

    InitCursor();
    SetRect(&bounds, 40, 60, 40 + kWinWidth, 60 + kWinHeight);
    CreateNewWindow(kDocumentWindowClass, kWindowCloseBoxAttribute,
                    &bounds, &g_window);
    if (g_window == NULL) {
        return 1;
    }
    CopyCStringToPascal("Data Browser Spike", title);
    SetWTitle(g_window, title);
    SetThemeWindowBackground(g_window, kThemeBrushDialogBackgroundActive,
                             true);
    ShowWindow(g_window);
    SelectWindow(g_window);

    /* One run per file: a log that accumulates across launches makes
       the reader work out which section is today's. */
    {
        FSSpec old_log;
        short vref;
        long dir;
        Str255 name;

        CopyCStringToPascal("Data Browser Spike Steps", name);
        if (FindFolder(kOnSystemDisk, kDesktopFolderType, kDontCreateFolder,
                       &vref, &dir) == noErr
            && FSMakeFSSpec(vref, dir, name, &old_log) == noErr) {
            FSpDelete(&old_log);
        }
    }
    step("launched");
    run_probe();
    write_report();
    step("probe done");
    build_browser();

    while (running) {
        if (!WaitNextEvent(everyEvent, &event, 20, NULL)) {
            continue;
        }
        switch (event.what) {
        case updateEvt:
            BeginUpdate(g_window);
            draw();
            EndUpdate(g_window);
            break;
        case mouseDown: {
            WindowRef which;

            if (FindWindow(event.where, &which) == inGoAway
                && TrackGoAway(which, event.where)) {
                running = false;
            }
            if (FindWindow(event.where, &which) == inContent
                && which == g_window) {
                Point local = event.where;

                SetPortWindowPort(g_window);
                GlobalToLocal(&local);
                /* The control wants the raw click: it runs its own
                   tracking for selection, dragging and header sorts. */
                HandleControlClick(g_browser, local, event.modifiers, NULL);
            }
            if (FindWindow(event.where, &which) == inDrag) {
                Rect drag;

                GetRegionBounds(GetGrayRgn(), &drag);
                DragWindow(which, event.where, &drag);
            }
            break;
        }
        case keyDown: {
            char c = (char)(event.message & charCodeMask);

            if ((event.modifiers & cmdKey) && (c == 'q' || c == 'Q')) {
                running = false;
                break;
            }
            /* Type-select and arrow keys are the control's business. */
            if (g_browser != NULL) {
                HandleControlKey(g_browser, (SInt16)((event.message
                                                      & keyCodeMask) >> 8),
                                 c, event.modifiers);
            }
            break;
        }
        }
    }
    return 0;
}
