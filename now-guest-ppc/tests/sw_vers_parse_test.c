/* Native (host-side) test for now-guest-ppc/src/software/sw_vers_parse.c — NOT built for
   the Mac. Parsing a 'vers' resource is plain byte work with no Toolbox
   dependency, so it runs under any host compiler:

       cc -Wall -Wextra -o sw_vers_test \
          now-guest-ppc/tests/sw_vers_parse_test.c now-guest-ppc/src/software/sw_vers_parse.c \
       && ./sw_vers_test

   The bounds a truncated or lying 'vers' must survive are the whole
   point of pulling this out of the Toolbox: a resource in a decade-old
   file is data, and a length byte that claims more than the handle
   holds must clamp, not read past it. Every case below is a byte array
   that a real old file could contain. */

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "sw_vers_parse.h"


/* Build a well-formed 'vers' into buf: 4 numeric bytes, 2 region, then
   the short and Get Info Pascal strings. Returns the byte count. */
static long build_vers(unsigned char *buf,
                       unsigned char major, unsigned char minorbug,
                       unsigned char stage, unsigned char rev,
                       const char *shortstr, const char *infostr)
{
    long n = 0;
    long sl = (long)strlen(shortstr);
    long il = (long)strlen(infostr);

    buf[n++] = major;
    buf[n++] = minorbug;
    buf[n++] = stage;
    buf[n++] = rev;
    buf[n++] = 0x00;                   /* region high */
    buf[n++] = 0x00;                   /* region low */
    buf[n++] = (unsigned char)sl;
    memcpy(buf + n, shortstr, (size_t)sl);
    n += sl;
    buf[n++] = (unsigned char)il;
    memcpy(buf + n, infostr, (size_t)il);
    n += il;
    return n;
}

/* A released 1.4.0: short "1.4", numeric "1.4.0 final", Get Info kept. */
static void test_normal_release(void)
{
    unsigned char v[64];
    long size = build_vers(v, 0x01, 0x40, 0x80, 0x00, "1.4",
                           "1.4, by NOW");
    char shortv[64], numeric[64], info[64];

    assert(sw_parse_vers(v, size, shortv, sizeof shortv,
                         numeric, sizeof numeric, info, sizeof info) == 1);
    assert(strcmp(shortv, "1.4") == 0);
    assert(strcmp(numeric, "1.4.0 final") == 0);
    assert(strcmp(info, "1.4, by NOW") == 0);
}

/* A non-final stage with a non-zero revision is a prerelease; the guard
   is (stage != final && rev != 0), so a beta at revision 0 is NOT. */
static void test_prerelease(void)
{
    unsigned char v[64];
    char shortv[64], numeric[64], info[64];
    long size;

    size = build_vers(v, 0x02, 0x10, 0x60, 0x01, "2.1b1", "2.1 beta 1");
    assert(sw_parse_vers(v, size, shortv, sizeof shortv,
                         numeric, sizeof numeric, info, sizeof info) == 1);
    assert(strcmp(shortv, "2.1b1") == 0);
    assert(strcmp(numeric, "2.1.0 beta (prerelease)") == 0);

    /* Same beta stage, revision 0: no suffix — the guard needs both. */
    size = build_vers(v, 0x02, 0x10, 0x60, 0x00, "2.1", "");
    assert(sw_parse_vers(v, size, shortv, sizeof shortv,
                         numeric, sizeof numeric, info, sizeof info) == 1);
    assert(strcmp(numeric, "2.1.0 beta") == 0);

    /* And a final at a non-zero revision is still not a prerelease. */
    size = build_vers(v, 0x01, 0x00, 0x80, 0x05, "1.0", "");
    assert(sw_parse_vers(v, size, shortv, sizeof shortv,
                         numeric, sizeof numeric, info, sizeof info) == 1);
    assert(strcmp(numeric, "1.0.0 final") == 0);
}

/* A resource too short to name a version is data, not a crash: it reads
   as absent (0), with every out buffer left "". */
