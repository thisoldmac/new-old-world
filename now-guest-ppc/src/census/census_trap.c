/* census_trap.c - Mixed Mode dispatch to the 68K-trap-only managers.
 *
 * The mechanism is spikes/census-trap, proven on the PB1400c: selftest
 * $4242 (the trap-free control), then CSGetCardServicesInfo answering CS
 * 2.01 / 4 sockets over the real $AAF0 trap. It reaches the ATA Manager
 * ($AAF1) and PC Card Manager ($AAF0) the only way a PowerPC Carbon app
 * can - a hand-built M68K RoutineDescriptor so CallUniversalProc thunks
 * PPC->68K rather than running the 68K bytes as PPC (the machine-wedge the
 * parent project paid for four times: corpus cis-metal-safe-mixed-mode-fix).
 *
 * Why the details are the way they are, none of them cosmetic:
 *  - the descriptor is kM68kISA|kOld68kRTA, not a cast on the code pointer;
 *  - each thunk ends in RTS and keeps its return address on the stack,
 *    because a trap preserves no scratch register;
 *  - CallUniversalProc is CALL_NOT_IN_CARBON (no 68K on OS X), so it is
 *    resolved from InterfaceLib by name, exactly like the ADB/SCSI managers;
 *  - the resolved pointer is called VARIADICALLY, so gcc spills the args to
 *    the PPC parameter-save area where the Mixed Mode glue reads them. A
 *    fixed-arg pointer leaves them in registers and the trap marshals
 *    garbage - the Type 1 bus error that cost the spike two rounds.
 *
 * Everything here is a read: CSGetCardServicesInfo touches no socket, ATA
 * IDENTIFY is non-destructive. The wedge risk was the dispatch, and the
 * dispatch is proven. */

#include "census_trap.h"

#include <MixedMode.h>
#include <stdarg.h>
#include <string.h>

/* A RoutineDescriptor flagged kM68kISA: the switch PPC->68K. */
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

/* ata: ataManager is ONEWORDINLINE($AAF1), pascal stack-based (pb pushed,
   autopopped):
     MOVEA.L 4(SP),A0  ; pb (our one arg, not popped)
     CLR.W   -(SP)     ; ATA result space
     MOVE.L  A0,-(SP)  ; push pb for the trap
     dc.w    $AAF1     ; trap autopops pb, leaves result
     MOVE.W  (SP)+,D0  ; pop the SInt16
     MOVE.W  D0,8(SP)  ; -> pascal result slot
     RTS */
static unsigned short g_ata_thunk[] = {
    0x206F, 0x0004, 0x4267, 0x2F08, 0xAAF1, 0x301F, 0x3F40, 0x0008, 0x4E75
};
static RoutineDescriptor g_ata_rd = BUILD_M68K_RD(kThunkInfo, g_ata_thunk);

/* pccard: pascal-callee $AAF0. Arg is a {selector, pb} block, read WITHOUT
   popping so the frame stays intact for RTS + Mixed Mode arg cleanup.
     MOVEA.L 4(SP),A0    ; arg block
     MOVE.L  (A0),D0     ; selector into D0 (the trap reads it there)
     CLR.W   -(SP)       ; CS result space
     MOVE.L  4(A0),-(SP) ; push pb
     dc.w    $AAF0       ; trap pops pb, fills result
     MOVE.W  (SP)+,D0    ; pop OSErr
     MOVE.W  D0,8(SP)    ; -> pascal result slot
     RTS */
static unsigned short g_pccard_thunk[] = {
    0x206F, 0x0004, 0x2010, 0x4267, 0x2F28, 0x0004,
    0xAAF0, 0x301F, 0x3F40, 0x0008, 0x4E75
};
static RoutineDescriptor g_pccard_rd =
    BUILD_M68K_RD(kThunkInfo, g_pccard_thunk);

/* VARIADIC on purpose - see the file header. */
typedef long (*CallUPPProc)(UniversalProcPtr, ProcInfoType, ...);
static CallUPPProc g_call_upp;
static int g_ready;                     /* 0 unknown, 1 yes, -1 no */

int census_trap_ready(void)
{
    CFragConnectionID conn = 0;
    Ptr mainAddr = NULL;
    Str255 err, pname;
    Ptr addr;
    CFragSymbolClass cls;

    if (g_ready != 0) {
        return g_ready == 1;
    }
    g_ready = -1;
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
    /* The Mixed Mode glue reads the 68K bytes as instructions; on a
       coherent-cache machine this is a no-op, but the trap managers
       predate the promise, so flush before first dispatch. */
    MakeDataExecutable(g_ata_thunk, sizeof g_ata_thunk);
    MakeDataExecutable(g_pccard_thunk, sizeof g_pccard_thunk);
    g_ready = 1;
    return 1;
}

