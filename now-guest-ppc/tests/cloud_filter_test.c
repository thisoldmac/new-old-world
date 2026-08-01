/* The live search's pure half:
     cc -Wall -Wextra -Werror -I ../src -I ../src/cloud \
        cloud_filter_test.c ../src/cloud/cloud_filter.c -o /tmp/t && /tmp/t

   Watched failing once by mutation before trusting it: flip
   cloud_filter_matches's `hn - qn` bound to `hn` and the "needle
   longer than haystack" case below stops refusing — the loop reads
   past the end of a short haystack instead. */

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "cloud_filter.h"

static void test_lower(void)
{
    char out[16];

    cloud_filter_lower("PhotoStream", out, sizeof out);
    assert(strcmp(out, "photostream") == 0);

    cloud_filter_lower("already-lower", out, sizeof out);
    assert(strcmp(out, "already-lower") == 0);

    /* Truncates at cap, still terminated. */
    cloud_filter_lower("ABCDEFGHIJ", out, 4);
    assert(strcmp(out, "abc") == 0);

    /* Empty in, empty out. */
    cloud_filter_lower("", out, sizeof out);
    assert(out[0] == '\0');
}

static void test_matches(void)
{
    /* Empty needle matches everything, including nothing at all. */
    assert(cloud_filter_matches("Vacation Photo", "") == 1);
    assert(cloud_filter_matches("", "") == 1);
    assert(cloud_filter_matches(NULL, "") == 1);

    /* Substring anywhere, case already folded on the needle side; the
       haystack's own case is folded by the function itself. */
    assert(cloud_filter_matches("Vacation Photo", "photo") == 1);
    assert(cloud_filter_matches("Vacation Photo", "vaca") == 1);
    assert(cloud_filter_matches("Vacation Photo", "PHOTO") == 0);
    /* ^ needle must arrive already-lowered (cloud_filter_lower's job);
       an un-folded needle simply will not match — this pins that the
       function does NOT fold needle, so a caller cannot skip the
       once-per-keystroke fold and rely on this to cover for it. */
    assert(cloud_filter_matches("Vacation Photo", "cation ph") == 1);

    /* A needle longer than the haystack refuses rather than reading
       out of bounds — the case the header comment's mutation note is
       about. */
    assert(cloud_filter_matches("hi", "hello") == 0);

    /* No match anywhere. */
    assert(cloud_filter_matches("Vacation Photo", "xyz") == 0);

    /* Empty or NULL haystack with a real needle: never a match. */
    assert(cloud_filter_matches("", "a") == 0);
    assert(cloud_filter_matches(NULL, "a") == 0);
}

static void test_matches_either(void)
{
    /* Either field, title or subtitle, admits the row. */
    assert(cloud_filter_matches_either("Family Trip", "12 photos", "trip")
           == 1);
    assert(cloud_filter_matches_either("Family Trip", "12 photos", "photos")
           == 1);
    assert(cloud_filter_matches_either("Family Trip", "12 photos", "xyz")
           == 0);

    /* Empty needle admits a row with an empty subtitle too — the
       "clearing the field restores the full list" contract. */
    assert(cloud_filter_matches_either("Family Trip", "", "") == 1);

    /* A NULL second field (some rows carry no subtitle) still lets the
       first field decide. */
    assert(cloud_filter_matches_either("Family Trip", NULL, "trip") == 1);
    assert(cloud_filter_matches_either("Family Trip", NULL, "xyz") == 0);
}

int main(void)
{
    test_lower();
    test_matches();
    test_matches_either();
    printf("cloud_filter_test: all assertions passed\n");
    return 0;
}
