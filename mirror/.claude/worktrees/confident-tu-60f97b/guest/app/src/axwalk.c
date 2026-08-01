/*
 * axwalk.c - bounded classic-Mac Window/Control record reader.
 *
 * The caller supplies the selected process's public ProcessInfoRec partition
 * bounds plus the live SysZone bounds. Every record, link, handle, and handle
 * data pointer must remain in one of those two explicit regions. The walker
 * never scans memory and never follows a pointer into another app partition or
 * outside the system heap.
 */
#include "axwalk.h"

#include <string.h>

#define AX_WINDOW_BYTES       148
#define AX_CONTROL_BYTES      296
#define AX_REGION_BYTES        10

static unsigned short be16(const unsigned char *p)
{
    return (unsigned short)(((unsigned short)p[0] << 8) | p[1]);
}

static short bes16(const unsigned char *p)
{
    return (short)be16(p);
}

static unsigned long be32(const unsigned char *p)
{
    return ((unsigned long)p[0] << 24)
         | ((unsigned long)p[1] << 16)
         | ((unsigned long)p[2] << 8)
         | (unsigned long)p[3];
}

static int range_ok(const ax_memory *memory, unsigned long addr, size_t len)
{
    int target_ok;
    int system_ok;

    if (memory == NULL || memory->read == NULL) {
        return 0;
    }
    target_ok = memory->target_lo < memory->target_hi
        && addr >= memory->target_lo && addr < memory->target_hi
        && len <= (size_t)(memory->target_hi - addr);
    system_ok = memory->system_lo < memory->system_hi
        && addr >= memory->system_lo && addr < memory->system_hi
        && len <= (size_t)(memory->system_hi - addr);
    return target_ok || system_ok;
}

int ax_read_bytes(const ax_memory *memory, unsigned long addr, void *out,
                  size_t len)
{
    if (!range_ok(memory, addr, len)) {
        return AX_INVALID;
    }
    return memory->read(memory->ctx, addr, out, len)
        ? AX_OK : AX_READ_ERROR;
}

static int pointer_ok(const ax_memory *memory, unsigned long addr, size_t len)
{
    return addr != 0 && (addr & 1UL) == 0 && range_ok(memory, addr, len);
}

int ax_read_handle(const ax_memory *memory, unsigned long handle,
                   unsigned long *data)
{
    unsigned char raw[4];
    int           rc;

    if (!pointer_ok(memory, handle, sizeof(raw))) {
        return AX_INVALID;
    }
    rc = ax_read_bytes(memory, handle, raw, sizeof(raw));
    if (rc != AX_OK) {
        return rc;
    }
    *data = be32(raw);
    return pointer_ok(memory, *data, 1) ? AX_OK : AX_INVALID;
}

static int read_pstr_handle(const ax_memory *memory, unsigned long handle,
                            char out[AX_TITLE_MAX + 1],
                            unsigned char *out_len)
{
    unsigned long data;
    unsigned char length;
    int           rc;

    out[0] = '\0';
    *out_len = 0;
    if (handle == 0) {
        return AX_OK;
    }
    rc = ax_read_handle(memory, handle, &data);
    if (rc != AX_OK) {
        return rc;
    }
    rc = ax_read_bytes(memory, data, &length, 1);
    if (rc != AX_OK) {
        return rc;
    }
    if (length != 0) {
        rc = ax_read_bytes(memory, data + 1, out, length);
        if (rc != AX_OK) {
            return rc;
        }
    }
    out[length] = '\0';
    *out_len = length;
    return AX_OK;
}

int ax_read_window(const ax_memory *memory, unsigned long address,
                   ax_window_info *out)
{
    unsigned char window[AX_WINDOW_BYTES];
    unsigned char region[AX_REGION_BYTES];
    unsigned long region_handle;
    unsigned long region_data;
    unsigned long title_handle;
    short         port_top;
    short         port_left;
    int           rc;

    if (out == NULL || !pointer_ok(memory, address, sizeof(window))) {
        return AX_INVALID;
    }
    rc = ax_read_bytes(memory, address, window, sizeof(window));
    if (rc != AX_OK) {
        return rc;
    }
    memset(out, 0, sizeof(*out));
    out->address = address;
    out->kind = bes16(window + 108);
    out->visible = window[110] != 0;
    out->control_list = be32(window + 140);
    out->next_window = be32(window + 144);
    if ((out->control_list != 0
         && !pointer_ok(memory, out->control_list, 4))
        || (out->next_window != 0
            && !pointer_ok(memory, out->next_window, sizeof(window)))) {
        return AX_INVALID;
    }

    title_handle = be32(window + 134);
    rc = read_pstr_handle(memory, title_handle, out->title, &out->title_len);
    if (rc != AX_OK) {
        return rc;
    }

    port_top = bes16(window + 16);
    port_left = bes16(window + 18);
    region_handle = be32(window + 118);
    if (region_handle == 0) {
        return AX_INVALID;
    }
    rc = ax_read_handle(memory, region_handle, &region_data);
    if (rc != AX_OK) {
        return rc;
    }
    rc = ax_read_bytes(memory, region_data, region, sizeof(region));
    if (rc != AX_OK) {
        return rc;
    }
    if (be16(region) < AX_REGION_BYTES) {
        return AX_INVALID;
    }
    out->top = bes16(region + 2);
    out->left = bes16(region + 4);
    out->bottom = bes16(region + 6);
    out->right = bes16(region + 8);
    out->origin_top = (short)(out->top - port_top);
    out->origin_left = (short)(out->left - port_left);
    return AX_OK;
}

int ax_read_control(const ax_memory *memory, const ax_window_info *window,
                    unsigned long handle, ax_control_info *out)
{
    unsigned char control[AX_CONTROL_BYTES];
    unsigned long record;
    unsigned char length;
    int           rc;

    if (window == NULL || out == NULL) {
        return AX_INVALID;
    }
    rc = ax_read_handle(memory, handle, &record);
    if (rc != AX_OK || !pointer_ok(memory, record, sizeof(control))) {
        return rc == AX_OK ? AX_INVALID : rc;
    }
    rc = ax_read_bytes(memory, record, control, sizeof(control));
    if (rc != AX_OK) {
        return rc;
    }
    memset(out, 0, sizeof(*out));
    out->address = handle;
    out->record = record;
    out->next_control = be32(control);
    out->visible = control[16] != 0;
    out->enabled = control[17] != 255;
    out->value = bes16(control + 18);   /* contrlValue / contrlMin / contrlMax */
    out->min = bes16(control + 20);
    out->max = bes16(control + 22);
    if (out->next_control != 0
        && !pointer_ok(memory, out->next_control, 4)) {
        return AX_INVALID;
    }
    out->top = (short)(bes16(control + 8) + window->origin_top);
    out->left = (short)(bes16(control + 10) + window->origin_left);
    out->bottom = (short)(bes16(control + 12) + window->origin_top);
    out->right = (short)(bes16(control + 14) + window->origin_left);
    length = control[40];
    out->title_len = length;
    if (length != 0) {
        memcpy(out->title, control + 41, length);
    }
    out->title[length] = '\0';
    return AX_OK;
}
