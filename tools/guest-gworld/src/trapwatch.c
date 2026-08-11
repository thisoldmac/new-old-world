/*
 * trapwatch.c - NOW Trap Watch: does a trap patch on the QDOffscreen
 * dispatch see a CFM caller at all?
 *
 * THE QUESTION IT ANSWERS (plan 013, slice D0). The shippable discovery
 * mechanism wants to patch NewGWorld / DisposeGWorld in the armed
 * process, because a patch hands over the port at creation - which is
 * also the world-replacement signal the join otherwise has to infer.
 * But the Finder imports NewGWorld from CarbonLib as a CFM call, and
 * native PowerPC callers do not necessarily dispatch through the 68K
 * trap table. The act plane's MenuSelect patch DOES reach the PPC
 * Finder, so some glue honours patches - whether QDOffscreen's does is
 * unknown and decides whether the approach exists. One boot answers it.
 *
 * THE MECHANISM. NewGWorld is selector 0x00160000 on trap $AB1D
 * (QDOffscreen dispatch; FOURWORDINLINE in QDOffscreen.h). This applet
 * plants a counting tail-patch on $AB1D:
 *
 *     move.l d0,(lastSel).l    ; 23 C0 <addr>   the selector, for
 *     addq.l #1,(count).l      ; 52 B9 <addr>   attribution
 *     tst.w  d0                ; 4A 40          selector 0 = NewGWorld:
 *     bne.s  +8                ; 66 06          a per-selector counter,
 *     addq.l #1,(ngw).l        ; 52 B9 <addr>   because the first run
 *     jmp    (old).l           ; 4E F9 <addr>   found ~0.6 ambient
 *                                               selector-7 calls per
 *                                               second drowning any
 *                                               single NewGWorld in the
 *                                               raw count
 *
 * The stub and its cells live in a NONRELOCATABLE SYSTEM-HEAP block,
 * because the patch runs in whatever process calls the trap - an
 * application-heap stub dies with this applet while the patch does not.
 * The patch is never removed (the act plane's rule: unpatching under a
 * live caller is the one thing more dangerous than patching), so the
 * block leaks by design; it is 32 bytes on a throwaway VM.
 *
 * ATTRIBUTION IS THE RIG'S JOB, and the protocol is written here so the
 * numbers mean something: read the report, drive the FINDER to open or
 * resize a window, read it again. Moved = CFM callers dispatch through
 * the patched trap and D0's mechanism exists. Still = they do not, and
 * the fallback is the bounded re-discovery scan. Then launch the 68K
 * loop applet as the POSITIVE control - its startup NewGWorld MUST move
 * the count, or the patch itself is broken and the Finder's null means
 * nothing (the control-first rule that saved the probe arc).
 *
 * This applet never calls NewGWorld itself.
 *
 * Named like the wedge applet: "NOW Trap Watch 120" runs two minutes.
 */

#include <Devices.h>
#include <Dialogs.h>
#include <Events.h>
#include <Files.h>
#include <Folders.h>
#include <Fonts.h>
#include <MacMemory.h>
#include <MacWindows.h>
#include <Menus.h>
#include <OSUtils.h>
#include <Patches.h>
#include <Processes.h>
#include <Quickdraw.h>
#include <TextEdit.h>
#include <TextUtils.h>
#include <Traps.h>
#include <Types.h>

enum { kDefaultSeconds = 120, kMaxSeconds = 600 };
enum { kQDExtensionsTrap = 0xAB1D };

/* The sys-heap block: two cells, then the code. Offsets are shared by
   the builder and the reporter, so they are named once. */
enum {
    kCellCount = 0,
    kCellLastSel = 4,
    kCellNewGWorld = 8,
    kCellCode = 12,
    kStubBytes = 12 + 28
};

static Ptr gStub;
static WindowPtr gWin;

