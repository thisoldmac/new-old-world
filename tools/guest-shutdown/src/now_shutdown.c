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
 * What is left is the standard shutdown Apple event addressed to the Finder.
 * This is the programmatic form of asking the Finder to shut down, so the
 * Finder owns its normal quit-application and Shutdown Manager sequence.
 * The earlier version called ShutDwnPower directly. That started shutdown,
 * but three preserved mac99 images still had the HFS mounted bit set after
 * the disk went quiet; a direct power request is therefore not evidence of
 * the clean Finder route this rig needs.
 *
 * This remains a RIG INSTRUMENT rather than a product feature. It asks the
 * whole machine to shut down as soon as it is launched, and should only be
 * staged into a disposable emulator clone whose ownership is already known.
 */

#include <AppleEvents.h>
#include <AERegistry.h>

static OSErr ask_finder_to_shut_down(void)
{
    const OSType finder = 'MACS';
    AEAddressDesc target = { typeNull, NULL };
    AppleEvent event = { typeNull, NULL };
    AppleEvent reply = { typeNull, NULL };
    OSErr err;

    err = AECreateDesc(typeApplSignature, &finder, sizeof finder, &target);
    if (err == noErr) {
        err = AECreateAppleEvent(kCoreEventClass, kAEShutDown, &target,
                                 kAutoGenerateReturnID, kAnyTransactionID,
                                 &event);
    }
    if (err == noErr) {
        err = AESend(&event, &reply, kAENoReply | kAECanInteract,
                     kAENormalPriority, kAEDefaultTimeout, NULL, NULL);
    }

    AEDisposeDesc(&reply);
    AEDisposeDesc(&event);
    AEDisposeDesc(&target);
    return err;
}

int main(void)
{
    OSErr err = ask_finder_to_shut_down();

    /*
     * AESend only establishes whether the Finder accepted the event; the
     * host independently waits for the machine to go down and verifies the
     * HFS unmounted bit. Returning quits this helper either way, so a failed
     * request leaves the guest up for diagnosis rather than power-cutting it.
     */
    return err == noErr ? 0 : 1;
}
