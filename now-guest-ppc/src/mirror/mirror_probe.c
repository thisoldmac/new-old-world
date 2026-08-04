#include "mirror_probe.h"

#include <Gestalt.h>
#include <LowMem.h>
#include <stddef.h>
#include <string.h>

#include "content_table.h"
#include "peek.h"
#include "peek_validate.h"

enum { kMirrorFreshTicks = 180 };

static unsigned long read_be32(unsigned long address)
{
    const unsigned char *p = (const unsigned char *)address;
    return ((unsigned long)p[0] << 24) | ((unsigned long)p[1] << 16)
        | ((unsigned long)p[2] << 8) | (unsigned long)p[3];
}

static int system_range_contains(unsigned long address,
                                 unsigned long required)
{
    unsigned long system_low;
    unsigned long system_high;
    THz system_zone = LMGetSysZone();

    system_low = (unsigned long)system_zone;
    system_high = system_zone != NULL ? read_be32(system_low) : 0;
    return system_high > system_low
        && now_peek_range_in_partition(address, required, system_low,
                                        system_high - system_low);
}

static const NowContentBlock *content_block(const NowPeekTable *table)
{
    unsigned long field_end = (unsigned long)offsetof(NowPeekTable,
                                                       content_block)
        + sizeof table->content_block;
    unsigned long address;
    unsigned long required;

    if (table->length < field_end || table->content_block == 0) {
        return NULL;
    }
    address = table->content_block;
    required = (unsigned long)offsetof(NowContentBlock, seq)
        + sizeof(((NowContentBlock *)0)->seq);
    if (!system_range_contains(address, required)) {
        return NULL;
    }
    return (const NowContentBlock *)address;
}

static int plane_format_compatible(const NowPeekTable *table,
                                   MirrorPlane plane,
                                   unsigned long format)
{
    unsigned long need;

    switch (plane) {
    case kMirrorPlaneStructure:
        return format >= kNowPeekAnchorFormatV1
            && format <= kNowPeekAnchorFormatV3;
    case kMirrorPlaneSemantics:
        return format == kNowPeekSemanticFormatV2;
    case kMirrorPlaneContent:
        return format == kNowContentFormatV2;
    case kMirrorPlaneInteraction:
        need = (unsigned long)offsetof(NowPeekTable, act_v2)
            + sizeof table->act_v2;
        return format == kNowPeekActFormatV2 && table->length >= need;
    }
    return 0;
}

static unsigned long plane_capability(MirrorPlane plane)
{
    static const unsigned long values[kMirrorPlaneCount] = {
        kNowPeekTableCapAnchors, kNowPeekTableCapTree,
        kNowPeekTableCapContent, kNowPeekTableCapAct
    };
    return values[(int)plane];
}

static unsigned long plane_format(const NowPeekTable *table,
                                  MirrorPlane plane)
{
    unsigned long need;

    switch (plane) {
    case kMirrorPlaneStructure:
        need = (unsigned long)offsetof(NowPeekTable, anchors);
        return table->length >= need ? table->anchor_format : 0;
    case kMirrorPlaneSemantics:
        need = (unsigned long)offsetof(NowPeekTable, semantic)
            + sizeof table->semantic;
        return table->length >= need ? table->semantic_format : 0;
    case kMirrorPlaneContent:
    {
        const NowContentBlock *block = content_block(table);
        if (block != NULL) {
            if (block->magic == (NowContentU32)kNowContentBlockMagic
                && block->length >= offsetof(NowContentBlock, seq)
                                      + sizeof block->seq) {
                return block->format;
            }
        }
        return 0;
    }
    case kMirrorPlaneInteraction:
        need = (unsigned long)offsetof(NowPeekTable, act)
            + sizeof table->act;
        return table->length >= need ? table->act_format : 0;
    }
    return 0;
}

static unsigned long plane_generation(const NowPeekTable *table,
                                      MirrorPlane plane)
{
    unsigned long need;

    switch (plane) {
    case kMirrorPlaneStructure:
        need = (unsigned long)offsetof(NowPeekTable, anchor_last_publish_ticks)
            + sizeof table->anchor_last_publish_ticks;
        return table->length >= need ? table->anchor_last_publish_ticks : 0;
    case kMirrorPlaneSemantics:
        need = (unsigned long)offsetof(NowPeekTable, semantic)
            + sizeof table->semantic;
        return table->length >= need ? table->semantic.response_generation : 0;
    case kMirrorPlaneContent:
    {
        const NowContentBlock *block = content_block(table);
        if (block != NULL) {
            if (block->magic == (NowContentU32)kNowContentBlockMagic) {
                return block->seq;
            }
        }
        return 0;
    }
    case kMirrorPlaneInteraction:
        need = (unsigned long)offsetof(NowPeekTable, act_v2)
            + sizeof table->act_v2;
        if (table->length >= need && table->act_format == kNowPeekActFormatV2) {
            return table->act_v2.resident_generation;
        }
        need = (unsigned long)offsetof(NowPeekTable, act) + sizeof table->act;
        return table->length >= need ? table->act.seq : 0;
    }
    return 0;
}

