#include "mirror_json.h"

#include "json.h"
#include "mirror_anchor.h"
#include "peek_table.h"

#include <stdio.h>
#include <string.h>

static const char *lifecycle_word(MirrorLifecycle value)
{
    switch (value) {
    case kMirrorLifecycleNeedsRestart: return "needs-restart";
    case kMirrorLifecycleWrongVersion: return "wrong-version";
    case kMirrorLifecycleActive: return "active";
    case kMirrorLifecycleDegraded: return "degraded";
    case kMirrorLifecycleAbsent: break;
    }
    return "absent";
}

static const char *plane_id(MirrorPlane plane)
{
    static const char *ids[kMirrorPlaneCount] = {
        "structure", "semantics", "content", "interaction",
        "transitions"
    };
    return ids[(int)plane];
}

static const char *plane_purpose(MirrorPlane plane)
{
    static const char *purposes[kMirrorPlaneCount] = {
        "Window and menu structure",
        "Native control and list meaning",
        "Data-driven window content",
        "Keyboard and mouse mutation",
        "Transitions a poll is too slow to see"
    };
    return purposes[(int)plane];
}

static const char *freshness_word(MirrorFreshness value)
{
    switch (value) {
    case kMirrorFreshPending: return "pending";
    case kMirrorFreshStale: return "stale";
    case kMirrorFreshCurrent: return "current";
    case kMirrorFreshUnavailable: break;
    }
    return "unavailable";
}

static const char *plane_state_word(MirrorPlaneState value)
{
    switch (value) {
    case kMirrorPlaneInactive: return "inactive";
    case kMirrorPlaneRequested: return "requested";
    case kMirrorPlaneRefused: return "refused";
    case kMirrorPlaneDegraded: return "degraded";
    case kMirrorPlaneActiveStale: return "active-stale";
    case kMirrorPlaneActiveCurrent: return "active-current";
    case kMirrorPlaneUnsupported: break;
    }
    return "unsupported";
}

static void identity_hex(const unsigned long words[kMirrorIdentityWords],
                         char out[41])
{
    int i;
    long used = 0;

    for (i = 0; i < kMirrorIdentityWords; ++i) {
        used += snprintf(out + used, (size_t)(41 - used), "%08lx",
                         words[i] & 0xffffffffUL);
    }
    out[40] = '\0';
}

