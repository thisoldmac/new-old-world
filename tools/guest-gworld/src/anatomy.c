/*
 * anatomy.c - the Toolbox's own account of itself, printed by a program
 * running inside it.
 *
 * Three of the research arc's phases need facts that no header and no
 * document can settle, because what matters is what THIS compiler, THESE
 * Universal Interfaces and THAT ROM agree on at run time:
 *
 *   P1  Structure layouts. `offsetof` is a compile-time constant, so a
 *       program that prints its own offsets is the authoritative answer
 *       for the dialect the extension is built in - and printing them
 *       beside the values read out of a LIVE port is what turns a
 *       declaration into a measurement.
 *   P2  The GWorld surface: every allocation flag, the pixel lifecycle,
 *       and the lifetime question the probe arc is blocked on.
 *   P3  Dispatch: whether the port's grafProcs is reached the same way
 *       for an offscreen port as for a window, and whether the standard
 *       procs a 68K program installs are the ones a native caller runs.
 *
 * Written to a file the rig pulls off the guest, for the reason the
 * first spike was: a result read off a screenshot cannot be diffed.
 */

#include <Devices.h>
#include <Dialogs.h>
#include <Folders.h>
#include <Fonts.h>
#include <Icons.h>
#include <LowMem.h>
#include <MacMemory.h>
#include <MacWindows.h>
#include <Quickdraw.h>
#include <QDOffscreen.h>
#include <Resources.h>
#include <TextEdit.h>
#include <Types.h>

#include <stddef.h>
#include <string.h>

static char gRep[32768];
static long gLen;

static void Say(const char *s)
{
    long n = (long)strlen(s);
    if (gLen + n + 2 >= (long)sizeof gRep) return;
    memcpy(gRep + gLen, s, (size_t)n);
    gLen += n;
    gRep[gLen++] = '\r';
    gRep[gLen] = '\0';
}

static void Num(const char *label, long v)
{
    char line[160], num[24];
    short i = 0, j;
    long t = v;
    int neg = 0;
    if (t < 0) { neg = 1; t = -t; }
    if (t == 0) num[i++] = '0';
    while (t > 0) { num[i++] = (char)('0' + (t % 10)); t /= 10; }
    if (neg) num[i++] = '-';
    strcpy(line, label); j = (short)strlen(line);
    while (i > 0) line[j++] = num[--i];
    line[j] = '\0';
    Say(line);
}

static void Hex(const char *label, unsigned long v)
{
    char line[160];
    const char *dig = "0123456789abcdef";
    short j, k;
    strcpy(line, label); j = (short)strlen(line);
    line[j++] = '0'; line[j++] = 'x';
    for (k = 28; k >= 0; k -= 4) line[j++] = dig[(v >> k) & 0xF];
    line[j] = '\0';
    Say(line);
}

#define OFF(type, field) Num("  " #type "." #field " @ ", \
                             (long)offsetof(type, field))
#define SIZ(type)        Num("  sizeof(" #type ") = ", (long)sizeof(type))

/* ---- P1: what this dialect says the structures are ------------------- */

