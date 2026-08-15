#include "continuity_selection.h"

#include <string.h>

#include <Carbon.h>

#include "continuity_intake.h"
#include "nowlog.h"
#include "pump.h"

static NowContinuityStubTable g_table;
/* The ending epoch's last grant, kept for one in-flight gesture. See
   now_continuity_selection.h for the rule and why the epoch is already
   over by the time the drag is released. */
static NowContinuityGrantHold g_hold;
static unsigned long g_table_epoch;
static unsigned long g_next_poll;
static int g_poll_seeded;

/* --- the one poll allowed inside a gesture --------------------------------

   The button gate below is right about the ordinary case and wrong about
   exactly one: the press that SELECTS the thing it then drags. That click
   is the same button-down that closes the gate, so its own selection can
   never be published, and the host binds whatever the previous gesture
   left cached — which on 2026-08-15 at 17:19 transferred `hello.txt` while
   a person watched `main.c` leave.

   So one probe is allowed per press, and the three fields below are what
   keep "one" honest across a gesture that can last a minute.

   ARMED AT THE DOWN, DUE AT THE FIRST DRAG. Not due at the down: a plain
   click is not a drag, and making every click across the edge pay a
   bounded Apple Event wait would be a feel regression charged to the whole
   feature for a case that only arises when the pointer moves. The first
   position applied under a held button is the earliest instant this can be
   distinguished, and it is still seconds before any cross.

   Whether the Finder answers at all from inside its drag loop is not
   assumed here — the probe logs its own outcome, which is how that
   question gets an answer rather than an argument. It is the improvement;
   the guarantee is confirm_serve_against_finder. */
#define kNowSelectionPressProbeTimeout 20L   /* ticks; ~1/3 second */
#define kNowSelectionPressProbeDelay 2UL     /* ticks after the drag begins */
static int g_press_probe_armed;
static int g_press_probe_due;
static unsigned long g_press_probe_at;

const NowContinuityStubTable *now_continuity_selection_table(void)
{
    return &g_table;
}

/* The table alone. The epoch ending is not the grant ending, so the two
   are separate acts and every caller says which one it means. */
static void forget_table(void)
{
    now_continuity_stub_reset(&g_table, 0);
    g_table_epoch = 0;
    g_poll_seeded = 0;
}

/* Move the table onto `live_epoch`, handing the dying epoch's final
   generation to the hold on the way. A crossing gesture is still
   physically held at this instant; without this the grab it is about to
   make is refused for an epoch the crossing itself ended.

   THE POLL IS NO LONGER THE ONLY CALLER. now_continuity_grab_resolve
   settles too, because a grab arrives on the same wire as the disarm and
   is dispatched before the poll runs; see now_continuity_selection.h. The
   log below therefore also fires from the grab path, which is where the
   evidence is worth having. */
static void settle_to_epoch(unsigned long live_epoch)
{
    unsigned long was = g_table_epoch;

    if (!now_continuity_selection_settle(&g_table, &g_hold, &g_table_epoch,
                                         live_epoch,
                                         (unsigned long)TickCount())) {
        return;
    }
    /* A fresh table has nothing polled into it yet, so the next pass must
       ask the Finder rather than wait out a cadence set under the old
       epoch. */
    g_poll_seeded = 0;
    if (was != 0 && g_hold.epoch != 0) {
        now_log(kLogInfo, "mirror",
                "grant held past epoch=%lu gen=%lu for %lu ticks %.31s",
                g_hold.epoch, g_hold.generation,
                (unsigned long)kNowContinuityGrantTicks, g_hold.item.name);
    }
}

void now_continuity_selection_forget(void)
{
    forget_table();
    /* The link, not the epoch. A grant is consent given to ONE host over
       ONE connection, so nothing survives a disconnect. */
    now_continuity_grant_release(&g_hold);
}

/* --- the Apple Event ------------------------------------------------------

   "tell application Finder to get selection as alias list", spelled out.
   The requested type is what makes it an alias list rather than a list of
   object specifiers: a specifier is a sentence about an item and would
   have to be resolved by asking the Finder AGAIN, which is one more round
   trip through the process this poll is trying not to disturb. */

