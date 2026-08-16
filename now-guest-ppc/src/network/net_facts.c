#include "net_facts.h"

#include <stdio.h>
#include <string.h>

void now_net_facts_clear(NetFacts *out)
{
    if (out == NULL) {
        return;
    }
    memset(out, 0, sizeof *out);
    /* Not-served rather than present: a cleared NetFacts describes a Mac
       nobody has asked yet, and every field must say that rather than
       reading as a machine with no address, no ports and no link. The
       zero VALUE is the safe one only because these enums put the honest
       absence first. */
    out->ot = kNetFactNotServed;
    out->link.state = kNetFactNotServed;
    out->inet.state = kNetFactNotServed;
    out->ports_state = kNetFactNotServed;
    /* The one field whose value is known before any probe runs, and
       known permanently: no documented Open Transport call enumerates
       the machine's connections (docs/ot-networking-surface.md). */
    out->connections = kNetFactUndocumented;
}

const char *now_net_state_sentence(NetFactState state)
{
    switch (state) {
    case kNetFactPresent:
        return "";
    case kNetFactNoOT:
        /* Names the fix, because this one is actionable and the person
           reading it can do something about it today. */
        return "Open Transport is not available. CarbonLib 1.6 or later "
               "provides it.";
    case kNetFactRefused:
        return "This Mac was asked and declined.";
    case kNetFactNotServed:
        return "Not measured yet.";
    case kNetFactUndocumented:
        /* Deliberately about Open Transport, not about this Mac. A
           person reading "unavailable" concludes their machine is
           broken; the truth is that the question has no documented way
           to be asked, and the machine is fine. This is the Connections
           card's whole placard line now (see net_layout.c) - the
           card lost its separate blurb line, not this sentence its
           reassurance. */
        return "Open Transport publishes no way to list a Mac's "
               "connections. Nothing is wrong with this Mac.";
    }
    return "";
}

const char *now_net_state_token(NetFactState state)
{
    switch (state) {
    case kNetFactPresent:
        return "present";
    case kNetFactNoOT:
        return "noOpenTransport";
    case kNetFactRefused:
        return "refused";
    case kNetFactNotServed:
        return "notServed";
    case kNetFactUndocumented:
        return "undocumented";
    }
    return "unknown";
}

long now_net_format_ip(unsigned long addr, char *out, long cap)
{
    int n;

    if (out == NULL || cap <= 0) {
        return 0;
    }
    out[0] = '\0';
    /* OT hands an InetHost as a 32-bit value in HOST order, already
       byte-swapped for us, so this is a shift-and-mask rather than a
       byte walk. Getting that backwards produces a plausible-looking
       address, which is why it is pinned by test rather than trusted. */
    n = snprintf(out, (size_t)cap, "%lu.%lu.%lu.%lu",
                 (addr >> 24) & 0xFFUL, (addr >> 16) & 0xFFUL,
                 (addr >> 8) & 0xFFUL, addr & 0xFFUL);
    if (n < 0) {
        out[0] = '\0';
        return 0;
    }
    if (n >= (int)cap) {
        return cap - 1;
    }
    return n;
}

void now_net_format_hw(const unsigned char *addr, long len,
                       char *out, long cap)
{
    long i;
    long need;

    if (out == NULL || cap <= 0) {
        return;
    }
    out[0] = '\0';
    if (addr == NULL || len <= 0) {
        return;
    }
    /* Two hex digits and a separator per byte, less the trailing
       separator, plus the terminator. Checked BEFORE writing rather than
       truncating mid-address: half a hardware address looks like a whole
       one and there is no way for a reader to tell. */
    need = len * 3;
    if (need > cap) {
        return;
    }
    for (i = 0; i < len; ++i) {
        snprintf(out + i * 3, (size_t)(cap - i * 3),
                 i + 1 < len ? "%02x:" : "%02x", (unsigned)addr[i]);
    }
}

void now_net_format_duration(unsigned long secs, char *out, long cap)
{
    unsigned long mins;
    unsigned long hours;

    if (out == NULL || cap <= 0) {
        return;
    }
    out[0] = '\0';
    /* Integer division throughout: a duration that rounds up to "1m"
       while the link has been up for four seconds is a small lie the
       page does not need to tell. */
    if (secs < 60UL) {
        snprintf(out, (size_t)cap, "%lus", secs);
        return;
    }
    mins = secs / 60UL;
    if (mins < 60UL) {
        snprintf(out, (size_t)cap, "%lum", mins);
        return;
    }
    hours = mins / 60UL;
    mins = mins % 60UL;
    if (mins == 0UL) {
        snprintf(out, (size_t)cap, "%luh", hours);
    } else {
        snprintf(out, (size_t)cap, "%luh %lum", hours, mins);
    }
}
