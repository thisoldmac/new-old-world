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

NowPeekState now_peek_status(unsigned long *caps)
{
    long response = 0;

    if (caps != NULL) {
        *caps = 0;
    }
    if (Gestalt((OSType)kNowPeekGestaltSelector, &response) == noErr
        && response != 0) {
        const NowPeekTable *table = (const NowPeekTable *)response;

        /* Gestalt answered, so an extension is loaded. Trust it only if
           the table is well-formed and the major matches exactly;
           anything else is a version we will not partially believe. */
        if (table->magic != (NowPeekU32)kNowPeekTableMagic
            || table->ext_major != kNowPeekExtMajor
            || table->length < (NowPeekU32)offsetof(NowPeekTable, anchors)) {
            return kNowPeekWrongVersion;
        }
        if (caps != NULL) {
            *caps = table->caps;
        }
        return kNowPeekActive;
    }
    /* Gestalt silent: nothing is loaded. The file being present means it
       is installed but the machine has not rebooted (INITs load at boot
       only); absent means it is simply not installed. */
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