static void ReportLayouts(void)
{
    Say("");
    Say("======== P1: structure layouts (offsetof, this compiler) ========");
    SIZ(GrafPort); SIZ(CGrafPort); SIZ(BitMap); SIZ(PixMap);
    SIZ(GDevice); SIZ(QDProcs); SIZ(CQDProcs); SIZ(Rect); SIZ(RgnHandle);
    Say("-- GrafPort");
    OFF(GrafPort, device); OFF(GrafPort, portBits); OFF(GrafPort, portRect);
    OFF(GrafPort, visRgn); OFF(GrafPort, clipRgn); OFF(GrafPort, bkPat);
    OFF(GrafPort, pnLoc); OFF(GrafPort, pnSize); OFF(GrafPort, pnMode);
    OFF(GrafPort, txFont); OFF(GrafPort, txFace); OFF(GrafPort, txSize);
    OFF(GrafPort, grafProcs);
    Say("-- CGrafPort (same size, different shape: the discriminator)");
    OFF(CGrafPort, device); OFF(CGrafPort, portPixMap);
    OFF(CGrafPort, portVersion); OFF(CGrafPort, grafVars);
    OFF(CGrafPort, chExtra); OFF(CGrafPort, pnLocHFrac);
    OFF(CGrafPort, portRect); OFF(CGrafPort, visRgn); OFF(CGrafPort, clipRgn);
    OFF(CGrafPort, bkPixPat); OFF(CGrafPort, rgbFgColor);
    OFF(CGrafPort, rgbBkColor); OFF(CGrafPort, pnLoc); OFF(CGrafPort, pnSize);
    OFF(CGrafPort, txFont); OFF(CGrafPort, txFace); OFF(CGrafPort, txSize);
    OFF(CGrafPort, grafProcs);
    Say("-- PixMap");
    OFF(PixMap, baseAddr); OFF(PixMap, rowBytes); OFF(PixMap, bounds);
    OFF(PixMap, pmVersion); OFF(PixMap, packType); OFF(PixMap, packSize);
    OFF(PixMap, hRes); OFF(PixMap, vRes); OFF(PixMap, pixelType);
    OFF(PixMap, pixelSize); OFF(PixMap, cmpCount); OFF(PixMap, cmpSize);
    OFF(PixMap, planeBytes); OFF(PixMap, pmTable);
    Say("-- BitMap");
    OFF(BitMap, baseAddr); OFF(BitMap, rowBytes); OFF(BitMap, bounds);
    Say("-- GDevice");
    OFF(GDevice, gdRefNum); OFF(GDevice, gdID); OFF(GDevice, gdType);
    OFF(GDevice, gdITable); OFF(GDevice, gdResPref); OFF(GDevice, gdSearchProc);
    OFF(GDevice, gdCompProc); OFF(GDevice, gdFlags); OFF(GDevice, gdPMap);
    OFF(GDevice, gdRefCon); OFF(GDevice, gdNextGD); OFF(GDevice, gdRect);
    OFF(GDevice, gdMode);
    Say("-- CQDProcs (the bottleneck table the whole content plane hooks)");
    OFF(CQDProcs, textProc); OFF(CQDProcs, lineProc); OFF(CQDProcs, rectProc);
    OFF(CQDProcs, rRectProc); OFF(CQDProcs, ovalProc); OFF(CQDProcs, arcProc);
    OFF(CQDProcs, polyProc); OFF(CQDProcs, rgnProc); OFF(CQDProcs, bitsProc);
    OFF(CQDProcs, commentProc); OFF(CQDProcs, txMeasProc);
    OFF(CQDProcs, getPicProc); OFF(CQDProcs, putPicProc);
    OFF(CQDProcs, opcodeProc); OFF(CQDProcs, newProc1);
    Say("-- Zone (what a heap walk steps through)");
    SIZ(Zone);
    OFF(Zone, bkLim); OFF(Zone, purgePtr); OFF(Zone, hFstFree);
    OFF(Zone, zcbFree); OFF(Zone, gzProc); OFF(Zone, heapData);
}

/* ---- P1 continued: the same fields, read off a LIVE port ------------- */

static void ReportLivePort(void)
{
    WindowPtr w;
    CGrafPtr port;
    Rect r;

    Say("");
    Say("======== P1: a live window port, read at the offsets above =====");
    SetRect(&r, 40, 60, 340, 240);
    w = NewCWindow(NULL, &r, (ConstStr255Param)"\panatomy", false, documentProc,
                   (WindowPtr)-1L, false, 0);
    if (w == NULL) { Say("  NewCWindow failed"); return; }
    port = (CGrafPtr)w;
    Hex("  window/port address = ", (unsigned long)port);
    Hex("  portVersion         = ",
        (unsigned long)(unsigned short)port->portVersion);
    Say((((unsigned short)port->portVersion & 0xC000U) == 0xC000U)
        ? "  discriminator: 0xC000 SET - this is a CGrafPort"
        : "  discriminator: CLEAR - a classic GrafPort");
    Hex("  portPixMap          = ", (unsigned long)port->portPixMap);
    Hex("  grafProcs (fresh)   = ", (unsigned long)port->grafProcs);
    Num("  portRect.right      = ", port->portRect.right);
    if (port->portPixMap != NULL && *port->portPixMap != NULL) {
        Hex("  pixmap baseAddr     = ",
            (unsigned long)(**port->portPixMap).baseAddr);
        Num("  pixmap rowBytes&3FFF= ",
            (long)((**port->portPixMap).rowBytes & 0x3FFF));
        Num("  pixmap pixelSize    = ", (**port->portPixMap).pixelSize);
    }
    DisposeWindow(w);
}

/* ---- P2: the GWorld surface, flag by flag ---------------------------- */

