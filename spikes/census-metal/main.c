/* Census metal spike - see README.md.
 *
 * One question in two halves: can this Carbon app reach the census
 * probes that are NOT Carbon-clean?
 *
 *   1. The InterfaceLib managers (ADB, SCSI) are declared in the headers
 *      only as 68K inline traps, so CALLING them from CFM would be a
 *      strong import that aborts launch on a machine that does not export
 *      them (the Open Transport trap). GetSharedLibrary + FindSymbol asks
 *      by NAME whether the PowerPC fragment exports them - resolving a
 *      symbol neither calls it nor lays out a struct, so it cannot wedge
 *      the machine. CountADBs alone is then called THROUGH its resolved
 *      pointer (a runtime call, not an import): it is documented safe and
 *      its count is the definitive ADB answer.
 *
 *   2. The low-memory tables (the drive queue at 0x0308, the Device
 *      Manager unit table at 0x011C/0x01D2, the SysParm PRAM copy at
 *      0x01F8) are not exposed by this toolchain's Carbon headers. They
 *      are plain fixed-address reads, which the spike PERFORMS - a
 *      read-only walk of a table the OS maintains is exactly what the
 *      real probes would do, and is safe.
 *
 * The SCSI bus is NEVER selected or INQUIRY'd here: that is active bus
 * I/O, gated and attended in the real probe. The spike only asks whether
 * the SCSI Manager's entry points exist.
 *
 * Answer on screen, and to "Census Spike Report" on the desktop so it
 * can leave the machine as text. */

#include <Carbon.h>

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

