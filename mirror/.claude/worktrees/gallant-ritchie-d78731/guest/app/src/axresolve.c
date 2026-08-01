/* axresolve.c - bounded traversal and exact duplicate-title resolution. */
#include "axresolve.h"

#include <string.h>

static unsigned long title_hash(const unsigned char *title, size_t length)
{
    unsigned long hash = 2166136261UL;
    size_t        i;

    for (i = 0; i < length; i++) {
        hash ^= title[i];
        hash *= 16777619UL;
    }
    return hash;
}

void ax_title_counter_reset(ax_title_counter *counter,
                            ax_title_entry *entries, unsigned int capacity)
{
    counter->entries = entries;
    counter->count = 0;
    counter->capacity = capacity;
}

int ax_title_counter_next(ax_title_counter *counter, const void *title_value,
                          size_t length, unsigned int *occurrence)
{
    const unsigned char *title = title_value;
    unsigned long        hash;
    unsigned int         i;

    if (counter == NULL || occurrence == NULL || length > AX_TITLE_MAX
        || (length != 0 && title == NULL)) {
        return AX_INVALID;
    }
    hash = title_hash(title, length);
    for (i = 0; i < counter->count; i++) {
        ax_title_entry *entry = &counter->entries[i];

        if (entry->hash == hash && entry->length == length
            && memcmp(entry->title, title, length) == 0) {
            *occurrence = entry->occurrence_count++;
            return AX_OK;
        }
    }
    if (counter->count >= counter->capacity) {
        return AX_INVALID;
    }
    counter->entries[counter->count].hash = hash;
    counter->entries[counter->count].occurrence_count = 1;
    counter->entries[counter->count].length = (unsigned char)length;
    if (length != 0) {
        memcpy(counter->entries[counter->count].title, title, length);
    }
    counter->count++;
    *occurrence = 0;
    return AX_OK;
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

int ax_resolve_ref(const ax_memory *memory, unsigned long window_list,
                   const ax_ref *ref, ax_resolved_control *out)
{
    unsigned long seen_windows[AX_RESOLVE_MAX_WINDOWS];
    unsigned long window_address = window_list;
    unsigned int  window_count = 0;
    unsigned int  matching_windows = 0;
    unsigned int  visible_window_count = 0;

    if (memory == NULL || ref == NULL || out == NULL) {
        return AX_INVALID;
    }
    memset(out, 0, sizeof(*out));
    while (window_address != 0) {
        ax_window_info window;
        unsigned long  seen_controls[AX_RESOLVE_MAX_CONTROLS];
        unsigned long  control_handle;
        unsigned int   control_count = 0;
        unsigned int   matching_controls = 0;
        unsigned int   visible_window_z;
        int            rc;

        if (window_count >= AX_RESOLVE_MAX_WINDOWS) {
            return AX_RESOLVE_NOT_FOUND;
        }
        if (address_seen(seen_windows, window_count, window_address)) {
            return AX_RESOLVE_CYCLE;
        }
        seen_windows[window_count] = window_address;
        rc = ax_read_window(memory, window_address, &window);
        if (rc != AX_OK) {
            return rc;
        }
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
            ax_control_info control;

            if (control_count >= AX_RESOLVE_MAX_CONTROLS) {
                return AX_RESOLVE_NOT_FOUND;
            }
            if (address_seen(seen_controls, control_count, control_handle)) {
                return AX_RESOLVE_CYCLE;
            }
            seen_controls[control_count] = control_handle;
            rc = ax_read_control(memory, &window, control_handle, &control);
            if (rc != AX_OK) {
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
                if (ref->node_fingerprint != ax_ref_node_fingerprint(
                        ref->serial_hi, ref->serial_lo,
                        (uint32_t)window_address, (uint32_t)control_handle)) {
                    return AX_RESOLVE_STALE;
                }
                return AX_RESOLVE_OK;
            }
            control_count++;
            control_handle = control.next_control;
        }
        return AX_RESOLVE_NOT_FOUND;
    }
    return AX_RESOLVE_NOT_FOUND;
}
