#ifndef NOW_MIRROR_LAYOUT_H
#define NOW_MIRROR_LAYOUT_H

#include "mirror_facts.h"

/* Rectangle arithmetic and sentence choice for the Mirror page. No
   Toolbox calls, so this compiles under the host's cc for
   now-guest-ppc/tests/mirror_layout_test.c - the pattern mcp_layout.c
   set, and for the same reason: the page is small enough that its whole
   argument is which words appear beside which state.

   TWO HALVES, AND THEY ARE NOT SYMMETRIC. The extensions are read-only
   because the system loads them at startup and nothing can load one
   afterwards. The agent is an application, so it starts and stops like
   one. Drawing those two halves the same way would be the lie; the page
   draws the second with buttons and the first with a sentence saying why
   it has none. */

enum {
    kMirrorMargin = 14,
    kMirrorHeadingHeight = 17,
    kMirrorLineHeight = 15,
    kMirrorRowHeight = 15,
    kMirrorLabelWidth = 108,      /* "Portal" and "Signature" both fit */
    kMirrorSectionGap = 14,
    kMirrorButtonTop = 8,         /* last agent row to the button band */
    kMirrorButtonWidth = 86,
    kMirrorButtonHeight = 20,
    kMirrorButtonGap = 10,
    kMirrorNoteGap = 12,
    kMirrorExtNoteLines = 2
};

typedef struct MirrorLayout {
    Rect ext_heading;
    Rect ext_rows[kMirrorExtCount];
    Rect ext_note[kMirrorExtNoteLines];   /* why there is no switch here */
    Rect agent_heading;
    Rect agent_rows[kMirrorAgentRows];
    Rect enable;                          /* real push buttons */
    Rect disable;
    Rect note[kMirrorNoteLines];          /* the last action's outcome */
} MirrorLayout;

void now_mirror_layout_compute(const Rect *body, MirrorLayout *out);

/* --- what the page says -------------------------------------------- */

const char *now_mirror_ext_name(MirrorExt which);

/* The one thing this extension is for, in a person's words rather than
   Mirror's. The row has to mean something to somebody who has never read
   Mirror's documentation. */
const char *now_mirror_ext_what(MirrorExt which);

/* The row's value column. Always a sentence, never a blank: an absent
   fact is reported as absent. */
void now_mirror_ext_value(const MirrorFacts *facts, MirrorExt which,
                          char *out, long cap);

/* The two lines under the extension rows. They carry the whole reason the
   rows have no controls, so they are not decoration and are not
   truncated away first. */
const char *now_mirror_ext_note(int line);

/* Row `index` of the agent half as a label/value pair. Returns 0 when
   there is no such row. */
int now_mirror_agent_row(const MirrorFacts *facts, int index,
                         char *label, long label_cap,
                         char *value, long value_cap);

/* Whether each button can do anything right now. A button that cannot is
   dimmed rather than hidden: the page is also a statement of what is
   possible here, and a control that vanishes teaches nobody. */
Boolean now_mirror_can_enable(const MirrorFacts *facts);
Boolean now_mirror_can_disable(const MirrorFacts *facts);

/* The last action's outcome, wrapped over kMirrorNoteLines lines.
   Returns the length written, 0 for a line with nothing on it. */
long now_mirror_note_line(const MirrorFacts *facts, int line, char *out,
                          long cap);

/* The bottom placard: both halves in one line. */
void now_mirror_status_text(const MirrorFacts *facts, char *out, long cap);

#endif /* NOW_MIRROR_LAYOUT_H */
