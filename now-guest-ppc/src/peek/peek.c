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

static int g_file_checked;
static Boolean g_file_present;

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
const NowPeekTable *now_peek_table(void)
{
    long response = 0;

    if (Gestalt((OSType)kNowPeekGestaltSelector, &response) != noErr
        || response == 0) {
        return NULL;
    }
    {
        const NowPeekTable *table = (const NowPeekTable *)response;

        if (table->magic != (NowPeekU32)kNowPeekTableMagic
            || table->ext_major != kNowPeekExtMajor
            || table->length < (NowPeekU32)offsetof(NowPeekTable, anchors)) {
            return NULL;              /* answered, but not one we trust */
        }
        return table;
    }
}

void now_peek_arm(unsigned long caps)
{
    NowPeekTable *table = (NowPeekTable *)now_peek_table();

    if (table != NULL) {
        table->arm_request |= (NowPeekU32)caps;
    }
}

void now_peek_disarm(unsigned long caps)
{
    NowPeekTable *table = (NowPeekTable *)now_peek_table();

    if (table != NULL) {
        table->arm_request &= ~(NowPeekU32)caps;
    }
}

/* The claims, one word per owner. See peek.h for what one shared bit
   cost. */
static unsigned long g_claims[kNowPeekOwnerCount];

static void publish_claims(void)
{
    NowPeekTable *table = (NowPeekTable *)now_peek_table();
    unsigned long wanted = 0;
    int i;

    if (table == NULL) {
        return;
    }
    for (i = 0; i < (int)kNowPeekOwnerCount; ++i) {
        wanted |= g_claims[i];
    }
    table->arm_request = (NowPeekU32)wanted;
}

void now_peek_claim(NowPeekOwner owner, unsigned long caps)
{
    if ((int)owner < 0 || (int)owner >= (int)kNowPeekOwnerCount) {
        return;
    }
    g_claims[owner] |= caps;
    publish_claims();
}

void now_peek_release(NowPeekOwner owner, unsigned long caps)
{
    if ((int)owner < 0 || (int)owner >= (int)kNowPeekOwnerCount) {
        return;
    }
    g_claims[owner] &= ~caps;
    publish_claims();
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
