#include "log_retention_classic.h"

#include <Files.h>
#include <string.h>

#include "log_retention.h"

static int same_pascal(const unsigned char *a, const unsigned char *b)
{
    if (a == NULL || b == NULL || a[0] != b[0]) return 0;
    return memcmp(a + 1, b + 1, a[0]) == 0;
}

short now_log_prune_classic(short vref, long dir,
                            const unsigned char *current,
                            int dialect, unsigned short keep)
{
    short deleted = 0;
    keep = now_log_retention_sanitize(keep);

    for (;;) {
        CInfoPBRec pb;
        Str255 name;
        NowLogCandidate oldest;
        int have_oldest = 0;
        int count = 0;
        short index;

        for (index = 1; ; ++index) {
            OSErr err;
            NowLogCandidate candidate;

            memset(&pb, 0, sizeof pb);
            name[0] = 0;
            pb.hFileInfo.ioNamePtr = name;
            pb.hFileInfo.ioVRefNum = vref;
            pb.hFileInfo.ioDirID = dir;
            pb.hFileInfo.ioFDirIndex = index;
            err = PBGetCatInfoSync(&pb);
            if (err == fnfErr) break;
            if (err != noErr) return deleted;
            if ((pb.hFileInfo.ioFlAttrib & ioDirMask) != 0
                || !now_log_name_matches(name, dialect)) {
                continue;
            }
            ++count;
            memset(&candidate, 0, sizeof candidate);
            candidate.created = pb.hFileInfo.ioFlCrDat;
            memcpy(candidate.name, name, name[0] + 1);
            candidate.current = same_pascal(name, current);
            if (!candidate.current
                && (!have_oldest
                    || now_log_candidate_older(&candidate, &oldest))) {
                oldest = candidate;
                have_oldest = 1;
            }
        }
        if (count <= (int)keep || !have_oldest) return deleted;
        {
            FSSpec victim;
            victim.vRefNum = vref;
            victim.parID = dir;
            memcpy(victim.name, oldest.name, oldest.name[0] + 1);
            if (FSpDelete(&victim) != noErr) return deleted;
        }
        ++deleted;
    }
}
