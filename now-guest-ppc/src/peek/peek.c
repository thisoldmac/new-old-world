#include "peek.h"

#include <Files.h>
#include <Folders.h>
#include <Gestalt.h>

#include <stdio.h>
#include <string.h>


/* The application's probe of the NOW Extension (docs/resident-
   components.md). The extension registers Gestalt selector 'NWex' at
   boot and answers with its shared table's address; this reads it,
   validates it against the contract compiled into both sides
   (peek_table.h), and reports one of four states an installer needs.

   Cost rule: Gestalt is a cheap trap, called every time. Scanning the
   Extensions folder (to tell "installed, needs restart" from "not
   installed" when Gestalt is silent) is file I/O, so it runs AT MOST
   ONCE and caches - an INIT's presence cannot change without a reboot,
   and the idle path must read no files (guest-ui-start-here.md). */

#define NOW_EXT_FILE_TYPE NOW_PEEK_4CC('I', 'N', 'I', 'T')
#define NOW_EXT_CREATOR NOW_PEEK_4CC('N', 'O', 'W', 'x')

enum { kNowPeekOwnerLeaseTicks = 600 };

static int g_file_checked;
static Boolean g_file_present;
static NowPeekLeaseSet g_leases;
static int g_leases_ready;
static NowPeekU32 g_session_nonce_hi;
static NowPeekU32 g_session_nonce_lo;
static NowPeekU32 g_session_epoch;
static NowPeekU32 g_published_caps;

/* Is a file of type INIT and creator 'NOWx' sitting in the Extensions
   folder? Identity is by type/creator, not by name, so a build deployed
   under any filename still counts. */
static Boolean scan_extensions_folder(void)
{
    CInfoPBRec pb;
    Str63 name;
    short vref;
    long dirid;
    short index;

    if (FindFolder(kOnSystemDisk, kExtensionFolderType, kDontCreateFolder,
                   &vref, &dirid) != noErr) {
        return false;
    }
    for (index = 1;; ++index) {
        memset(&pb, 0, sizeof pb);
        pb.hFileInfo.ioNamePtr = name;
        pb.hFileInfo.ioVRefNum = vref;
        pb.hFileInfo.ioDirID = dirid;
        pb.hFileInfo.ioFDirIndex = index;
        if (PBGetCatInfoSync(&pb) != noErr) {
            break;                    /* past the last item */
        }
        if ((pb.hFileInfo.ioFlAttrib & ioDirMask) != 0) {
            continue;                 /* a folder, not an extension */
        }
        if ((NowPeekU32)pb.hFileInfo.ioFlFndrInfo.fdType == NOW_EXT_FILE_TYPE
            && (NowPeekU32)pb.hFileInfo.ioFlFndrInfo.fdCreator
                   == NOW_EXT_CREATOR) {
            return true;
        }
    }
    return false;
}

static Boolean extension_file_present(void)
{
    if (!g_file_checked) {
        g_file_present = scan_extensions_folder();
        g_file_checked = 1;
    }
    return g_file_present;
}

/* The validated table, or NULL. Shared by the status probe and the
   arm/read paths so the acceptance rule lives in one place. */
static NowPeekTable *raw_table(void)
{
    long response = 0;

    if (Gestalt((OSType)kNowPeekGestaltSelector, &response) != noErr
        || response == 0) {
        return NULL;
    }
    {
        NowPeekTable *table = (NowPeekTable *)response;

        if (table->magic != (NowPeekU32)kNowPeekTableMagic
            || table->ext_major != kNowPeekExtMajor
            || table->length < (NowPeekU32)offsetof(NowPeekTable, anchors)) {
            return NULL;              /* answered, but not one we trust */
        }
        return table;
    }
}

