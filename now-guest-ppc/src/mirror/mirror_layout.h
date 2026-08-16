#ifndef NOW_MIRROR_LAYOUT_H
#define NOW_MIRROR_LAYOUT_H

#include "mirror_facts.h"

enum {
    kMirrorMargin = 14,
    kMirrorHeadingHeight = 17,
    kMirrorRowHeight = 16,
    kMirrorLabelWidth = 116,
    kMirrorSectionGap = 12,
    /* Five since 2026-08-07. The fifth is "Installed", and it is on this
       page rather than in a log because it is the one line that answers
       what a person actually wants to know before keeping a system
       extension: with nothing running, what is still hooked? The four
       above it are all about what the resident CAN do. */
    kMirrorLifecycleRows = 5,
    kMirrorNoteLines = 1,
    /* Platinum's checkbox row. One row since 2026-08-15, where there were
       four: the guest's granularity retired to the host and what is left
       is this Mac's consent. */
    kMirrorPolicyRowHeight = 18,
    /* The push button that opens the host's own Mirror window. Platinum's
       standard push-button height is 20 and a
       button wants a comfortable label width; both are here rather than
       in the module so the geometry has one home the native test can
       compile. */
    kMirrorButtonWidth = 168,
    kMirrorButtonHeight = 20,
    kMirrorButtonGap = 10
};

typedef struct MirrorLayout {
    Rect heading;
    Rect lifecycle_rows[kMirrorLifecycleRows];
    Rect plane_heading;
    Rect plane_rows[kMirrorPlaneCount];
    Rect policy_heading;
    Rect consent_row;
    /* The sentence under the checkbox that says where the REST of the
       decision is made. It is on the page rather than in the manual
       because "on" here does not mean "everything is being captured",
       and a consent switch that overstates what it grants is the one
       mistake this page cannot afford. */
    Rect consent_note;
    Rect policy_status;
    Rect note[kMirrorNoteLines];
    /* Where the "Show Mirror on Host" button goes, and the status line
       under it that carries the host's own answer. */
    Rect show_button;
    Rect show_status;
} MirrorLayout;

void now_mirror_layout_compute(const Rect *body, MirrorLayout *out);
void now_mirror_lifecycle_text(const MirrorFacts *facts, char *out, long cap);
const char *now_mirror_plane_name(MirrorPlane plane);
const char *now_mirror_plane_purpose(MirrorPlane plane);
void now_mirror_plane_value(const MirrorFacts *facts, MirrorPlane plane,
                            char *out, long cap);
const char *now_mirror_note(int line);
/* The consent line under the checkbox, named for the machine that owns
   the other half of the decision. `peer` is `conn_peer_label()`'s answer
   — "Other Mac" when nothing is connected — and is never NULL. */
void now_mirror_consent_note(Boolean enabled, const char *peer, char *out,
                             long cap);
void now_mirror_status_text(const MirrorFacts *facts, char *out, long cap);
/* The "Installed" row's sentence. Toolbox-free and here rather than in
   the module, like every other string on this page, so the host `cc`
   compiles it and the native test can read what a person would read. */
void now_mirror_rest_text(const MirrorFacts *facts, char *out, long cap);

/* True when two snapshots would draw the same application-owned pixels.
   Resident heartbeat, liveness and generation counters deliberately do not
   participate: they are acquisition evidence, not text on this page, and
   comparing the whole struct made their normal motion repaint the page once
   per poll. */
int now_mirror_display_equal(const MirrorFacts *a, const MirrorFacts *b);

#endif /* NOW_MIRROR_LAYOUT_H */
