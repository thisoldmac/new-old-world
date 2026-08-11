/*
 * log.c - see log.h for why this is File Manager and not stdio.
 */
#include "log.h"

#include <Files.h>
#include <OSUtils.h>
#include <Processes.h>
#include <TextUtils.h>
#include <string.h>

#include "log_retention.h"
#include "log_retention_classic.h"
#include "n68_devsettings_file.h"

static short gRef = 0;      /* 0 = closed; a real refNum is never 0 */
static short gVol = 0;
static long  gDir = 0;

/* Unsigned decimal into buf, returns length written. Hand-rolled because the
 * only numbers this log formats are small, and reaching for printf to do it
 * drags ~30 KB of newlib float machinery into a 384 KB partition. */
static short put_uint(char *buf, unsigned long v)
{
    char  tmp[12];
    short n = 0;
    short i;

    if (v == 0) {
        buf[0] = '0';
        return 1;
    }
    while (v > 0 && n < (short)sizeof(tmp)) {
        tmp[n++] = (char)('0' + (char)(v % 10));
        v /= 10;
    }
    for (i = 0; i < n; i++) {
        buf[i] = tmp[n - 1 - i];
    }
    return n;
}

/* Zero-padded, so a launch stamp sorts correctly in the Finder. */
static short put_uint_pad(char *buf, unsigned long v, short width)
{
    short n = put_uint(buf, v);
    short pad;
    short i;

    if (n >= width) {
        return n;
    }
    pad = (short)(width - n);
    for (i = (short)(n - 1); i >= 0; i--) {
        buf[i + pad] = buf[i];
    }
    for (i = 0; i < pad; i++) {
        buf[i] = '0';
    }
    return width;
}

static void write_bytes(const void *p, long len)
{
    long count = len;

    if (gRef == 0 || len <= 0) {
        return;
    }
    (void)FSWrite(gRef, &count, p);
}

/* Committed on every line, not at close: the run this log exists to explain
 * is the one that ends in a forced restart, and an uncommitted catalog EOF
 * reads back short or empty afterwards. */
static void commit(void)
{
    (void)FlushVol(NULL, gVol);
}

void now68k_log_open(void)
{
    ProcessSerialNumber psn;
    ProcessInfoRec      info;
    FSSpec              appSpec;
    FSSpec              logSpec;
    DateTimeRec         stamp;
    unsigned long       secs;
    Str255              name;
    short               n;
    OSErr               err;
    N68DevSettings      settings;
    unsigned short      keep = kNowLogRetentionDefault;

    if (gRef != 0) {
        return;
    }
    if (now68k_devsettings_load(&settings)
        && settings.have_log_retention) {
        keep = settings.log_retention;
    }

    /* Beside the application, not in the launch directory: a build dropped
     * on the Desktop otherwise scatters its logs there. */
    if (GetCurrentProcess(&psn) != noErr) {
        return;
    }
    memset(&info, 0, sizeof(info));
    info.processInfoLength = sizeof(info);
    info.processAppSpec    = &appSpec;
    if (GetProcessInformation(&psn, &info) != noErr) {
        return;
    }
    gVol = appSpec.vRefNum;
    gDir = appSpec.parID;

    /* One file per launch piles up fast, so they live in their own folder
     * rather than silting up the folder the application sits in. Created on
     * demand; if it cannot be made we fall back to writing beside the app,
     * because losing the log is worse than an untidy directory. */
    {
        FSSpec      dirSpec;
        CInfoPBRec  cat;
        long        logDir = 0;
        OSErr       dirErr;

        /* A "\p" literal is char*; every Toolbox string argument is
         * ConstStr255Param. The warning gate makes the mismatch an error,
         * which is the point - it caught a real one in window.c. */
        dirErr = FSMakeFSSpec(gVol, gDir, (ConstStr255Param)"\plogs", &dirSpec);
        if (dirErr == noErr || dirErr == fnfErr) {
            dirErr = FSpDirCreate(&dirSpec, smSystemScript, &logDir);
            if (dirErr == dupFNErr) {
                /* Already there - ask the catalog for its dirID. */
                memset(&cat, 0, sizeof(cat));
                cat.dirInfo.ioVRefNum = dirSpec.vRefNum;
                cat.dirInfo.ioDrDirID = dirSpec.parID;
                cat.dirInfo.ioNamePtr = dirSpec.name;
                cat.dirInfo.ioFDirIndex = 0;
                if (PBGetCatInfoSync(&cat) == noErr
                    && (cat.dirInfo.ioFlAttrib & ioDirMask) != 0) {
                    logDir = cat.dirInfo.ioDrDirID;
                }
            } else if (dirErr != noErr) {
                logDir = 0;
            }
        }
        if (logDir != 0) {
            gDir = logDir;
        }
    }

    /* One file per launch, stamped HHMMSS. Relaunching to read the log of a
     * hang must not be the act that destroys it. "NOW-68K log HHMMSS" is 18
     * characters, well inside HFS's 31. */
    GetDateTime(&secs);
    SecondsToDate(secs, &stamp);
    memcpy(&name[1], "NOW-68K log ", 12);
    n = 12;
    n = (short)(n + put_uint_pad((char *)&name[1] + n,
                                 (unsigned long)stamp.hour, 2));
    n = (short)(n + put_uint_pad((char *)&name[1] + n,
                                 (unsigned long)stamp.minute, 2));
    n = (short)(n + put_uint_pad((char *)&name[1] + n,
                                 (unsigned long)stamp.second, 2));
    name[0] = (unsigned char)n;

    (void)FSMakeFSSpec(gVol, gDir, name, &logSpec);
    err = FSpCreate(&logSpec, 'ttxt', 'TEXT', smSystemScript);
    if (err != noErr && err != dupFNErr) {
        return;
    }
    if (FSpOpenDF(&logSpec, fsWrPerm, &gRef) != noErr) {
        gRef = 0;
        return;
    }
    (void)now_log_prune_classic(gVol, gDir, logSpec.name,
                                kNowLogDialect68K, keep);
    now68k_log("NOW-68K startup log");
}

void now68k_log(const char *msg)
{
    if (gRef == 0 || msg == NULL) {
        return;
    }
    write_bytes(msg, (long)strlen(msg));
    write_bytes("\r", 1);   /* this machine's line ending; '\n' renders the
                               whole log as a single line in TeachText */
    commit();
}

void now68k_log_num(const char *msg, long value)
{
    char  num[16];
    short n = 0;

    if (gRef == 0 || msg == NULL) {
        return;
    }
    write_bytes(msg, (long)strlen(msg));
    num[n++] = ' ';
    if (value < 0) {
        num[n++] = '-';
        n = (short)(n + put_uint(num + n, (unsigned long)(-value)));
    } else {
        n = (short)(n + put_uint(num + n, (unsigned long)value));
    }
    write_bytes(num, n);
    write_bytes("\r", 1);
    commit();
}

void now68k_log_close(void)
{
    if (gRef != 0) {
        (void)FSClose(gRef);
        commit();
        gRef = 0;
    }
}
