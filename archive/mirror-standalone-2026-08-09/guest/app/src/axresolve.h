/*
 * axresolve.h - bounded stable-reference resolution over an ax_memory seam.
 *
 * This module owns traversal limits, cycle detection, and duplicate-title
 * occurrence semantics shared by perception and action. It has no Toolbox
 * dependency, so synthetic host fixtures can prove the resolver policy.
 */
#ifndef TIMBOTTU_AXRESOLVE_H
#define TIMBOTTU_AXRESOLVE_H

#include "axref.h"
#include "axwalk.h"

#define AX_RESOLVE_MAX_WINDOWS 16
#define AX_RESOLVE_MAX_CONTROLS 32

enum {
    AX_RESOLVE_OK = 0,
    AX_RESOLVE_NOT_FOUND = -10,
    AX_RESOLVE_CYCLE = -11,
    AX_RESOLVE_STALE = -12
};

typedef struct {
    unsigned long  window_address;
    unsigned long  control_handle;
    unsigned int   window_z;
    unsigned int   visible_window_z;
    ax_window_info window;
    ax_control_info control;
} ax_resolved_control;

typedef struct {
    unsigned long hash;
    unsigned int  occurrence_count;
    unsigned char length;
    unsigned char title[AX_TITLE_MAX];
} ax_title_entry;

typedef struct {
    ax_title_entry *entries;
    unsigned int    count;
    unsigned int    capacity;
} ax_title_counter;

void ax_title_counter_reset(ax_title_counter *counter,
                            ax_title_entry *entries, unsigned int capacity);
int ax_title_counter_next(ax_title_counter *counter, const void *title,
                          size_t length, unsigned int *occurrence);

int ax_resolve_ref(const ax_memory *memory, unsigned long window_list,
                   const ax_ref *ref, ax_resolved_control *out);

#endif /* TIMBOTTU_AXRESOLVE_H */
