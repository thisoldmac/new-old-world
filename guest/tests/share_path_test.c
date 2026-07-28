/* The share-boundary rule (contract/share_path.h), tested directly.
 *
 *     cc -Wall -Wextra -Werror -I ../../contract share_path_test.c -o /tmp/t
 *
 * This check is the whole of the share boundary. Everything downstream
 * resolves the path for real against the File Manager, by which point a
 * traversal has already succeeded - so a hole here is not a bug that
 * shows up as a wrong answer, it is a bug that shows up as the other
 * machine reading a file outside the folder it was offered.
 *
 * It went untested on the PowerPC guest for the life of the project. The
 * 68K guest published its copy specifically so its traversal cases could
 * be walked, and its header said in as many words that the rule was
 * "stated in both places". Both are now one header and this is its test.
 */
#include "share_path.h"

#include <stdio.h>
#include <string.h>

static int g_checks;
static int g_failed;

static void expect(const char *rel, int want, const char *why)
{
    int got = now_share_path_ok(rel);

    g_checks++;
    if (got != want) {
        g_failed++;
        fprintf(stderr, "FAIL %-28s got %d want %d  (%s)\n",
                rel == NULL ? "(NULL)" : rel, got, want, why);
    }
}

int main(void)
{
    /* ---- the traversals this exists to refuse --------------------- */
    expect(":Lab", 0, "leading colon starts at the parent");
    expect("Lab::Secrets", 0, "empty segment means parent");
    expect("::", 0, "nothing but parents");
    expect(":", 0, "a bare colon is the parent");
    expect("a::b::c", 0, "several, mid-path");
    expect(":a:b", 0, "leading, with real segments after it");
    expect("Lab:::Secrets", 0, "three deep");

    /* A traversal buried where a naive check looks only at the ends. */
    expect("one:two::three:four", 0, "traversal in the middle");

    /* ---- what must keep working ----------------------------------- */
    expect("", 1, "the share root itself");
    expect("Lab", 1, "one segment");
    expect("Lab:Code", 1, "two segments");
    expect("Lab:Code:now:guest:src", 1, "deep but honest");
    expect("a", 1, "one character");

    /* Names a Mac can really have. A colon is the separator, so it is
       not among these; everything else on a classic volume is fair. */
    expect("My Documents:Read Me", 1, "spaces");
    expect("Système", 1, "high-MacRoman bytes pass through");
    expect("file.txt", 1, "dots are not special");
    expect("..", 1, "dot-dot is NOT traversal in a colon path");
    expect("Lab:..:Code", 1, "dot-dot mid-path is a literal name");

    /* A TRAILING colon is allowed, and this case is here because the
       rule's own comment used to claim otherwise - it said a bare colon
       at "either end" was refused, while both guests accepted this one.
       The code was right: "Lab:" names the folder Lab, which is inside
       the share. Only an EMPTY segment walks upward, and a trailing
       colon leaves no segment after it to be empty. Asserted so that
       nobody tightens the rule to match the sentence that was wrong. */
    expect("Lab:", 1, "trailing colon names a folder, it does not ascend");

    /* ---- the 31-character segment cap ------------------------------ */
    {
        char seg31[64], seg32[64], deep[128];

        memset(seg31, 'x', 31); seg31[31] = '\0';
        memset(seg32, 'x', 32); seg32[32] = '\0';

        expect(seg31, 1, "31 characters is what HFS can name");
        expect(seg32, 0, "32 cannot, and is refused not truncated");

        /* The cap is per SEGMENT, not per path: a long path of short
           names is fine, and the counter must reset at each colon. */
        strcpy(deep, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");   /* 31 */
        strcat(deep, ":");
        strcat(deep, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");   /* 31 */
        expect(deep, 1, "the cap is per segment, so the count resets");

        strcpy(deep, "ok:");
        strcat(deep, seg32);
        expect(deep, 0, "an overlong segment anywhere fails the path");
    }

    /* ---- the argument itself --------------------------------------- */
    expect(NULL, 0, "NULL is refused rather than dereferenced");

    if (g_failed != 0) {
        fprintf(stderr, "%d of %d checks failed\n", g_failed, g_checks);
        return 1;
    }
    printf("share_path: %d checks ok\n", g_checks);
    return 0;
}