static OSErr build_selection_specifier(AEDesc *out)
{
    AERecord rec = { typeNull, NULL };
    AEDesc container = { typeNull, NULL };
    DescType want_class = cProperty;
    DescType key_form = formPropertyID;
    DescType which = pSelection;
    OSErr err;

    out->descriptorType = typeNull;
    out->dataHandle = NULL;

    err = AECreateList(NULL, 0, true, &rec);
    if (err == noErr) {
        err = AEPutKeyPtr(&rec, keyAEDesiredClass, typeType,
                          &want_class, sizeof want_class);
    }
    if (err == noErr) {
        err = AEPutKeyPtr(&rec, keyAEKeyForm, typeEnumerated,
                          &key_form, sizeof key_form);
    }
    if (err == noErr) {
        err = AEPutKeyPtr(&rec, keyAEKeyData, typeType,
                          &which, sizeof which);
    }
    if (err == noErr) {
        /* A null container is the application itself — the Finder's own
           `selection`, not some window's. */
        err = AEPutKeyDesc(&rec, keyAEContainer, &container);
    }
    if (err == noErr) {
        err = AECoerceDesc(&rec, typeObjectSpecifier, out);
    }
    AEDisposeDesc(&rec);
    AEDisposeDesc(&container);
    return err;
}

/* Fill `spec` from the first item of the Finder's answer.

   FIRST ITEM ONLY, and that is the contract's word rather than this
   function running out of room: a multiple selection needs a promise
   group and a host-side answer to "some of these arrived", which is a
   later slice. Returns noErr with `found` false for an empty selection —
   which is an ANSWER, not a failure, and the difference matters because
   only one of the two should clear the host's cache. */
static OSErr ask_finder_for_selection(FSSpec *spec, Boolean *found,
                                      long timeout_ticks)
{
    AEAddressDesc target = { typeNull, NULL };
    AppleEvent event = { typeNull, NULL };
    AppleEvent reply = { typeNull, NULL };
    AEDesc specifier = { typeNull, NULL };
    AEDescList list = { typeNull, NULL };
    OSType finder = 'MACS';
    DescType want = typeAlias;
    OSErr err;

    *found = false;
    err = AECreateDesc(typeApplSignature, &finder, sizeof finder, &target);
    if (err == noErr) {
        err = AECreateAppleEvent(kAECoreSuite, kAEGetData, &target,
                                 kAutoGenerateReturnID, kAnyTransactionID,
                                 &event);
    }
    if (err == noErr) {
        err = build_selection_specifier(&specifier);
    }
    if (err == noErr) {
        err = AEPutParamDesc(&event, keyDirectObject, &specifier);
    }
    if (err == noErr) {
        err = AEPutParamPtr(&event, keyAERequestedType, typeType,
                            &want, sizeof want);
    }
    if (err == noErr) {
        /* kAENeverInteract: this runs behind a person's back by design,
           and a Finder that decided to put up a dialog on our behalf
           would be a modal nested inside whatever the guest is doing —
           the one thing pump.h says wire code must never cause.

           The idle proc is the shared one, so the wire keeps being
           served for the whole bounded wait (pump.h). Two seconds is
           generous for a live Finder and short enough that a wedged one
           costs a poll rather than the connection; the cadence means the
           next attempt is along shortly either way.

           THE TIMEOUT IS THE CALLER'S because the callers are not asking
           the same question under the same conditions. The ordinary poll
           runs with the Finder idle and can afford to wait. The press
           probe runs with the Finder inside its own Drag Manager loop,
           where the honest expectation is no answer at all — so it pays a
           fraction of a second for the chance of one and gives up. */
        err = AESend(&event, &reply, kAEWaitReply | kAENeverInteract,
                     kAENormalPriority, timeout_ticks, now_pump_ae_idle(),
                     NULL);
    }
    if (err == noErr) {
        OSErr list_err = AEGetParamDesc(&reply, keyDirectObject,
                                        typeAEList, &list);
        if (list_err == noErr) {
            long count = 0;
            if (AECountItems(&list, &count) == noErr && count > 0) {
                AEKeyword keyword;
                DescType kind;
                Size actual;

                /* typeFSS first: the Apple Event Manager coerces an alias
                   to one itself, and an FSSpec is what the File Manager
                   wants next. The alias fallback is for the reply that
                   arrives as something else — a specifier the Finder
                   declined to coerce — where resolving it ourselves is
                   the only route left. */
                if (AEGetNthPtr(&list, 1, typeFSS, &keyword, &kind,
                                spec, sizeof *spec, &actual) == noErr) {
                    *found = true;
                } else {
                    AEDesc item = { typeNull, NULL };
                    if (AEGetNthDesc(&list, 1, typeAlias, &keyword,
                                     &item) == noErr) {
                        Boolean changed = false;
                        AliasHandle alias = (AliasHandle)item.dataHandle;
                        if (alias != NULL
                            && ResolveAlias(NULL, alias, spec,
                                            &changed) == noErr) {
                            *found = true;
                        }
                    }
                    AEDisposeDesc(&item);
                }
            }
        } else if (list_err != errAEDescNotFound) {
            /* A reply that is not a list and not an absent parameter is
               the Finder saying something we do not understand; report
               it rather than reading it as "nothing selected". */
            err = list_err;
        }
    }
    AEDisposeDesc(&list);
    AEDisposeDesc(&reply);
    AEDisposeDesc(&specifier);
    AEDisposeDesc(&event);
    AEDisposeDesc(&target);
    return err;
}

