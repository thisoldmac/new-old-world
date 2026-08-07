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
    kNowAxWinStrucRgn = 114,      /* structure region; see axwalk.h */
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
    kNowAxCtlDefProc = 24,        /* Controls.h: Handle contrlDefProc */
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

/* range_ok answers "either zone"; this answers WHICH, and that is the
   whole of the standard-versus-custom split. Same half-open convention
   and the same validator, so a zone that is unset (hi == lo) claims
   nothing rather than claiming everything. */
static int in_zone(unsigned long lo, unsigned long hi,
                   unsigned long addr, size_t len)
{
    return hi > lo
        && now_peek_range_in_partition(addr, (unsigned long)len, lo, hi - lo);
}

/* The classification, kept pure and away from the Toolbox so the native
   test can drive every branch. Order matters: the system heap is tested
   FIRST, because a target partition is carved out of the same address
   space and an overlap would otherwise silently relabel a shared CDEF as
   the application's own. */
static short def_proc_origin(const NowAxMemory *memory, unsigned long handle)
{
    if (memory == NULL) {
        return (short)kNowAxDefProcIndeterminate;
    }
    if (handle == 0) {
        return (short)kNowAxDefProcAbsent;
    }
    /* A handle is a master pointer slot: even, and inside a zone. An odd
       value is not a handle at all, whatever else it may be. */
    if ((handle & 1UL) != 0) {
        return (short)kNowAxDefProcIndeterminate;
    }
    if (in_zone(memory->system_lo, memory->system_hi, handle, 4)) {
        return (short)kNowAxDefProcSystem;
    }
    if (in_zone(memory->target_lo, memory->target_hi, handle, 4)) {
        return (short)kNowAxDefProcApplication;
    }
    return (short)kNowAxDefProcIndeterminate;
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

/* One region handle -> its bounding box, with the two checks that make a
   foreign read of one safe: the handle must dereference inside the zones
   this walk may read, and the rgnSize word must be at least a header's
   worth or the thing is not a Region at all. Both regions of a window go
   through this, so neither can be validated more loosely than the other
   by accident. */
static int read_region_bbox(const NowAxMemory *memory,
                            unsigned long region_handle, short *out)
{
    unsigned char region[kNowAxRegionBytes];
    unsigned long region_data;
    int           rc;

    if (region_handle == 0) {
        return kNowAxInvalid;         /* a window always has both regions */
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
    out[0] = bes16(region + 2);
    out[1] = bes16(region + 4);
    out[2] = bes16(region + 6);
    out[3] = bes16(region + 8);
    return kNowAxOk;
}

int now_ax_read_window(const NowAxMemory *memory, unsigned long address,
                       NowAxWindow *out)
{
    unsigned char window[kNowAxWindowBytes];
    unsigned long title_handle;
    short         cont[4];
    short         struc[4];
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
    rc = read_region_bbox(memory, be32(window + kNowAxWinContRgn), cont);
    if (rc != kNowAxOk) {
        return rc;
    }
    out->top = cont[0];
    out->left = cont[1];
    out->bottom = cont[2];
    out->right = cont[3];
    out->origin_top = (short)(out->top - port_top);
    out->origin_left = (short)(out->left - port_left);
    /* AND THE FRAME A PERSON SEES, out of the same record. Refused
       exactly as an unreadable content region is - a window reported
       with one region under the other's name is the failure this merge
       exists to end, and it would be invisible: a plausible rectangle
       about twenty pixels out. */
    rc = read_region_bbox(memory, be32(window + kNowAxWinStrucRgn), struc);
    if (rc != kNowAxOk) {
        return rc;
    }
    out->struc_top = struc[0];
    out->struc_left = struc[1];
    out->struc_bottom = struc[2];
    out->struc_right = struc[3];
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
    /* Inside the record already read and validated, so no second range
       check - and the classification only COMPARES the value, it never
       follows it. Nothing here dereferences a foreign CDEF. */
    out->def_proc = be32(control + kNowAxCtlDefProc);
    out->def_proc_origin = def_proc_origin(memory, out->def_proc);
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

/* DialogRecord, after its 156-byte WindowRecord base. These are the fields in
   Dialogs.h's public DialogRecord: items, textH, editField, editOpen,
   aDefItem. Read as bytes because a PPC struct would not preserve the 68K
   packing whose memory we are observing. */
enum {
    kNowAxDialogRecordBytes = 170,
    kNowAxDialogItems = 156,
    kNowAxDialogEditField = 164,
    kNowAxDialogDefaultItem = 168,
    kNowAxDialogItemFixed = 14,
    kNowAxDITLCtrlItem = 4,
    kNowAxDITLStatText = 8,
    kNowAxDITLEditText = 16,
    kNowAxDITLIconItem = 32,
    kNowAxDITLPicItem = 64,
    kNowAxDITLItemDisable = 128
};

int now_ax_open_dialog_items(const NowAxMemory *memory,
                             unsigned long window,
                             NowAxDialogCursor *cursor)
{
    unsigned char record[kNowAxDialogRecordBytes];
    unsigned char count_raw[2];
    unsigned long items_handle;
    unsigned long items;
    short count_minus_one;
    int rc;

    if (cursor == NULL) {
        return kNowAxInvalid;
    }
    memset(cursor, 0, sizeof(*cursor));
    rc = now_ax_read_bytes(memory, window, record, sizeof(record));
    if (rc != kNowAxOk) {
        return rc;
    }
    items_handle = be32(record + kNowAxDialogItems);
    rc = now_ax_read_handle(memory, items_handle, &items);
    if (rc != kNowAxOk) {
        return rc;
    }
    rc = now_ax_read_bytes(memory, items, count_raw, sizeof(count_raw));
    if (rc != kNowAxOk) {
        return rc;
    }
    count_minus_one = bes16(count_raw);
    if (count_minus_one < -1
        || count_minus_one + 1 > kNowAxDialogMaxItems) {
        return kNowAxTruncated;
    }
    cursor->next = items + 2;
    cursor->remaining = (short)(count_minus_one + 1);
    cursor->index = 0;
    cursor->default_item = bes16(record + kNowAxDialogDefaultItem);
    /* DialogRecord.editField is zero-based and -1 means none. */
    cursor->edit_item = (short)(bes16(record + kNowAxDialogEditField) + 1);
    if (cursor->default_item > cursor->remaining) {
        return kNowAxInvalid;
    }
    if (cursor->edit_item > cursor->remaining) {
        return kNowAxInvalid;
    }
    return kNowAxOk;
}

int now_ax_dialog_next(const NowAxMemory *memory, NowAxDialogCursor *cursor,
                       NowAxDialogItem *item)
{
    unsigned char fixed[kNowAxDialogItemFixed];
    unsigned char raw_type;
    unsigned char type;
    unsigned char len;
    unsigned long total;
    int rc;

    if (cursor == NULL || item == NULL) {
        return kNowAxInvalid;
    }
    if (cursor->remaining == 0) {
        return kNowAxNotFound;
    }
    rc = now_ax_read_bytes(memory, cursor->next, fixed, sizeof(fixed));
    if (rc != kNowAxOk) {
        return rc;
    }
    memset(item, 0, sizeof(*item));
    item->number = (short)(cursor->index + 1);
    item->handle = be32(fixed);
    item->top = bes16(fixed + 4);
    item->left = bes16(fixed + 6);
    item->bottom = bes16(fixed + 8);
    item->right = bes16(fixed + 10);
    raw_type = fixed[12];
    type = (unsigned char)(raw_type & ~kNowAxDITLItemDisable);
    len = fixed[13];
    item->enabled = (raw_type & kNowAxDITLItemDisable) == 0;
    item->visible = 1;

    if ((type & ~3U) == kNowAxDITLCtrlItem) {
        switch (type & 3U) {
        case 0: item->kind = kNowAxDialogPushButton; break;
        case 1: item->kind = kNowAxDialogCheckBox; break;
        case 2: item->kind = kNowAxDialogRadioButton; break;
        default: item->kind = kNowAxDialogResourceControl; break;
        }
    } else if (type == kNowAxDITLStatText) {
        item->kind = kNowAxDialogStaticText;
    } else if (type == kNowAxDITLEditText) {
        item->kind = kNowAxDialogEditText;
    } else if (type == kNowAxDITLIconItem) {
        item->kind = kNowAxDialogIcon;
    } else if (type == kNowAxDITLPicItem) {
        item->kind = kNowAxDialogPicture;
    } else {
        item->kind = kNowAxDialogUserItem;
    }

    if (len != 0) {
        rc = now_ax_read_bytes(memory,
                               cursor->next + kNowAxDialogItemFixed,
                               item->title, len);
        if (rc != kNowAxOk) {
            return rc;
        }
    }
    item->title[len] = '\0';
    item->title_len = len;

    /* Item records are word-aligned. Validate the complete variable record
       before committing the cursor so a malformed tail never leaves a
       plausible prefix behind. */
    total = (unsigned long)kNowAxDialogItemFixed + (unsigned long)len;
    if (total & 1UL) {
        ++total;
    }
    if (total < kNowAxDialogItemFixed
        || now_ax_read_bytes(memory, cursor->next, fixed, 1) != kNowAxOk
        || (total > 1
            && now_ax_read_bytes(memory, cursor->next + total - 1,
                                 fixed, 1) != kNowAxOk)) {
        return kNowAxInvalid;
    }
    cursor->next += total;
    ++cursor->index;
    --cursor->remaining;
    return kNowAxOk;
}
