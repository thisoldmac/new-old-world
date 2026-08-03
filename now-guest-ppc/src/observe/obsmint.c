/* Minting a reference for an address a walk is holding. See obsmint.h. */

#include "obsmint.h"

#include <string.h>

#include "axresolve.h"

void now_obs_walk_begin(NowObsWalk *walk, NowObsRegistry *registry)
{
    if (walk == NULL) {
        return;
    }
    memset(walk, 0, sizeof(*walk));
    walk->registry = registry;
    (void)now_obs_epoch_begin(registry);
}

void now_obs_walk_aim(NowObsWalk *walk, const NowAxMemory *memory,
                      unsigned long window_list, unsigned long psn_hi,
                      unsigned long psn_lo,
                      unsigned long process_fingerprint, unsigned long ticks)
{
    if (walk == NULL) {
        return;
    }
    walk->memory = memory;
    walk->window_list = window_list;
    walk->psn_hi = psn_hi;
    walk->psn_lo = psn_lo;
    walk->process_fingerprint = process_fingerprint;
    walk->ticks = ticks;
}

void now_obs_walk_end(NowObsWalk *walk)
{
    if (walk == NULL) {
        return;
    }
    now_obs_epoch_end(walk->registry);
    walk->registry = NULL;
    walk->memory = NULL;
}

static int seen(const unsigned long *addresses, unsigned int count,
                unsigned long address)
{
    unsigned int i;

    for (i = 0; i < count; i++) {
        if (addresses[i] == address) {
            return 1;
        }
    }
    return 0;
}

/* Where `target` sits on this process's window chain, by the resolver's
   own arithmetic: its occurrence among windows wearing the same title,
   counted over EVERY window in chain order.
   [`now_obs_resolve_window` / `now_ax_resolve_ref` count it exactly this
   way, and a producer that counted differently would mint a reference
   that resolves to a neighbour or to nothing.]

   Returns 1 with the window read and its occurrence set. Returns 0 when
   the target is not on the chain, when the chain fails validation or
   repeats an address, or when the target sits past
   kNowAxResolveMaxWindows - because a resolution stops there and answers
   NotFound, so a reference minted past it could never be redeemed. */
static int locate_window(const NowObsWalk *walk, unsigned long target,
                         NowAxWindow *out, unsigned int *occurrence)
{
    unsigned long addresses[kNowAxResolveMaxWindows];
    unsigned long address = walk->window_list;
    unsigned int  count = 0;
    unsigned int  matching = 0;
    NowAxWindow   wanted;

    if (target == 0
        || now_ax_read_window(walk->memory, target, &wanted) != kNowAxOk) {
        return 0;
    }
    while (address != 0) {
        NowAxWindow window;

        if (count >= (unsigned int)kNowAxResolveMaxWindows) {
            return 0;
        }
        if (seen(addresses, count, address)) {
            return 0;
        }
        addresses[count] = address;
        if (now_ax_read_window(walk->memory, address, &window) != kNowAxOk) {
            return 0;
        }
        if (address == target) {
            *out = window;
            *occurrence = matching;
            return 1;
        }
        if (window.title_len == wanted.title_len
            && memcmp(window.title, wanted.title,
                      (size_t)wanted.title_len) == 0) {
            matching++;
        }
        count++;
        address = window.next_window;
    }
    return 0;
}

/* The same question one level down: where `target` sits on a window's
   control chain, bounded by kNowAxResolveMaxControls for the same
   reason. */
static int locate_control(const NowObsWalk *walk, const NowAxWindow *window,
                          unsigned long target, NowAxControl *out,
                          unsigned int *occurrence)
{
    unsigned long handles[kNowAxResolveMaxControls];
    unsigned long handle = window->control_list;
    unsigned int  count = 0;
    unsigned int  matching = 0;
    NowAxControl  wanted;

    if (target == 0
        || now_ax_read_control(walk->memory, window, target, &wanted)
           != kNowAxOk) {
        return 0;
    }
    while (handle != 0) {
        NowAxControl control;

        if (count >= (unsigned int)kNowAxResolveMaxControls) {
            return 0;
        }
        if (seen(handles, count, handle)) {
            return 0;
        }
        handles[count] = handle;
        if (now_ax_read_control(walk->memory, window, handle, &control)
            != kNowAxOk) {
            return 0;
        }
        if (handle == target) {
            *out = control;
            *occurrence = matching;
            return 1;
        }
        if (control.title_len == wanted.title_len
            && memcmp(control.title, wanted.title,
                      (size_t)wanted.title_len) == 0) {
            matching++;
        }
        count++;
        handle = control.next_control;
    }
    return 0;
}

/* Everything the identity carries that does not depend on which element
   this is. */
static void identity_head(const NowObsWalk *walk, NowObsIdentity *id)
{
    memset(id, 0, sizeof(*id));
    id->psn_hi = walk->psn_hi;
    id->psn_lo = walk->psn_lo;
    id->process_fingerprint = walk->process_fingerprint;
    id->minted_ticks = walk->ticks;
    id->text_kind = kNowObsTextNone;
    id->ref.psn_hi = walk->psn_hi;
    id->ref.psn_lo = walk->psn_lo;
}

static void set_window_ref(NowObsIdentity *id, const NowAxWindow *window,
                           unsigned int occurrence, unsigned long address)
{
    memcpy(id->ref.window_title, window->title, (size_t)window->title_len);
    id->ref.window_title[window->title_len] = 0;
    id->ref.window_title_len = (size_t)window->title_len;
    id->ref.window_occurrence = occurrence;
    id->window_address = address;
}

