/* Re-proving a reference against the machine. See obsresolve.h. */

#include "obsresolve.h"

#include <string.h>

static int address_seen(const unsigned long *seen, unsigned int count,
                        unsigned long address)
{
    unsigned int i;

    for (i = 0; i < count; i++) {
        if (seen[i] == address) {
            return 1;
        }
    }
    return 0;
}

int now_obs_resolve_window(const NowAxMemory *memory,
                           unsigned long window_list, const NowAxRef *ref,
                           NowAxResolved *out)
{
    unsigned long seen[kNowAxResolveMaxWindows];
    unsigned long address = window_list;
    unsigned int  count = 0;
    unsigned int  matching = 0;
    unsigned int  visible_count = 0;

    if (memory == NULL || ref == NULL || out == NULL) {
        return kNowAxInvalid;
    }
    memset(out, 0, sizeof(*out));
    while (address != 0) {
        NowAxWindow  window;
        unsigned int visible_z;
        int          rc;

        if (count >= (unsigned int)kNowAxResolveMaxWindows) {
            return kNowAxResolveNotFound;
        }
        if (address_seen(seen, count, address)) {
            return kNowAxResolveCycle;
        }
        seen[count] = address;
        rc = now_ax_read_window(memory, address, &window);
        if (rc != kNowAxOk) {
            return rc;
        }
        visible_z = visible_count;
        if (window.visible) {
            visible_count++;
        }
        if (window.title_len == ref->window_title_len
            && memcmp(window.title, ref->window_title,
                      ref->window_title_len) == 0
            && matching++ == ref->window_occurrence) {
            out->window_address = address;
            out->control_handle = 0;
            out->window_z = count;
            out->visible_window_z = visible_z;
            out->window = window;
            /* The same test the control path makes, with a zero control
               handle - a window reference is minted against exactly that
               pair, so a window at a new address is Stale for the same
               reason and by the same arithmetic. */
            if (ref->node_fingerprint
                != now_ax_ref_fingerprint(ref->psn_hi, ref->psn_lo,
                                          address, 0UL)) {
                return kNowAxResolveStale;
            }
            return kNowAxResolveOk;
        }
        count++;
        address = window.next_window;
    }
    return kNowAxResolveNotFound;
}

/* The one place a `why` becomes a verdict. A table rather than a
   judgement at each call site: the mapping IS the policy, and a policy
   spread over fifteen returns is a policy that drifts. */
static NowObsVerdict verdict_for(NowObsWhy why)
{
    switch (why) {
    case kNowObsWhyNone:
        return kNowObsOk;
    case kNowObsWhyOracleAmbiguous:
        return kNowObsAmbiguous;
    case kNowObsWhyOracleMismatch:
    case kNowObsWhyProcessRecycled:
        return kNowObsMismatch;
    case kNowObsWhyAddressesMoved:
        return kNowObsStale;
    case kNowObsWhyMalformed:
    case kNowObsWhyUnminted:
    case kNowObsWhyNoProcess:
    case kNowObsWhyNoPlane:
    case kNowObsWhyNoAnchor:
    case kNowObsWhyUnreadable:
    case kNowObsWhyNoWindowList:
    case kNowObsWhyElementGone:
    case kNowObsWhyCycle:
    case kNowObsWhyUnreadableRecord:
        break;
    }
    return kNowObsNotFound;
}

static void refuse(NowObsResolution *out, NowObsWhy why)
{
    memset(out, 0, sizeof(*out));
    out->why = why;
    out->verdict = verdict_for(why);
}

static NowObsWhy why_for_bind(NowObsBindStatus bind)
{
    switch (bind) {
    case kNowObsBindOk:
        return kNowObsWhyNone;
    case kNowObsBindNoProcess:
        return kNowObsWhyNoProcess;
    case kNowObsBindNoPlane:
        return kNowObsWhyNoPlane;
    case kNowObsBindNoAnchor:
        return kNowObsWhyNoAnchor;
    case kNowObsBindAmbiguous:
        return kNowObsWhyOracleAmbiguous;
    case kNowObsBindMismatch:
        return kNowObsWhyOracleMismatch;
    case kNowObsBindUnreadable:
        break;
    }
    return kNowObsWhyUnreadable;
}

static NowObsWhy why_for_walk(int rc)
{
    switch (rc) {
    case kNowAxResolveOk:
        return kNowObsWhyNone;
    case kNowAxResolveStale:
        return kNowObsWhyAddressesMoved;
    case kNowAxResolveCycle:
        return kNowObsWhyCycle;
    case kNowAxResolveNotFound:
        return kNowObsWhyElementGone;
    default:
        break;
    }
    /* Everything else is the walk's own vocabulary for "these bytes are
       not a window record" - a read the seam refused, a pointer that
       failed validation. It is not the caller's reference that is wrong,
       so it gets its own reason. */
    return kNowObsWhyUnreadableRecord;
}