static void Flavour(const char *tag, short depth, GWorldFlags flags)
{
    GWorldPtr world = NULL;
    Rect b;
    QDErr err;
    PixMapHandle pix;
    CGrafPtr port;
    Handle recovered;
    char line[160];
    GWorldFlags state;

    SetRect(&b, 0, 0, 64, 48);
    err = NewGWorld(&world, depth, &b, NULL, NULL, flags);
    Say("");
    strcpy(line, "-- "); strcat(line, tag); Say(line);
    if (err != noErr || world == NULL) {
        Num("   NewGWorld err = ", (long)err);
        return;
    }
    port = (CGrafPtr)world;
    pix = GetGWorldPixMap(world);
    Hex("   GWorldPtr        = ", (unsigned long)world);
    Hex("   as CGrafPtr      = ", (unsigned long)port);
    Say(((void *)world == (void *)port)
        ? "   GWorldPtr IS the CGrafPtr (same address)"
        : "   GWorldPtr DIFFERS from its CGrafPtr (private record!)");
    /* Is the port itself a relocatable block? Inside Macintosh says a
       GWorld's CGrafPort is an always-locked handle; RecoverHandle is
       how a program asks rather than believes. */
    recovered = RecoverHandle((Ptr)world);
    Hex("   RecoverHandle(port) = ", (unsigned long)recovered);
    Say(recovered != NULL
        ? "   the port IS a relocatable block (locked handle)"
        : "   the port is NOT recoverable (a pointer, or another zone)");
    Hex("   portVersion      = ",
        (unsigned long)(unsigned short)port->portVersion);
    Hex("   pixmap handle    = ", (unsigned long)pix);
    if (pix != NULL && *pix != NULL) {
        Hex("   pixmap deref     = ", (unsigned long)*pix);
        Hex("   baseAddr         = ", (unsigned long)(**pix).baseAddr);
        Num("   rowBytes & 3FFF  = ", (long)((**pix).rowBytes & 0x3FFF));
        Num("   pixelSize        = ", (**pix).pixelSize);
        recovered = RecoverHandle((Ptr)*pix);
        Say(recovered == (Handle)pix
            ? "   RecoverHandle(pixmap): AGREES"
            : "   RecoverHandle(pixmap): DISAGREES");
    }
    state = GetPixelsState(pix);
    Num("   GetPixelsState   = ", (long)state);
    Say((state & pixelsLocked) ? "     pixelsLocked SET"
                               : "     pixelsLocked clear");
    Say((state & pixelsPurgeable) ? "     pixelsPurgeable SET"
                                  : "     pixelsPurgeable clear");
    /* What LockPixels changes, and whether baseAddr moves. */
    {
        Ptr before = (pix && *pix) ? (**pix).baseAddr : NULL;
        Boolean ok = LockPixels(pix);
        Ptr after = (pix && *pix) ? (**pix).baseAddr : NULL;
        Say(ok ? "   LockPixels: true" : "   LockPixels: FALSE (purged)");
        Say(before == after ? "   baseAddr unchanged by LockPixels"
                            : "   baseAddr MOVED under LockPixels");
        UnlockPixels(pix);
    }
    DisposeGWorld(world);
}

static void ReportGWorldSurface(void)
{
    Say("");
    Say("======== P2: the GWorld surface, flag by flag =================");
    Flavour("depth=0 (device) flags=none", 0, 0);
    Flavour("depth=8 flags=none", 8, 0);
    Flavour("depth=32 flags=none", 32, 0);
    Flavour("flags=useTempMem", 0, useTempMem);
    Flavour("flags=keepLocal", 0, keepLocal);
    Flavour("flags=pixelsPurgeable", 0, pixelsPurgeable);
    Flavour("flags=noNewDevice", 0, noNewDevice);
}

/* ---- P2: LIFETIME, which is what the probe arc is blocked on --------- */

static void ReportLifetime(void)
{
    GWorldPtr a = NULL, b = NULL, c = NULL;
    Rect r;
    unsigned long addr_a, addr_b;

    Say("");
    Say("======== P2: lifetime - is an address reused after dispose? ====");
    SetRect(&r, 0, 0, 120, 80);
    if (NewGWorld(&a, 0, &r, NULL, NULL, 0) != noErr) {
        Say("  first NewGWorld failed"); return;
    }
    addr_a = (unsigned long)a;
    Hex("  first  GWorld at ", addr_a);
    DisposeGWorld(a);
    Say("  disposed");
    if (NewGWorld(&b, 0, &r, NULL, NULL, 0) != noErr) {
        Say("  second NewGWorld failed"); return;
    }
    addr_b = (unsigned long)b;
    Hex("  second GWorld at ", addr_b);
    Say(addr_a == addr_b
        ? "  SAME ADDRESS REUSED. An observer polling for a port cannot "
          "tell one repaint's world from the next by address alone."
        : "  different address. A disposed world's address does not "
          "immediately recur.");
    /* And what does the disposed port's memory look like now? An
       observer that scanned and found this address would be reading
       this. */
    Hex("  disposed port's first word now = ", *(unsigned long *)addr_a);
    if (NewGWorld(&c, 0, &r, NULL, NULL, 0) == noErr) {
        Hex("  third  GWorld at ", (unsigned long)c);
        DisposeGWorld(c);
    }
    DisposeGWorld(b);
}

