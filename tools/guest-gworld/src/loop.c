/*
 * loop.c - NOW GWorld Loop: the chase's positive control, and the only
 * thing that can make a null result from a foreign application mean
 * anything.
 *
 * THE PROBLEM IT SOLVES. The probe hunts another process's offscreen
 * GWorld by sighting a blit into that process's window and then, at the
 * next event-loop pass, searching the heaps for the port that owns the
 * blitted pixels. Against the Finder it has never found one. That is
 * either a defect in the chase or a fact about the Finder, and the two
 * are indistinguishable without a target the chase is GUARANTEED to be
 * able to find.
 *
 * So this is that target, built to be maximally findable:
 *
 *   - ONE GWorld, created at startup and kept for the program's whole
 *     life. Nothing transient, nothing disposed between repaints.
 *   - Its content drawn ONCE, then blitted into the window on every
 *     update, exactly the composite-and-blit shape the probe hunts.
 *   - A long, cooperative event loop, so the extension's jGNE filter
 *     runs in this context again and again with the world still alive.
 *
 * If the chase cannot find THIS, it cannot find anything, and no null
 * from any application may be reported as a fact about that
 * application. If it CAN, then the Finder's null is evidence - and the
 * leading explanation becomes lifetime: an offscreen world that does
 * not outlive the repaint that built it.
 *
 * It also blits at a size a person can recognise in the drain: the
 * window is content-sized so the composite is the largest blit in the
 * frame, which is what the sighting now selects on.
 *
 * Renamed by the rig to carry its duration, the wedge applet's trick:
 * "NOW GWorld Loop 90" runs for ninety seconds and quits. Bounded
 * always - an instrument that will not let go is a rig you get to use
 * once.
 */

#include <Devices.h>
#include <Dialogs.h>
#include <Events.h>
#include <Fonts.h>
#include <MacMemory.h>
#include <MacWindows.h>
#include <Processes.h>
#include <Quickdraw.h>
#include <QDOffscreen.h>
#include <TextEdit.h>
#include <Types.h>

#include <Folders.h>
#include <LowMem.h>
#include <Resources.h>
#include <string.h>

enum { kDefaultSeconds = 120, kMaxSeconds = 600 };

static GWorldPtr gWorld;
static WindowPtr gWin;
static Rect gBounds;

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

/* Draw the offscreen content ONCE. Deliberately a mix of families, so a
   drain taken while the world is hooked shows what a real composite
   would look like: text with a pen, primitives, and no blits of its
   own. */
static void BuildWorld(void)
{
    CGrafPtr saved;
    GDHandle savedDev;
    Rect r;
    short i;

    GetGWorld(&saved, &savedDev);
    SetGWorld(gWorld, NULL);
    r = gBounds;
    EraseRect(&r);
    for (i = 0; i < 6; ++i) {
        SetRect(&r, 8, 8 + i * 28, 190, 30 + i * 28);
        FrameRect(&r);
        MoveTo(14, 24 + i * 28);
        DrawString((ConstStr255Param)"\poffscreen row");
    }
    MoveTo(0, 0);
    LineTo(gBounds.right, gBounds.bottom);
    SetGWorld(saved, savedDev);
}

/* The control's own account of what the chase is hunting. Written once
   at startup: if the probe reports different numbers, the difference IS
   the defect, and without this the two can only be guessed at. */