static void fill_planes(MirrorFacts *facts, const NowPeekTable *table,
                        unsigned long now)
{
    int i;
    Boolean resident_fresh = table->heartbeat != 0
        && now - table->heartbeat <= kMirrorFreshTicks;

    for (i = 0; i < kMirrorPlaneCount; ++i) {
        MirrorPlaneFact *plane = &facts->planes[i];
        unsigned long capability = plane_capability((MirrorPlane)i);

        plane->capability = capability;
        plane->supported = (table->caps & capability) != 0;
        plane->format = plane_format(table, (MirrorPlane)i);
        plane->requested = (table->arm_request & capability) != 0;
        plane->active = (table->arm_active & capability) != 0;
        plane->generation = plane_generation(table, (MirrorPlane)i);
        if (!plane->supported) {
            plane->freshness = kMirrorFreshUnavailable;
            plane->state = kMirrorPlaneUnsupported;
        } else if (!plane_format_compatible(table, (MirrorPlane)i,
                                            plane->format)) {
            plane->freshness = kMirrorFreshUnavailable;
            plane->state = kMirrorPlaneRefused;
            strcpy(plane->reason,
                   "resident capability has no compatible format");
            facts->lifecycle = kMirrorLifecycleDegraded;
        } else if (!plane->requested) {
            plane->freshness = kMirrorFreshUnavailable;
            plane->state = kMirrorPlaneInactive;
        } else if (!plane->active) {
            plane->freshness = kMirrorFreshPending;
            plane->state = kMirrorPlaneRequested;
        } else if (!resident_fresh) {
            plane->freshness = kMirrorFreshStale;
            plane->state = kMirrorPlaneActiveStale;
            facts->lifecycle = kMirrorLifecycleDegraded;
        } else {
            plane->freshness = kMirrorFreshCurrent;
            plane->state = kMirrorPlaneActiveCurrent;
        }
    }
    if (!resident_fresh) {
        facts->lifecycle = kMirrorLifecycleDegraded;
        strcpy(facts->reason, "resident heartbeat is stale");
    }
}

void now_mirror_probe(MirrorFacts *facts)
{
    unsigned long caps = 0;
    NowPeekState status;
    const NowPeekTable *table;

    memset(facts, 0, sizeof *facts);
    status = now_peek_status(&caps);
    switch (status) {
    case kNowPeekNeedsRestart:
        facts->lifecycle = kMirrorLifecycleNeedsRestart;
        return;
    case kNowPeekWrongVersion: {
        long response = 0;
        facts->lifecycle = kMirrorLifecycleWrongVersion;
        if (Gestalt((OSType)kNowPeekGestaltSelector, &response) == noErr
            && response != 0
            && system_range_contains((unsigned long)response,
                                     (unsigned long)offsetof(NowPeekTable,
                                                              caps))) {
            const NowPeekTable *foreign = (const NowPeekTable *)response;
            facts->resident_major = foreign->ext_major;
            facts->resident_minor = foreign->ext_minor;
            facts->table_length = foreign->length;
        }
        return;
    }
    case kNowPeekActive:
        facts->lifecycle = kMirrorLifecycleActive;
        break;
    case kNowPeekNotInstalled:
    default:
        facts->lifecycle = kMirrorLifecycleAbsent;
        return;
    }

    table = now_peek_table();
    if (table == NULL) {
        facts->lifecycle = kMirrorLifecycleDegraded;
        strcpy(facts->reason, "resident table disappeared during snapshot");
        return;
    }
    facts->resident_major = table->ext_major;
    facts->resident_minor = table->ext_minor;
    facts->table_length = table->length;
    facts->capabilities = table->caps;
    facts->requested_bits = table->arm_request;
    facts->active_bits = table->arm_active;
    facts->heartbeat = table->heartbeat;
    {
        NowPeekBuildIdentity identity;
        if (now_peek_build_identity(&identity)) {
            int i;
            facts->has_build_identity = 1;
            for (i = 0; i < kMirrorIdentityWords; ++i) {
                facts->source_manifest[i] = identity.source_manifest[i];
                facts->build_fingerprint[i] = identity.build_fingerprint[i];
            }
        }
    }
    fill_planes(facts, table, (unsigned long)TickCount());
}
