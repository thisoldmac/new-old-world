/*
 * ptshared.h - the Portal shared-block contract.
 *
 * AXPeek proved the mechanism and used half of it. A GNEFilter INIT runs inside
 * EVERY application's context, with that process's A5 world current — which is
 * the only reason the per-process Toolbox roots are visible at all. AXPeek looks
 * through that window. The Portal reaches through it.
 *
 * The difference matters because everything the act plane cannot do from outside
 * is trivial from inside: per-process low memory is just memory, the Menu
 * Manager's own MDEF can be asked where its items are, and a tracking loop is
 * not something to defeat because we are already running underneath it.
 *
 * Shape, deliberately the same as AXPeek's so the discipline carries over: one
 * NewPtrSys block in the SYSTEM heap (globally addressable from any process),
 * its address published via Gestalt, coherence by seqlock. The host writes a
 * request addressed to a target A5; the hook executes it the next time it finds
 * itself running as that process, and writes the reply back.
 *
 * Addressing is by A5 rather than PSN on purpose: inside the hook, the current
 * A5 world is a single low-memory read (0x0904), while a PSN would need
 * Process Manager calls that are not safe there. The caller already knows the
 * mapping — AXPeek publishes A5 per process, which is exactly what its oracle
 * is for.
 *
 * Provenance: P-DOC. Low-memory addresses and the MDEF message protocol come
 * from Inside Macintosh (Toolbox Essentials, the Menu Manager); nothing here is
 * derived from a disassembly.
 */
#ifndef PORTAL_PTSHARED_H
#define PORTAL_PTSHARED_H

#include <stdint.h>

/* 'TBpt' — block magic and the Gestalt selector that publishes its address. */
#define PT_MAGIC    0x54427074UL
#define PT_GESTALT  0x54427074UL
#define PT_VERSION  1UL

#define PT_MAX_ITEMS 64        /* items reported per menu; fixed, never allocates */

/* Requests. A request is claimed by exactly one process — the one whose A5
 * matches — and the hook never blocks: if the target is not current, it does
 * nothing and the next process's hook call looks again. */
enum {
    PT_OP_NONE = 0,
    /* Ask the target's own Menu Manager where a menu's items ARE, rather than
     * assuming uniform rows. This is the whole reason menu selection missed:
     * the guest reports no item geometry, and separators are not row-height. */
    PT_OP_MENU_GEOMETRY = 1,
    /* Perform a menu command the way the application itself would: arm a
     * guarded MenuSelect patch so the app's own call returns our chosen
     * (menuID, item) and its own command handler runs. No menu is drawn, no
     * tracking loop runs, and nothing depends on mouse motion or timing. */
    PT_OP_MENU_INVOKE = 2,
    /* Prove the patch's calling convention against a known answer, in the
     * target's own context. The ABI bug this exists to catch was SILENT: the
     * patch reported firing and the application did nothing, because the value
     * it read was never the value we wrote. A wrong ABI does not crash, it
     * lies — so the mechanism has to be able to check itself. */
    PT_OP_SELFTEST = 3,
    /* Act on a control the way the application would: arm a guarded
     * TrackControl patch so the app's own call returns the part code we choose.
     * The app then runs its real mouse-down handler. Same shape as
     * MENU_INVOKE — answer the question the app asks, rather than simulating a
     * user convincingly enough to make it ask. */
    PT_OP_CONTROL_INVOKE = 4
};

/* Request status, written by the hook. */
enum {
    PT_STATUS_IDLE = 0,
    PT_STATUS_PENDING = 1,      /* posted by the host, not yet claimed        */
    PT_STATUS_DONE = 2,
    PT_STATUS_ERROR = 3
};

/* Error codes; small and specific, so a failure names itself. */
enum {
    PT_ERR_NONE = 0,
    PT_ERR_NO_MENU = 1,         /* no such menu id in this process's MenuList */
    PT_ERR_NO_MDEF = 2,         /* the menu's MDEF handle was not loadable    */
    PT_ERR_BAD_OP = 3,
    PT_ERR_NO_PATCH = 4,        /* the MenuSelect patch was never installed  */
    PT_ERR_NOT_TAKEN = 5,       /* armed, but the app never called MenuSelect */
    PT_ERR_NO_CTL_PATCH = 7,    /* the TrackControl patch was never installed */
    PT_ERR_ABI = 6              /* the patch answered, and the caller read
                                 * something else — the Pascal result slot or
                                 * the callee-pops contract is wrong */
};

typedef struct {
    int16_t top;
    int16_t left;
    int16_t bottom;
    int16_t right;
} PTRect;

typedef struct {
    uint32_t seq;               /* seqlock: odd while the hook is writing     */
    uint32_t magic;             /* PT_MAGIC once the INIT is live             */
    uint32_t version;

    /* --- the bypass switch ------------------------------------------------ *
     * Zero means the Portal does NOTHING: the GNEFilter hook returns before it
     * looks at anything, and the MenuSelect patch chains straight to the real
     * trap. The extension stays installed and the hook stays chained — we do
     * not unpatch, because a patch that vanishes while a caller is inside it is
     * worse than one that stays — but with this clear the machine behaves as
     * though the Portal were not there.
     *
     * It lives in the shared block rather than behind an op ON PURPOSE: the
     * host writes it directly, so turning the Portal OFF is immediate and does
     * not depend on the target process being alive, frontmost, or pumping its
     * event loop. A safety switch that needs the thing it is protecting you
     * from to cooperate is not a safety switch. */
    uint32_t enabled;

    /* --- request, written by the host ------------------------------------- */
    uint32_t targetA5;          /* which process this is addressed to         */
    uint32_t op;
    int32_t  menuID;            /* which menu (geometry, and invoke)          */
    int32_t  itemIndex;         /* PT_OP_MENU_INVOKE: 1-based item            */
    uint32_t controlHandle;     /* PT_OP_CONTROL_INVOKE: the ControlHandle    */
    int32_t  partCode;          /* PT_OP_CONTROL_INVOKE: part to answer with  */
    uint32_t status;
    uint32_t error;

    /* --- reply, written by the hook in the target's context ---------------- */
    uint32_t servedA5;          /* the A5 that actually served it             */
    uint32_t servedTicks;
    int32_t  itemCount;
    uint32_t armed;             /* invoke: the patch is waiting to fire       */
    uint32_t fired;             /* invoke: the patch answered a MenuSelect    */
    uint32_t sawActionProc;     /* control: the actionProc the app passed —
                                 * 0 = none, 0xFFFFFFFF = the Control Manager's
                                 * "use the control's own" sentinel, else a
                                 * real ProcPtr. Recorded because which of the
                                 * three it is decides how a control is driven */
    uint32_t selftestWant;      /* selftest: the packed value we answered with */
    uint32_t selftestGot;       /* selftest: what the caller actually received */
    int16_t  menuHeight;
    int16_t  menuWidth;
    PTRect   items[PT_MAX_ITEMS];   /* menu-local rects, item 1 at index 0    */
} PTShared;

typedef PTShared *PTSharedPtr;

#endif /* PORTAL_PTSHARED_H */