/* ---- P3: how the bottlenecks are reached ---------------------------- */

static long gWinText, gWinBits, gOffText, gOffBits;
static CQDProcs gStd, gWinHooks, gOffHooks;

static pascal void WinText(short n, const void *t, Point a, Point b)
{ gWinText++; InvokeQDTextUPP(n, t, a, b, gStd.textProc); }
static pascal void WinBits(const BitMap *s, const Rect *sr, const Rect *dr,
                           short m, RgnHandle mr)
{ gWinBits++; InvokeQDBitsUPP(s, sr, dr, m, mr, gStd.bitsProc); }
static pascal void OffText(short n, const void *t, Point a, Point b)
{ gOffText++; InvokeQDTextUPP(n, t, a, b, gStd.textProc); }
static pascal void OffBits(const BitMap *s, const Rect *sr, const Rect *dr,
                           short m, RgnHandle mr)
{ gOffBits++; InvokeQDBitsUPP(s, sr, dr, m, mr, gStd.bitsProc); }

static void ReportDispatch(void)
{
    WindowPtr w;
    GWorldPtr world = NULL;
    CGrafPtr saved;
    GDHandle savedDev;
    Rect r, gr;
    PixMapHandle pix;

    Say("");
    Say("======== P3: is an offscreen port dispatched like a window? ===");
    gWinText = gWinBits = gOffText = gOffBits = 0;

    SetRect(&r, 40, 60, 340, 240);
    w = NewCWindow(NULL, &r, (ConstStr255Param)"\panatomy", true, documentProc,
                   (WindowPtr)-1L, false, 0);
    SetRect(&gr, 0, 0, 120, 80);
    if (w == NULL || NewGWorld(&world, 0, &gr, NULL, NULL, 0) != noErr) {
        Say("  could not build both ports"); if (w) DisposeWindow(w);
        return;
    }
    gWinHooks = gStd;
    gWinHooks.textProc = NewQDTextUPP(WinText);
    gWinHooks.bitsProc = NewQDBitsUPP(WinBits);
    gOffHooks = gStd;
    gOffHooks.textProc = NewQDTextUPP(OffText);
    gOffHooks.bitsProc = NewQDBitsUPP(OffBits);

    /* The window, drawn to directly. */
    SetPort((GrafPtr)w);
    ((CGrafPtr)w)->grafProcs = &gWinHooks;
    MoveTo(10, 20); DrawString((ConstStr255Param)"\pwindow");
    ((CGrafPtr)w)->grafProcs = NULL;

    /* The offscreen world, same calls. */
    GetGWorld(&saved, &savedDev);
    SetGWorld(world, NULL);
    ((CGrafPtr)world)->grafProcs = &gOffHooks;
    MoveTo(10, 20); DrawString((ConstStr255Param)"\poffscreen");
    ((CGrafPtr)world)->grafProcs = NULL;
    SetGWorld(saved, savedDev);

    Num("  window   text hooks fired = ", gWinText);
    Num("  window   bits hooks fired = ", gWinBits);
    Num("  offscreen text hooks fired = ", gOffText);
    Num("  offscreen bits hooks fired = ", gOffBits);
    Say((gWinText > 0 && gOffText > 0)
        ? "  SAME MECHANISM: both ports dispatch text through grafProcs."
        : "  ASYMMETRY: the two ports do not dispatch alike.");
    Say((gWinBits == 0 && gOffBits == 0)
        ? "  StdText did NOT nest through StdBits on either port."
        : "  StdText DID nest through StdBits (the re-entrancy fact).");

    /* And now the composite blit itself, hooked on the WINDOW, so the
       source pixmap it reports can be compared with the GWorld's own. */
    pix = GetGWorldPixMap(world);
    LockPixels(pix);
    SetPort((GrafPtr)w);
    ((CGrafPtr)w)->grafProcs = &gWinHooks;
    /* Non-Carbon: there is no GetPortBitMapForCopyBits. A colour port's
       destination bitmap IS its dereferenced portPixMap, which is the
       same identity the probe's chase tries to recover from a blit. */
    CopyBits((BitMap *)*pix,
             (BitMap *)*((CGrafPtr)w)->portPixMap,
             &gr, &gr, srcCopy, NULL);
    ((CGrafPtr)w)->grafProcs = NULL;
    UnlockPixels(pix);
    Num("  after a GWorld->window CopyBits, window bits = ", gWinBits);
    Hex("  the source we passed  = ", (unsigned long)*pix);
    Hex("  the GWorld's portPixMap = ",
        (unsigned long)((CGrafPtr)world)->portPixMap);
    Say((unsigned long)*pix
            == (unsigned long)*((CGrafPtr)world)->portPixMap
        ? "  the blit's source IS the port's own pixmap record"
        : "  the blit's source is a DIFFERENT record from the port's");

    DisposeGWorld(world);
    DisposeWindow(w);
}

