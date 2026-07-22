/* Trap-dispatch spike - see README.md.
 *
 * Two census probes NOW wants (ata, pccard) live behind 68K Toolbox traps
 * this PowerPC CFM app cannot import: the ATA Manager at $AAF1 and the PC
 * Card Manager at $AAF0. The parent project learned the hard way - four
 * machine wedges over a week (corpus finding cis-metal-safe-mixed-mode-fix)
 * - that the danger was NEVER the managers. It was reaching them wrong:
 * CallUniversalProc on a RAW code pointer runs the 68K bytes as native PPC
 * and wedges the machine. The fix: a real M68K RoutineDescriptor (kM68kISA)
 * so Mixed Mode thunks PPC->68K, and an RTS thunk that keeps its return
 * address on the stack because the trap preserves no scratch register.
 *
 * This reimplements that recipe in NOW's own code (no TimBotTu runtime is
 * imported; the thunk bytes are the recovered hardware trap ABI, not
 * borrowed logic) and follows the corpus's methodology: prove the dispatch
 * with a TRAP-FREE selftest (returns 0x4242) BEFORE touching any trap. A
 * wrong descriptor fails there as survivable app death, never a machine
 * wedge, because the bytes run under emulation. Only if selftest passes
 * does it try the two read-only trap calls.
 *
 * Carbon hides CallUniversalProc (it is CALL_NOT_IN_CARBON - no 68K on OS
 * X), but the symbol lives in InterfaceLib on OS 9, so it is resolved by
 * name, exactly as the ADB/SCSI probes resolve their managers. The
 * RoutineDescriptor struct, _MixedModeMagic, kM68kISA and MakeDataExecutable
 * all compile and link under Carbon directly.
 *
 * Nothing configures a card or powers a socket: CSGetCardServicesInfo
 * (selector 7) reads Card Services' version and socket count; ATA IDENTIFY
 * is a non-destructive drive read. Attended, because no emulator covers it.
 *
 * Each risky step is written to "Census Trap Steps" on the desktop BEFORE
 * it is taken, so a whole-machine wedge names the last thing attempted. */

#include <Carbon.h>
#include <MixedMode.h>

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

enum { kWinW = 490, kWinH = 470, kLineH = 12, kMaxLines = 72 };

static WindowRef g_window;
static char g_lines[kMaxLines][96];
static int g_count;

static void crumb(const char *file, const char *what, Boolean truncate);

/* Persist every line to "Census Trap Spike" the instant it is reported, so
   a crash mid-run still leaves the whole story on the desktop. */
static void report(const char *fmt, ...)
{
    va_list a;
    if (g_count >= kMaxLines) return;
    va_start(a, fmt);
    vsnprintf(g_lines[g_count], sizeof g_lines[0], fmt, a);
    va_end(a);
    crumb("Census Trap Spike", g_lines[g_count], g_count == 0);
    ++g_count;
}

static void crumb(const char *file, const char *what, Boolean truncate)
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
    CopyCStringToPascal(file, name);
    if (FSMakeFSSpec(vref, dir, name, &spec) == fnfErr) {
        FSpCreate(&spec, 'ttxt', 'TEXT', smSystemScript);
    }
    if (FSpOpenDF(&spec, fsWrPerm, &ref) != noErr) {
        return;
    }
    if (truncate) { SetEOF(ref, 0); } else { SetFPos(ref, fsFromLEOF, 0); }
    len = (long)strlen(what);
    FSWrite(ref, &len, what);
    len = 1;
    FSWrite(ref, &len, "\r");
    FSClose(ref);
}

/* Write the last-attempted step to disk before a risky call. */
static void step(const char *what) { crumb("Census Trap Steps", what, false); }

/* --- the Mixed Mode dispatch machinery ---------------------------------- *
 * A hand-built RoutineDescriptor flagged kM68kISA so CallUniversalProc
 * switches PPC->68K. The struct, magic and constants all compile under
 * Carbon; only CallUniversalProc must be resolved at runtime. */

#define BUILD_M68K_RD(procInfo, procedure) {                        \
        _MixedModeMagic, kRoutineDescriptorVersion,                 \
        kSelectorsAreNotIndexable, 0, 0, 0, 0,                      \
        { { (procInfo), 0, kM68kISA | kOld68kRTA,                   \
            kProcDescriptorIsAbsolute | kUseCurrentISA,             \
            (ProcPtr)(procedure), 0, 0 } } }

/* pascal callee, 2-byte result, one 4-byte pointer arg. */
#define kThunkInfo (kPascalStackBased                              \
    | RESULT_SIZE(SIZE_CODE(sizeof(OSErr)))                        \
    | STACK_ROUTINE_PARAMETER(1, SIZE_CODE(sizeof(void *))))

/* selftest: the corpus's proven trap-free control (no trap touched).
     MOVEA.L (SP)+,A1    ; pop the return address
     ADDQ.L  #4,SP       ; discard the one 4-byte arg (pascal callee pops)
     MOVE.W  #$4242,(SP) ; write the sentinel into the result slot
     JMP     (A1)        ; return */
