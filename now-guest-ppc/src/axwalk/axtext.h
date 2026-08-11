#ifndef NOW_AXTEXT_H
#define NOW_AXTEXT_H

/* A Dialog Manager window's editable text, read out of its TextEdit
   record. Ported from archive/mirror-standalone-2026-08-09/guest/app/src/axtext.c; the offsets are
   measurements, per axwalk.h.

   This is what makes a dialog legible rather than merely visible. A
   window walk gives you "a window called Save As"; this gives you what
   is actually typed in it, and where the selection sits. */

#include "axwalk.h"

enum {
    /* A bound, not a belief. A TERec's length is a 16-bit count and can
       legitimately exceed this; the reader returns what fits and says
       so rather than sizing a buffer off a foreign word. */
    kNowAxTextMax = 1024
};

typedef struct {
    unsigned int  length;         /* teLength, the full text */
    unsigned int  returned;       /* bytes actually in `text` */
    unsigned int  selection_start;
    unsigned int  selection_end;
    unsigned char active;
    unsigned char truncated;      /* returned < length */
    char          text[kNowAxTextMax + 1];
} NowAxText;

/* Reads the dialog's TextEdit contents. Returns kNowAxNotFound when the
   window is not a dialog, or is one with no TextEdit record - which is
   an answer, not a failure. */
int now_ax_read_dialog_text(const NowAxMemory *memory, unsigned long window,
                            NowAxText *out);

#endif /* NOW_AXTEXT_H */