/* ---- P3: QuickDraw's own code, read from inside its address space ----
   SetStdCProcs hands out the addresses of the standard bottlenecks, so
   the implementation is simply THERE to be read - but only from a
   context whose mapping is right, which QEMU's memsave is not (it
   translates through whatever CPU context the machine stopped in, and
   this arc has already been burned by that twice). A program running on
   the guest has no such problem. */
static void DumpProc(const char *tag, void *addr, short bytes)
{
    const unsigned char *p = (const unsigned char *)addr;
    const char *dig = "0123456789abcdef";
    char line[160];
    short i, j, k;

    Say("");
    { char t[120]; strcpy(t, "-- "); strcat(t, tag); Say(t); }
    Hex("   address = ", (unsigned long)addr);
    if (addr == NULL) { Say("   (null)"); return; }
    for (i = 0; i < bytes; i += 16) {
        j = 0;
        line[j++] = ' '; line[j++] = ' ';
        for (k = 28; k >= 0; k -= 4)
            line[j++] = dig[(((unsigned long)(p + i)) >> k) & 0xF];
        line[j++] = ':';
        for (k = 0; k < 16 && i + k < bytes; ++k) {
            line[j++] = ' ';
            line[j++] = dig[(p[i + k] >> 4) & 0xF];
            line[j++] = dig[p[i + k] & 0xF];
        }
        line[j] = '\0';
        Say(line);
    }
}

static void ReportProcCode(void)
{
    Say("");
    Say("======== P3: the standard bottlenecks' own code ================");
    DumpProc("StdText", (void *)gStd.textProc, 96);
    DumpProc("StdBits", (void *)gStd.bitsProc, 96);
    DumpProc("StdRect", (void *)gStd.rectProc, 64);
    DumpProc("StdRgn",  (void *)gStd.rgnProc, 64);
}

static void WriteReport(void)
{
    Str255 name = "\pNOW Anatomy Report.txt";
    short vRefNum = 0; long dirID = 0; short ref = 0;
    long count = gLen;
    FSSpec spec;

    if (FindFolder(kOnSystemDisk, kDesktopFolderType, kDontCreateFolder,
                   &vRefNum, &dirID) != noErr) { vRefNum = 0; dirID = 0; }
    if (FSMakeFSSpec(vRefNum, dirID, name, &spec) != noErr
        && FSMakeFSSpec(vRefNum, dirID, name, &spec) != fnfErr) return;
    (void)FSpDelete(&spec);
    if (FSpCreate(&spec, 'ttxt', 'TEXT', smSystemScript) != noErr) return;
    if (FSpOpenDF(&spec, fsWrPerm, &ref) != noErr) return;
    (void)FSWrite(ref, &count, gRep);
    (void)FSClose(ref);
    (void)FlushVol(NULL, spec.vRefNum);
}

int main(void)
{
    InitGraf(&qd.thePort); InitFonts(); InitWindows(); InitMenus();
    TEInit(); InitDialogs(NULL); InitCursor();

    gLen = 0; gRep[0] = '\0';
    Say("NOW Toolbox anatomy - docs/local/toolbox-re/PLAN.md");
    Say("Emulator run, 68K application on a PowerPC guest. Not metal.");

    SetStdCProcs(&gStd);
    Say("");
    Hex("SetStdCProcs textProc = ", (unsigned long)gStd.textProc);
    Hex("SetStdCProcs bitsProc = ", (unsigned long)gStd.bitsProc);

    ReportLayouts();
    ReportLivePort();
    ReportGWorldSurface();
    ReportLifetime();
    ReportDispatch();
    ReportProcCode();

    Say("");
    Say("end of report");
    WriteReport();
    return 0;
}
