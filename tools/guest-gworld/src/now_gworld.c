/*
 * NOW GWorld - the isolated spike under the GWorld probe.
 *
 * WHY THIS EXISTS, and what it is allowed to conclude.
 *
 * docs/gworld-probe-brief.md asks one question: when an application
 * composites in an offscreen GWorld and blits the result, can the
 * drawing that BUILT the composite be seen? The probe that asks it of a
 * FOREIGN application (qdtrace mode=probe) has to solve discovery first
 * - find another process's GWorld port - and on 2026-08-06 it found
 * nothing, in the Finder and in NOW itself. A null result there has at
 * least three explanations and the instrument could not tell them
 * apart, which is precisely the report the brief refuses to accept.
 *
 * So this owns both ends. It allocates the GWorld, hooks it in its OWN
 * context, draws into it, and counts. Two questions, cleanly separated:
 *
 *   1. THE MECHANISM. Does drawing into an offscreen GWorld go through
 *      the port's grafProcs at all? Everything the probe does rests on
 *      yes, and nothing has verified it. If the answer is no, the
 *      semantic road is closed for EVERY application at once - the
 *      brief's outcome 3, established by mechanism rather than by
 *      failing to find one application's port.
 *   2. THE GEOGRAPHY. Where do the port, the pixmap handle and the
 *      pixels actually live, and how do they answer the questions the
 *      chase asks of them? Inside Macintosh says a GWorld's CGrafPort
 *      is an always-locked HANDLE in the application heap and that
 *      useTempMem moves only the pixel buffer; the chase assumes things
 *      about rects, zones and RecoverHandle that nobody has measured on
 *      this machine. Each row here is one of the chase's assumptions,
 *      tested.
 *
 * WHAT IT CANNOT ANSWER. Everything about the FOREIGN case: whether a
 * resident can find another process's GWorld, and whether a hook
 * installed from outside behaves like one installed from within. This
 * is the floor of a three-tier suite, not a replacement for it - spike
 * (here) then control (NOW's own GWorld, hooked by the resident) then
 * spread (foreign applications). A tier only runs when the one below is
 * green.
 *
 * PLotIconID IS IN THE LIST ON PURPOSE. The brief's outcome 2 - some
 * families arrive, some do not - is most likely to be decided by icons,
 * because an icon drawn from a resource may reach the screen through a
 * path the bottlenecks do not see. MacTech's account of CopyBits says
 * StdBits is where blits vector; whether IconUtilities honours that is
 * exactly the kind of claim worth measuring rather than citing.
 *
 * The results go to a TEXT FILE the rig pulls back off the guest
 * (Harness.pull_file), not to the screen: a result a person has to read
 * off a screenshot is a result nobody can diff.
 */

#include <Devices.h>
#include <Dialogs.h>
#include <Folders.h>
#include <Fonts.h>
#include <Icons.h>
#include <MacMemory.h>
#include <MacWindows.h>
#include <Quickdraw.h>
#include <QDOffscreen.h>
#include <Resources.h>
#include <TextEdit.h>
#include <TextUtils.h>
#include <Types.h>

#include <string.h>

/* Which hooks fired, and nothing else. One counter per family we drive;
   `bits` is the interesting one because StdText blits glyphs through it
   and PlotIcon may or may not. */
typedef struct {
    long text, line, rect, bits, rgn;
} HookCounts;

static HookCounts gCount;
static CQDProcs gStd;
static CQDProcs gHooks;

/* Report accumulator. A fixed buffer, appended to and written once: the
   spike must not allocate while a GWorld experiment is in flight, and a
   report that fails to write because the heap moved would lose the run
   it describes. */
static char gReport[16384];
static long gReportLen;

static void Say(const char *s)
{
    long n = (long)strlen(s);

    if (gReportLen + n + 2 >= (long)sizeof gReport) {
        return;
    }
    memcpy(gReport + gReportLen, s, (size_t)n);
    gReportLen += n;
    gReport[gReportLen++] = '\r';        /* the guest's own line ending */
    gReport[gReportLen] = '\0';
}

static void SayNum(const char *label, long v)
{
    char line[128];
    char num[24];
    short i = 0, j;
    long t = v;
    int neg = 0;

    if (t < 0) { neg = 1; t = -t; }
    if (t == 0) { num[i++] = '0'; }
    while (t > 0) { num[i++] = (char)('0' + (t % 10)); t /= 10; }
    if (neg) { num[i++] = '-'; }
    strcpy(line, label);
    j = (short)strlen(line);
    while (i > 0) { line[j++] = num[--i]; }
    line[j] = '\0';
    Say(line);
}