static void ReportIdentity(void)
{
    Str255 fname = "\pNOW Loop Identity.txt";
    short vRef = 0; long dirID = 0; short ref = 0;
    FSSpec spec;
    char buf[512];
    long len;
    PixMapHandle pix;
    Handle rec;
    CGrafPtr port = (CGrafPtr)gWorld;
    THz appz = ApplicationZone();
    const char *dig = "0123456789abcdef";
    short j = 0, k;
    unsigned long vals[16];
    const char *labels[16];
    short n = 0, v;

    if (gWorld == NULL) return;
    pix = GetGWorldPixMap(gWorld);
    rec = (pix != NULL) ? RecoverHandle((Ptr)*pix) : NULL;

    labels[n] = "port        "; vals[n++] = (unsigned long)port;
    labels[n] = "portPixMap  "; vals[n++] = (unsigned long)port->portPixMap;
    labels[n] = "pixDeref    "; vals[n++] = (unsigned long)(pix ? *pix : 0);
    labels[n] = "RecoverHndl "; vals[n++] = (unsigned long)rec;
    labels[n] = "baseAddr    "; vals[n++] =
        (unsigned long)((pix && *pix) ? (**pix).baseAddr : 0);
    labels[n] = "appzone lo  "; vals[n++] =
        (unsigned long)(appz ? (Ptr)&appz->heapData : 0);
    labels[n] = "appzone hi  "; vals[n++] =
        (unsigned long)(appz ? appz->bkLim : 0);
    labels[n] = "portVersion "; vals[n++] =
        (unsigned long)(unsigned short)port->portVersion;
    /* The ceiling the extension's read guard uses. If this is below the
       heaps, that guard rejects every candidate and the chase can never
       match - which is exactly the shape of failure being chased. */
    labels[n] = "LMGetMemTop "; vals[n++] = (unsigned long)LMGetMemTop();
    labels[n] = "sysz lo     "; vals[n++] =
        (unsigned long)(SystemZone() ? (Ptr)&SystemZone()->heapData : 0);
    labels[n] = "sysz hi     "; vals[n++] =
        (unsigned long)(SystemZone() ? SystemZone()->bkLim : 0);

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

/* The composite, into the window. The shape the probe sights on. */
static void BlitWorld(void)
{
    PixMapHandle pix;

    if (gWorld == NULL || gWin == NULL) return;
    pix = GetGWorldPixMap(gWorld);
    if (pix == NULL) return;
    SetPort((GrafPtr)gWin);
    LockPixels(pix);
    /* Non-Carbon: a colour port's destination bitmap is its own
       dereferenced portPixMap. */
    CopyBits((BitMap *)*pix,
             (BitMap *)*((CGrafPtr)gWin)->portPixMap,
             &gBounds, &gBounds, srcCopy, NULL);
    UnlockPixels(pix);
}

int main(void)
{
    EventRecord event;
    long seconds;
    unsigned long deadline;
    Rect wr;

    InitGraf(&qd.thePort); InitFonts(); InitWindows(); InitMenus();
    TEInit(); InitDialogs(NULL); InitCursor();

    seconds = ParseSeconds();
    deadline = TickCount() + (unsigned long)(seconds * 60);

    SetRect(&gBounds, 0, 0, 200, 180);
    SetRect(&wr, 60, 80, 60 + 200, 80 + 180);
    gWin = NewCWindow(NULL, &wr, (ConstStr255Param)"\pGWorld Loop", true,
                      documentProc, (WindowPtr)-1L, false, 0);
    if (gWin == NULL) return 0;

    if (NewGWorld(&gWorld, 0, &gBounds, NULL, NULL, 0) != noErr
        || gWorld == NULL) {
        DisposeWindow(gWin);
        return 0;
    }
    BuildWorld();
    ReportIdentity();
    BlitWorld();

    /* Cooperative from here: WaitNextEvent is what lets the extension's
       filter run in this context, which is the moment the chase needs.
       A tight loop would starve the very machinery under test. */
    while ((long)(TickCount() - deadline) < 0) {
        if (WaitNextEvent(everyEvent, &event, 6L, NULL)) {
            if (event.what == updateEvt) {
                BeginUpdate(gWin);
                BlitWorld();
                EndUpdate(gWin);
                continue;
            }
        }
        /* Re-blit on a cadence as well, so a probe that arms mid-run
           always has a fresh composite to sight without needing anyone
           to poke the window. */
        BlitWorld();
    }

    DisposeGWorld(gWorld);
    DisposeWindow(gWin);
    return 0;
}
