/* The Files page's path row: naming the place being browsed.
 *
 *     cc -Wall -Wextra -Werror -I ../src/files files_path_label_test.c \
 *        ../src/files/files_path_label.c -o /tmp/t && /tmp/t
 *
 * The row used to say "Shared folder" whatever the host was sharing,
 * and for a subfolder it glued the root straight onto the path with no
 * separator - which read fine only while the root happened to end in a
 * colon. What is pinned here: the listing's own root name wins when
 * present, older hosts still get a label rather than nothing, and a
 * subfolder reads as breadcrumbs from the share root with exactly one
 * colon at the join whichever spelling of root arrived.
 */

#include <stdio.h>
#include <string.h>

#include "files_path_label.h"

static int g_failures;

static void check(const char *root, const char *path, const char *want)
{
    char out[160];

    memset(out, '#', sizeof out);
    now_files_path_label(root, path, out, sizeof out);
    if (strcmp(out, want) != 0) {
        printf("FAIL root=\"%s\" path=\"%s\"\n  want \"%s\"\n  got  \"%s\"\n",
               root != NULL ? root : "(null)",
               path != NULL ? path : "(null)", want, out);
        ++g_failures;
    }
}

int main(void)
{
    /* The root listing names the share by the responder's own name. */
    check("iCloud Drive", "", "iCloud Drive");

    /* A host predating file.listing.root still gets a label. */
    check("", "", "Shared folder");
    check(NULL, "", "Shared folder");

    /* A subfolder reads as breadcrumbs from the share root. */
    check("iCloud Drive", "Attic:Old Sites",
          "iCloud Drive:Attic:Old Sites");
    check("", "Attic:Old Sites", "Shared folder:Attic:Old Sites");
    check(NULL, "Docs", "Shared folder:Docs");

    /* A classic-side root arrives wearing its own separator; the join
       must not double it. */
    check("Macintosh HD:Lab:", "Code", "Macintosh HD:Lab:Code");
    check("Macintosh HD:Lab:", "", "Macintosh HD:Lab:");

    /* A label longer than the buffer is cut, not overrun, and is still
       a string. */
    {
        char tiny[8];

        now_files_path_label("iCloud Drive", "Attic", tiny, sizeof tiny);
        if (strlen(tiny) != 7 || strncmp(tiny, "iCloud ", 7) != 0) {
            printf("FAIL tiny cap: got \"%s\"\n", tiny);
            ++g_failures;
        }
    }

    /* A hostile cap leaves the buffer alone rather than writing at it. */
    {
        char guard[4] = "abc";

        now_files_path_label("x", "y", guard, 0);
        now_files_path_label("x", "y", NULL, 16);
        if (strcmp(guard, "abc") != 0) {
            printf("FAIL cap 0 wrote anyway\n");
            ++g_failures;
        }
    }

    if (g_failures != 0) {
        printf("%d failure%s\n", g_failures, g_failures == 1 ? "" : "s");
        return 1;
    }
    printf("files_path_label: all ok\n");
    return 0;
}