static void test_truncated(void)
{
    unsigned char five[5] = { 0x01, 0x40, 0x80, 0x00, 0x00 };
    unsigned char shortonly[8] = { 0x01, 0x40, 0x80, 0x00, 0x00, 0x00,
                                   0x01, 'A' };
    char shortv[64], numeric[64], info[64];

    strcpy(shortv, "sentinel");
    strcpy(numeric, "sentinel");
    strcpy(info, "sentinel");
    assert(sw_parse_vers(five, sizeof five, shortv, sizeof shortv,
                         numeric, sizeof numeric, info, sizeof info) == 0);
    assert(shortv[0] == '\0');
    assert(numeric[0] == '\0');
    assert(info[0] == '\0');

    /* Exactly the numeric bytes, region, and a one-char short string —
       nothing past it for a Get Info length, so info stays "". */
    assert(sw_parse_vers(shortonly, sizeof shortonly,
                         shortv, sizeof shortv, numeric, sizeof numeric,
                         info, sizeof info) == 1);
    assert(strcmp(shortv, "A") == 0);
    assert(strcmp(numeric, "1.4.0 final") == 0);
    assert(info[0] == '\0');
}

/* A short-version length of 0 is a real, if odd, resource: it yields a
   version (1) with an empty short string, and the numeric still renders. */
static void test_empty_short(void)
{
    unsigned char v[7] = { 0x03, 0x21, 0x80, 0x00, 0x00, 0x00, 0x00 };
    char shortv[64], numeric[64], info[64];

    assert(sw_parse_vers(v, sizeof v, shortv, sizeof shortv,
                         numeric, sizeof numeric, info, sizeof info) == 1);
    assert(shortv[0] == '\0');
    assert(strcmp(numeric, "3.2.1 final") == 0);
    assert(info[0] == '\0');
}

/* Two independent clamps. A length byte larger than the buffer must fit
   the buffer; a length byte larger than the handle must fit the handle —
   the second is the guard against reading past a lying resource. */
static void test_oversized_clamp(void)
{
    unsigned char v[64];
    char small[4];
    char shortv[64], numeric[64], info[64];
    long size;

    /* Buffer clamp: a real 10-char short version into a 4-byte buffer
       keeps 3 characters plus the NUL, never more. */
    size = build_vers(v, 0x01, 0x00, 0x80, 0x00, "ABCDEFGHIJ", "");
    assert(sw_parse_vers(v, size, small, sizeof small,
                         NULL, 0, NULL, 0) == 1);
    assert(strcmp(small, "ABC") == 0);

    /* Handle clamp: a length byte of 200 in a resource that ends at 10
       must read only the 3 bytes that are actually there. */
    {
        unsigned char lying[10] = { 0x01, 0x00, 0x80, 0x00, 0x00, 0x00,
                                    200, 'X', 'Y', 'Z' };

        assert(sw_parse_vers(lying, sizeof lying, shortv, sizeof shortv,
                             numeric, sizeof numeric,
                             info, sizeof info) == 1);
        assert(strcmp(shortv, "XYZ") == 0);   /* clamped to size - 7 */
        assert(info[0] == '\0');
    }

    /* A Get Info length that overruns the handle clamps the same way. */
    {
        unsigned char lying_info[12] = { 0x01, 0x00, 0x80, 0x00, 0x00,
                                         0x00, 0x02, 'v', '1', 200,
                                         'H', 'i' };

        assert(sw_parse_vers(lying_info, sizeof lying_info,
                             shortv, sizeof shortv, numeric, sizeof numeric,
                             info, sizeof info) == 1);
        assert(strcmp(shortv, "v1") == 0);
        assert(strcmp(info, "Hi") == 0);      /* the 2 bytes that exist */
    }
}

/* now_software_read_version passes NULL for the numeric and Get Info
   buffers with cap 0; that must skip those fields, not fault, and still
   fill the short version. NULL bytes / short size read as absent. */
static void test_null_buffers(void)
{
    unsigned char v[64];
    long size = build_vers(v, 0x01, 0x40, 0x80, 0x00, "1.4", "info");
    char shortv[64];

    assert(sw_parse_vers(v, size, shortv, sizeof shortv,
                         NULL, 0, NULL, 0) == 1);
    assert(strcmp(shortv, "1.4") == 0);

    /* Every buffer skipped at once is legal too. */
    assert(sw_parse_vers(v, size, NULL, 0, NULL, 0, NULL, 0) == 1);

    /* No bytes at all is absent, not a crash. */
    assert(sw_parse_vers(NULL, 0, shortv, sizeof shortv,
                         NULL, 0, NULL, 0) == 0);
    assert(shortv[0] == '\0');
}

int main(void)
{
    test_normal_release();
    test_prerelease();
    test_truncated();
    test_empty_short();
    test_oversized_clamp();
    test_null_buffers();

    printf("sw_vers_parse_test: all assertions passed\n");
    return 0;
}
