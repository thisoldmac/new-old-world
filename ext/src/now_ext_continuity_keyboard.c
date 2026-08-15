/* Continuity V8 keyboard delivery. The PPC app resolves and addresses the
   foreground target; this resident half performs the one operation CarbonLib
   cannot: PPostEvent from that target application's own A5 world.

   This is deliberately a jGNE-only plane. It allocates nothing, waits for
   nothing, drains at most four entries per pass, and never runs from a Time
   Manager task or Open Transport notifier. It produces Event Manager key
   events with modifiers; it does not alter GetKeys or physical ADB state. */
#include "now_ext_continuity_keyboard.h"

#include <Events.h>
#include <LowMem.h>
#include <Processes.h>

#include "now_continuity_keyboard_logic.h"
#include "now_ext_continuity_trace.h"

enum { kNowContinuityKeyDrainPerPass = 4 };

static NowPeekContinuityCell *keyboard_cell(NowPeekTable *table)
{
    if (table == NULL || table->magic != (NowPeekU32)kNowPeekTableMagic)
        return NULL;
    if (table->length < (NowPeekU32)(offsetof(NowPeekTable, continuity)
                                     + sizeof(NowPeekContinuityCell)))
        return NULL;
    if (table->continuity_format
            != (NowPeekU32)NOW_CONTINUITY_FORMAT_CURRENT)
        return NULL;
    if (!(table->caps & (NowPeekU32)kNowPeekTableCapContinuity))
        return NULL;
    return &table->continuity;
}

void now_ext_continuity_keyboard_flush(NowPeekContinuityCell *cell)
{
    now_continuity_keyboard_resident_flush(cell);
}

/* V13 KeyMap co-write. The Finder chooses move/copy/alias inside the
   Drag Manager loop from LIVE key state (GetKeys reads low-memory
   KeyMap), not from the press event's modifiers - so the forwarded host
   modifier word must be visible there too. This is a CO-WRITE, never
   ownership: only the four modifier bits are touched, only the bits WE
   set are ever cleared (a remembered previous word scopes the clear),
   the ADB driver rewrites the map on every real key transition and wins
   between passes, and an epoch end or takeover clears our bits through
   the same remembered word. Virtual keycodes 55-59 live in KeyMap bytes
   6 and 7. */
static volatile unsigned char *volatile gKeyMapLM =
    (volatile unsigned char *)0x0174UL;
static NowPeekU32 gStampedModifiers;

static void keymap_bits(NowPeekU32 word, unsigned char *b6,
                        unsigned char *b7)
{
    *b6 = (unsigned char)((word & 0x0100u) ? 0x80 : 0);  /* command, key 55 */
    *b7 = (unsigned char)(((word & 0x0200u) ? 0x01 : 0)   /* shift, 56 */
                          | ((word & 0x0800u) ? 0x04 : 0) /* option, 58 */
                          | ((word & 0x1000u) ? 0x08 : 0)); /* control, 59 */
}

static void keymap_costamp(NowPeekU32 word)
{
    unsigned char prev6, prev7, now6, now7;

    if (word == gStampedModifiers)
        return;
    keymap_bits(gStampedModifiers, &prev6, &prev7);
    keymap_bits(word, &now6, &now7);
    gKeyMapLM[6] = (unsigned char)((gKeyMapLM[6] & ~prev6) | now6);
    gKeyMapLM[7] = (unsigned char)((gKeyMapLM[7] & ~prev7) | now7);
    gStampedModifiers = word;
}

void now_ext_continuity_keyboard_gne(NowPeekTable *table)
{
    NowPeekContinuityCell *cell = keyboard_cell(table);
    NowPeekU32 current_a5;
    int drained;

    if (cell == NULL)
        return;
    if (!cell->enabled
            || (cell->state != (NowPeekU32)kNowPeekContinuityStateArmed
                && cell->state
                    != (NowPeekU32)kNowPeekContinuityStateActive)) {
        now_continuity_keyboard_resident_flush(cell);
        keymap_costamp(0);
        return;
    }
    keymap_costamp(cell->host_modifiers);
    current_a5 = (NowPeekU32)LMGetCurrentA5();
    for (drained = 0; drained < kNowContinuityKeyDrainPerPass; ++drained) {
        NowContinuityKeySnapshot event;
        ProcessSerialNumber front;
        EvQElPtr element = NULL;
        UInt32 message;
        short event_kind;
        int peek;
        OSErr err;

        peek = now_continuity_keyboard_peek(cell, current_a5, &event);
        if (peek == kNowContinuityKeyPeekNone)
            return;
        if (peek == kNowContinuityKeyPeekInvalid) {
            now_continuity_keyboard_commit(
                cell, &event, kNowPeekContinuityKeyErrorInvalid);
            now_ext_continuity_trace_keyboard_result(
                event.generation, event.action,
                (NowPeekU32)kNowPeekContinuityKeyErrorInvalid);
            continue;
        }
        if (GetFrontProcess(&front) != noErr
                || (NowPeekU32)front.highLongOfPSN
                    != event.target_psn_high
                || (NowPeekU32)front.lowLongOfPSN
                    != event.target_psn_low) {
            now_ext_continuity_keyboard_flush(cell);
            return;
        }
        if (event.action == (NowPeekU32)kNowPeekContinuityKeyDown)
            event_kind = keyDown;
        else if (event.action == (NowPeekU32)kNowPeekContinuityKeyUp)
            event_kind = keyUp;
        else
            event_kind = autoKey;
        message = ((UInt32)event.key_code << 8)
            | (UInt32)event.character;
        err = PPostEvent(event_kind, message, &element);
        if (err == noErr && element != NULL) {
            element->evtQModifiers = (short)event.modifiers;
            now_continuity_keyboard_commit(
                cell, &event, kNowPeekContinuityKeyErrorNone);
            now_ext_continuity_trace_keyboard_result(
                event.generation, event.action,
                (NowPeekU32)kNowPeekContinuityKeyErrorNone);
        } else if (err == evtNotEnb && event_kind == keyUp) {
            /* keyUp is masked out of the system event mask by default, so
               this refusal is the OS working as documented, not a lost
               key - the other two keyboard posters in this tree already
               ignore it (input_cmds.c, now_ext_act.c). Counting it as
               failure kept `failed` at ~50% of `queued` forever
               (79 of 174, all keyUps, 2026-08-13 210811) and buried any
               real failure under the noise. */
            now_continuity_keyboard_commit(
                cell, &event, kNowPeekContinuityKeyErrorNone);
            now_ext_continuity_trace_keyboard_result(
                event.generation, event.action,
                (NowPeekU32)kNowPeekContinuityKeyErrorNone);
        } else {
            now_continuity_keyboard_commit(
                cell, &event, kNowPeekContinuityKeyErrorPostFailed);
            now_ext_continuity_trace_keyboard_result(
                event.generation, event.action,
                (NowPeekU32)kNowPeekContinuityKeyErrorPostFailed);
        }
    }
}