static SInt16 dispatch(RoutineDescriptor *rd, void *arg)
{
    return (SInt16)g_call_upp((UniversalProcPtr)rd, kThunkInfo, arg);
}

/* --- is the trap at the other end actually there? ------------------------
 *
 * census_trap_ready() above proves the ROUTE: CallUniversalProc resolved,
 * the thunks flushed, the ISA switch built. It proves nothing whatever
 * about the DESTINATION, and the two were conflated here until a Power Mac
 * paid for it. The 1400c this file was written against has a PC Card
 * Manager at $AAF0; a Power Mac G4 running the same Mac OS 9.1 does not,
 * and $AAF0 there is _Unimplemented. Dispatching into it on 2026-08-07
 * killed NOW mid-`census`, then wedged the anchor worker — a SEPARATE
 * process — and the Finder crashed under the human's hands a moment later.
 * A trap-table entry is not a place to arrive uninvited.
 *
 * The trap table is read the same way CallUniversalProc is reached:
 * GetToolboxTrapAddress is CALL_NOT_IN_CARBON, so it is resolved from
 * InterfaceLib BY NAME rather than linked. That is not a workaround, it is
 * the established pattern in this file — and it is available for exactly
 * the same reason the traps are: on Mac OS 9 a CarbonLib application is
 * still running in the classic environment.
 *
 * The comparison is the canonical one: a trap is unimplemented when its
 * table entry EQUALS _Unimplemented's ($A89F). Toolbox trap numbers are
 * the low ten bits of the trap word, so $AAF0 -> $2F0 and $A89F -> $09F. */

enum { kUnimplementedTrapNum = 0x009F };

typedef UniversalProcPtr (*GetToolboxTrapAddressProc)(short);
static GetToolboxTrapAddressProc g_get_trap;
static int g_get_trap_ready;            /* 0 unknown, 1 yes, -1 no */

static int trap_reader_ready(void)
{
    CFragConnectionID conn = 0;
    Ptr mainAddr = NULL;
    Str255 err, pname;
    Ptr addr;
    CFragSymbolClass cls;

    if (g_get_trap_ready != 0) {
        return g_get_trap_ready == 1;
    }
    g_get_trap_ready = -1;
    CopyCStringToPascal("InterfaceLib", pname);
    if (GetSharedLibrary(pname, kPowerPCCFragArch, kReferenceCFrag,
                         &conn, &mainAddr, err) != noErr) {
        return 0;
    }
    CopyCStringToPascal("GetToolboxTrapAddress", pname);
    if (FindSymbol(conn, pname, &addr, &cls) != noErr) {
        return 0;
    }
    g_get_trap = (GetToolboxTrapAddressProc)addr;
    g_get_trap_ready = 1;
    return 1;
}

int census_trap_implemented(unsigned short trap_word,
                            unsigned long *at, unsigned long *unimplemented)
{
    UniversalProcPtr here, none;

    if (at != NULL) { *at = 0; }
    if (unimplemented != NULL) { *unimplemented = 0; }
    if (!trap_reader_ready()) {
        return -1;
    }
    here = g_get_trap((short)(trap_word & 0x03FF));
    none = g_get_trap((short)kUnimplementedTrapNum);
    if (at != NULL) { *at = (unsigned long)here; }
    if (unimplemented != NULL) { *unimplemented = (unsigned long)none; }
    /* A NULL entry is not a trap either, and reading _Unimplemented itself
       as NULL means the table did not answer — neither is a dispatch. */
    if (here == NULL || none == NULL) {
        return here == NULL ? 0 : -1;
    }
    return here != none;
}

/* --- parameter blocks (laid out to match ATA.h / CardServices.h, using
   the spike's verified offsets rather than the Carbon-gated headers) ------ */

typedef struct {
    void *link; UInt16 qType; UInt8 vers; UInt8 rsvd; void *rsvd2;
    void *callback; OSErr result; UInt8 fn; UInt8 ioSpeed; UInt16 flags;
    SInt16 rsvd3; UInt32 deviceID; UInt32 timeout; void *c1; void *c2;
    UInt16 state; UInt16 sems; SInt32 rsvd4;
    UInt16 r1[4]; UInt8 *buffer; UInt16 r2[12]; SInt16 r3[6];
} TrapAtaIdentify;
enum { kAtaFnIdentify = 0x13 };
/* ATA.h: bATAFlagIORead = 13. Named here because this file deliberately
   does not include the Carbon-gated header; the value is checked against
   Universal Interfaces ATA.h, not remembered. */
