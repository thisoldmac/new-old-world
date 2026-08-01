/* The bounded Window/Control record reader. See axwalk.h for where these
   offsets came from and why they may not be tidied.

   The walker never scans memory and never follows a pointer it has not
   first proved to be inside the target partition or the system heap.
   Note the ORDER in every function below: validate, then dereference,
   then validate what the dereference produced. That order is the whole
   contract - a check performed after a read is not a check. */

#include "axwalk.h"

#include <string.h>

#include "peek_validate.h"

enum {
    /* A classic WindowRecord is 156 bytes (through refCon). We read 148:
       everything up to and including nextWindow, which is the last field
       this walk uses. Reading only what is used keeps the validated
       range as small as it can honestly be. */
    kNowAxWindowBytes = 148,
    kNowAxControlBytes = 296,
    kNowAxRegionBytes = 10,       /* rgnSize + rgnBBox */

    /* WindowRecord, 2-byte packed as the 68K Toolbox laid it out. A
       PPC-compiled struct would pad these, which is why they are read as
       bytes at literal offsets. */
    kNowAxWinKind = 108,
    kNowAxWinVisible = 110,
    kNowAxWinPortTop = 16,        /* portRect.top, LOCAL coordinates */
    kNowAxWinPortLeft = 18,
    kNowAxWinContRgn = 118,       /* content region; see axwalk.h */
    kNowAxWinTitleHandle = 134,
    kNowAxWinControlList = 140,
    kNowAxWinNextWindow = 144,

    /* ControlRecord. contrlRect is at 8; contrlTitle is a Str255 at 40. */
    kNowAxCtlNext = 0,
    kNowAxCtlRect = 8,
    kNowAxCtlVisible = 16,
    kNowAxCtlHilite = 17,         /* 255 = the whole control is disabled */
    kNowAxCtlValue = 18,
    kNowAxCtlMin = 20,
    kNowAxCtlMax = 22,
    kNowAxCtlTitle = 40
};

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

/* The boundary. Upstream had its own inline version of this; NOW has
   one already, tested exhaustively without a Toolbox, and one boundary
   is the point of having a boundary at all. Either region will do - a
   window record lives in its process's partition, its region and master
   pointers often do not. */
static int range_ok(const NowAxMemory *memory, unsigned long addr, size_t len)
{
    if (memory == NULL || memory->read == NULL) {
        return 0;
    }
    if (memory->target_hi > memory->target_lo
        && now_peek_range_in_partition(
               addr, (unsigned long)len, memory->target_lo,
               memory->target_hi - memory->target_lo)) {
        return 1;
    }
    if (memory->system_hi > memory->system_lo
        && now_peek_range_in_partition(
               addr, (unsigned long)len, memory->system_lo,
               memory->system_hi - memory->system_lo)) {
        return 1;
    }
    return 0;
}

int now_ax_read_bytes(const NowAxMemory *memory, unsigned long addr,
                      void *out, size_t len)
{
    if (!range_ok(memory, addr, len)) {
        return kNowAxInvalid;
    }
    return memory->read(memory->ctx, addr, out, len)
        ? kNowAxOk : kNowAxReadError;
}

/* A pointer we are willing to follow: non-zero, EVEN, and in range. The
   alignment test is not decoration - on 68K an odd pointer is an address
   error, and a wrong-offset read produces odd values far more often than
   it produces in-range ones, so this is the cheapest lie detector we
   have. */
static int pointer_ok(const NowAxMemory *memory, unsigned long addr,
                      size_t len)
{
    return addr != 0 && (addr & 1UL) == 0 && range_ok(memory, addr, len);
}

int now_ax_read_handle(const NowAxMemory *memory, unsigned long handle,
                       unsigned long *data)
{
    unsigned char raw[4];
    int           rc;

    if (!pointer_ok(memory, handle, sizeof(raw))) {
        return kNowAxInvalid;
    }
    rc = now_ax_read_bytes(memory, handle, raw, sizeof(raw));
    if (rc != kNowAxOk) {
        return rc;
    }
    *data = be32(raw);
    /* The master pointer is validated too, before anyone dereferences
       what we just produced. */
    return pointer_ok(memory, *data, 1) ? kNowAxOk : kNowAxInvalid;
}

/* A Pascal string behind a handle. An absent handle is not an error -
   a window may legitimately have no title. */
static int read_pstr_handle(const NowAxMemory *memory, unsigned long handle,
                            char out[kNowAxTitleMax + 1],
                            unsigned char *out_len)
{
    unsigned long data;
    unsigned char length;
    int           rc;

    out[0] = '\0';
    *out_len = 0;
    if (handle == 0) {
        return kNowAxOk;
    }
    rc = now_ax_read_handle(memory, handle, &data);
    if (rc != kNowAxOk) {
        return rc;
    }
    rc = now_ax_read_bytes(memory, data, &length, 1);
    if (rc != kNowAxOk) {
        return rc;
    }
    if (length != 0) {
        rc = now_ax_read_bytes(memory, data + 1, out, length);
        if (rc != kNowAxOk) {
            return rc;
        }
    }
    out[length] = '\0';
    *out_len = length;
    return kNowAxOk;
}

