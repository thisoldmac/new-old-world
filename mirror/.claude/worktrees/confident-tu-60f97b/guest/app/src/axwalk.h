/*
 * axwalk.h - bounded, passive classic-Mac accessibility memory walking.
 *
 * The parser knows byte layouts, not how memory is obtained. The guest binds
 * the read seam to one ProcessInfoRec partition plus validated SysZone bounds;
 * host tests bind it to synthetic big-endian fixtures. Every pointer crosses
 * this seam before it is interpreted.
 */
#ifndef TIMBOTTU_AXWALK_H
#define TIMBOTTU_AXWALK_H

#include <stddef.h>

#define AX_TITLE_MAX 255

enum {
    AX_OK = 0,
    AX_READ_ERROR = -1,
    AX_INVALID = -2,
    AX_NOT_FOUND = -3,
    AX_AMBIGUOUS = -4
};

typedef int (*ax_read_fn)(void *ctx, unsigned long addr, void *out,
                          size_t len);

typedef struct {
    ax_read_fn    read;
    void         *ctx;
    unsigned long target_lo;
    unsigned long target_hi;
    unsigned long system_lo;
    unsigned long system_hi;
} ax_memory;

typedef struct {
    unsigned long address;
    unsigned long next_window;
    unsigned long control_list;
    short         kind;
    unsigned char visible;
    short         origin_top;
    short         origin_left;
    short         top;
    short         left;
    short         bottom;
    short         right;
    unsigned char title_len;
    char          title[AX_TITLE_MAX + 1];
} ax_window_info;

typedef struct {
    unsigned long address;
    unsigned long record;
    unsigned long next_control;
    unsigned char visible;
    unsigned char enabled;
    short         top;
    short         left;
    short         bottom;
    short         right;
    unsigned char title_len;
    char          title[AX_TITLE_MAX + 1];
    short         value;    /* contrlValue @18 (checkbox on/off, scroll pos) */
    short         min;      /* contrlMin   @20 */
    short         max;      /* contrlMax   @22 */
} ax_control_info;

int ax_read_bytes(const ax_memory *memory, unsigned long address, void *out,
                  size_t len);
int ax_read_handle(const ax_memory *memory, unsigned long handle,
                   unsigned long *data);
int ax_read_window(const ax_memory *memory, unsigned long address,
                   ax_window_info *out);
int ax_read_control(const ax_memory *memory, const ax_window_info *window,
                    unsigned long handle, ax_control_info *out);

#endif /* TIMBOTTU_AXWALK_H */
