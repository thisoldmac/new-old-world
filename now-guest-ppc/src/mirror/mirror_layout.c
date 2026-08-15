#include "mirror_layout.h"

#include <stdio.h>
#include <string.h>

#include "resident_version.h"

static Rect row(Rect body, short top)
{
    Rect value;
    value.left = (short)(body.left + kMirrorMargin);
    value.right = (short)(body.right - kMirrorMargin);
    value.top = top;
    value.bottom = (short)(top + kMirrorRowHeight);
    return value;
}

void now_mirror_layout_compute(const Rect *body, MirrorLayout *out)
{
    short y;
    int i;

    memset(out, 0, sizeof *out);
    y = (short)(body->top + kMirrorMargin);
    out->heading = row(*body, y);
    y = (short)(y + kMirrorHeadingHeight);
    for (i = 0; i < kMirrorLifecycleRows; ++i) {
        out->lifecycle_rows[i] = row(*body, y);
        y = (short)(y + kMirrorRowHeight);
    }
    y = (short)(y + 8);
    out->plane_heading = row(*body, y);
    y = (short)(y + kMirrorHeadingHeight);
    for (i = 0; i < kMirrorPlaneCount; ++i) {
        out->plane_rows[i] = row(*body, y);
        y = (short)(y + kMirrorRowHeight);
    }
    y = (short)(y + 8);
    out->policy_heading = row(*body, y);
    y = (short)(y + kMirrorHeadingHeight);
    out->consent_row = row(*body, y);
    out->consent_row.bottom = (short)(y + kMirrorPolicyRowHeight);
    y = (short)(y + kMirrorPolicyRowHeight);
    out->consent_note = row(*body, y);
    y = (short)(y + kMirrorRowHeight);
    out->policy_status = row(*body, y);
    y = (short)(y + kMirrorRowHeight + 6);
    out->show_button = row(*body, y);
    out->show_button.right = (short)(out->show_button.left
                                     + kMirrorButtonWidth);
    out->show_button.bottom = (short)(y + kMirrorButtonHeight);
    y = (short)(y + kMirrorButtonHeight + 4);
    out->show_status = row(*body, y);
    y = (short)(y + kMirrorRowHeight + 6);
    for (i = 0; i < kMirrorNoteLines; ++i) {
        out->note[i] = row(*body, y);
        y = (short)(y + kMirrorRowHeight);
    }
}

void now_mirror_lifecycle_text(const MirrorFacts *facts, char *out, long cap)
{
    switch (facts->lifecycle) {
    case kMirrorLifecycleNeedsRestart:
        snprintf(out, (size_t)cap,
                 "Installed. Restart this Mac to activate NOW Extension.");
        break;
    case kMirrorLifecycleWrongVersion:
        snprintf(out, (size_t)cap,
                 "NOW Extension version %lu is incompatible with this app.",
                 facts->resident_major);
        break;
    case kMirrorLifecycleActive:
        if (facts->resident_major != NOW_RESIDENT_VERSION_MAJOR
            || facts->resident_minor != NOW_RESIDENT_VERSION_MINOR) {
            snprintf(out, (size_t)cap,
                     "Warning: extension %lu.%lu is active; this app "
                     "expects %d.%d.", facts->resident_major,
                     facts->resident_minor, NOW_RESIDENT_VERSION_MAJOR,
                     NOW_RESIDENT_VERSION_MINOR);
        } else {
            snprintf(out, (size_t)cap, "NOW Extension is active.");
        }
        break;
    case kMirrorLifecycleDegraded:
        snprintf(out, (size_t)cap,
                 "NOW Extension is active but degraded%s%s.",
                 facts->reason[0] ? ": " : "", facts->reason);
        break;
    case kMirrorLifecycleAbsent:
    default:
        snprintf(out, (size_t)cap, "NOW Extension is not installed.");
        break;
    }
}

