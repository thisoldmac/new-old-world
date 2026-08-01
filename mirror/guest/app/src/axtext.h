/*
 * axtext.h - bounded reader for a Dialog Manager window's TextEdit record.
 */
#ifndef TIMBOTTU_AXTEXT_H
#define TIMBOTTU_AXTEXT_H

#include "axwalk.h"

#define AX_TEXT_MAX 1024

typedef struct {
    unsigned int  length;
    unsigned int  returned;
    unsigned int  selection_start;
    unsigned int  selection_end;
    unsigned char active;
    unsigned char truncated;
    char          text[AX_TEXT_MAX + 1];
} ax_text_info;

int ax_read_dialog_text(const ax_memory *memory, unsigned long window,
                        ax_text_info *out);

#endif /* TIMBOTTU_AXTEXT_H */
