#ifndef NOW_EXT_ADB_OBSERVER_H
#define NOW_EXT_ADB_OBSERVER_H

#include "peek_table.h"

/* Passive diagnostic only. Start and stop are called synchronously from the
   PPC application's resident service. Once installed, the wrapper remains a
   transparent member of the ADB handler chain until reboot. */
void now_ext_adb_observer_start(NowPeekTable *table, NowPeekU32 epoch);
void now_ext_adb_observer_stop(void);
void now_ext_adb_observer_rollback(NowPeekTable *table);

#endif /* NOW_EXT_ADB_OBSERVER_H */
