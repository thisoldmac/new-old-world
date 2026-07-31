/* DialogRecord.textH and the TERec behind it. See axtext.h. */

#include "axtext.h"

#include <string.h>

enum {
    /* A DialogRecord is a WindowRecord (156) followed by the dialog's
       own fields; textH is the TEHandle at 160. */
    kNowAxDialogTextH = 160,

    /* TERec. Everything read here lives in its first 66 bytes, which is
       why exactly that many are fetched: destRect/viewRect/selRect, the
       selection, the active flag, teLength and hText. */
    kNowAxTeRecBytes = 66,
    kNowAxTeSelStart = 32,
    kNowAxTeSelEnd = 34,
    kNowAxTeActive = 36,
    kNowAxTeLength = 60,
    kNowAxTeHText = 62
};

static unsigned short be16(const unsigned char *p)
{
    return (unsigned short)(((unsigned short)p[0] << 8) | p[1]);
}

static unsigned long be32(const unsigned char *p)
{
    return ((unsigned long)p[0] << 24)
         | ((unsigned long)p[1] << 16)
         | ((unsigned long)p[2] << 8)
         | (unsigned long)p[3];
}

int now_ax_read_dialog_text(const NowAxMemory *memory, unsigned long window,
                            NowAxText *out)
{
    unsigned char raw_handle[4];
    unsigned char te[kNowAxTeRecBytes];
    unsigned long te_handle;
    unsigned long te_record;
    unsigned long text_handle;
    unsigned long text_data;
    unsigned int  length;
    unsigned int  returned;
    unsigned int  selection_start;
    unsigned int  selection_end;
    int           rc;

    if (out == NULL) {
        return kNowAxInvalid;
    }
    memset(out, 0, sizeof(*out));
    rc = now_ax_read_bytes(memory, window + kNowAxDialogTextH,
                           raw_handle, sizeof(raw_handle));
    if (rc != kNowAxOk) {
        return rc;
    }
    te_handle = be32(raw_handle);
    if (te_handle == 0) {
        return kNowAxNotFound;        /* not a dialog, or no text in it */
    }
    rc = now_ax_read_handle(memory, te_handle, &te_record);
    if (rc != kNowAxOk) {
        return rc;
    }
    rc = now_ax_read_bytes(memory, te_record, te, sizeof(te));
    if (rc != kNowAxOk) {
        return rc;
    }
    length = be16(te + kNowAxTeLength);
    selection_start = be16(te + kNowAxTeSelStart);
    selection_end = be16(te + kNowAxTeSelEnd);
    /* Coherence, checked BEFORE anything is dereferenced with these
       numbers: a selection outside the text, or a length with the sign
       bit set, means this is not a TERec and the offsets are wrong. */
    if (length > 0x7fffU || selection_start > selection_end
        || selection_end > length) {
        return kNowAxInvalid;
    }
    text_handle = be32(te + kNowAxTeHText);
    if (length != 0) {
        rc = now_ax_read_handle(memory, text_handle, &text_data);
        if (rc != kNowAxOk) {
            return rc;
        }
    }
    returned = length > kNowAxTextMax ? kNowAxTextMax : length;
    if (returned != 0) {
        rc = now_ax_read_bytes(memory, text_data, out->text, returned);
        if (rc != kNowAxOk) {
            return rc;
        }
    }
    out->text[returned] = '\0';
    out->length = length;
    out->returned = returned;
    out->selection_start = selection_start;
    out->selection_end = selection_end;
    out->active = be16(te + kNowAxTeActive) != 0;
    /* The full length is reported alongside what fits, so a consumer can
       say "truncated" rather than quietly presenting a prefix as the
       whole text. */
    out->truncated = returned != length;
    return kNowAxOk;
}