static void SayHex(const char *label, unsigned long v)
{
    char line[128];
    const char *digits = "0123456789abcdef";
    short j, k;

    strcpy(line, label);
    j = (short)strlen(line);
    line[j++] = '0'; line[j++] = 'x';
    for (k = 28; k >= 0; k -= 4) {
        line[j++] = digits[(v >> k) & 0xF];
    }
    line[j] = '\0';
    Say(line);
}

/* ---- the hooks -------------------------------------------------------
   Deliberately the same shape as the extension's: guard nothing, count,
   then tail-call the standard proc so the drawing still happens. The
   re-entrancy guard is absent BECAUSE its absence is informative here -
   if text arrives as N bits ops instead of one text op, that is the
   nested-call fact the extension's guard exists for, seen directly. */

static pascal void SpikeText(short byteCount, const void *textBuf,
                             Point numer, Point denom)
{
    gCount.text++;
    InvokeQDTextUPP(byteCount, textBuf, numer, denom, gStd.textProc);
}

static pascal void SpikeLine(Point newPt)
{
    gCount.line++;
    InvokeQDLineUPP(newPt, gStd.lineProc);
}

static pascal void SpikeRect(GrafVerb verb, const Rect *r)
{
    gCount.rect++;
    InvokeQDRectUPP(verb, r, gStd.rectProc);
}

static pascal void SpikeBits(const BitMap *srcBits, const Rect *srcRect,
                             const Rect *dstRect, short mode,
                             RgnHandle maskRgn)
{
    gCount.bits++;
    InvokeQDBitsUPP(srcBits, srcRect, dstRect, mode, maskRgn,
                    gStd.bitsProc);
}

static pascal void SpikeRgn(GrafVerb verb, RgnHandle rgn)
{
    gCount.rgn++;
    InvokeQDRgnUPP(verb, rgn, gStd.rgnProc);
}

/* ---- geography -------------------------------------------------------
   Every question the chase asks of a GWorld, asked here where the answer
   is checkable against code we wrote. */

static void DescribeZone(const char *what, unsigned long addr)
{
    THz app = ApplicationZone();
    THz sys = SystemZone();
    char line[160];

    strcpy(line, what);
    if (app != NULL
        && addr >= (unsigned long)&app->heapData
        && addr < (unsigned long)app->bkLim) {
        strcat(line, " zone=APPLICATION");
    } else if (sys != NULL
               && addr >= (unsigned long)&sys->heapData
               && addr < (unsigned long)sys->bkLim) {
        strcat(line, " zone=SYSTEM");
    } else {
        /* The case that would explain a sweep finding nothing. Named
           rather than lumped into "other", because "neither zone the
           probe walks" IS the finding if it happens. */
        strcat(line, " zone=NEITHER");
    }
    Say(line);
}