static unsigned short g_self_thunk[] = {
    0x225F, 0x588F, 0x3EBC, 0x4242, 0x4ED1
};
static RoutineDescriptor g_self_rd =
    BUILD_M68K_RD(kThunkInfo, g_self_thunk);

/* ata: MOVEA.L 4(SP),A0 (pb, no pop); DC.W $AAF1; MOVE.W D0,8(SP); RTS.
   The ATA trap is register-based (A0 = pb, result word in D0). */
static unsigned short g_ata_thunk[] = {
    0x206F, 0x0004, 0xAAF1, 0x3F40, 0x0008, 0x4E75
};
static RoutineDescriptor g_ata_rd = BUILD_M68K_RD(kThunkInfo, g_ata_thunk);

/* pccard: pascal-callee $AAF0. Arg is a {selector, pb} block, read WITHOUT
   popping so the frame stays intact for RTS + Mixed Mode arg cleanup.
     MOVEA.L 4(SP),A0    ; arg block
     MOVE.L  (A0),D0     ; selector (unused by trap, but keeps the shape)
     CLR.W   -(SP)       ; CS result space
     MOVE.L  4(A0),-(SP) ; push pb
     dc.w    $AAF0       ; trap pops pb, fills result; selector must be in D0
     MOVE.W  (SP)+,D0    ; pop OSErr
     MOVE.W  D0,8(SP)    ; -> pascal result slot
     RTS */
static unsigned short g_pccard_thunk[] = {
    0x206F, 0x0004, 0x2010, 0x4267, 0x2F28, 0x0004,
    0xAAF0, 0x301F, 0x3F40, 0x0008, 0x4E75
};
static RoutineDescriptor g_pccard_rd =
    BUILD_M68K_RD(kThunkInfo, g_pccard_thunk);

/* VARIADIC on purpose: CallUniversalProc reads its args per procInfo from
   the PowerPC stack parameter-save area, the way a variadic callee does.
   A fixed-arg pointer would leave the arg only in a register and the
   manager would marshal garbage - the Type 1 bus error. Declaring the
   pointer variadic makes gcc spill the args to the stack as expected. */
typedef long (*CallUPPProc)(UniversalProcPtr, ProcInfoType, ...);
static CallUPPProc g_call_upp;

static int resolve_call_upp(void)
{
    CFragConnectionID conn = 0;
    Ptr mainAddr = NULL;
    Str255 err, pname;
    Ptr addr;
    CFragSymbolClass cls;

    CopyCStringToPascal("InterfaceLib", pname);
    if (GetSharedLibrary(pname, kPowerPCCFragArch, kReferenceCFrag,
                         &conn, &mainAddr, err) != noErr) {
        return 0;
    }
    CopyCStringToPascal("CallUniversalProc", pname);
    if (FindSymbol(conn, pname, &addr, &cls) != noErr) {
        return 0;
    }
    g_call_upp = (CallUPPProc)addr;
    return 1;
}

static SInt16 dispatch(RoutineDescriptor *rd, void *arg)
{
    return (SInt16)g_call_upp((UniversalProcPtr)rd, kThunkInfo, arg);
}

/* --- parameter blocks (from ATA.h / CardServices.h) --------------------- */

typedef struct {
    void *link; UInt16 qType; UInt8 vers; UInt8 rsvd; void *rsvd2;
    void *callback; OSErr result; UInt8 fn; UInt8 ioSpeed; UInt16 flags;
    SInt16 rsvd3; UInt32 deviceID; UInt32 timeout; void *c1; void *c2;
    UInt16 state; UInt16 sems; SInt32 rsvd4;
    UInt16 r1[4]; UInt8 *buffer; UInt16 r2[12]; SInt16 r3[6];
} SpikeAtaIdentify;
enum { kAtaFnIdentify = 0x13 };

typedef struct {
    UInt8 signature[2]; UInt16 count; UInt16 revision; UInt16 csLevel;
    UInt16 reserved; UInt16 vStrLen; UInt8 *vendorString;
} SpikeCSInfo;
enum { kCSGetCardServicesInfo = 7 };

typedef struct { long selector; void *pb; } CSArg;

/* --- run ---------------------------------------------------------------- */

