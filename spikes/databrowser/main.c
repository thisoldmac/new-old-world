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
    kWinHeight = 420,
    kLineHeight = 12,
    kMaxLines = 64
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

static const char *const kIconServices[] = {
    "GetIconRefFromTypeInfo",
    "GetIconRefFromFile",
    "PlotIconRef",
    "ReleaseIconRef",
    "AcquireIconRef"
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
           found == count ? " — all of them" : "");
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
    icons = probe_group("CarbonLib", "Icon Services", kIconServices,
                        (int)(sizeof kIconServices / sizeof kIconServices[0]));
    report("");
    list = probe_group("InterfaceLib", "List Manager (fallback)",
                       kListManager,
                       (int)(sizeof kListManager / sizeof kListManager[0]));
    report("");
    report("VERDICT");
    if (browser) {
        report("  Data Browser is available. The native list is possible;");
        report("  the cost is hand-declaring its ABI (no headers exist).");
        report(icons ? "  Icons available too."
                     : "  Icon Services INCOMPLETE — list would be text-only.");
    } else {
        report("  Data Browser is NOT available here. Phase 2 uses the");
        report(list ? "  List Manager, which is present."
                    : "  List Manager — WHICH IS ALSO INCOMPLETE. Investigate.");
    }
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
    for (i = 0; i < g_count; ++i) {
        MoveTo(12, 20 + i * kLineHeight);
        CopyCStringToPascal(g_lines[i], text);
        DrawString(text);
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

    run_probe();
    write_report();

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
            if (FindWindow(event.where, &which) == inDrag) {
                Rect drag;

                GetRegionBounds(GetGrayRgn(), &drag);
                DragWindow(which, event.where, &drag);
            }
            break;
        }
        case keyDown:
            if ((event.message & charCodeMask) == 'q'
                || (event.message & charCodeMask) == 'Q') {
                running = false;
            }
            break;
        }
    }
    return 0;
}