static void ReportGeography(GWorldPtr world, const char *tag)
{
    PixMapHandle pix = GetGWorldPixMap(world);
    CGrafPtr port = (CGrafPtr)world;
    Handle recovered;
    char line[160];

    Say("");
    strcpy(line, "-- geography: ");
    strcat(line, tag);
    Say(line);

    SayHex("  port            = ", (unsigned long)port);
    DescribeZone("  port", (unsigned long)port);
    SayHex("  portVersion     = ",
           (unsigned long)(unsigned short)port->portVersion);
    SayHex("  grafProcs@alloc = ", (unsigned long)port->grafProcs);
    SayNum("  portRect.left   = ", port->portRect.left);
    SayNum("  portRect.top    = ", port->portRect.top);
    SayNum("  portRect.right  = ", port->portRect.right);
    SayNum("  portRect.bottom = ", port->portRect.bottom);

    if (pix == NULL) {
        Say("  pixmap          = NULL (!)");
        return;
    }
    SayHex("  pixmapHandle    = ", (unsigned long)pix);
    DescribeZone("  pixmapHandle", (unsigned long)pix);
    SayHex("  pixmapDeref     = ", (unsigned long)*pix);
    DescribeZone("  pixmapDeref", (unsigned long)*pix);
    SayHex("  baseAddr        = ", (unsigned long)(**pix).baseAddr);
    DescribeZone("  baseAddr", (unsigned long)(**pix).baseAddr);
    SayHex("  rowBytes(raw)   = ",
           (unsigned long)(unsigned short)(**pix).rowBytes);
    SayNum("  bounds.left     = ", (**pix).bounds.left);
    SayNum("  bounds.top      = ", (**pix).bounds.top);
    SayNum("  bounds.right    = ", (**pix).bounds.right);
    SayNum("  bounds.bottom   = ", (**pix).bounds.bottom);
    Say((port->portRect.right == (**pix).bounds.right
         && port->portRect.bottom == (**pix).bounds.bottom
         && port->portRect.left == (**pix).bounds.left
         && port->portRect.top == (**pix).bounds.top)
        ? "  portRect==bounds: YES (the chase's assumption holds)"
        : "  portRect==bounds: NO  (the chase's assumption is WRONG)");

    /* The assumption the first chase attempt rested on, and the one the
       Finder's blit did not satisfy. Asked here of a GWorld pixmap that
       IS a handle, in its own context, so a failure means something. */
    recovered = RecoverHandle((Ptr)*pix);
    SayHex("  RecoverHandle   = ", (unsigned long)recovered);
    Say(recovered == (Handle)pix
        ? "  RecoverHandle: AGREES with the pixmap handle"
        : "  RecoverHandle: DISAGREES (the handle route cannot work here)");
}

/* ---- the mechanism --------------------------------------------------- */

static void DrawInto(GWorldPtr world, const char *tag)
{
    CGrafPtr savedPort;
    GDHandle savedDevice;
    Rect r;
    RgnHandle rgn;
    Handle iconSuite;
    char line[160];
    CGrafPtr port = (CGrafPtr)world;

    memset(&gCount, 0, sizeof gCount);

    GetGWorld(&savedPort, &savedDevice);
    SetGWorld(world, NULL);

    /* Install AFTER SetGWorld and before any drawing, the same order the
       resident uses. If the port already had procs we would be the
       second customiser and the numbers would be somebody else's; the
       geography report above prints grafProcs at allocation so a
       non-NULL there is visible rather than silently overwritten. */
    port->grafProcs = &gHooks;

    /* One of each family the probe cares about. Kept small and explicit:
       every call here must be attributable to exactly one counter. */
    MoveTo(4, 12);
    DrawString((ConstStr255Param)"\pspike");                       /* -> text (or bits!)  */

    MoveTo(0, 0);
    LineTo(40, 40);                              /* -> line             */

    SetRect(&r, 2, 20, 60, 50);
    FrameRect(&r);                               /* -> rect             */
    PaintRect(&r);                               /* -> rect             */

    rgn = NewRgn();
    if (rgn != NULL) {
        SetRectRgn(rgn, 5, 5, 30, 30);
        PaintRgn(rgn);                           /* -> rgn              */
        DisposeRgn(rgn);
    }

    /* THE OUTCOME-2 QUESTION. If an icon plotted from a resource emits a
       bits op inside the offscreen port, a composited icon view is
       recoverable in principle; if it emits nothing, that family is
       lost no matter how good discovery gets. */
    SetRect(&r, 60, 4, 92, 36);
    iconSuite = NULL;
    if (GetIconSuite(&iconSuite, 128, svAllAvailableData) == noErr
        && iconSuite != NULL) {
        (void)PlotIconSuite(&r, atNone, ttNone, iconSuite);
        DisposeIconSuite(iconSuite, true);
        Say("  (PlotIconSuite: suite 128 found and plotted)");
    } else {
        /* No suite of our own: plot a system icon instead, which is the
           same code path through IconUtilities. Reported either way,
           because "we could not test it" and "it emitted nothing" must
           never look alike. */
        if (PlotIconID(&r, atNone, ttNone, -16455) == noErr) {
            Say("  (PlotIconID: system icon -16455 plotted)");
        } else {
            Say("  (PlotIcon: NEITHER route plotted - family UNTESTED)");
        }
    }

    port->grafProcs = NULL;
    SetGWorld(savedPort, savedDevice);

    Say("");
    strcpy(line, "-- hooks fired: ");
    strcat(line, tag);
    Say(line);
    SayNum("  text = ", gCount.text);
    SayNum("  line = ", gCount.line);
    SayNum("  rect = ", gCount.rect);
    SayNum("  rgn  = ", gCount.rgn);
    SayNum("  bits = ", gCount.bits);

    if (gCount.text == 0 && gCount.line == 0 && gCount.rect == 0
        && gCount.rgn == 0 && gCount.bits == 0) {
        Say("  VERDICT: NOTHING fired. Offscreen drawing does not consult");
        Say("           this port's grafProcs, and the semantic road is");
        Say("           closed for every application at once.");
    } else {
        Say("  VERDICT: the bottlenecks DO fire on an offscreen GWorld.");
        Say("           The mechanism is sound; a null result from the");
        Say("           foreign probe is a DISCOVERY failure, not this.");
    }
}