static long ParseSeconds(void)
{
    ProcessSerialNumber psn;
    ProcessInfoRec info;
    Str255 name;
    short i;
    long value = 0;
    int seen = 0;

    psn.highLongOfPSN = 0;
    psn.lowLongOfPSN = kCurrentProcess;
    info.processInfoLength = sizeof(info);
    info.processName = name;
    info.processAppSpec = NULL;
    if (GetProcessInformation(&psn, &info) != noErr || name[0] == 0) {
        return kDefaultSeconds;
    }
    for (i = 1; i <= name[0]; i++) {
        if (name[i] >= '0' && name[i] <= '9') {
            value = value * 10 + (name[i] - '0');
            seen = 1;
        } else if (seen) {
            break;
        }
    }
    if (!seen || value <= 0) return kDefaultSeconds;
    if (value > kMaxSeconds) return kMaxSeconds;
    return value;
}

/* Build the stub and swap it in. Returns the old dispatch address, 0 on
   failure. The instruction bytes are written by hand rather than
   compiled, because the code must be position-independent-with-absolutes
   and live outside this application's world. */
static unsigned long InstallWatch(void)
{
    unsigned long old;
    unsigned char *p;
    unsigned long cnt_addr, sel_addr, ngw_addr;

    gStub = NewPtrSysClear(kStubBytes);
    if (gStub == NULL) return 0;
    old = (unsigned long)NGetTrapAddress(kQDExtensionsTrap, ToolTrap);
    if (old == 0) return 0;

    cnt_addr = (unsigned long)(gStub + kCellCount);
    sel_addr = (unsigned long)(gStub + kCellLastSel);
    ngw_addr = (unsigned long)(gStub + kCellNewGWorld);
    p = (unsigned char *)(gStub + kCellCode);

    *p++ = 0x23; *p++ = 0xC0;                     /* move.l d0,(abs).l  */
    *p++ = (unsigned char)(sel_addr >> 24); *p++ = (unsigned char)(sel_addr >> 16);
    *p++ = (unsigned char)(sel_addr >> 8);  *p++ = (unsigned char)sel_addr;
    *p++ = 0x52; *p++ = 0xB9;                     /* addq.l #1,(abs).l  */
    *p++ = (unsigned char)(cnt_addr >> 24); *p++ = (unsigned char)(cnt_addr >> 16);
    *p++ = (unsigned char)(cnt_addr >> 8);  *p++ = (unsigned char)cnt_addr;
    *p++ = 0x4A; *p++ = 0x40;                     /* tst.w d0           */
    *p++ = 0x66; *p++ = 0x06;                     /* bne.s past the add */
    *p++ = 0x52; *p++ = 0xB9;                     /* addq.l #1,(abs).l  */
    *p++ = (unsigned char)(ngw_addr >> 24); *p++ = (unsigned char)(ngw_addr >> 16);
    *p++ = (unsigned char)(ngw_addr >> 8);  *p++ = (unsigned char)ngw_addr;
    *p++ = 0x4E; *p++ = 0xF9;                     /* jmp (abs).l        */
    *p++ = (unsigned char)(old >> 24); *p++ = (unsigned char)(old >> 16);
    *p++ = (unsigned char)(old >> 8);  *p++ = (unsigned char)old;

    /* Instructions were written through the data path; make sure the
       emulated CPU does not run stale bytes. BlockMove of a block onto
       itself is the classic cache-flush idiom and is enough here. */
    BlockMove(gStub, gStub, kStubBytes);

    NSetTrapAddress((UniversalProcPtr)(gStub + kCellCode),
                    kQDExtensionsTrap, ToolTrap);
    return old;
}

static unsigned long ReadCount(void)
{
    return gStub != NULL ? *(volatile unsigned long *)(gStub + kCellCount) : 0;
}

static unsigned long ReadLastSel(void)
{
    return gStub != NULL ? *(volatile unsigned long *)(gStub + kCellLastSel) : 0;
}

static unsigned long ReadNewGWorld(void)
{
    return gStub != NULL
        ? *(volatile unsigned long *)(gStub + kCellNewGWorld) : 0;
}

