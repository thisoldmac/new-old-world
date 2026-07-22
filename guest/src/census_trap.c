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
    memset(&pb, 0, sizeof pb);
    pb.vers = 1;
    pb.fn = kAtaFnIdentify;
    pb.deviceID = device_id;
    pb.timeout = 1000;                  /* ms; a live drive answers at once */
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