static Boolean current_app_identity(ProcessSerialNumber *psn_out)
{
    ProcessSerialNumber psn;
    ProcessInfoRec info;
    Str31 name;

    if (GetCurrentProcess(&psn) != noErr) {
        return false;
    }
    memset(&info, 0, sizeof info);
    info.processInfoLength = sizeof info;
    info.processName = name;
    name[0] = 0;
    if (GetProcessInformation(&psn, &info) != noErr
        || (NowPeekU32)info.processSignature
               != (NowPeekU32)kNowPeekCanonicalAppCreator
        || !EqualString(name, (ConstStr255Param)"\pNew Old World",
                        false, false)) {
        return false;
    }
    if (psn_out != NULL) {
        *psn_out = psn;
    }
    return true;
}

static int writer_region_ready(const NowPeekTable *table)
{
    unsigned long need = (unsigned long)offsetof(NowPeekTable, writer)
        + (unsigned long)sizeof table->writer;

    return table != NULL && table->length >= need
        && table->writer_format == kNowPeekWriterFormatV1
        && table->writer_length == sizeof table->writer;
}

static int writer_current(const NowPeekTable *table, NowPeekU32 now)
{
    return writer_region_ready(table)
        && (table->writer.session_nonce_hi != 0
            || table->writer.session_nonce_lo != 0)
        && table->writer.app_creator == kNowPeekCanonicalAppCreator
        && table->writer.app_name == kNowPeekCanonicalAppName
        && table->writer.heartbeat_ticks != 0
        && now - table->writer.heartbeat_ticks
               <= (NowPeekU32)kNowPeekWriterLeaseTicks;
}

static int maintain_writer(NowPeekTable *table, NowPeekU32 now)
{
    ProcessSerialNumber psn;
    NowPeekWriterLease *writer;

    if (!writer_region_ready(table) || !current_app_identity(&psn)) {
        return 0;                    /* dev-named app: read-only NWex */
    }
    writer = &table->writer;
    if (g_session_nonce_hi != 0 || g_session_nonce_lo != 0) {
        if (writer->session_nonce_hi == g_session_nonce_hi
            && writer->session_nonce_lo == g_session_nonce_lo
            && writer->owner_epoch == g_session_epoch) {
            writer->heartbeat_ticks = now;        /* renew, publish last */
            return 1;                 /* resident independently gates use */
        }
    }
    if (writer_current(table, now)) {
        return 0;                    /* another current session owns it */
    }

    g_session_nonce_hi = (NowPeekU32)psn.highLongOfPSN ^ table->boot_ticks;
    g_session_nonce_lo = (NowPeekU32)psn.lowLongOfPSN ^ now ^ 0x4E576578UL;
    if (g_session_nonce_hi == 0 && g_session_nonce_lo == 0) {
        g_session_nonce_lo = 1;
    }
    g_session_epoch = writer->owner_epoch + 1;
    if (g_session_epoch == 0) {
        g_session_epoch = 1;
    }
    writer->heartbeat_ticks = 0;     /* invalidate before replacement */
    writer->session_nonce_hi = g_session_nonce_hi;
    writer->session_nonce_lo = g_session_nonce_lo;
    writer->psn_high = (NowPeekU32)psn.highLongOfPSN;
    writer->psn_low = (NowPeekU32)psn.lowLongOfPSN;
    writer->app_creator = (NowPeekU32)kNowPeekCanonicalAppCreator;
    writer->app_name = (NowPeekU32)kNowPeekCanonicalAppName;
    writer->owner_epoch = g_session_epoch;
    writer->heartbeat_ticks = now;   /* commit */
    now_peek_leases_begin_session(&g_leases, g_session_epoch);
    g_leases_ready = 1;
    g_published_caps = 0;
    return 1;                        /* resident may settle echo next pass */
}

static void publish_claims_to(NowPeekTable *table, NowPeekU32 now)
{
    NowPeekU32 wanted = now_peek_leases_union(&g_leases, now);

    if (wanted != g_published_caps || table->arm_request != wanted) {
        table->arm_request = wanted;
        g_published_caps = wanted;
    }
}

static void publish_claims(void)
{
    NowPeekTable *table = raw_table();
    NowPeekU32 now = (NowPeekU32)TickCount();

    if (table == NULL || !maintain_writer(table, now)) {
        return;
    }
    publish_claims_to(table, now);
}