int now_ax_read_window(const NowAxMemory *memory, unsigned long address,
                       NowAxWindow *out)
{
    unsigned char window[kNowAxWindowBytes];
    unsigned char region[kNowAxRegionBytes];
    unsigned long region_handle;
    unsigned long region_data;
    unsigned long title_handle;
    short         port_top;
    short         port_left;
    int           rc;

    if (out == NULL || !pointer_ok(memory, address, sizeof(window))) {
        return kNowAxInvalid;
    }
    rc = now_ax_read_bytes(memory, address, window, sizeof(window));
    if (rc != kNowAxOk) {
        return rc;
    }
    memset(out, 0, sizeof(*out));
    out->address = address;
    out->kind = bes16(window + kNowAxWinKind);
    out->visible = window[kNowAxWinVisible] != 0;
    out->control_list = be32(window + kNowAxWinControlList);
    out->next_window = be32(window + kNowAxWinNextWindow);
    /* Both links are checked HERE, before the caller can walk either.
       A window whose chain leaves the readable zones is refused whole
       rather than reported with a poisoned link. */
    if ((out->control_list != 0
         && !pointer_ok(memory, out->control_list, 4))
        || (out->next_window != 0
            && !pointer_ok(memory, out->next_window, sizeof(window)))) {
        return kNowAxInvalid;
    }

    title_handle = be32(window + kNowAxWinTitleHandle);
    rc = read_pstr_handle(memory, title_handle, out->title, &out->title_len);
    if (rc != kNowAxOk) {
        return rc;
    }

    port_top = bes16(window + kNowAxWinPortTop);
    port_left = bes16(window + kNowAxWinPortLeft);
    region_handle = be32(window + kNowAxWinContRgn);
    if (region_handle == 0) {
        return kNowAxInvalid;         /* a window always has a content rgn */
    }
    rc = now_ax_read_handle(memory, region_handle, &region_data);
    if (rc != kNowAxOk) {
        return rc;
    }
    rc = now_ax_read_bytes(memory, region_data, region, sizeof(region));
    if (rc != kNowAxOk) {
        return rc;
    }
    /* rgnSize below the header size means this is not a Region. */
    if (be16(region) < kNowAxRegionBytes) {
        return kNowAxInvalid;
    }
    out->top = bes16(region + 2);
    out->left = bes16(region + 4);
    out->bottom = bes16(region + 6);
    out->right = bes16(region + 8);
    out->origin_top = (short)(out->top - port_top);
    out->origin_left = (short)(out->left - port_left);
    return kNowAxOk;
}

int now_ax_read_control(const NowAxMemory *memory, const NowAxWindow *window,
                        unsigned long handle, NowAxControl *out)
{
    unsigned char control[kNowAxControlBytes];
    unsigned long record;
    unsigned char length;
    int           rc;

    if (window == NULL || out == NULL) {
        return kNowAxInvalid;
    }
    rc = now_ax_read_handle(memory, handle, &record);
    if (rc != kNowAxOk || !pointer_ok(memory, record, sizeof(control))) {
        return rc == kNowAxOk ? kNowAxInvalid : rc;
    }
    rc = now_ax_read_bytes(memory, record, control, sizeof(control));
    if (rc != kNowAxOk) {
        return rc;
    }
    memset(out, 0, sizeof(*out));
    out->address = handle;
    out->record = record;
    out->next_control = be32(control + kNowAxCtlNext);
    out->visible = control[kNowAxCtlVisible] != 0;
    out->enabled = control[kNowAxCtlHilite] != 255;
    out->value = bes16(control + kNowAxCtlValue);
    out->min = bes16(control + kNowAxCtlMin);
    out->max = bes16(control + kNowAxCtlMax);
    if (out->next_control != 0
        && !pointer_ok(memory, out->next_control, 4)) {
        return kNowAxInvalid;
    }
    /* Local to global, using the window's content origin. */
    out->top = (short)(bes16(control + kNowAxCtlRect) + window->origin_top);
    out->left = (short)(bes16(control + kNowAxCtlRect + 2)
                        + window->origin_left);
    out->bottom = (short)(bes16(control + kNowAxCtlRect + 4)
                          + window->origin_top);
    out->right = (short)(bes16(control + kNowAxCtlRect + 6)
                         + window->origin_left);
    /* The title is INSIDE the record we already read and validated, so
       it needs no second range check - a Str255 at 40 cannot leave a
       296-byte buffer. */
    length = control[kNowAxCtlTitle];
    out->title_len = length;
    if (length != 0) {
        memcpy(out->title, control + kNowAxCtlTitle + 1, length);
    }
    out->title[length] = '\0';
    return kNowAxOk;
}