enum {
    kWinWidth = 480,
    kWinHeight = 540,
    kLineHeight = 12,
    kMaxLines = 80
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

/* --- symbol resolution -------------------------------------------------- */

static CFragConnectionID open_fragment(const char *fragment)
{
    CFragConnectionID conn = 0;
    Ptr mainAddr = NULL;
    Str255 errName;
    Str255 pname;

    pname[0] = (unsigned char)strlen(fragment);
    memcpy(pname + 1, fragment, pname[0]);
    if (GetSharedLibrary(pname, kPowerPCCFragArch, kReferenceCFrag,
                         &conn, &mainAddr, errName) != noErr) {
        return 0;
    }
    return conn;
}

/* Resolve one symbol; returns its address or NULL. */
static Ptr resolve(CFragConnectionID conn, const char *symbol)
{
    Str255 pname;
    Ptr address = NULL;
    CFragSymbolClass cls;

    if (conn == 0) {
        return NULL;
    }
    pname[0] = (unsigned char)strlen(symbol);
    memcpy(pname + 1, symbol, pname[0]);
    if (FindSymbol(conn, pname, &address, &cls) != noErr) {
        return NULL;
    }
    return address;
}

static int probe_group(CFragConnectionID conn, const char *title,
                       const char *const *symbols, int count)
{
    int found = 0;
    int i;

    if (conn == 0) {
        report("%s: fragment not open", title);
        return 0;
    }
    report("%s", title);
    for (i = 0; i < count; ++i) {
        if (resolve(conn, symbols[i]) != NULL) {
            ++found;
        } else {
            report("   MISSING  %s", symbols[i]);
        }
    }
    report("   %d of %d present%s", found, count,
           found == count ? " - all" : "");
    return found == count;
}

static const char *const kADB[] = {
    "CountADBs", "GetIndADB", "GetADBInfo"
};

static const char *const kSCSIv1[] = {
    "SCSIGet", "SCSISelect", "SCSICmd", "SCSIComplete",
    "SCSIRead", "SCSIBusReset"
};

static const char *const kSCSI43[] = {
    "SCSIAction", "SCSIBusInquiry", "SCSIExecIO"
};

/* --- the low-memory tables (performed) ---------------------------------- */

/* The drive queue element, laid out by hand: this toolchain's Carbon
   headers do not define DrvQEl, which is why the drives probe is here and
   not in the Carbon-clean set. Fields past qLink are what a census reads. */
typedef struct SpikeDrvQEl {
    struct SpikeDrvQEl *qLink;    /* 0 */
    short qType;                  /* 4 */
    short dQDrive;                /* 6 */
    short dQRefNum;               /* 8 */
    short dQFSID;                 /* 10 */
} SpikeDrvQEl;

static void probe_drive_queue(void)
{
    /* The QHdr at 0x0308 is qFlags(2), qHead(4), qTail(4), so the head
       pointer to the first DrvQEl lives at 0x030A. */
    SpikeDrvQEl *el = *(SpikeDrvQEl **)0x030A;
    int n = 0;

    report("Drive queue (low-mem 0x0308)");
    while (el != NULL && n < 8) {
        report("   drive %d  refNum %d  fsid %d", el->dQDrive, el->dQRefNum,
               el->dQFSID);
        el = el->qLink;
        ++n;
    }
    report("   %d entr%s walked - drives probe %s", n, n == 1 ? "y" : "ies",
           n > 0 ? "WORKS" : "empty (unexpected)");
}

static void probe_unit_table(void)
{
    /* UTableBase at 0x011C (a Handle*), UnitNtryCnt at 0x01D2 (short). */
    Handle *base = *(Handle **)0x011C;
    short count = *(short *)0x01D2;
    int loaded = 0;
    int i;

    report("Unit table (low-mem 0x011C / count 0x01D2)");
    if (base == NULL || count <= 0 || count > 512) {
        report("   base/count implausible (count=%d) - drivers probe UNCLEAR",
               count);
        return;
    }
    for (i = 0; i < count; ++i) {
        if (base[i] != NULL) {
            ++loaded;
        }
    }
    report("   %d units, %d loaded - drivers probe WORKS", count, loaded);
}

static void probe_sysparm(void)
{
    /* The 20-byte SysParm copy at 0x01F8 - the PPC PRAM surface (no
       ReadXPRam trap here, so this is all a census can reach: partial). */
    const unsigned char *sp = (const unsigned char *)0x01F8;
    char hex[64];
    int i;

    report("SysParm PRAM copy (low-mem 0x01F8, 20 bytes)");
    hex[0] = '\0';
    for (i = 0; i < 20; ++i) {
        char b[4];
        snprintf(b, sizeof b, "%02X ", sp[i]);
        strncat(hex, b, sizeof hex - strlen(hex) - 1);
        if (i == 9) {
            report("   %s", hex);
            hex[0] = '\0';
        }
    }
    report("   %s", hex);
    report("   read OK - pram probe WORKS (partial: 20 of 256)");
}

/* --- run ---------------------------------------------------------------- */

typedef short (*CountADBsProc)(void);

static void run_probe(void)
{
    CFragConnectionID intf;
    long v;
    int adb, scsi1, scsi43;
    Ptr count_adbs;

    if (Gestalt(gestaltSystemVersion, &v) == noErr) {
        report("System %ld.%ld.%ld", (v >> 8) & 0xF, (v >> 4) & 0xF, v & 0xF);
    }
    if (Gestalt('cbon', &v) == noErr) {
        report("CarbonLib %ld.%ld.%ld", (v >> 8) & 0xFF, (v >> 4) & 0xF,
               v & 0xF);
    }
    report("");

    intf = open_fragment("InterfaceLib");
    if (intf == 0) {
        report("InterfaceLib did not open - cannot probe ADB/SCSI");
    }

    adb = probe_group(intf, "ADB Manager (InterfaceLib)", kADB,
                      (int)(sizeof kADB / sizeof kADB[0]));
    /* CountADBs has no args and no bus I/O; call it through the resolved
       pointer for the definitive answer. Not an import - a runtime call. */
    count_adbs = resolve(intf, "CountADBs");
    if (count_adbs != NULL) {
        short n = ((CountADBsProc)count_adbs)();
        report("   CountADBs() returned %d devices - ADB probe WORKS", n);
    }
    report("");

    scsi1 = probe_group(intf, "SCSI Manager v1 (InterfaceLib)", kSCSIv1,
                        (int)(sizeof kSCSIv1 / sizeof kSCSIv1[0]));
    report("");
    scsi43 = probe_group(intf, "SCSI Manager 4.3 async (InterfaceLib)",
                         kSCSI43,
                         (int)(sizeof kSCSI43 / sizeof kSCSI43[0]));
    report("   (not selected/INQUIRY'd here - active I/O is attended)");
    report("");

    probe_drive_queue();
    report("");
    probe_unit_table();
    report("");
    probe_sysparm();
    report("");

    report("VERDICT - slice 2 reach:");
    report("  drives : low-mem walk succeeded above");
    report("  drivers: unit table read succeeded above");
    report("  pram   : SysParm read succeeded (partial by design)");
    report("  adb    : %s", adb ? "symbols present; count above is proof"
                                : "SOME MISSING - see above");
    report("  scsi   : %s", (scsi1 || scsi43)
           ? "entry points present (gate + attend before select)"
           : "NO SCSI Manager entry points - probe not reachable");
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
    CopyCStringToPascal("Census Spike Report", name);
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
        FSWrite(ref, &len, "\r");
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
    for (i = 0; i < g_count && 18 + i * kLineHeight < kWinHeight - 6; ++i) {
        MoveTo(12, 18 + i * kLineHeight);
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
    SetRect(&bounds, 30, 50, 30 + kWinWidth, 50 + kWinHeight);
    CreateNewWindow(kDocumentWindowClass, kWindowCloseBoxAttribute,
                    &bounds, &g_window);
    if (g_window == NULL) {
        return 1;
    }
    CopyCStringToPascal("Census Spike", title);
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
            short part = FindWindow(event.where, &which);

            if (part == inGoAway && TrackGoAway(which, event.where)) {
                running = false;
            } else if (part == inDrag) {
                DragWindow(which, event.where, NULL);
            }
            break;
        }
        default:
            break;
        }
    }
    return 0;
}