/* **ONE row per plane, and the array is UNSIZED on purpose.**
 *
 * Two arrays sized `[kMirrorPlaneCount]` with four initialisers each is
 * how P5 came to be drawn from one element past the end of both: C fills
 * the missing row with a null pointer and says nothing. Leaving the bound
 * off makes the TABLE the length it actually is, and the assert below
 * compares that length against the enumeration — so a plane added to one
 * and not the other fails the build on both compilers rather than
 * rendering as a blank line.
 *
 * The purposes are the resident's own words for these planes, so a
 * person reading the page and a person reading a `mirror` reply are
 * reading one vocabulary. */
typedef struct MirrorPlaneLabel {
    const char *name;
    const char *purpose;
} MirrorPlaneLabel;

static const MirrorPlaneLabel k_plane_labels[] = {
    { "Structure",   "windows and menus" },
    { "Semantics",   "native control meaning" },
    { "Content",     "data-driven contents" },
    { "Interaction", "keyboard and mouse input" },
    { "Transitions", "transitions a poll is too slow to see" }
};

_Static_assert(sizeof k_plane_labels / sizeof k_plane_labels[0]
                   == kMirrorPlaneCount,
               "every MirrorPlane needs a name and a purpose: this table "
               "and the enumeration are one list, and the four-row "
               "version of it drew P5 from past its own end");

/* Range-checked, and the empty string is the honest answer rather than a
   read of whatever follows the table. Belt to the assert's braces: the
   assert covers the table, this covers a plane index that came off the
   wire. */
static const MirrorPlaneLabel *label_for(MirrorPlane plane)
{
    static const MirrorPlaneLabel none = { "", "" };

    if ((int)plane < 0 || (int)plane >= kMirrorPlaneCount) {
        return &none;
    }
    return &k_plane_labels[(int)plane];
}

const char *now_mirror_plane_name(MirrorPlane plane)
{
    return label_for(plane)->name;
}

const char *now_mirror_plane_purpose(MirrorPlane plane)
{
    return label_for(plane)->purpose;
}

void now_mirror_plane_value(const MirrorFacts *facts, MirrorPlane plane,
                            char *out, long cap)
{
    const MirrorPlaneFact *value = &facts->planes[(int)plane];

    switch (value->state) {
    case kMirrorPlaneInactive:
        snprintf(out, (size_t)cap, "Available, not requested");
        break;
    case kMirrorPlaneRequested:
        snprintf(out, (size_t)cap, "Requested, waiting for resident");
        break;
    case kMirrorPlaneRefused:
        snprintf(out, (size_t)cap, "Refused%s%s",
                 value->reason[0] ? ": " : "", value->reason);
        break;
    case kMirrorPlaneDegraded:
        snprintf(out, (size_t)cap, "Degraded%s%s",
                 value->reason[0] ? ": " : "", value->reason);
        break;
    case kMirrorPlaneActiveStale:
        snprintf(out, (size_t)cap, "Active, stale, format %lu", value->format);
        break;
    case kMirrorPlaneActiveCurrent:
        snprintf(out, (size_t)cap, "Active, current, format %lu", value->format);
        break;
    case kMirrorPlaneUnsupported:
    default:
        snprintf(out, (size_t)cap, "Unsupported");
        break;
    }
}

void now_mirror_consent_note(Boolean enabled, const char *peer, char *out,
                             long cap)
{
    const char *name = (peer != NULL && peer[0] != '\0') ? peer : "Other Mac";

    /* Both sentences name the OTHER half out loud. Off, a person needs to
       know that turning it on is not the whole story; on, they need to
       know that "on" is a permission and not a capture — the host still
       chooses which planes, and a switch that read as "everything is
       being watched" would be a lie in the safer-sounding direction. */
    if (enabled) {
        snprintf(out, (size_t)cap,
                 "%.40s decides which planes are captured.", name);
    } else {
        snprintf(out, (size_t)cap,
                 "%.40s cannot mirror this Mac while this is off.", name);
    }
}

const char *now_mirror_note(int line)
{
    static const char *notes[kMirrorNoteLines] = {
        "Apps not yet observed stay as window skeletons until they pump."
    };
    return line >= 0 && line < kMirrorNoteLines ? notes[line] : "";
}

void now_mirror_status_text(const MirrorFacts *facts, char *out, long cap)
{
    now_mirror_lifecycle_text(facts, out, cap);
}