void now_obs_resolve(const NowObsRegistry *registry, NowObsKind kind,
                     const char *text, size_t len, const NowObsLive *live,
                     NowObsResolution *out)
{
    const NowObsEntry *entry;
    NowObsWhy          why;
    NowAxResolved      resolved;
    int                rc;

    if (out == NULL) {
        return;
    }
    if (registry == NULL || live == NULL) {
        refuse(out, kNowObsWhyMalformed);
        return;
    }
    /* Shape first, so a caller that sent nonsense is told THAT rather
       than "no such element" - the two are different bugs and only one
       of them is about the machine's state. */
    if (!now_obs_token_valid(kind, text, len)) {
        refuse(out, kNowObsWhyMalformed);
        return;
    }
    entry = now_obs_lookup(registry, kind, text, len);
    if (entry == NULL) {
        refuse(out, kNowObsWhyUnminted);
        return;
    }

    why = why_for_bind(live->bind);
    if (why != kNowObsWhyNone) {
        refuse(out, why);
        return;
    }

    /* The recycled-PSN check, BEFORE the walk. Doing it after would mean
       walking a stranger's heap first and only then noticing it was a
       stranger's, and the walk is the dangerous half. */
    if (live->process_fingerprint != entry->identity.process_fingerprint) {
        refuse(out, kNowObsWhyProcessRecycled);
        return;
    }
    if (live->window_list == 0) {
        refuse(out, kNowObsWhyNoWindowList);
        return;
    }
    if (live->memory == NULL) {
        refuse(out, kNowObsWhyUnreadable);
        return;
    }

    /* WHICH WALK, and the test is the identity rather than the kind. An
       element reference with no control handle names a TEXT element - a
       dialog's own TextEdit record - which is reached through its window
       and has no control title to match on. Sending it down the control
       walk would look for a control with an empty title and find the
       first untitled one, which is precisely the "answers to the same
       name" failure the fingerprint exists to refuse. So it takes the
       window walk, whose fingerprint is computed against a zero control
       handle - exactly what it was minted with. */
    if (kind == kNowObsKindWindow
        || entry->identity.control_handle == 0) {
        rc = now_obs_resolve_window(live->memory, live->window_list,
                                    &entry->identity.ref, &resolved);
    } else {
        rc = now_ax_resolve_ref(live->memory, live->window_list,
                                &entry->identity.ref, &resolved);
    }
    why = why_for_walk(rc);
    if (why != kNowObsWhyNone) {
        refuse(out, why);
        return;
    }

    /* Belt and braces, and it is not redundant: the walk proves the
       reference's OWN fingerprint, this proves the addresses it landed
       on are the ones the registry recorded. They agree unless something
       has written to the entry, and a reference layer that cannot detect
       its own table being wrong has no business dispatching an act. */
    if (resolved.window_address != entry->identity.window_address
        || resolved.control_handle != entry->identity.control_handle) {
        refuse(out, kNowObsWhyAddressesMoved);
        return;
    }

    memset(out, 0, sizeof(*out));
    out->verdict = kNowObsOk;
    out->why = kNowObsWhyNone;
    out->resolved = resolved;
}

const char *now_obs_verdict_name(NowObsVerdict verdict)
{
    switch (verdict) {
    case kNowObsOk:        return "ok";
    case kNowObsNotFound:  return "not-found";
    case kNowObsAmbiguous: return "ambiguous";
    case kNowObsMismatch:  return "mismatch";
    case kNowObsStale:     return "stale";
    }
    return "not-found";
}

const char *now_obs_why_text(NowObsWhy why)
{
    switch (why) {
    case kNowObsWhyNone:
        return "the reference still names this element";
    case kNowObsWhyMalformed:
        return "not a well-formed reference of this kind";
    case kNowObsWhyUnminted:
        return "no observation minted this reference, or it has expired";
    case kNowObsWhyNoProcess:
        return "the process this reference names is no longer running";
    case kNowObsWhyNoPlane:
        return "the anchor plane is absent or not armed";
    case kNowObsWhyNoAnchor:
        return "the process has not pumped its event loop since arming";
    case kNowObsWhyOracleAmbiguous:
        return "two anchor slots claim this partition and nothing "
               "distinguishes them";
    case kNowObsWhyOracleMismatch:
        return "the anchor claiming this partition describes a different "
               "address space";
    case kNowObsWhyUnreadable:
        return "the process bound, but its anchor's own pointers failed "
               "validation";
    case kNowObsWhyProcessRecycled:
        return "that process serial number now belongs to a different "
               "program";
    case kNowObsWhyNoWindowList:
        return "the process has no windows";
    case kNowObsWhyElementGone:
        return "nothing in this process answers to that name any more";
    case kNowObsWhyCycle:
        return "the window or control chain points back at itself";
    case kNowObsWhyUnreadableRecord:
        return "a window or control record failed the memory boundary";
    case kNowObsWhyAddressesMoved:
        return "an element of that name exists, but it is not the one "
               "this reference was minted against";
    }
    return "refused";
}