const NowPeekTable *now_peek_table(void)
{
    NowPeekTable *table = raw_table();

    if (table != NULL) {
        NowPeekU32 now = (NowPeekU32)TickCount();

        if (maintain_writer(table, now) && g_leases_ready) {
            publish_claims_to(table, now);
        }
    }
    return table;
}

void now_peek_claim(NowPeekOwner owner, unsigned long caps)
{
    if ((int)owner < 0 || (int)owner >= (int)kNowPeekOwnerCount) {
        return;
    }
    now_peek_claim_until(owner, caps,
                         (unsigned long)TickCount()
                             + kNowPeekOwnerLeaseTicks);
}

void now_peek_claim_until(NowPeekOwner owner, unsigned long caps,
                          unsigned long expiry_ticks)
{
    NowPeekU32 now = (NowPeekU32)TickCount();
    NowPeekTable *table = raw_table();

    if (table != NULL) {
        (void)maintain_writer(table, now);
    }
    if (!g_leases_ready) {
        now_peek_leases_init(&g_leases, g_session_epoch);
        g_leases_ready = 1;
    }
    now_peek_leases_claim(&g_leases, owner, (NowPeekU32)caps, now,
                          (NowPeekU32)expiry_ticks);
    publish_claims();
}

void now_peek_release(NowPeekOwner owner, unsigned long caps)
{
    if ((int)owner < 0 || (int)owner >= (int)kNowPeekOwnerCount) {
        return;
    }
    now_peek_leases_release(&g_leases, owner, (NowPeekU32)caps);
    publish_claims();
}

void now_peek_disconnect(void)
{
    now_peek_leases_disconnect(&g_leases);
    publish_claims();
}

int now_peek_build_identity(NowPeekBuildIdentity *out)
{
    const NowPeekTable *table = now_peek_table();
    unsigned long need;

    if (table == NULL || out == NULL) {
        return 0;
    }
    need = (unsigned long)offsetof(NowPeekTable, identity)
        + (unsigned long)sizeof table->identity;
    if (table->length < need
        || table->identity_format != kNowPeekIdentityFormatV1
        || table->identity_length != sizeof table->identity) {
        return 0;
    }
    BlockMoveData((Ptr)&table->identity, (Ptr)out, (Size)sizeof *out);
    return 1;
}

int now_peek_build_matches(
    const NowPeekU32 expected[kNowPeekIdentityWordCount])
{
    NowPeekBuildIdentity identity;

    return expected != NULL && now_peek_build_identity(&identity)
        && memcmp(identity.build_fingerprint, expected,
                  sizeof identity.build_fingerprint) == 0;
}

NowPeekState now_peek_status(unsigned long *caps)
{
    const NowPeekTable *table = now_peek_table();
    long response = 0;

    if (caps != NULL) {
        *caps = 0;
    }
    if (table != NULL) {
        if (caps != NULL) {
            *caps = table->caps;
        }
        return kNowPeekActive;
    }
    /* Gestalt answering but the table rejected is a version we will not
       partially believe; Gestalt silent means nothing is loaded. */
    if (Gestalt((OSType)kNowPeekGestaltSelector, &response) == noErr
        && response != 0) {
        return kNowPeekWrongVersion;
    }
    /* The file being present means installed-but-not-rebooted (INITs
       load at boot only); absent means simply not installed. */
    return extension_file_present() ? kNowPeekNeedsRestart
                                    : kNowPeekNotInstalled;
}

void now_peek_status_line(char *out, long cap)
{
    unsigned long ignored;

    switch (now_peek_status(&ignored)) {
    case kNowPeekActive:
        snprintf(out, (size_t)cap, "NOW Extension active");
        break;
    case kNowPeekWrongVersion:
        snprintf(out, (size_t)cap, "NOW Extension needs updating");
        break;
    case kNowPeekNeedsRestart:
        snprintf(out, (size_t)cap,
                 "NOW Extension installed - restart to activate");
        break;
    default:
        snprintf(out, (size_t)cap, "NOW Extension not installed");
        break;
    }
}