static int usable(const NowObsWalk *walk, char *out, size_t cap)
{
    return walk != NULL && walk->registry != NULL && walk->memory != NULL
           && out != NULL && cap >= kNowObsTokenMax;
}

/* --- minting for THIS application ---------------------------------------

   The walk above is written for a foreign process: `usable` demands a
   memory reader and `locate_window` reads a WindowRecord through it. A
   self walk has neither, and correctly so - nothing on that path reads
   memory, because the Toolbox answers directly.

   So the refusal came before the work: every self window and every self
   control was refused a reference, which is why NOW's own window could
   not be moved, resized, zoomed or closed from the mirror, and why a
   click on its own buttons did nothing. Watched 2026-08-03.

   The identity these build is the same shape a foreign one has - psn,
   process fingerprint, address - minus the occurrence bookkeeping, which
   exists to disambiguate two windows a walk found by title. There is no
   ambiguity here: a WindowRef IS the identity, and the resolver proves
   it live by asking whether it is still in this application's window
   list. */

int now_obs_walk_self_window_ref(NowObsWalk *walk, unsigned long window,
                                 char *out, size_t cap)
{
    NowObsIdentity id;

    if (walk == NULL || walk->registry == NULL || out == NULL
            || cap < kNowObsTokenMax || window == 0) {
        if (walk != NULL) {
            walk->refused++;
        }
        return 0;
    }
    out[0] = '\0';
    identity_head(walk, &id);
    id.window_address = window;
    id.control_handle = 0;
    id.node_fingerprint = now_ax_ref_fingerprint(id.psn_hi, id.psn_lo,
                                                 window, 0UL);
    id.ref.node_fingerprint = id.node_fingerprint;
    if (!now_obs_intern(walk->registry, kNowObsKindWindow, &id, out, cap)) {
        out[0] = '\0';
        walk->refused++;
        return 0;
    }
    walk->granted++;
    return 1;
}

int now_obs_walk_self_control_ref(NowObsWalk *walk, unsigned long window,
                                  unsigned long control, char *out,
                                  size_t cap)
{
    NowObsIdentity id;

    if (walk == NULL || walk->registry == NULL || out == NULL
            || cap < kNowObsTokenMax || control == 0) {
        if (walk != NULL) {
            walk->refused++;
        }
        return 0;
    }
    out[0] = '\0';
    identity_head(walk, &id);
    id.window_address = window;
    id.control_handle = control;
    id.node_fingerprint = now_ax_ref_fingerprint(id.psn_hi, id.psn_lo,
                                                 window, control);
    id.ref.node_fingerprint = id.node_fingerprint;
    if (!now_obs_intern(walk->registry, kNowObsKindElement, &id, out, cap)) {
        out[0] = '\0';
        walk->refused++;
        return 0;
    }
    walk->granted++;
    return 1;
}

int now_obs_walk_window_ref(NowObsWalk *walk, unsigned long window_address,
                            char *out, size_t cap)
{
    NowObsIdentity id;
    NowAxWindow    window;
    unsigned int   occurrence = 0;

    if (!usable(walk, out, cap)) {
        if (walk != NULL) {
            walk->refused++;
        }
        return 0;
    }
    out[0] = '\0';
    if (!locate_window(walk, window_address, &window, &occurrence)) {
        walk->refused++;
        return 0;
    }
    identity_head(walk, &id);
    set_window_ref(&id, &window, occurrence, window_address);
    id.control_handle = 0;
    id.node_fingerprint = now_ax_ref_fingerprint(id.psn_hi, id.psn_lo,
                                                 window_address, 0UL);
    id.ref.node_fingerprint = id.node_fingerprint;
    if (!now_obs_intern(walk->registry, kNowObsKindWindow, &id, out, cap)) {
        out[0] = '\0';
        walk->refused++;
        return 0;
    }
    walk->granted++;
    return 1;
}

int now_obs_walk_control_ref(NowObsWalk *walk, unsigned long window_address,
                             unsigned long control_handle, char *out,
                             size_t cap)
{
    NowObsIdentity id;
    NowAxWindow    window;
    NowAxControl   control;
    unsigned int   window_occurrence = 0;
    unsigned int   control_occurrence = 0;

    if (!usable(walk, out, cap)) {
        if (walk != NULL) {
            walk->refused++;
        }
        return 0;
    }
    out[0] = '\0';
    if (!locate_window(walk, window_address, &window, &window_occurrence)
        || !locate_control(walk, &window, control_handle, &control,
                           &control_occurrence)) {
        walk->refused++;
        return 0;
    }
    identity_head(walk, &id);
    set_window_ref(&id, &window, window_occurrence, window_address);
    id.control_handle = control_handle;
    memcpy(id.ref.control_title, control.title, (size_t)control.title_len);
    id.ref.control_title[control.title_len] = 0;
    id.ref.control_title_len = (size_t)control.title_len;
    id.ref.control_occurrence = control_occurrence;
    id.node_fingerprint = now_ax_ref_fingerprint(id.psn_hi, id.psn_lo,
                                                 window_address,
                                                 control_handle);
    id.ref.node_fingerprint = id.node_fingerprint;
    if (!now_obs_intern(walk->registry, kNowObsKindElement, &id, out, cap)) {
        out[0] = '\0';
        walk->refused++;
        return 0;
    }
    walk->granted++;
    return 1;
}
