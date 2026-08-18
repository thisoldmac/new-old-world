#include "continuity_selection.h"

#include <stdio.h>
#include <string.h>

#include <Carbon.h>

#include "continuity_dragmgr.h"
#include "continuity_intake.h"
#include "nowlog.h"
#include "pump.h"

static NowContinuityStubTable g_table;
/* The ending epoch's last grant, kept for one in-flight gesture. See
   now_continuity_selection.h for the rule and why the epoch is already
   over by the time the drag is released. */
static NowContinuityGrantHold g_hold;
/* The table the POST-EPOCH mint publishes from, and the record of the
   epoch it publishes under. Separate from g_table because the settle has
   already moved that one onto the live epoch (or onto none) by the time a
   crossing gesture's identity is drained — see
   now_continuity_stub_publish_post_epoch. */
static NowContinuityStubTable g_post;
static NowContinuityEndedEpoch g_ended;
static int g_post_pending;
/* Which table the last change published, so the wire asks one question and
   gets the epoch, generation and item of ONE frame. It is never NULL. */
static const NowContinuityStubTable *g_published = &g_table;
static unsigned long g_table_epoch;
static unsigned long g_next_poll;
static int g_poll_seeded;
/* A generation the drag plane minted since the wire last looked. It rides
   the poll's return value rather than a second service call: the wire owes
   the host ONE continuity.selection per generation whatever produced it,
   and a second sender would be a second place for the epoch gates to be
   wrong. */
static int g_drag_pending;

const NowContinuityStubTable *now_continuity_selection_table(void)
{
    return g_published;
}