/* ---- one experiment per allocation flavour --------------------------- */

static void RunFlavour(short depth, GWorldFlags flags, const char *tag)
{
    GWorldPtr world = NULL;
    Rect bounds;
    QDErr err;
    char line[160];

    SetRect(&bounds, 0, 0, 120, 80);
    err = NewGWorld(&world, depth, &bounds, NULL, NULL, flags);
    if (err != noErr || world == NULL) {
        strcpy(line, "== FAILED to allocate: ");
        strcat(line, tag);
        Say(line);
        SayNum("   NewGWorld err = ", (long)err);
        return;
    }
    Say("");
    strcpy(line, "======== ");
    strcat(line, tag);
    Say(line);
    ReportGeography(world, tag);
    DrawInto(world, tag);
    DisposeGWorld(world);
}

/* ---- writing the report ---------------------------------------------- */

static void WriteReport(void)
{
    Str255 name = "\pNOW GWorld Report.txt";
    short vRefNum = 0;
    long dirID = 0;
    short ref = 0;
    long count = gReportLen;
    FSSpec spec;
    OSErr err;

    /* The boot volume's root, which is where the rig looks for it. */
    err = FindFolder(kOnSystemDisk, kDesktopFolderType, kDontCreateFolder,
                     &vRefNum, &dirID);
    if (err != noErr) {
        vRefNum = 0;
        dirID = 0;
    }
    err = FSMakeFSSpec(vRefNum, dirID, name, &spec);
    if (err != noErr && err != fnfErr) {
        return;
    }
    (void)FSpDelete(&spec);
    if (FSpCreate(&spec, 'ttxt', 'TEXT', smSystemScript) != noErr) {
        return;
    }
    if (FSpOpenDF(&spec, fsWrPerm, &ref) != noErr) {
        return;
    }
    (void)FSWrite(ref, &count, gReport);
    (void)FSClose(ref);
    (void)FlushVol(NULL, spec.vRefNum);
}

int main(void)
{
    InitGraf(&qd.thePort);
    InitFonts();
    InitWindows();
    InitMenus();
    TEInit();
    InitDialogs(NULL);
    InitCursor();

    gReportLen = 0;
    gReport[0] = '\0';

    Say("NOW GWorld spike - docs/gworld-probe-brief.md");
    Say("Emulator run. Nothing here has executed on physical hardware.");

    /* The standard bottlenecks, once, exactly as the extension takes
       them: a COPY with our ten overridden, never the port's previous
       procs (now_content.c's no-chain rule, and the spike inherits the
       reasoning even though it patches only its own ports). */
    SetStdCProcs(&gStd);
    gHooks = gStd;
    gHooks.textProc = NewQDTextUPP(SpikeText);
    gHooks.lineProc = NewQDLineUPP(SpikeLine);
    gHooks.rectProc = NewQDRectUPP(SpikeRect);
    gHooks.bitsProc = NewQDBitsUPP(SpikeBits);
    gHooks.rgnProc = NewQDRgnUPP(SpikeRgn);

    if (gStd.textProc == NULL || gStd.bitsProc == NULL) {
        Say("SetStdCProcs left a null proc: no experiment is possible.");
        WriteReport();
        return 0;
    }

    /* The flavours the era actually uses, and the two the Finder might.
       depth 0 means "same as the deepest device", which is what most
       compositing code asks for. */
    RunFlavour(0, 0, "depth=device flags=none");
    RunFlavour(8, 0, "depth=8 flags=none");
    RunFlavour(0, useTempMem, "depth=device flags=useTempMem");

    Say("");
    Say("end of report");
    WriteReport();
    return 0;
}
