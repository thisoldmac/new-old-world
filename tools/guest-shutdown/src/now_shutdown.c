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
 * What is left as a fallback is the Toolbox call the Finder itself eventually
 * makes. ShutDwnPower starts the Shutdown Manager sequence, but mac99 does not
 * reliably finish the HFS unmount on this route. The host therefore verifies
 * the unmounted bit and refuses to preserve a dirty image. The measured clean
 * route drives the Finder's actual Special > Shut Down menu through NOW.
 *
 * This is a RIG INSTRUMENT rather than a product feature: it exists only as a
 * last guest-side route for a disposable emulator clone. Do not use it to stop
 * a machine somebody is using or treat disk quiet as a clean shutdown.
 */

#include <ShutDown.h>

int main(void)
{
    ShutDwnPower();

    /*
     * Returning leaves the guest up for diagnosis if the Shutdown Manager
     * declines. The host independently verifies the HFS unmounted bit even
     * when the call appears to complete.
     */
    return 0;
}
