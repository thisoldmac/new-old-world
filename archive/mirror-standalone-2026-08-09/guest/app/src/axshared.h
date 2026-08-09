/*
 * axshared.h - the AXPeek shared-buffer contract (docs/41).
 *
 * Shared between the axpeek INIT (writer, in each app's active context) and the
 * toolkit-worker `axtree` verb. The buffer is one
 * NewPtrSys block in the *system heap* — globally addressable from any process
 * — whose address the INIT publishes via a Gestalt selector (AX_GESTALT).
 *
 * Coherence is a seqlock: the writer bumps `seq` to odd before touching the
 * body and to the next even after; the reader samples `seq`, copies, re-samples,
 * and retries while it is odd or changed. No locks, interrupt-safe, and a torn
 * snapshot is never observed. Keep this header free of Toolbox types so the
 * host-side harness can include it verbatim.
 */
#ifndef AXPEEK_AXSHARED_H
#define AXPEEK_AXSHARED_H

#include <stddef.h>
#include <stdint.h>

/* 'TBax' — buffer magic and the Gestalt selector that publishes its address. */
#define AX_MAGIC    0x54426178UL
#define AX_GESTALT  0x54426178UL
#define AX_VERSION  4UL

#define AX_NAME_MAX   32        /* CurApName is a Str31 + length byte       */
#define AX_SAMPLE_MAX 32        /* fixed: the resident writer never allocates */

typedef struct {
    uint32_t       currentA5;            /* current process's A5-world anchor */
    uint32_t       stackBase;            /* second partition-membership proof */
    uint32_t       windowList;           /* process-local low-memory 0x09D6   */
    uint32_t       menuList;             /* process-local low-memory 0x0A1C   */
    uint32_t       ticks;                /* sample freshness                  */
    unsigned char  appName[AX_NAME_MAX]; /* low-memory CurApName, Pascal      */
} AXContextSample;

/*
 * Version 4 is a pointer oracle, not a tree snapshot. The INIT records the
 * process-local pointers visible in each sampled A5 world.  A normal-context
 * reader maps currentA5/stackBase into public ProcessInfoRec partitions and
 * then walks windowList directly.
 */
typedef struct {
    uint32_t       magic;                /* AX_MAGIC once the INIT is live      */
    uint32_t       version;              /* AX_VERSION                          */
    volatile uint32_t seq;               /* seqlock; odd = write in progress    */
    uint32_t       ticks;                /* TickCount at last write (liveness)  */
    uint32_t       calls;                /* # committed samples (0 => dead)     */
    uint32_t       lastTrap;             /* which trap last fired (Gate-1 tag)  */
    int32_t        lastErr;
    uint32_t       sampleCount;          /* populated slots, capped above       */
    uint32_t       nextSlot;             /* deterministic full-table eviction   */
    AXContextSample samples[AX_SAMPLE_MAX];
} AXShared;

_Static_assert(sizeof(AXContextSample) == 52,
               "AXContextSample wire layout changed");
_Static_assert(offsetof(AXShared, samples) == 36,
               "AXShared header layout changed");
_Static_assert(sizeof(AXShared) == 1700, "AXShared v4 layout changed");

#endif /* AXPEEK_AXSHARED_H */