/*
 * What this machine is still HOLDING, in a sentence.
 *
 * The order is by how hard each thing is to undo, worst first, because a
 * person reading one line reads the front of it. Trap patches lead: they
 * are in this machine's dispatch table until it restarts, since
 * unpatching from the middle of a chain another extension may have joined
 * is unsafe — so "Restart to clear" is the honest end of that sentence
 * and it is the only place on this page those words appear.
 *
 * "Nothing but the event hook" is the resting answer and it is stated
 * positively rather than as an empty list, because an empty list reads
 * like a question that failed. The event hook is always there and saying
 * so is not an apology: it is what would notice the next arm.
 */
void now_mirror_rest_text(const MirrorFacts *facts, char *out, long cap)
{
    unsigned long bits;
    int n = 0;

    if (cap <= 0) {
        return;
    }
    out[0] = '\0';
    /* A resident too old to carry the word must not be reported as
       holding nothing. "Did not say" and "nothing" are opposite claims
       and the reassuring one would be the invented one. */
    if (!facts->has_rest_state) {
        snprintf(out, (size_t)cap, "This resident does not report it");
        return;
    }
    bits = facts->rest_state;
    if ((bits & kNowPeekRestCursorTrackingPatched) != 0) {
        n += snprintf(out + n, (size_t)(cap - n),
                      "%sCursor tracking patched (restart to clear)",
                      n > 0 ? ", " : "");
    }
    if ((bits & kNowPeekRestActPatched) != 0 && n < cap) {
        if (n > 0) {
            n += snprintf(out + n, (size_t)(cap - n),
                          ", act traps patched (restart to clear)");
        } else {
            n += snprintf(out + n, (size_t)(cap - n),
                          "Trap patches in (restart to clear)");
        }
    }
    if ((bits & kNowPeekRestQDExtPatched) != 0 && n < cap) {
        n += snprintf(out + n, (size_t)(cap - n), "%sNewGWorld patched",
                      n > 0 ? ", " : "");
    }
    if ((bits & kNowPeekRestContentHooks) != 0 && n < cap) {
        n += snprintf(out + n, (size_t)(cap - n), "%sdraw hooks live",
                      n > 0 ? ", " : "");
    }
    if ((bits & kNowPeekRestLivenessTicking) != 0 && n < cap) {
        n += snprintf(out + n, (size_t)(cap - n), "%sliveness ticking",
                      n > 0 ? ", " : "");
    }
    if ((bits & kNowPeekRestTransport) != 0 && n < cap) {
        n += snprintf(out + n, (size_t)(cap - n), "%sMacTCP stream open",
                      n > 0 ? ", " : "");
    }
    if (n == 0) {
        /* The block is not listed as a holding when it is the only one:
           it is allocated on every machine that has the plane at all, so
           naming it here would make the resting state look busy. Zero versus
           nonzero keeps the diagnostic distinction without turning a live
           pass counter into a once-per-second repaint clock. */
        snprintf(out, (size_t)cap, "Nothing but the event hook (%s)",
                 facts->gne_passes == 0 ? "not yet observed" : "running");
    }
}

int now_mirror_display_equal(const MirrorFacts *a, const MirrorFacts *b)
{
    int i;

    if (a == NULL || b == NULL) {
        return 0;
    }
    if (a->lifecycle != b->lifecycle
        || a->resident_major != b->resident_major
        || a->resident_minor != b->resident_minor
        || a->capabilities != b->capabilities
        || a->requested_bits != b->requested_bits
        || a->active_bits != b->active_bits
        || a->has_build_identity != b->has_build_identity
        || a->has_rest_state != b->has_rest_state
        || a->rest_state != b->rest_state
        || (a->gne_passes == 0) != (b->gne_passes == 0)
        || strcmp(a->reason, b->reason) != 0) {
        return 0;
    }
    for (i = 0; i < kMirrorPlaneCount; ++i) {
        const MirrorPlaneFact *left = &a->planes[i];
        const MirrorPlaneFact *right = &b->planes[i];

        if (left->state != right->state
            || left->format != right->format
            || strcmp(left->reason, right->reason) != 0) {
            return 0;
        }
    }
    return 1;
}