/* --- the stub ------------------------------------------------------------ */

static OSErr stub_from_spec(const FSSpec *spec, NowContinuityStubItem *out)
{
    CInfoPBRec pb;
    Str63 name;
    unsigned char len;

    memset(out, 0, sizeof *out);
    len = spec->name[0];
    /* HFS cannot hold a longer one, so this is a corrupt reply rather
       than a truncation to make good. A stub the guest cannot name is a
       stub whose grab could not be resolved anyway. */
    if (len == 0 || (long)len >= (long)sizeof out->name) {
        return paramErr;
    }
    BlockMoveData(spec->name, name, (long)len + 1);

    memset(&pb, 0, sizeof pb);
    pb.hFileInfo.ioNamePtr = name;
    pb.hFileInfo.ioVRefNum = spec->vRefNum;
    pb.hFileInfo.ioDirID = spec->parID;
    pb.hFileInfo.ioFDirIndex = 0;
    if (PBGetCatInfoSync(&pb) != noErr) {
        return fnfErr;
    }

    memcpy(out->name, spec->name + 1, len);
    out->name[len] = '\0';
    out->volume_ref = spec->vRefNum;
    out->dir_id = spec->parID;
    out->is_folder = (pb.hFileInfo.ioFlAttrib & ioDirMask) != 0;
    if (out->is_folder) {
        out->modified = (unsigned long)pb.dirInfo.ioDrMdDat;
    } else {
        out->modified = (unsigned long)pb.hFileInfo.ioFlMdDat;
        out->data_size = pb.hFileInfo.ioFlLgLen;
        out->rsrc_size = pb.hFileInfo.ioFlRLgLen;
        out->file_type = (unsigned long)pb.hFileInfo.ioFlFndrInfo.fdType;
        out->creator = (unsigned long)pb.hFileInfo.ioFlFndrInfo.fdCreator;
    }
    return noErr;
}

/* The other end of the grant's life: a NEW epoch has published a
   selection of its own, so the previous gesture is over however it ended
   and the held grant is no longer anybody's in-flight drag. The clock is
   the backstop, this is the ordinary case. */
static void release_grant_for_new_epoch(unsigned long live_epoch)
{
    if (g_hold.epoch == 0 || g_hold.epoch == live_epoch) {
        return;
    }
    now_log(kLogInfo, "mirror",
            "grant released epoch=%lu gen=%lu: epoch %lu published its own "
            "selection", g_hold.epoch, g_hold.generation, live_epoch);
    now_continuity_grant_release(&g_hold);
}

void now_continuity_selection_note_press(void)
{
    g_press_probe_armed = 1;
    g_press_probe_due = 0;
}

void now_continuity_selection_note_press_drag(void)
{
    if (!g_press_probe_armed || g_press_probe_due) {
        return;
    }
    g_press_probe_due = 1;
    g_press_probe_at = (unsigned long)TickCount()
        + kNowSelectionPressProbeDelay;
}