int now_continuity_selection_published_after_epoch(void)
{
    return g_published == &g_post;
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
    /* READ BEFORE THE RESET, because after it this number exists nowhere.
       It is the floor the post-epoch mint counts on from, and a mint that
       reused a generation the host already cached would be the wrong file
       wearing a valid number. */
    unsigned long was_generation = g_table.generation;
    unsigned long now_ticks = (unsigned long)TickCount();

    if (!now_continuity_selection_settle(&g_table, &g_hold, &g_table_epoch,
                                         live_epoch, now_ticks)) {
        return;
    }
    /* WHICH EPOCH A LATE DRAIN BELONGS TO. The identity of a crossing
       gesture is drained after this point, so without the record there is
       nothing left to say which consent that gesture was made under. A new
       epoch clears it: a drag drained under a running epoch is that
       epoch's, and publishing it under a dead one would be a consent
       resurrected. */
    if (live_epoch != 0) {
        now_continuity_epoch_ended_release(&g_ended);
    } else {
        now_continuity_epoch_ended(&g_ended, was, was_generation, now_ticks);
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
    /* Including the mint made for a gesture whose epoch had ended: it is a
       grant like any other, and its host is gone. */
    now_continuity_stub_reset(&g_post, 0);
    now_continuity_epoch_ended_release(&g_ended);
    g_post_pending = 0;
    g_published = &g_table;
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




/* Turn one V15 identity into the same NowContinuityStubItem a poll would
   have made. It goes through stub_from_spec deliberately: the drag gives
   volume, directory and name, and the sizes, date and folderness the host
   needs come from the File Manager exactly as they do for a selection. A
   drag-sourced stub is then the SAME SHAPE as a polled one, which is what
   lets the grab, the grant hold and the wire stay single-implementation. */
static OSErr stub_from_drag(const NowContinuityDragIdentity *ident,
                            NowContinuityStubItem *out)
{
    FSSpec spec;

    memset(&spec, 0, sizeof spec);
    spec.vRefNum = ident->vref;
    spec.parID = ident->parid;
    BlockMoveData(ident->name, spec.name, (long)ident->name[0] + 1);
    return stub_from_spec(&spec, out);
}

int now_continuity_selection_note_drag(const NowContinuityDragIdentity *ident)
{
    unsigned long live_epoch = now_continuity_live_epoch();
    NowContinuityStubItem item;

    if (ident == NULL || ident->seq == 0 || !ident->is_hfs) {
        return 0;
    }
    /* The settle runs FIRST and unconditionally, as it always did — but it
       is no longer allowed to be the end of the story. It records which
       epoch just ended (see settle_to_epoch), and the crossing case below
       reads that record, so the reset it performs cannot take the gesture's
       consent with it. */
    settle_to_epoch(live_epoch);
    if (stub_from_drag(ident, &item) != noErr) {
        /* The Drag Manager named something the File Manager will not
           describe. Refusing beats publishing a stub whose grab could only
           fail later, further from the cause. */
        now_log(kLogWarn, "mirror",
                "drag identity unusable seq=%lu vref=%d par=%ld",
                ident->seq, (int)ident->vref, ident->parid);
        return 0;
    }
    if (item.is_folder) {
        /* Folders cross in a later slice, on both sources. Named rather
           than published so the refusal happens here, once, instead of at
           the host's bind and again at the guest's grab. */
        return 0;
    }
    if (live_epoch == 0) {
        /* THE CROSSING GESTURE, and it is the ordinary one rather than the
           corner: crossing back is what ends the epoch, and the crossing's
           own release is what ends the Finder's drag loop and lets this
           drain run at all. There is no live epoch to publish under and
           nothing left in the table to hold, so the mint is made under the
           epoch the gesture BEGAN in — bounded by the grant's own window,
           grantable at once, and announced on the wire as what it is.

           A drag drained while nothing is armed still publishes nothing:
           g_ended is empty then, and the mint refuses. */
        if (!now_continuity_stub_publish_post_epoch(
                &g_post, &g_hold, &g_ended, &item, ident->seq,
                (unsigned long)TickCount())) {
            if (g_ended.epoch != 0) {
                now_log(kLogWarn, "mirror",
                        "drag not published seq=%lu: the window on epoch "
                        "%lu has closed", ident->seq, g_ended.epoch);
            }
            return 0;
        }
        g_post_pending = 1;
        now_log(kLogInfo, "mirror",
                "selection after epoch=%lu gen=%lu seq=%lu %.31s (drag)",
                g_post.epoch, g_post.generation, ident->seq,
                g_post.item.name);
        return 1;
    }
    if (!now_continuity_stub_observe_drag(&g_table, &item, ident->seq)) {
        return 0;
    }
    release_grant_for_new_epoch(live_epoch);
    g_drag_pending = 1;
    now_log(kLogInfo, "mirror",
            "selection epoch=%lu gen=%lu %.31s (drag)",
            live_epoch, g_table.generation, g_table.item.name);
    return 1;
}

int now_continuity_selection_poll(unsigned long live_epoch)
{
    FSSpec spec;
    Boolean found = false;
    NowContinuityStubItem item;
    OSErr err;
    unsigned long now;

    /* Settling here rather than at the disarm handler is what makes the
       gate true however the epoch ended, including the ways nobody calls a
       handler for (lease expiry, a resident reset, the host walking away).
       It is no longer the ONLY place that settles — the grab resolves
       through the same function — but it is still the backstop for the
       endings no frame announces. */
    settle_to_epoch(live_epoch);
    /* THE POST-EPOCH MINT GOES OUT BEFORE THE EPOCH GATE, because by
       construction there is no live epoch when it exists: the gesture that
       minted it is the gesture that ended the epoch. Gating it would be
       this function refusing to say the one thing only it can say. */
    if (g_post_pending) {
        g_post_pending = 0;
        if (g_post.have_item) {
            g_published = &g_post;
            return 1;
        }
    }
    g_published = &g_table;
    if (live_epoch == 0) {
        return 0;                  /* no epoch, no poll */
    }
    /* THE DRAG PLANE'S GENERATION GOES OUT FIRST, and before the button
       gate rather than after it - a drag-sourced generation exists exactly
       when the button IS down, so a gate written for the poll would
       swallow the one thing it cannot produce. Checked after the settle so
       an epoch that turned over in between cannot publish a table that has
       already been reset out from under it. */
    if (g_drag_pending) {
        g_drag_pending = 0;
        if (g_table.have_item
                && g_table.item.source == kNowStubSourceDrag) {
            return 1;
        }
    }
    /* NOT WHILE THIS MACHINE IS THE DRAG SOURCE, and this is the one
       gate whose absence cost a 600 KB file.
     *
       The poll asks the Finder a question and waits for the reply. A
       NOW-originated promise drag reaches its send proc INSIDE the
       Finder's own drop handling — the Finder is sitting in
       GetFlavorData waiting for us — and the send proc pumps the wire by
       hand so the promised bytes can arrive. Every one of those pumped
       passes ran a full conn_service, and conn_service reaches this
       poll. So we asked a process that could not answer, waited the
       whole 120-tick timeout, and did it again on the next pass, with
       the AE's own idle hook bounced (it is a nested now_wire_pump).
       Two-second blackouts, back to back, on the reader of a stream
       whose sender does not wait: the collapse in
       docs/large-transfers.md, entered on purpose.
     *
       The button gate below does not cover it. That gate reads the
       PLANE's button, and the drop happens after the host has released
       — the release is what produced the drop.
     *
       Refusing here also costs nothing that was ever worth having: the
       poll's own header says a selection read is worthless while the
       Finder holds a Drag Manager loop, and the drag plane's own
       generation (g_drag_pending, above) is the fact this gesture
       actually produces. */
    if (now_continuity_drag_in_flight()) {
        return 0;
    }
    if (now_continuity_button_is_down()) {
        /* Mid-gesture. Do not touch the deadline: the next pass after the
           button comes up should poll immediately, because that is the
           moment the selection is most likely to have just changed.

           AND THERE IS NO EXCEPTION TO PUT HERE, which cost an emulator
           round to learn. A press that selects the file it drags cannot
           publish its own selection — see the header — and the obvious
           remedy, one probe per press, was written, armed at the down edge
           and measured: not one probe ran in 21 seconds of held drag,
           because THIS APPLICATION GETS NO TASK TIME AT ALL while the
           Finder holds its Drag Manager loop. Nothing of ours runs, so
           there is no gate to make an exception in. The whole gesture's
           worth of log lines lands in the second the button comes up. */
        return 0;
    }
    now = (unsigned long)TickCount();
    if (g_poll_seeded && now < g_next_poll) {
        return 0;
    }
    g_poll_seeded = 1;
    g_next_poll = now + kNowSelectionPollTicks;

    err = ask_finder_for_selection(&spec, &found,
                                   (long)kNowSelectionPollTimeoutTicks);
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
            "grab refused: the Mac's selection is not what this grab "
            "names - serving=%.31s selected=%.31s err=%d",
            serve->name,
            (read_ok && found) ? observed.name : "<unreadable>",
            (int)err);
    return verdict;
}

/* THE SAME LAST CHECK, ASKING THE DRAG INSTEAD.

   A drag-sourced generation names the file the Drag Manager handed us,
   which for a never-selected file is deliberately NOT what the Finder has
   selected. Confirming it against the selection would refuse the one
   gesture this whole route exists to serve, so the witness changes with
   the source and the contract says so once, under `source`.

   The check is stricter than the selection's rather than looser: it is
   not enough that the drag plane still names this file, it must still be
   the SAME DRAG - `seq` moves for every gesture. A second pick-up of the
   same icon has a generation of its own, and serving it under the first
   one's name would be the stale-generation hole reopened one layer down.

   IT DOES NOT ASK THE FINDER AT ALL, which is the point: the Finder is a
   process that may be busy, and the resident's record is a shared cell
   this side reads in three lines. The consent was the drag; the drag is
   what is consulted. */
static int confirm_serve_against_drag(const NowContinuityStubItem *serve)
{
    NowContinuityDragIdentity ident;
    NowContinuityStubItem observed;
    int read_ok;
    int verdict;

    read_ok = now_continuity_drag_identity(&ident) && ident.is_hfs;
    if (read_ok && stub_from_drag(&ident, &observed) != noErr) {
        /* The plane named something this side cannot describe. Not a
           confirmation; treating it as one would be the guard reading its
           own failure as a pass. */
        read_ok = 0;
    }
    verdict = now_continuity_grab_confirm_drag(
        serve, read_ok,
        read_ok ? &observed : (const NowContinuityStubItem *)0,
        read_ok ? ident.seq : 0UL);
    if (verdict == kNowGrabOK) {
        return verdict;
    }
    now_log(kLogWarn, "mirror",
            "grab refused: the drag is not what this grab names - "
            "serving=%.31s seq=%lu dragging=%.31s seq=%lu",
            serve->name, serve->drag_seq,
            read_ok ? observed.name : "<unreadable>",
            read_ok ? ident.seq : 0UL);
    return verdict;
}

/* Which witness this stub is owed. One line, one place, so a third source
   cannot be added without landing here. */
static int confirm_serve(const NowContinuityStubItem *serve)
{
    if (serve != NULL && serve->source == kNowStubSourceDrag) {
        return confirm_serve_against_drag(serve);
    }
    return confirm_serve_against_finder(serve);
}

void now_continuity_selection_describe(char *out, unsigned long size)
{
    if (out == NULL || size == 0) {
        return;
    }
    snprintf(out, (size_t)size,
             "table=%lu/%lu src=%d seq=%lu %.31s hold=%lu/%lu seq=%lu %.31s",
             g_table_epoch, g_table.generation,
             g_table.have_item ? (int)g_table.item.source : -1,
             g_table.have_item ? g_table.item.drag_seq : 0UL,
             g_table.have_item ? g_table.item.name : "<none>",
             g_hold.epoch, g_hold.generation,
             g_hold.epoch != 0 ? g_hold.item.drag_seq : 0UL,
             g_hold.epoch != 0 ? g_hold.item.name : "<none>");
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
        /* THE STATE, NAMED AT THE REFUSAL. Three attended rounds were
           diagnosed from the host's side of this refusal alone; this line
           is the guest's half — what the table and the hold actually held
           when the ask arrived. */
        now_log(kLogWarn, "mirror",
                "grab state at refusal: asked=%lu/%lu live=%lu "
                "table=%lu/%lu src=%d seq=%lu %.31s "
                "hold=%lu/%lu seq=%lu %.31s",
                epoch, generation, live_epoch,
                g_table_epoch, g_table.generation,
                g_table.have_item ? (int)g_table.item.source : -1,
                g_table.have_item ? g_table.item.drag_seq : 0UL,
                g_table.have_item ? g_table.item.name : "<none>",
                g_hold.epoch, g_hold.generation,
                g_hold.epoch != 0 ? g_hold.item.drag_seq : 0UL,
                g_hold.epoch != 0 ? g_hold.item.name : "<none>");
        return verdict;
    }
    /* THE LAST CHECK, AND THE ONLY ONE THAT ASKS THE MACHINE. Everything
       above proves consent was given for this generation; none of it can
       notice the generation stopped describing what the person is holding.
       Before the checks below turn a stub into a real FSSpec, ask.

       NOT FOR A GRAB SERVED FROM THE HOLD. After the epoch there is no
       live witness to ask: the crossing released the press, the Finder's
       drag loop returned, and the resident's drag record died with it —
       consulting it here refused every crossing gesture by construction
       (attended, 2026-08-17). The hold IS the witness for this window:
       captured while the consent was live, bound to its drag_seq, and the
       FSMakeFSSpec below still re-resolves the identity so a file moved
       or renamed since refuses here exactly as it always did. */
    if (!after_epoch) {
        verdict = confirm_serve(serve);
        if (verdict != kNowGrabOK) {
            return verdict;
        }
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