enum { kAtaFlagIORead = 1 << 13 };

typedef struct {
    UInt8 signature[2]; UInt16 count; UInt16 revision; UInt16 csLevel;
    UInt16 reserved; UInt16 vStrLen; UInt8 *vendorString;
} TrapCSInfo;
enum { kCSGetCardServicesInfo = 7 };

typedef struct { long selector; void *pb; } CSArg;

SInt16 census_ata_identify(unsigned long device_id, unsigned char *buf)
{
    TrapAtaIdentify pb;

    if (!census_trap_ready()) {
        return -1;
    }
    /* The guard sits HERE as well as in the probe, so a future caller
       cannot reach the trap by a route that forgot to ask. */
    if (census_trap_implemented(0xAAF1, NULL, NULL) != 1) {
        return -1;
    }
    memset(&pb, 0, sizeof pb);
    pb.vers = 1;
    pb.fn = kAtaFnIdentify;
    pb.deviceID = device_id;
    pb.timeout = 1000;                  /* ms; a live drive answers at once */
    /* THE DIRECTION OF THE TRANSFER, AND IT IS NOT OPTIONAL. Drive
       Identify moves 512 bytes from the drive to `buffer`, and the ATA
       Manager only drives that data phase when the read flag says so.
       Without it the call still returns noErr — so it looks like a
       working probe that happens to meet drives with nothing to say —
       and that is exactly how it read on the PB1400c on 2026-07-22:
       "the manager answers noErr with an EMPTY IDENTIFY buffer". The
       buffer was empty because nobody ever asked for the data.

       The empty buffer was the harmless half. The device is left mid-
       command, and on Mac OS 9 the cost lands minutes later on the ONE
       write nothing else can cover for: the Shutdown Manager's final
       "volume unmounted" flag. The machine runs, the census page comes
       back, hundreds of blocks are written, the Finder's Special > Shut
       Down powers the Mac off in six seconds looking perfect — and the
       HFS volume comes back marked mounted, so every clone of that image
       opens in Disk First Aid and scripts/bake-ext-image refuses it.

       Measured on the emulator 2026-08-07, same base image and same
       shutdown route throughout: no census -> CLEAN; the full 14-probe
       sweep -> DIRTY; `--probes ata` alone -> DIRTY; the same probe
       narrowed to the one device id that answers -> DIRTY (so it is the
       SUCCESSFUL Identify, not the timeouts on the absent ids); with
       this flag, `--probes ata` -> CLEAN and the full sweep -> CLEAN.
       A static parameter block was tried first and changed nothing,
       which is how the queue-element theory was ruled out.

       Not metal-verified: nobody has yet shut a PB1400c down after a
       census. The row's contents on that machine should be re-read too —
       it may no longer say "no IDENTIFY data". */
    pb.flags = kAtaFlagIORead;
    pb.buffer = buf;
    if (dispatch(&g_ata_rd, &pb) != noErr) {
        return -1;
    }
    return pb.result;
}

SInt16 census_cs_info(unsigned char sig[2], unsigned short *count,
                      unsigned short *revision, unsigned short *level,
                      unsigned char *vendor, unsigned short vendor_cap)
{
    TrapCSInfo pb;
    CSArg arg;
    SInt16 err;

    if (!census_trap_ready()) {
        return -1;
    }
    /* The guard sits HERE as well as in the probe — see census_ata_identify. */
    if (census_trap_implemented(0xAAF0, NULL, NULL) != 1) {
        return -1;
    }
    memset(&pb, 0, sizeof pb);
    if (vendor != NULL && vendor_cap > 0) {
        vendor[0] = '\0';
        pb.vStrLen = (UInt16)(vendor_cap - 1);
        pb.vendorString = vendor;
    }
    arg.selector = kCSGetCardServicesInfo;
    arg.pb = &pb;
    err = dispatch(&g_pccard_rd, &arg);
    if (err == noErr) {
        if (sig != NULL) { sig[0] = pb.signature[0]; sig[1] = pb.signature[1]; }
        if (count != NULL) { *count = pb.count; }
        if (revision != NULL) { *revision = pb.revision; }
        if (level != NULL) { *level = pb.csLevel; }
    }
    return err;
}
