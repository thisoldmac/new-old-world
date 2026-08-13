#ifndef NOW_EXT_ADB_OBSERVER_H
#define NOW_EXT_ADB_OBSERVER_H

#include "peek_table.h"

/* Start and stop are called synchronously from the PPC application's resident
   service. Once installed, the wrapper remains a transparent member of the
   ADB handler chain until reboot. `inject` is opt-in; zero is passive. */
void now_ext_adb_observer_start(NowPeekTable *table, NowPeekU32 epoch,
                                unsigned inject);
void now_ext_adb_observer_stop(void);
void now_ext_adb_observer_rollback(NowPeekTable *table);
NowPeekU32 now_ext_adb_observer_physical_seq(void);

#endif /* NOW_EXT_ADB_OBSERVER_H */
