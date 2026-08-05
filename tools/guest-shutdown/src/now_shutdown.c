/*
 * NOW Shut Down - a Macintosh shutting ITSELF down, on request, with no
 * person at the keyboard.
 *
 * WHY THIS EXISTS. A classic Mac has no outside power button that software
 * on this side of the wire can press. QMP `system_powerdown` is ACPI and
 * OS 9 on mac99 ignores it; QMP `quit` is a power CUT, which sets the
 * volume's unclean bit and makes Disk First Aid part of the next boot -
 * and an INIT loads at boot only, so scripts/spin-up-ppc must reboot for
 * a living. So the shutdown has to be asked for from INSIDE the guest.
 *
 * Every route that goes through the human interface was measured and
 * rejected on 2026-08-05 (docs/open-issues.md):
 *
 *   - the lab's canonical anchor worker has no `script` verb, so
 *     `tell application "Finder" to shut down` cannot be sent;
 *   - QMP keyboard events never reach this guest at all. `has-adb=false`
 *     on mac99,via=pmu, so there is no ADB keyboard and no ADB power key,
 *     and neither `send-key` nor `input-send-event` moves a single key in
 *     Key Caps;
 *   - the worker's `click` verb closes a menu without selecting from it,
 *     because MenuSelect's tracking loop reads the real button state and
 *     a posted event pair is already up by the time it looks.
 *
 * What is left is the Toolbox call the Finder itself ends up making.
 * ShutDwnPower (_ShutDown, selector 1, since System 7.1) runs every
 * registered shutdown procedure, flushes and unmounts the volumes, and
 * asks the power manager to cut power - which on QEMU exits the process,
 * so the host can watch for that and know the guest went down on its own.
 *
 * WHAT IT DELIBERATELY DOES NOT DO: send quit AppleEvents to running
 * applications. The Finder does that before it calls the Shutdown Manager,
 * and this does not, so an application holding unsaved work loses it. That
 * is why this is a RIG INSTRUMENT and not a product feature: the moment
 * scripts/spin-up-ppc uses it is chosen so that nothing but the system's
 * own background processes is running. Do not reach for it to stop a
 * machine somebody is using.
 */

#include <ShutDown.h>

int main(void)
{
    ShutDwnPower();

    /*
     * Only reached if the Shutdown Manager declined, which nothing here
     * has ever seen. Returning quits the application and leaves the guest
     * up, so the host's wait-for-exit times out and says so - the same
     * outcome as any other failure to go down, and better than a bomb box
     * nobody is present to read.
     */
    return 0;
}