long now_mirror_json(const MirrorFacts *facts, long id, char *out, long cap)
{
    char escaped[kMirrorReasonMax * 2 + 8];
    long n;
    int i;

    if (facts == NULL || out == NULL || cap <= 0) {
        return 0;
    }
    n = snprintf(out, (size_t)cap,
                 "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
                 "\"output\":{\"mirror\":{\"schema\":%d,"
                 "\"extension\":{\"selector\":\"NWex\","
                 "\"lifecycle\":\"%s\",\"expectedMajor\":%d",
                 id, kMirrorFactsSchema, lifecycle_word(facts->lifecycle),
                 kNowPeekExtMajor);

    if ((facts->lifecycle == kMirrorLifecycleActive
         || facts->lifecycle == kMirrorLifecycleDegraded
         || facts->lifecycle == kMirrorLifecycleWrongVersion) && n < cap) {
        n += snprintf(out + n, (size_t)(cap - n),
                      ",\"residentMajor\":%lu,\"residentMinor\":%lu,"
                      "\"tableLength\":%lu,\"capabilities\":%lu,"
                      "\"requested\":%lu,\"active\":%lu,"
                      "\"heartbeat\":%lu,\"livenessTicks\":%lu,"
                      /* Reachability only — nothing has been dialled.
                         The OSErr rides along so a refusal says why. */
                      "\"transportProbe\":%lu,\"transportResult\":%ld,"
                      /* And the channel: what the resident's OWN
                         connection is doing, and how many frames it has
                         put on the wire. */
                      "\"channelState\":%lu,\"channelResult\":%ld,"
                      "\"channelSends\":%lu",
                      facts->resident_major, facts->resident_minor,
                      facts->table_length, facts->capabilities,
                      facts->requested_bits, facts->active_bits,
                      facts->heartbeat, facts->liveness_ticks,
                      facts->transport_probe, facts->transport_result,
                      facts->channel_state, facts->channel_result,
                      facts->channel_sends);
    }
    /* Emitted only when the resident actually said it, so a host reading
       this can tell "nothing is installed" from "this resident is too old
       to have been asked" — opposite claims that a defaulted 0 would make
       identical, and the reassuring one would be the lie. */
    if (facts->has_rest_state && n < cap) {
        n += snprintf(out + n, (size_t)(cap - n),
                      ",\"restState\":%lu,\"gnePasses\":%lu",
                      facts->rest_state, facts->gne_passes);
    }
    if (facts->has_build_identity && n < cap) {
        char source[41];
        char build[41];
        identity_hex(facts->source_manifest, source);
        identity_hex(facts->build_fingerprint, build);
        n += snprintf(out + n, (size_t)(cap - n),
                      ",\"sourceManifest\":\"%s\","
                      "\"buildFingerprint\":\"%s\"", source, build);
    }
    if (facts->reason[0] != '\0' && n < cap) {
        now_json_escape(facts->reason, escaped, (long)sizeof escaped);
        n += snprintf(out + n, (size_t)(cap - n),
                      ",\"reason\":\"%s\"", escaped);
    }
    /* P1's own evidence. Emitted LAST inside `extension` and bounded by
       what is left of the reply, because it is the only variable-length
       thing in this object: the fields above are a fixed cost and this
       one grows with the machine. A slot that does not fit is counted
       into `slotsOmitted` rather than dropped, and the array is closed
       properly either way - a truncated reply is not a short answer, it
       is not JSON. */
    if (facts->anchors.present || facts->anchors.slot_count > 0
        || facts->anchors.slots_omitted > 0) {
        int si;
        /* Budgeted HERE, against the reply actually written so far,
           rather than guessed when the facts were gathered: the fields
           above are conditional, so how much room is left is not knowable
           until this point. */
        int budget = now_mirror_anchor_slot_budget(cap, n);
        int emit = facts->anchors.slot_count;
        int omitted = facts->anchors.slots_omitted;

        if (emit > budget) {
            omitted += emit - budget;
            emit = budget;
        }
        if (n < cap) {
            n += snprintf(out + n, (size_t)(cap - n),
                          ",\"anchors\":{\"present\":%s,"
                          "\"count\":%lu,\"eventPasses\":%lu,"
                          "\"slotScans\":%lu,\"fullPublishes\":%lu,"
                          "\"changePublishes\":%lu,"
                          "\"cadencePublishes\":%lu,"
                          "\"lastPublishTicks\":%lu,"
                          "\"nowTicks\":%lu,\"slotsOmitted\":%d,"
                          "\"slots\":[",
                          facts->anchors.present ? "true" : "false",
                          facts->anchors.count,
                          facts->anchors.event_passes,
                          facts->anchors.slot_scans,
                          facts->anchors.full_publishes,
                          facts->anchors.change_publishes,
                          facts->anchors.cadence_publishes,
                          facts->anchors.last_publish_ticks,
                          facts->anchors.now_ticks, omitted);
        }
        for (si = 0; si < emit && n < cap; ++si) {
            const MirrorAnchorSlotFact *s = &facts->anchors.slots[si];
            now_json_escape(s->name, escaped, (long)sizeof escaped);
            n += snprintf(out + n, (size_t)(cap - n),
                          "%s{\"slot\":%d,\"name\":\"%s\",\"a5\":%lu,"
                          "\"windowList\":%lu,\"stampTicks\":%lu,"
                          "\"ageTicks\":%lu}",
                          si == 0 ? "" : ",", s->slot, escaped, s->a5,
                          s->window_list, s->stamp_ticks, s->age_ticks);
        }
        if (n < cap) {
            n += snprintf(out + n, (size_t)(cap - n), "]}");
        }
    }
    if (n < cap) {
        n += snprintf(out + n, (size_t)(cap - n),
                      "},\"policy\":{\"structure\":%s,"
                      "\"finderComplements\":%s,\"content\":%s,"
                      "\"foregroundCycle\":%s},\"planes\":[",
                      facts->policy.structure ? "true" : "false",
                      facts->policy.finder_complements ? "true" : "false",
                      facts->policy.content ? "true" : "false",
                      facts->policy.foreground_cycle ? "true" : "false");
    }
    for (i = 0; i < kMirrorPlaneCount && n < cap; ++i) {
        const MirrorPlaneFact *plane = &facts->planes[i];
        n += snprintf(out + n, (size_t)(cap - n),
                      "%s{\"id\":\"%s\",\"purpose\":\"%s\","
                      "\"capability\":%lu,\"supported\":%s,"
                      "\"format\":%lu,\"requested\":%s,\"active\":%s,"
                      "\"freshness\":\"%s\",\"state\":\"%s\","
                      "\"generation\":%lu",
                      i == 0 ? "" : ",", plane_id((MirrorPlane)i),
                      plane_purpose((MirrorPlane)i),
                      plane->capability,
                      plane->supported ? "true" : "false", plane->format,
                      plane->requested ? "true" : "false",
                      plane->active ? "true" : "false",
                      freshness_word(plane->freshness),
                      plane_state_word(plane->state), plane->generation);
        if (plane->reason[0] != '\0' && n < cap) {
            now_json_escape(plane->reason, escaped, (long)sizeof escaped);
            n += snprintf(out + n, (size_t)(cap - n),
                          ",\"reason\":\"%s\"", escaped);
        }
        if (n < cap) {
            n += snprintf(out + n, (size_t)(cap - n), "}");
        }
    }
    if (n < cap) {
        n += snprintf(out + n, (size_t)(cap - n), "]}}}");
    }
    return n < cap ? n : cap - 1;
}