static void run_probe(void)
{
    long v;

    if (Gestalt(gestaltSystemVersion, &v) == noErr) {
        report("System %ld.%ld.%ld", (v >> 8) & 0xF, (v >> 4) & 0xF, v & 0xF);
    }
    if (!resolve_call_upp()) {
        report("CallUniversalProc not in InterfaceLib - cannot dispatch. STOP");
        return;
    }
    report("CallUniversalProc resolved at $%08lX", (unsigned long)g_call_upp);
    report("self descriptor $%08lX, thunk $%08lX",
           (unsigned long)&g_self_rd, (unsigned long)g_self_thunk);
    MakeDataExecutable(g_self_thunk, sizeof g_self_thunk);
    MakeDataExecutable(g_ata_thunk, sizeof g_ata_thunk);
    MakeDataExecutable(g_pccard_thunk, sizeof g_pccard_thunk);
    report("");

    /* Stage 1 - the trap-free control. */
    step("selftest: ABOUT TO dispatch trap-free thunk");
    report("selftest: about to call...");
    {
        SInt16 r = dispatch(&g_self_rd, (void *)0);
        step("selftest: RETURNED (did not crash)");
        report("selftest: returned $%04X %s", (unsigned short)r,
               (unsigned short)r == 0x4242 ? "- Mixed Mode OK"
                                           : "- WRONG, stopping");
        if ((unsigned short)r != 0x4242) {
            step("selftest wrong value - not touching traps");
            return;
        }
    }
    report("");

    /* Stage 2 - ATA IDENTIFY via $AAF1. */
    {
        static unsigned char buf[512];
        SpikeAtaIdentify pb;
        SInt16 err;

        memset(&pb, 0, sizeof pb);
        memset(buf, 0, sizeof buf);
        pb.vers = 1;
        pb.fn = kAtaFnIdentify;
        pb.deviceID = 0x0000;               /* bus 0, device 0 */
        pb.timeout = 1000;
        pb.buffer = buf;
        step("ata: $AAF1 IDENTIFY device 0.0");
        err = dispatch(&g_ata_rd, &pb);
        report("ata: trap err=%d, pb result=%d", (int)err, (int)pb.result);
        if (err == noErr && pb.result == noErr) {
            char model[42];
            int i;
            for (i = 0; i < 40; i++) {
                unsigned char c = buf[27 * 2 + (i ^ 1)];  /* words 27.., swapped */
                model[i] = (c >= 32 && c < 127) ? (char)c : ' ';
            }
            model[40] = '\0';
            report("ata: model \"%s\"", model);
        } else {
            report("ata: no drive at 0.0 (or the ATA trap ABI differs)");
        }
    }
    report("");

    /* Stage 3 - Card Services info via $AAF0. */
    {
        static unsigned char vendor[64];
        SpikeCSInfo pb;
        CSArg arg;
        SInt16 err;

        memset(&pb, 0, sizeof pb);
        memset(vendor, 0, sizeof vendor);
        pb.vStrLen = sizeof vendor - 1;     /* real buffer: no NULL scribble */
        pb.vendorString = vendor;
        arg.selector = kCSGetCardServicesInfo;
        arg.pb = &pb;
        step("pccard: $AAF0 CSGetCardServicesInfo (sel 7)");
        err = dispatch(&g_pccard_rd, &arg);
        report("pccard: trap err=%d", (int)err);
        if (err == 0) {
            report("pccard: sig %c%c, %u sockets, CS level $%04X",
                   pb.signature[0] ? pb.signature[0] : '?',
                   pb.signature[1] ? pb.signature[1] : '?',
                   pb.count, pb.csLevel);
            report("pccard: vendor \"%.40s\"", (char *)vendor);
        } else {
            report("pccard: no Card Services (err above)");
        }
    }
    report("");
    report("VERDICT: read the stages - selftest gates the two traps.");
}

/* --- window ------------------------------------------------------------- */

static void draw(void)
{
    Rect b;
    Str255 t;
    int i;

    SetPortWindowPort(g_window);
    GetWindowPortBounds(g_window, &b);
    EraseRect(&b);
    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    for (i = 0; i < g_count && 18 + i * kLineH < kWinH - 6; ++i) {
        MoveTo(12, 18 + i * kLineH);
        CopyCStringToPascal(g_lines[i], t);
        DrawString(t);
    }
}

int main(void)
{
    EventRecord e;
    Rect b;
    Str255 title;
    Boolean running = true;
    int i;

    InitCursor();
    SetRect(&b, 30, 50, 30 + kWinW, 50 + kWinH);
    CreateNewWindow(kDocumentWindowClass, kWindowCloseBoxAttribute, &b,
                    &g_window);
    if (g_window == NULL) return 1;
    CopyCStringToPascal("Census Trap Spike", title);
    SetWTitle(g_window, title);
    SetThemeWindowBackground(g_window, kThemeBrushDialogBackgroundActive, true);
    ShowWindow(g_window);
    SelectWindow(g_window);

    {
        FSSpec old;
        short vref;
        long dir;
        Str255 name;
        CopyCStringToPascal("Census Trap Steps", name);
        if (FindFolder(kOnSystemDisk, kDesktopFolderType, kDontCreateFolder,
                       &vref, &dir) == noErr
            && FSMakeFSSpec(vref, dir, name, &old) == noErr) {
            FSpDelete(&old);
        }
    }
    step("launched");
    run_probe();                        /* report() persists each line itself */
    (void)i;
    step("done");

    while (running) {
        if (!WaitNextEvent(everyEvent, &e, 20, NULL)) continue;
        if (e.what == updateEvt) {
            BeginUpdate(g_window);
            draw();
            EndUpdate(g_window);
        } else if (e.what == mouseDown) {
            WindowRef w;
            short part = FindWindow(e.where, &w);
            if (part == inGoAway && TrackGoAway(w, e.where)) {
                running = false;
            } else if (part == inDrag) {
                DragWindow(w, e.where, NULL);
            }
        }
    }
    return 0;
}
