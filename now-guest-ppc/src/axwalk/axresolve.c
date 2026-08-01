/* Bounded traversal, exact duplicate-title resolution, and the node
   fingerprint. See axresolve.h - including for what did not cross. */

#include "axresolve.h"

#include <string.h>

#define kNowAx32 0xFFFFFFFFUL         /* the target's word; see below */

/* FNV-1a, the same two constants and the same LEAST-SIGNIFICANT-BYTE-
   first feed order as upstream, because a fingerprint that hashed the
   bytes in a different order would still be a fine hash and would stop
   matching references minted by the other side of the port. The 32-bit
   masks are not a change: on the target `unsigned long` IS 32 bits and
   the arithmetic wrapped; on a 64-bit host running the tests it would
   not, so the mask is what keeps the two identical. */
static unsigned long fnv1a_word(unsigned long hash, unsigned long value)
{
    unsigned int byte;

    for (byte = 0; byte < 4; byte++) {
        hash ^= (value >> (byte * 8)) & 0xffUL;
        hash = (hash * 16777619UL) & kNowAx32;
    }
    return hash;
}

unsigned long now_ax_ref_fingerprint(unsigned long psn_hi,
                                     unsigned long psn_lo,
                                     unsigned long window_address,
                                     unsigned long control_handle)
{
    unsigned long hash = 2166136261UL;

    hash = fnv1a_word(hash, psn_hi & kNowAx32);
    hash = fnv1a_word(hash, psn_lo & kNowAx32);
    hash = fnv1a_word(hash, window_address & kNowAx32);
    hash = fnv1a_word(hash, control_handle & kNowAx32);
    return hash;
}

static unsigned long title_hash(const unsigned char *title, size_t length)
{
    unsigned long hash = 2166136261UL;
    size_t        i;

    for (i = 0; i < length; i++) {
        hash ^= title[i];
        hash = (hash * 16777619UL) & kNowAx32;
    }
    return hash;
}

void now_ax_title_counter_reset(NowAxTitleCounter *counter,
                                NowAxTitleEntry *entries,
                                unsigned int capacity)
{
    counter->entries = entries;
    counter->count = 0;
    counter->capacity = capacity;
}

int now_ax_title_counter_next(NowAxTitleCounter *counter,
                              const void *title_value, size_t length,
                              unsigned int *occurrence)
{
    const unsigned char *title = title_value;
    unsigned long        hash;
    unsigned int         i;

    if (counter == NULL || occurrence == NULL || length > kNowAxTitleMax
        || (length != 0 && title == NULL)) {
        return kNowAxInvalid;
    }
    hash = title_hash(title, length);
    for (i = 0; i < counter->count; i++) {
        NowAxTitleEntry *entry = &counter->entries[i];

        /* The hash narrows the search; the memcmp decides it. Two
           titles that collide must not be counted as one. */
        if (entry->hash == hash && entry->length == length
            && memcmp(entry->title, title, length) == 0) {
            *occurrence = entry->occurrence_count++;
            return kNowAxOk;
        }
    }
    if (counter->count >= counter->capacity) {
        return kNowAxInvalid;
    }
    counter->entries[counter->count].hash = hash;
    counter->entries[counter->count].occurrence_count = 1;
    counter->entries[counter->count].length = (unsigned char)length;
    if (length != 0) {
        memcpy(counter->entries[counter->count].title, title, length);
    }
    counter->count++;
    *occurrence = 0;
    return kNowAxOk;
}

static int address_seen(const unsigned long *seen, unsigned int count,
                        unsigned long address)
{
    unsigned int i;

    for (i = 0; i < count; i++) {
        if (seen[i] == address) {
            return 1;
        }
    }
    return 0;
}

int now_ax_resolve_ref(const NowAxMemory *memory, unsigned long window_list,
                       const NowAxRef *ref, NowAxResolved *out)
{
    unsigned long seen_windows[kNowAxResolveMaxWindows];
    unsigned long window_address = window_list;
    unsigned int  window_count = 0;
    unsigned int  matching_windows = 0;
    unsigned int  visible_window_count = 0;

    if (memory == NULL || ref == NULL || out == NULL) {
        return kNowAxInvalid;
    }
    memset(out, 0, sizeof(*out));
    while (window_address != 0) {
        NowAxWindow   window;
        unsigned long seen_controls[kNowAxResolveMaxControls];
        unsigned long control_handle;
        unsigned int  control_count = 0;
        unsigned int  matching_controls = 0;
        unsigned int  visible_window_z;
        int           rc;

        if (window_count >= kNowAxResolveMaxWindows) {
            return kNowAxResolveNotFound;
        }
        if (address_seen(seen_windows, window_count, window_address)) {
            return kNowAxResolveCycle;
        }
        seen_windows[window_count] = window_address;
        rc = now_ax_read_window(memory, window_address, &window);
        if (rc != kNowAxOk) {
            return rc;
        }
        /* Two z-orders, because they answer different questions: where
           the window sits in the chain, and where it sits among the
           windows a person can actually see. */
        visible_window_z = visible_window_count;
        if (window.visible) {
            visible_window_count++;
        }
        if (window.title_len != ref->window_title_len
            || memcmp(window.title, ref->window_title,
                      ref->window_title_len) != 0) {
            window_count++;
            window_address = window.next_window;
            continue;
        }
        if (matching_windows++ != ref->window_occurrence) {
            window_count++;
            window_address = window.next_window;
            continue;
        }

        control_handle = window.control_list;
        while (control_handle != 0) {
            NowAxControl control;

            if (control_count >= kNowAxResolveMaxControls) {
                return kNowAxResolveNotFound;
            }
            if (address_seen(seen_controls, control_count, control_handle)) {
                return kNowAxResolveCycle;
            }
            seen_controls[control_count] = control_handle;
            rc = now_ax_read_control(memory, &window, control_handle,
                                     &control);
            if (rc != kNowAxOk) {
                return rc;
            }
            if (control.title_len == ref->control_title_len
                && memcmp(control.title, ref->control_title,
                          ref->control_title_len) == 0
                && matching_controls++ == ref->control_occurrence) {
                out->window_address = window_address;
                out->control_handle = control_handle;
                out->window_z = window_count;
                out->visible_window_z = visible_window_z;
                out->window = window;
                out->control = control;
                /* Found by name - now check it is still the same THING.
                   The result is filled either way so a caller can see
                   what it found, but Stale is not Ok and must not be
                   acted on as though it were. */
                if (ref->node_fingerprint != now_ax_ref_fingerprint(
                        ref->psn_hi, ref->psn_lo, window_address,
                        control_handle)) {
                    return kNowAxResolveStale;
                }
                return kNowAxResolveOk;
            }
            control_count++;
            control_handle = control.next_control;
        }
        /* The named window was found and did not hold the named
           control. Later windows cannot hold it either - this
           occurrence was the one asked for. */
        return kNowAxResolveNotFound;
    }
    return kNowAxResolveNotFound;
}
