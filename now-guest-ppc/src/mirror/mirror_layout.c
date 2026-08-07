#include "mirror_layout.h"

#include <stdio.h>
#include <string.h>

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
    y = (short)(y + kMirrorSectionGap);
    out->plane_heading = row(*body, y);
    y = (short)(y + kMirrorHeadingHeight);
    for (i = 0; i < kMirrorPlaneCount; ++i) {
        out->plane_rows[i] = row(*body, y);
        y = (short)(y + kMirrorRowHeight);
    }
    y = (short)(y + kMirrorSectionGap);
    out->show_button = row(*body, y);
    out->show_button.right = (short)(out->show_button.left
                                     + kMirrorButtonWidth);
    out->show_button.bottom = (short)(y + kMirrorButtonHeight);
    y = (short)(y + kMirrorButtonHeight + kMirrorButtonGap);
    out->show_status = row(*body, y);
    y = (short)(y + kMirrorRowHeight + kMirrorSectionGap);
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
        snprintf(out, (size_t)cap, "NOW Extension is active.");
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

const char *now_mirror_note(int line)
{
    static const char *notes[kMirrorNoteLines] = {
        "These are observed guest facts. Mirror policy belongs to the host.",
        "The button asks that Mac to show its Mirror; policy stays there."
    };
    return line >= 0 && line < kMirrorNoteLines ? notes[line] : "";
}

void now_mirror_status_text(const MirrorFacts *facts, char *out, long cap)
{
    now_mirror_lifecycle_text(facts, out, cap);
}
