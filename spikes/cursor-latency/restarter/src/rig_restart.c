/*
 * rig_restart.c - restart the guest, properly, from inside.
 *
 * THIS IS A RIG INSTRUMENT. See ../README.md.
 *
 * An INIT loads at boot ONLY, so every staging cycle needs a real
 * reboot. The obvious ways are all wrong here:
 *
 *   - QMP `quit` is a power cut. It leaves the HFS volume marked
 *     mounted, so every later clone opens Disk First Aid, and it is
 *     forbidden in this spike's brief.
 *   - QMP `system_powerdown` is ACPI, which OS 9 on mac99 ignores
 *     entirely (measured in the parent checkout's tools/shutdown-guest).
 *   - Driving Special > Restart with the harness does not work: its
 *     click posts a mouseDown and mouseUp together, so MenuSelect's
 *     tracking loop sees the button already up and selects nothing.
 *     Watched here, 2026-08-07: the menu did not even stay open.
 *
 * A classic Mac shuts down from inside. So this is the smallest thing
 * that can be `launch`ed: it asks the Shutdown Manager to restart, which
 * runs the shutdown procedures and flushes the volumes on the way out -
 * which is the part that matters, because the whole point is to not
 * leave the disk dirty.
 */

#include <MacTypes.h>

extern void rig_shut_dwn_start(void);

int main(void)
{
    rig_shut_dwn_start();
    return 0;                   /* not reached */
}