void now_continuity_selection_note_release(void)
{
    g_press_probe_armed = 0;
    g_press_probe_due = 0;
}

/* Consumed whatever it returns. A probe that fired and learned nothing has
   still spent its one turn: the alternative is an Apple Event per service
   pass for the length of a drag, which is the starvation the button gate
   exists to prevent, arriving one door further in. */
static int press_probe_take(void)
{
    if (!g_press_probe_armed || !g_press_probe_due) {
        return 0;
    }
    if ((long)((unsigned long)TickCount() - g_press_probe_at) < 0) {
        return 0;
    }
    g_press_probe_armed = 0;
    g_press_probe_due = 0;
    return 1;
}

int now_continuity_selection_poll(unsigned long live_epoch)
{
    FSSpec spec;
    Boolean found = false;
    NowContinuityStubItem item;
    OSErr err;
    unsigned long now;
    long timeout = (long)kNowSelectionPollTimeoutTicks;
    int probe = 0;

    /* Settling here rather than at the disarm handler is what makes the
       gate true however the epoch ended, including the ways nobody calls a
       handler for (lease expiry, a resident reset, the host walking away).
       It is no longer the ONLY place that settles — the grab resolves
       through the same function — but it is still the backstop for the
       endings no frame announces. */
    settle_to_epoch(live_epoch);
    if (live_epoch == 0) {
        return 0;                  /* no epoch, no poll */
    }
    if (now_continuity_button_is_down()) {
        /* Mid-gesture. Do not touch the deadline: the next pass after the
           button comes up should poll immediately, because that is the
           moment the selection is most likely to have just changed.

           The one exception is the press probe, and it is an exception to
           the CADENCE too — the whole point is to ask once, now, about a
           selection this gesture created and nothing else will publish. */
        if (!press_probe_take()) {
            return 0;
        }
        probe = 1;
        timeout = kNowSelectionPressProbeTimeout;
    }
    if (!probe) {
        now = (unsigned long)TickCount();
        if (g_poll_seeded && now < g_next_poll) {
            return 0;
        }
        g_poll_seeded = 1;
        g_next_poll = now + kNowSelectionPollTicks;
    }

    err = ask_finder_for_selection(&spec, &found, timeout);
    if (probe) {
        /* Logged whatever happened, including the boring answer. Whether a
           Finder inside its own drag loop answers an Apple Event at all is
           the ordering fact this whole defect turns on, and it is not
           something either half can be reasoned into: an `err=-1712`
           (errAETimeout) line here says the probe cannot fix the
           single-gesture bind and the grab confirmation is carrying it
           alone, which is a different piece of news from silence. */
        now_log(kLogInfo, "mirror",
                "selection press probe epoch=%lu err=%d found=%d",
                live_epoch, (int)err, found ? 1 : 0);
    }
    if (err != noErr) {
        /* NOT SILENT, and not reported to the host either. A Finder that
           did not answer says nothing about what is selected, so the
           cached stub stands; the line is here because the alternative is
           a plane that stops working with no trace of when it stopped. */
        now_log(kLogWarn, "mirror",
                "selection poll failed epoch=%lu err=%d", live_epoch,
                (int)err);
        return 0;
    }
    if (found && stub_from_spec(&spec, &item) == noErr) {
        if (!now_continuity_stub_observe(&g_table, &item)) {
            return 0;
        }
        release_grant_for_new_epoch(live_epoch);
        now_log(kLogInfo, "mirror",
                "selection epoch=%lu gen=%lu %.31s%s",
                live_epoch, g_table.generation, g_table.item.name,
                g_table.item.is_folder ? " (folder)" : "");
        return 1;
    }
    if (!now_continuity_stub_observe(&g_table, (const NowContinuityStubItem *)0)) {
        return 0;
    }
    release_grant_for_new_epoch(live_epoch);
    now_log(kLogInfo, "mirror", "selection epoch=%lu gen=%lu cleared",
            live_epoch, g_table.generation);
    return 1;
}

