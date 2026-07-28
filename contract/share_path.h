/* The share-boundary rule, stated once.
 *
 * A guest publishes one folder and the other machine may browse, read and
 * write inside it. This is the check that keeps "inside" meaning
 * something, and it is the whole of that defence: everything downstream
 * resolves the path for real against the File Manager, by which point a
 * traversal has already succeeded.
 *
 * WHY A LEADING OR DOUBLED COLON IS THE POINT. These are HFS colon-paths,
 * where an empty segment means "parent" - so ":Lab" and "Lab::Secrets"
 * are requests to walk UP out of the share, and a share that can be
 * escaped upward is not a share. They are refused rather than resolved.
 * The 31-character segment cap is what HFS can name; a longer one cannot
 * refer to a real file and is refused rather than silently truncated
 * into one that does.
 *
 * A TRAILING colon is allowed: "Lab:" names the folder Lab, which is
 * inside the share. Only an empty segment ascends, and a trailing colon
 * leaves no segment after it to be empty. This is worth stating because
 * the rule's previous comment - in both guests - claimed a bare colon at
 * "either end" was refused, which neither implementation did. The code
 * was right and the sentence was wrong; share_path_test.c now pins the
 * case so nobody tightens the rule to match the sentence.
 *
 * WHY THIS FILE EXISTS. Both guests implemented this rule separately, in
 * fileshare.c and n68_putrx.c, character for character the same - and
 * only one of them was tested. That is the shape AGENTS.md warns about
 * twice over: a limit stated in more than one place is a limit that will
 * eventually disagree with itself, and two halves that never met in a
 * test is the defect class this project has paid most for. Both guests
 * are reached by the same host over the same verbs; a guest that
 * resolved one of these paths would be the one that leaked.
 *
 * There is no shared library to link here - a 68K application and a
 * PowerPC application share no binary - so the rule is a header the way
 * peek_table.h is a header: compiled by every side that reads it,
 * including the host `cc` for its native test
 * (now-guest-ppc/tests/share_path_test.c).
 *
 * `static` rather than `extern`: each translation unit gets its own copy
 * and no build gains a link-order dependency, which matters on targets
 * where the two guests share no build system at all.
 */
#ifndef NOW_CONTRACT_SHARE_PATH_H
#define NOW_CONTRACT_SHARE_PATH_H

#ifndef NULL
#include <stddef.h>
#endif

/* 1 if `rel` names a location inside the share: colon-separated
   segments, each 1..31 characters, relative to the share root. "" is the
   root itself and is allowed. NULL is refused. */
static int now_share_path_ok(const char *rel)
{
    long seg = 0;

    if (rel == NULL) {
        return 0;
    }
    /* Redundant with the empty-segment test below, which already catches
       a leading colon on the first pass - deliberately kept, because the
       rule this file exists to state is easier to read with the two
       ascent cases named separately. Removing it changes no behaviour,
       and share_path_test.c cannot tell the difference; that was
       confirmed by mutation rather than assumed. */
    if (rel[0] == ':') {
        return 0;                 /* leading colon = "start at the parent" */
    }
    for (; *rel != '\0'; ++rel) {
        if (*rel == ':') {
            if (seg == 0) {
                return 0;         /* empty segment = traversal */
            }
            seg = 0;
        } else if (++seg > 31) {
            return 0;             /* longer than HFS can name */
        }
    }
    return 1;
}

#endif /* NOW_CONTRACT_SHARE_PATH_H */
