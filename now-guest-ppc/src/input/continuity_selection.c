#include "continuity_selection.h"

#include <string.h>

#include <Carbon.h>

#include "continuity_intake.h"
#include "nowlog.h"
#include "pump.h"

static NowContinuityStubTable g_table;
static unsigned long g_table_epoch;
static unsigned long g_next_poll;
static int g_poll_seeded;

const NowContinuityStubTable *now_continuity_selection_table(void)
{
    return &g_table;
}

void now_continuity_selection_forget(void)
{
    now_continuity_stub_reset(&g_table, 0);
    g_table_epoch = 0;
    g_poll_seeded = 0;
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
static OSErr ask_finder_for_selection(FSSpec *spec, Boolean *found)
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
           next attempt is along shortly either way. */
        err = AESend(&event, &reply, kAEWaitReply | kAENeverInteract,
                     kAENormalPriority, 120, now_pump_ae_idle(), NULL);
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

int now_continuity_selection_poll(unsigned long live_epoch)
{
    FSSpec spec;
    Boolean found = false;
    NowContinuityStubItem item;
    OSErr err;
    unsigned long now;

    if (live_epoch == 0) {
        /* NO EPOCH, NO POLL — and no table either. Forgetting here rather
           than at the disarm handler is what makes the gate true however
           the epoch ended, including the ways nobody calls a handler for
           (lease expiry, a resident reset, the host walking away). */
        if (g_table_epoch != 0) {
            now_continuity_selection_forget();
        }
        return 0;
    }
    if (live_epoch != g_table_epoch) {
        now_continuity_stub_reset(&g_table, live_epoch);
        g_table_epoch = live_epoch;
        g_poll_seeded = 0;
    }
    if (now_continuity_button_is_down()) {
        /* Mid-gesture. Do not touch the deadline: the next pass after the
           button comes up should poll immediately, because that is the
           moment the selection is most likely to have just changed. */
        return 0;
    }
    now = (unsigned long)TickCount();
    if (g_poll_seeded && now < g_next_poll) {
        return 0;
    }
    g_poll_seeded = 1;
    g_next_poll = now + kNowSelectionPollTicks;

    err = ask_finder_for_selection(&spec, &found);
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
        now_log(kLogInfo, "mirror",
                "selection epoch=%lu gen=%lu %.31s%s",
                live_epoch, g_table.generation, g_table.item.name,
                g_table.item.is_folder ? " (folder)" : "");
        return 1;
    }
    if (!now_continuity_stub_observe(&g_table, (const NowContinuityStubItem *)0)) {
        return 0;
    }
    now_log(kLogInfo, "mirror", "selection epoch=%lu gen=%lu cleared",
            live_epoch, g_table.generation);
    return 1;
}

int now_continuity_selection_grab(unsigned long live_epoch,
                                  unsigned long epoch,
                                  unsigned long generation,
                                  FSSpec *out)
{
    Str63 name;
    int verdict = now_continuity_grab_check(&g_table, live_epoch, epoch,
                                            generation);
    unsigned long len;

    if (verdict != kNowGrabOK) {
        return verdict;
    }
    len = strlen(g_table.item.name);
    name[0] = (unsigned char)len;
    BlockMoveData(g_table.item.name, name + 1, (long)len);
    /* Resolved from the identity triple every time rather than from a
       stored FSSpec, so an item moved or renamed since the stub was
       published fails HERE. The alternative — a spec that still points
       somewhere — would serve whatever now sits at that name under a
       consent given for something else. */
    if (FSMakeFSSpec(g_table.item.volume_ref, g_table.item.dir_id,
                     name, out) != noErr) {
        return kNowGrabStaleSelection;
    }
    return kNowGrabOK;
}