/* Ask the Finder what is selected RIGHT NOW and hold the serve up against
   it. See now_continuity_selection.h for why this exists at all; what
   belongs here is why it can be asked at this moment when the poll cannot.

   By the time a grab arrives the guest press has been released — the host
   settles the pointer to the press origin and releases it before it hands
   anything to its own drag session (docs/open-issues.md, the unbound
   cross-release entry) — so the Finder is out of the Drag Manager's nested
   loop and back in its event loop, which is precisely the condition the
   poll's button gate is protecting against. The ordinary timeout is right
   here for the same reason: nothing is being dragged while we wait, and
   the person is watching a transfer they asked for. */
static int confirm_serve_against_finder(const NowContinuityStubItem *serve)
{
    FSSpec spec;
    Boolean found = false;
    NowContinuityStubItem observed;
    OSErr err;
    int read_ok;
    int verdict;

    err = ask_finder_for_selection(&spec, &found,
                                   (long)kNowSelectionPollTimeoutTicks);
    read_ok = (err == noErr);
    if (read_ok && found && stub_from_spec(&spec, &observed) != noErr) {
        /* The Finder named something this side cannot describe. That is not
           a confirmation, and treating it as one would be the guard reading
           its own failure as a pass. */
        found = false;
    }
    verdict = now_continuity_grab_confirm(
        serve, read_ok,
        (read_ok && found) ? &observed : (const NowContinuityStubItem *)0);
    if (verdict == kNowGrabOK) {
        return verdict;
    }
    now_log(kLogWarn, "mirror",
            "grab refused: the Mac's selection is not what this grab names "
            "— serving=%.31s selected=%.31s err=%d",
            serve->name,
            (read_ok && found) ? observed.name : "<unreadable>",
            (int)err);
    return verdict;
}

int now_continuity_selection_grab(unsigned long live_epoch,
                                  unsigned long epoch,
                                  unsigned long generation,
                                  FSSpec *out)
{
    Str63 name;
    const NowContinuityStubItem *serve = (const NowContinuityStubItem *)0;
    int after_epoch = 0;
    int verdict;
    unsigned long len;

    /* The settle the resolve does is not silent: it can be the moment the
       grant is taken, and this is the only path that reaches it before the
       poll does. Take the transition through the glue so the log fires, then
       decide against a table that has already moved. */
    settle_to_epoch(live_epoch);
    verdict = now_continuity_grab_resolve(&g_table, &g_hold, &g_table_epoch,
                                          live_epoch, epoch, generation,
                                          (unsigned long)TickCount(),
                                          &serve, &after_epoch);

    if (verdict == kNowGrabGrantExpired) {
        now_log(kLogWarn, "mirror",
                "grant expired epoch=%lu gen=%lu: the gesture outlived its "
                "%lu-tick window", epoch, generation,
                (unsigned long)kNowContinuityGrantTicks);
        return verdict;
    }
    if (verdict != kNowGrabOK) {
        return verdict;
    }
    /* THE LAST CHECK, AND THE ONLY ONE THAT ASKS THE MACHINE. Everything
       above proves consent was given for this generation; none of it can
       notice the generation stopped describing what the person is holding.
       Before the checks below turn a stub into a real FSSpec, ask. */
    verdict = confirm_serve_against_finder(serve);
    if (verdict != kNowGrabOK) {
        return verdict;
    }
    if (after_epoch) {
        /* Named, because this is the one place a grab is served under an
           epoch that has already ended, and a log that cannot show the
           difference cannot show the rule working either. */
        now_log(kLogInfo, "mirror",
                "grant honored after epoch=%lu gen=%lu live=%lu %.31s",
                epoch, generation, live_epoch, serve->name);
    }
    len = strlen(serve->name);
    name[0] = (unsigned char)len;
    BlockMoveData(serve->name, name + 1, (long)len);
    /* Resolved from the identity triple every time rather than from a
       stored FSSpec, so an item moved or renamed since the stub was
       published fails HERE. The alternative — a spec that still points
       somewhere — would serve whatever now sits at that name under a
       consent given for something else. */
    if (FSMakeFSSpec(serve->volume_ref, serve->dir_id, name, out) != noErr) {
        return kNowGrabStaleSelection;
    }
    return kNowGrabOK;
}
