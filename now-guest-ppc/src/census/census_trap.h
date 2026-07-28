#ifndef NOW_CENSUS_TRAP_H
#define NOW_CENSUS_TRAP_H

/* Reaching the two 68K-trap-only managers - ATA ($AAF1) and PC Card
   ($AAF0) - from this PowerPC Carbon app, through Mixed Mode. The recipe
   is the parent project's hard-won one (corpus finding
   cis-metal-safe-mixed-mode-fix), reimplemented here and proven on the
   PB1400c by spikes/census-trap: a real M68K RoutineDescriptor so
   CallUniversalProc thunks PPC->68K instead of running the bytes as PPC
   (the machine-wedge), an RTS thunk that keeps its return address on the
   stack, and CallUniversalProc resolved from InterfaceLib (it is
   CALL_NOT_IN_CARBON) and called variadically. Metal-verified: selftest
   $4242, and CSGetCardServicesInfo returned CS 2.01 / 4 sockets. */

#include <Carbon.h>

/* Bring the Mixed Mode path up (resolve CallUniversalProc, prepare the
   thunks). Returns 1 when ready, 0 when it cannot be reached (then the
   caller answers `refused`). Cheap and idempotent. */
int census_trap_ready(void);

/* ATA IDENTIFY DEVICE for `device_id` (bus | device<<8) into `buf` (512
   bytes). Returns the trap result: 0 = the ATA Manager answered. `buf`
   holds the raw IDENTIFY response - on some drives the manager answers
   with an empty buffer, which is the caller's to notice. */
SInt16 census_ata_identify(unsigned long device_id, unsigned char *buf);

/* CSGetCardServicesInfo (selector 7): Card Services' own version and
   socket count - read-only, no socket or card touched. Fills the fields
   and returns the trap result (0 = ok). `vendor` gets the zero-terminated
   CS vendor string. */
SInt16 census_cs_info(unsigned char sig[2], unsigned short *count,
                      unsigned short *revision, unsigned short *level,
                      unsigned char *vendor, unsigned short vendor_cap);

#endif /* NOW_CENSUS_TRAP_H */
