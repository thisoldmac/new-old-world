#include "mirror_layout.h"

#include <stdio.h>
#include <string.h>

/* Plain field assignment throughout: SetRect is Toolbox, and this file
   also runs under the host's cc. */
static void set_rect(Rect *r, short left, short top, short right,
                     short bottom)
{
    r->left = left;
    r->top = top;
    r->right = right;
    r->bottom = bottom;
}

void now_mirror_layout_compute(const Rect *body, MirrorLayout *out)
{
    short left = (short)(body->left + kMirrorMargin);
    short right = (short)(body->right - kMirrorMargin);
    short y = (short)(body->top + kMirrorMargin);
    int i;

    set_rect(&out->ext_heading, left, y, right,
             (short)(y + kMirrorHeadingHeight));
    y = out->ext_heading.bottom;
    for (i = 0; i < kMirrorExtCount; ++i) {
        set_rect(&out->ext_rows[i], left, y, right,
                 (short)(y + kMirrorRowHeight));
        y = out->ext_rows[i].bottom;
    }
    for (i = 0; i < kMirrorExtNoteLines; ++i) {
        set_rect(&out->ext_note[i], left, y, right,
                 (short)(y + kMirrorLineHeight));
        y = out->ext_note[i].bottom;
    }

    y = (short)(y + kMirrorSectionGap);
    set_rect(&out->agent_heading, left, y, right,
             (short)(y + kMirrorHeadingHeight));
    y = out->agent_heading.bottom;
    for (i = 0; i < kMirrorAgentRows; ++i) {
        set_rect(&out->agent_rows[i], left, y, right,
                 (short)(y + kMirrorRowHeight));
        y = out->agent_rows[i].bottom;
    }

    /* The buttons sit under the rows they act on, in reading order, and
       at a fixed size: a push button is a real control and the Control
       Manager draws it, so the layout gives it the metrics rather than
       stretching it to the pane. */
    y = (short)(y + kMirrorButtonTop);
    set_rect(&out->enable, left, y, (short)(left + kMirrorButtonWidth),
             (short)(y + kMirrorButtonHeight));
    set_rect(&out->disable,
             (short)(out->enable.right + kMirrorButtonGap), y,
             (short)(out->enable.right + kMirrorButtonGap
                     + kMirrorButtonWidth),
             (short)(y + kMirrorButtonHeight));
    y = out->enable.bottom;

    y = (short)(y + kMirrorNoteGap);
    for (i = 0; i < kMirrorNoteLines; ++i) {
        set_rect(&out->note[i], left, y, right,
                 (short)(y + kMirrorLineHeight));
        y = out->note[i].bottom;
    }
}

/* --- the extension half --------------------------------------------- */

const char *now_mirror_ext_name(MirrorExt which)
{
    switch (which) {
    case kMirrorExtAX:     return "AXPeek";
    case kMirrorExtQD:     return "QDPeek";
    default:               return "Portal";
    }
}

const char *now_mirror_ext_what(MirrorExt which)
{
    /* Mirror's own names for these are internal ones. What a person needs
       is what stops working when the row says absent. */
    switch (which) {
    case kMirrorExtAX:     return "reads window and menu structure";
    case kMirrorExtQD:     return "records what applications draw";
    default:               return "delivers clicks and menu choices";
    }
}

void now_mirror_ext_value(const MirrorFacts *facts, MirrorExt which,
                          char *out, long cap)
{
    int i = (int)which;

    switch (facts->ext_state[i]) {
    case kMirrorExtResident:
        snprintf(out, (size_t)cap, "Resident, version %lu - %s",
                 facts->ext_version[i], now_mirror_ext_what(which));
        break;
    case kMirrorExtOtherVersion:
        /* Loaded, and not one this build was written against. Naming the
           version is the whole value of the row: it turns "Mirror is
           broken" into "that machine is running an older extension". */
        snprintf(out, (size_t)cap,
                 "Resident, but version %lu is not one this page knows",
                 facts->ext_version[i]);
        break;
    default:
        snprintf(out, (size_t)cap, "Not loaded - %s",
                 now_mirror_ext_what(which));
        break;
    }
}

const char *now_mirror_ext_note(int line)
{
    /* The load-bearing sentences on this page. The first says what
       "not loaded" actually means, because the two causes need different
       actions from the person reading it; the second forecloses the
       question the three rows raise. */
    switch (line) {
    case 0:
        return "An extension is loaded only at startup. Not loaded means "
               "it is not installed, or this Mac";
    case 1:
        return "has not restarted since it was. Nothing can switch one on "
               "or off while the Mac is running.";
    default:
        return "";
    }
}

