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

/* The State row when a process IS there. Running is only half the answer:
   the other half is which port that process was told to serve, and the
   two were one sentence on this page until a live agent bound a stale
   port and the row said "Running" about a machine nothing could reach. */
static void running_text(const MirrorFacts *facts, char *out, long cap)
{
    switch (facts->port_state) {
    case kMirrorPortNamed:
        snprintf(out, (size_t)cap, "Running, and mirror.port says port %ld",
                 facts->port);
        break;
    case kMirrorPortAbsent:
        snprintf(out, (size_t)cap,
                 "Running on %d, the agent's default - no mirror.port "
                 "beside it", (int)kMirrorAgentPort);
        break;
    case kMirrorPortUnusable:
        snprintf(out, (size_t)cap,
                 "Running on %d, the agent's default - mirror.port names "
                 "no usable port", (int)kMirrorAgentPort);
        break;
    default:
        /* No folder was resolved, so nothing was read - and a process
           whose file we never looked for gets no claim about its port. */
        snprintf(out, (size_t)cap, "Running");
        break;
    }
}

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
            running_text(facts, value, value_cap);
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
        snprintf(label, (size_t)label_cap, "Port");
        switch (facts->port_state) {
        case kMirrorPortNamed:
            /* The number, and where it came from. Flagging a port that is
               not Mirror's own is the one comparison neither machine
               makes for itself: every forward in this tree is wired to
               1420, so a file naming anything else is the signature of
               the defect that cost 2026-08-02. */
            if (facts->port == (long)kMirrorAgentPort) {
                snprintf(value, (size_t)value_cap,
                         "%ld, from mirror.port beside the agent",
                         facts->port);
            } else {
                snprintf(value, (size_t)value_cap,
                         "%ld, from mirror.port - not Mirror's usual %d",
                         facts->port, (int)kMirrorAgentPort);
            }
            break;
        case kMirrorPortAbsent:
            /* The agent's own read_port returns its compiled-in default
               when the file is missing, so this is a KNOWN port, not an
               unknown one. Saying so is the difference between a page
               that sends somebody to stage a file they do not need and
               one that tells them what will happen. */
            snprintf(value, (size_t)value_cap,
                     "%d, the agent's default - no mirror.port beside it",
                     (int)kMirrorAgentPort);
            break;
        case kMirrorPortUnusable:
            /* Same answer, for the same reason: read_port ignores a
               number outside its range and falls back to the default. */
            snprintf(value, (size_t)value_cap,
                     "%d, the agent's default - mirror.port names no port "
                     "between %d and %d, so the agent ignores it",
                     (int)kMirrorAgentPort, (int)kMirrorPortLow,
                     (int)kMirrorPortHigh);
            break;
        default:
            snprintf(value, (size_t)value_cap, "-");
            break;
        }
        return 1;
    case 2:
        snprintf(label, (size_t)label_cap, "Program");
        snprintf(value, (size_t)value_cap, "%.110s",
                 facts->agent_path[0] != '\0' ? facts->agent_path
                                              : "unknown");
        return 1;
    case 3:
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

/* Why pressing Enable would produce a process nobody can reach, or NULL
   when it would not. mirror_probe.c asks this BEFORE LaunchApplication,
   so the refusal is the launch not happening rather than a caveat under
   one that did.

   The button stays live and refuses out loud rather than going dim,
   which is the opposite of the choice the extension rows made and for
   the opposite reason: a dim extension row has a sentence beneath it
   saying why, and there is nowhere to put a sentence for a state a
   person can fix in a minute by staging one file. A dimmed Enable here
   would be a page that knows the cure and will not say it. */
Boolean now_mirror_enable_refusal(const MirrorFacts *facts, char *out,
                                  long cap)
{
    out[0] = '\0';
    (void)facts;
    (void)cap;
    /* NO PORT-BASED REFUSAL, and the two that used to be here were both
     * wrong about the machine.
     *
     * They rested on "the number is a property of a binary nobody here
     * can read". Read Mirror's own read_port (guest/app/src/main.c): a
     * MISSING file returns kDefaultPort, and a file naming anything
     * outside 1024..65535 ALSO returns kDefaultPort. There is no input
     * for which the agent binds something unknowable - it binds the
     * file's number when the file names a usable one, and 1420
     * otherwise. This side already knows that constant; it is
     * kMirrorAgentPort in mirror_facts.h, read from those same sources.
     *
     * So refusing to launch over a missing mirror.port stopped a launch
     * that would have worked, in front of somebody who had just copied
     * the agent next to the application and had every reason to expect
     * Enable to enable something. The honest fix is not a better refusal
     * sentence: it is to report the port the agent WILL serve - which
     * the port row now does, marking whether the number came from the
     * file or from the agent's own default - and to let the launch
     * happen.
     *
     * What the original caution was right about is kept elsewhere:
     * running and serving are still different facts, the page still
     * cannot see the port a RUNNING process actually bound, and the row
     * still says where its number came from. */
    return (Boolean)0;
}

Boolean now_mirror_can_disable(const MirrorFacts *facts)
{
    return (Boolean)(facts->agent == kMirrorAgentRunning);
}

/* --- the note ------------------------------------------------------- */

/* One line's worth of `text` from `from`, broken at a space. Returns
   where the next line starts, or the length when there is no more.
   kMirrorNoteChars is the budget, and kMirrorNoteMax is sized from it, so
   a note that fits its buffer fits the page. */
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
       what it has to answer with.

       A running agent carries its port here too. The placard is the line
       a person reads without opening the page, and "running" alone is
       the exact sentence that was true and useless. */
    if (facts->agent == kMirrorAgentRunning) {
        char where[48];

        if (facts->port_state == kMirrorPortNamed) {
            snprintf(where, sizeof where, "running on port %ld",
                     facts->port);
        } else {
            snprintf(where, sizeof where, "running, port unknown");
        }
        snprintf(out, (size_t)cap, "Agent %s; %d of %d extensions loaded.",
                 where, resident, (int)kMirrorExtCount);
        return;
    }
    snprintf(out, (size_t)cap, "Agent %s; %d of %d extensions loaded.",
             facts->agent == kMirrorAgentNoFile ? "not installed"
                                                : "not running",
             resident, (int)kMirrorExtCount);
}
