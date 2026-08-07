/* A Toolbox stand-in, for ONE purpose: compiling act/act_menu_identity.c
   with the host cc so `menuact`'s identity check can be tested without a
   Macintosh.

   It declares only what act_menu_probe.h touches — the process serial
   number, which appears there in a prototype and nowhere in the decision
   this test is about. Nothing rests on the field names beyond their
   being the real ones; if they were wrong the cross-build would refuse
   act_menu_probe.c, which is a better gate than this file could be.

   Nothing in the product tree may include it: it is on the include path
   of the native tests only. */
#ifndef NOW_TEST_SHIM_PROCESSES_H
#define NOW_TEST_SHIM_PROCESSES_H

typedef struct {
    unsigned long highLongOfPSN;
    unsigned long lowLongOfPSN;
} ProcessSerialNumber;

#endif