static void WriteReport(unsigned long old)
{
    Str255 fname = "\pNOW Trap Watch.txt";
    short vRef = 0; long dirID = 0; short ref = 0;
    FSSpec spec;
    char buf[256];
    long len;
    const char *dig = "0123456789abcdef";
    short j = 0, k;
    unsigned long vals[5];
    const char *labels[5];
    short n = 0, v;

    labels[n] = "count       "; vals[n++] = ReadCount();
    labels[n] = "lastSelector"; vals[n++] = ReadLastSel();
    labels[n] = "newGWorld   "; vals[n++] = ReadNewGWorld();
    labels[n] = "oldDispatch "; vals[n++] = old;
    labels[n] = "stub        "; vals[n++] = (unsigned long)gStub;

    for (v = 0; v < n; ++v) {
        for (k = 0; labels[v][k]; ++k) buf[j++] = labels[v][k];
        buf[j++] = '='; buf[j++] = '0'; buf[j++] = 'x';
        for (k = 28; k >= 0; k -= 4) buf[j++] = dig[(vals[v] >> k) & 0xF];
        buf[j++] = '\r';
    }
    buf[j] = '\0';
    len = j;

    if (FindFolder(kOnSystemDisk, kDesktopFolderType, kDontCreateFolder,
                   &vRef, &dirID) != noErr) { vRef = 0; dirID = 0; }
    if (FSMakeFSSpec(vRef, dirID, fname, &spec) != noErr
        && FSMakeFSSpec(vRef, dirID, fname, &spec) != fnfErr) return;
    (void)FSpDelete(&spec);
    if (FSpCreate(&spec, 'ttxt', 'TEXT', smSystemScript) != noErr) return;
    if (FSpOpenDF(&spec, fsWrPerm, &ref) != noErr) return;
    (void)FSWrite(ref, &len, buf);
    (void)FSClose(ref);
    (void)FlushVol(NULL, spec.vRefNum);
}

static void DrawStatus(void)
{
    Str255 s;
    Rect r;

    if (gWin == NULL) return;
    SetPort((GrafPtr)gWin);
    SetRect(&r, 0, 0, 300, 60);
    EraseRect(&r);
    MoveTo(12, 20);
    DrawString((ConstStr255Param)"\pQDOffscreen trap calls:");
    NumToString((long)ReadCount(), s);
    MoveTo(200, 20);
    DrawString(s);
    MoveTo(12, 40);
    DrawString((ConstStr255Param)"\pNewGWorld calls:");
    NumToString((long)ReadNewGWorld(), s);
    MoveTo(200, 40);
    DrawString(s);
}

int main(void)
{
    EventRecord event;
    long seconds;
    unsigned long deadline, nextReport;
    unsigned long old;
    Rect wr;

    InitGraf(&qd.thePort); InitFonts(); InitWindows(); InitMenus();
    TEInit(); InitDialogs(NULL); InitCursor();

    seconds = ParseSeconds();
    deadline = TickCount() + (unsigned long)(seconds * 60);

    SetRect(&wr, 60, 80, 60 + 300, 80 + 60);
    gWin = NewWindow(NULL, &wr, (ConstStr255Param)"\pTrap Watch", true,
                     documentProc, (WindowPtr)-1L, false, 0);
    if (gWin == NULL) return 0;

    old = InstallWatch();
    if (old == 0) {
        DisposeWindow(gWin);
        return 0;
    }
    WriteReport(old);
    nextReport = TickCount() + 60;

    while ((long)(TickCount() - deadline) < 0) {
        if (WaitNextEvent(everyEvent, &event, 10L, NULL)) {
            if (event.what == updateEvt) {
                BeginUpdate(gWin);
                DrawStatus();
                EndUpdate(gWin);
                continue;
            }
        }
        if ((long)(TickCount() - nextReport) >= 0) {
            WriteReport(old);
            DrawStatus();
            nextReport = TickCount() + 60;
        }
    }

    /* The patch stays; only the window goes. See the header. */
    DisposeWindow(gWin);
    return 0;
}
