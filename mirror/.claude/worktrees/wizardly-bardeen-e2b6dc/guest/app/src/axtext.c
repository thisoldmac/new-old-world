/*
 * axtext.c - passive parser for DialogRecord.textH and its TERec text handle.
 */
#include "axtext.h"

#include <string.h>

#define AX_DIALOG_TEXTH_OFFSET 160UL
#define AX_TEREC_HEADER_BYTES   66UL
#define AX_TE_SEL_START         32UL
#define AX_TE_SEL_END           34UL
#define AX_TE_ACTIVE            36UL
#define AX_TE_LENGTH            60UL
#define AX_TE_HTEXT             62UL

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

int ax_read_dialog_text(const ax_memory *memory, unsigned long window,
                        ax_text_info *out)
{
    unsigned char raw_handle[4];
    unsigned char te[AX_TEREC_HEADER_BYTES];
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
        return AX_INVALID;
    }
    memset(out, 0, sizeof(*out));
    rc = ax_read_bytes(memory, window + AX_DIALOG_TEXTH_OFFSET,
                       raw_handle, sizeof(raw_handle));
    if (rc != AX_OK) {
        return rc;
    }
    te_handle = be32(raw_handle);
    if (te_handle == 0) {
        return AX_NOT_FOUND;
    }
    rc = ax_read_handle(memory, te_handle, &te_record);
    if (rc != AX_OK) {
        return rc;
    }
    rc = ax_read_bytes(memory, te_record, te, sizeof(te));
    if (rc != AX_OK) {
        return rc;
    }
    length = be16(te + AX_TE_LENGTH);
    selection_start = be16(te + AX_TE_SEL_START);
    selection_end = be16(te + AX_TE_SEL_END);
    if (length > 0x7fffU || selection_start > selection_end
        || selection_end > length) {
        return AX_INVALID;
    }
    text_handle = be32(te + AX_TE_HTEXT);
    if (length != 0) {
        rc = ax_read_handle(memory, text_handle, &text_data);
        if (rc != AX_OK) {
            return rc;
        }
    }
    returned = length > AX_TEXT_MAX ? AX_TEXT_MAX : length;
    if (returned != 0) {
        rc = ax_read_bytes(memory, text_data, out->text, returned);
        if (rc != AX_OK) {
            return rc;
        }
    }
    out->text[returned] = '\0';
    out->length = length;
    out->returned = returned;
    out->selection_start = selection_start;
    out->selection_end = selection_end;
    out->active = be16(te + AX_TE_ACTIVE) != 0;
    out->truncated = returned != length;
    return AX_OK;
}