/* --- the agent half -------------------------------------------------- */

int now_mirror_agent_row(const MirrorFacts *facts, int index,
                         char *label, long label_cap,
                         char *value, long value_cap)
{
    label[0] = '\0';
    value[0] = '\0';
    switch (index) {
    case 0:
        snprintf(label, (size_t)label_cap, "State");
        switch (facts->agent) {
        case kMirrorAgentRunning:
            snprintf(value, (size_t)value_cap, "Running");
            break;
        case kMirrorAgentStopped:
            snprintf(value, (size_t)value_cap, "Not running");
            break;
        default:
            /* Not "not running": nothing is there to run, and the two
               want different things done about them. */
            snprintf(value, (size_t)value_cap,
                     "Not installed - no agent where Mirror stages it");
            break;
        }
        return 1;
    case 1:
        snprintf(label, (size_t)label_cap, "Program");
        snprintf(value, (size_t)value_cap, "%.110s",
                 facts->agent_path[0] != '\0' ? facts->agent_path
                                              : "unknown");
        return 1;
    case 2:
        snprintf(label, (size_t)label_cap, "Signature");
        if (facts->agent == kMirrorAgentRunning
            && facts->agent_sig[0] != '\0') {
            /* Reported, not matched on. Mirror's agent is built by
               Retro68 and carries the default creator, so a signature is
               not an identity here - it is a fact worth showing beside
               one. What this page matches on is the file itself; see
               mirror_probe.c. */
            snprintf(value, (size_t)value_cap, "'%.4s' (Mirror sets none)",
                     facts->agent_sig);
        } else {
            snprintf(value, (size_t)value_cap, "-");
        }
        return 1;
    default:
        return 0;
    }
}

Boolean now_mirror_can_enable(const MirrorFacts *facts)
{
    return (Boolean)(facts->agent == kMirrorAgentStopped);
}

Boolean now_mirror_can_disable(const MirrorFacts *facts)
{
    return (Boolean)(facts->agent == kMirrorAgentRunning);
}

/* --- the note ------------------------------------------------------- */

/* One line's worth of `text` from `from`, broken at a space. Returns
   where the next line starts, or the length when there is no more. The
   budget is characters rather than pixels because this file has no port;
   the module still passes every drawn line through TruncString, so a
   narrow window shortens rather than overflows. */
enum { kMirrorNoteChars = 84 };

static long wrap_at(const char *text, long from, char *out, long cap)
{
    long len = (long)strlen(text);
    long take;
    long i;

    out[0] = '\0';
    if (from >= len) {
        return len;
    }
    take = len - from;
    if (take > kMirrorNoteChars) {
        take = kMirrorNoteChars;
        for (i = take; i > 0; --i) {
            if (text[from + i] == ' ') {
                take = i;
                break;
            }
        }
    }
    if (take > cap - 1) {
        take = cap - 1;
    }
    memcpy(out, text + from, (size_t)take);
    out[take] = '\0';
    from += take;
    while (text[from] == ' ') {
        ++from;
    }
    return from;
}

long now_mirror_note_line(const MirrorFacts *facts, int line, char *out,
                          long cap)
{
    long at = 0;
    int i;

    out[0] = '\0';
    if (facts->note[0] == '\0' || line < 0 || line >= kMirrorNoteLines) {
        return 0;
    }
    for (i = 0; i <= line; ++i) {
        at = wrap_at(facts->note, at, out, cap);
    }
    return (long)strlen(out);
}

/* --- the placard ----------------------------------------------------- */

void now_mirror_status_text(const MirrorFacts *facts, char *out, long cap)
{
    int resident = 0;
    int i;

    for (i = 0; i < kMirrorExtCount; ++i) {
        if (facts->ext_state[i] == kMirrorExtResident
            || facts->ext_state[i] == kMirrorExtOtherVersion) {
            ++resident;
        }
    }
    /* Both halves, because either one alone reads as a working Mirror
       when it is not: the agent answers Mirror's wire, the extensions are
       what it has to answer with. */
    snprintf(out, (size_t)cap, "Agent %s; %d of %d extensions loaded.",
             facts->agent == kMirrorAgentRunning ? "running"
                 : (facts->agent == kMirrorAgentNoFile ? "not installed"
                                                       : "not running"),
             resident, (int)kMirrorExtCount);
}
