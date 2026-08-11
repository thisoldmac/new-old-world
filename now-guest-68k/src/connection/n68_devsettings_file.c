/*
 * n68_devsettings_file.c - see n68_devsettings_file.h. Finds the dev
 * settings file beside the application and hands its bytes to the parser.
 */
#include "n68_devsettings_file.h"

#include <Files.h>
#include <Processes.h>
#include <TextUtils.h>
#include <string.h>

/* One read, one buffer, on the stack of a call made once at startup. The
 * whole file is five short lines; 512 bytes is room for a lab bench's worth
 * of commented-out hosts on top of that, and it costs nothing after
 * window_init returns - the alternative, a file-scope buffer, would sit in
 * BSS for the life of a run to hold something read once (window.c's own
 * static budget comment is the reason to care). A longer file is read up to
 * this cap and cut back to its last complete line, so the cap can drop a
 * setting but can never invent one out of half a line. */
#define kReadCap 512

/* The application's own folder, resolved the way log.c and main.c's
 * chdir_to_app_folder already resolve it: Process Manager, not the launch
 * default directory, which is NOT the same place (Rumpus deposits builds on
 * the Desktop). Duplicated rather than shared because log.c keeps this
 * inside now68k_log_open and exports no seam for it; if a third caller
 * appears, that is the moment to lift one out of log.c rather than write
 * this a third time. */
static int app_folder(short *vRefNum, long *dirID)
{
    ProcessSerialNumber psn;
    ProcessInfoRec      info;
    FSSpec              appSpec;

    if (GetCurrentProcess(&psn) != noErr) {
        return 0;
    }
    memset(&info, 0, sizeof(info));
    info.processInfoLength = sizeof(info);
    info.processAppSpec    = &appSpec;
    if (GetProcessInformation(&psn, &info) != noErr) {
        return 0;
    }
    *vRefNum = appSpec.vRefNum;
    *dirID   = appSpec.parID;
    return 1;
}

int now68k_devsettings_load(N68DevSettings *s)
{
    FSSpec spec;
    short  vRefNum = 0;
    short  ref = 0;
    long   dirID = 0;
    long   eof = 0;
    long   count;
    char   buf[kReadCap];

    n68_devsettings_init(s);

    if (!app_folder(&vRefNum, &dirID)) {
        return 0;
    }
    /* fnfErr from FSMakeFSSpec still fills in a valid spec, but there is
     * nothing to open behind it - and this is the shipping case, so it
     * returns without a word. */
    if (FSMakeFSSpec(vRefNum, dirID,
                     (ConstStr255Param)kN68DevSettingsFileName, &spec) != noErr) {
        return 0;
    }
    /* fsRdPerm, not fsRdWrPerm: nothing here ever writes this file. The
     * human owns it, and a settings file the application can rewrite is a
     * preferences file, which this product deliberately does not have. */
    if (FSpOpenDF(&spec, fsRdPerm, &ref) != noErr) {
        return 0;
    }

    if (GetEOF(ref, &eof) != noErr) {
        (void)FSClose(ref);
        return 0;
    }
    if (eof <= 0) {
        /* An empty file is a real answer, not an error: it says "there is a
         * settings file here and it sets nothing." Parsing zero bytes is a
         * no-op, so the caller gets the no-file state with a 1 return. */
        (void)FSClose(ref);
        return 1;
    }

    count = (eof > (long)kReadCap) ? (long)kReadCap : eof;
    if (FSRead(ref, &count, buf) != noErr && count <= 0) {
        (void)FSClose(ref);
        return 0;
    }
    (void)FSClose(ref);

    /* eofErr on a short read is not a failure - count says how much
     * actually arrived, and a partial file still has whole lines in it. */
    if (count > (long)kReadCap) {
        count = (long)kReadCap;
    }
    if (eof > (long)kReadCap) {
        /* Cut back to the last complete line so the truncation cannot
         * synthesize a setting from half a line - "autoconnect = o" would
         * otherwise be a malformed line the human never wrote, and
         * "port = 5" a value they never meant. */
        while (count > 0 && buf[count - 1] != '\r' && buf[count - 1] != '\n') {
            count--;
        }
    }

    n68_devsettings_parse(s, buf, count);
    return 1;
}
