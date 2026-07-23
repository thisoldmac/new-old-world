/* Native (host-side) test for guest/src/json.c — NOT built for the Mac.
   The scanner is plain C with no Toolbox dependency, so it can run under
   any host compiler:

       cc -Wall -Wextra -Werror -I ../src json_native_test.c ../src/json.c \
          -o json_native_test && ./json_native_test

   Asserts the tolerant behaviors the three pre-consolidation copies were
   patched for: whitespace around the colon, missing keys, bounded copies
   into small buffers, and type-mismatch returns. */

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "json.h"


/* --- decoding what the other machine sends ------------------------------
   The host speaks UTF-8; this machine draws MacRoman and stores MacRoman
   in file names. Everything a person reads crosses that boundary, and a
   name that changes crossing it names a different file. */
/* The trap that reported every successful send as a failure: "ok" is a
   JSON boolean, find_int is strtol, and strtol on "true" is 0. Reading
   a boolean as an int is not a type mismatch the compiler can see —
   both return long — so it has to be caught here. */
static void test_booleans_are_not_integers(void)
{
    const char done[] = "{\"type\":\"file.done\",\"id\":5,\"ok\":true}";

    assert(now_json_find_int(done, "ok", -1) == 0);   /* the trap */
    assert(now_json_find_bool(done, "ok", 0) == 1);   /* the answer */
    assert(now_json_find_bool("{\"ok\":false}", "ok", 1) == 0);
    /* Absent reads as the fallback, so "no answer" and "said no" stay
       different things. */
    assert(now_json_find_bool("{\"id\":1}", "ok", 1) == 1);
    assert(now_json_find_bool("{\"id\":1}", "ok", 0) == 0);
}

static void test_text_decoding(void)
{
    char buf[64];

    /* Swift's encoder emits raw UTF-8 for non-ASCII, not \u escapes. */
    assert(now_json_find_text("{\"name\":\"caf\xC3\xA9\"}", "name",
                              buf, sizeof buf) == 1);
    assert((unsigned char)buf[3] == 0x8E);   /* MacRoman e-acute */
    assert(buf[4] == '\0');

    /* And \u escapes, which is what THIS machine emits going the other
       way, so a name can survive a round trip. */
    assert(now_json_find_text("{\"name\":\"caf\\u00e9\"}", "name",
                              buf, sizeof buf) == 1);
    assert((unsigned char)buf[3] == 0x8E);

    /* The registered mark: MacRoman 0xA8, U+00AE, UTF-8 0xC2 0xAE. The
       host sends it raw (this form), and a launch/reveal target must
       decode to the single MacRoman byte FSMakeFSSpec matches on -
       "Adobe Photoshop(R) 5.0" round-tripped to "no such file" when the
       command handlers read it with find_string instead. */
    assert(now_json_find_text("{\"target\":\"P\xC2\xAE\"}", "target",
                              buf, sizeof buf) == 1);
    assert((unsigned char)buf[0] == 'P');
    assert((unsigned char)buf[1] == 0xA8);   /* MacRoman registered mark */
    assert(buf[2] == '\0');

    /* The Apple logo: MacRoman 0xF0, U+F8FF. A file really can be
       called this, and it is the character most likely to be mangled. */
    assert(now_json_find_text("{\"n\":\"\\uF8FF\"}", "n", buf,
                              sizeof buf) == 1);
    assert((unsigned char)buf[0] == 0xF0);

    /* Something MacRoman has no answer for becomes a visible mark, not
       nothing: a name must not silently shorten. */
    assert(now_json_find_text("{\"n\":\"a\\u4E2Db\"}", "n", buf,
                              sizeof buf) == 1);
    assert(strcmp(buf, "a?b") == 0);

    /* Outside the BMP arrives as a surrogate pair and must consume BOTH
       halves, or the second one decodes as a stray character. */
    assert(now_json_find_text("{\"n\":\"a\\uD83D\\uDE00b\"}", "n", buf,
                              sizeof buf) == 1);
    assert(strcmp(buf, "a?b") == 0);

    /* Escaped quotes and backslashes survive as themselves. */
    assert(now_json_find_text("{\"n\":\"a\\\"b\\\\c\"}", "n", buf,
                              sizeof buf) == 1);
    assert(strcmp(buf, "a\"b\\c") == 0);

    /* A newline in a name becomes CR: this machine's line ending. The
       classic volume root really does contain "Icon\r". */
    assert(now_json_find_text("{\"n\":\"Icon\\n\"}", "n", buf,
                              sizeof buf) == 1);
    assert(strcmp(buf, "Icon\r") == 0);

    /* Malformed UTF-8 must not walk off the end. Built at runtime: a
       \xFF followed by 'b' in a literal is one hex escape out of range. */
    {
        char malformed[16];

        snprintf(malformed, sizeof malformed, "{\"n\":\"a%c%cb\"}",
                 (char)0xFF, (char)0xFE);
        assert(now_json_find_text(malformed, "n", buf, sizeof buf) == 1);
        assert(strlen(buf) <= 4);
    }

    /* Bounded like every other copy here. */
    {
        char small[4];

        assert(now_json_find_text("{\"n\":\"abcdefgh\"}", "n", small,
                                  sizeof small) == 1);
        assert(strlen(small) == 3);
    }

    /* A round trip: escape then decode gives back what we started with. */
    {
        char wire[128];
        char back[64];
        char original[16];

        snprintf(original, sizeof original, "Caf%c %c Notes",
                 (char)0x8E, (char)0xF0);      /* e-acute, Apple logo */
        char message[160];

        now_json_escape(original, wire, sizeof wire);
        snprintf(message, sizeof message, "{\"n\":\"%s\"}", wire);
        assert(now_json_find_text(message, "n", back, sizeof back) == 1);
        assert(strcmp(back, original) == 0);
    }
}

/* --- the inbound HFS path the File Manager will open --------------------
   A path argument is not a protocol token. The host sends it UTF-8, and
   FSMakeFSSpec wants the MacRoman byte, so the file-op verbs (file.move,
   file.trash, file.restore, file.list) pull "path"/"toPath"/"trashedAs"
   with find_text. This pins the reason: the same file.move payload
   decoded both ways, and only find_text hands the File Manager a name it
   can resolve. If the extractor is ever reverted to find_string, the
   registered sign below reaches FSMakeFSSpec as the wrong two bytes and
   the move looks for a file that does not exist. */
static void test_inbound_hfs_path(void)
{
    /* Disk:caf(e-acute)(registered): the accent is UTF-8 0xC3 0xA9, the
       registered sign 0xC2 0xAE — the byte the Software fix was traced
       to, MacRoman 0xA8. */
    const char move[] =
        "{\"type\":\"file.move\",\"id\":1,"
        "\"path\":\"Disk:caf\xC3\xA9\xC2\xAE\","
        "\"toPath\":\"Disk:Trash\"}";
    char from[224], to[224];

    /* What the fixed server does: UTF-8 collapsed to the MacRoman bytes
       an FSSpec is built from. */
    assert(now_json_find_text(move, "path", from, sizeof from) == 1);
    assert(strncmp(from, "Disk:caf", 8) == 0);   /* ASCII, colon and all */
    assert((unsigned char)from[8] == 0x8E);      /* e-acute   */
    assert((unsigned char)from[9] == 0xA8);      /* registered */
    assert(from[10] == '\0');                     /* two bytes became two */

    /* The bug the swap removes: find_string keeps the raw UTF-8, so the
       name is four bytes where the file's is two — a different file. */
    assert(now_json_find_string(move, "path", from, sizeof from) == 1);
    assert((unsigned char)from[8] == 0xC3);
    assert((unsigned char)from[9] == 0xA9);
    assert((unsigned char)from[10] == 0xC2);
    assert((unsigned char)from[11] == 0xAE);

    /* toPath comes through the same door; ASCII here, unchanged. */
    assert(now_json_find_text(move, "toPath", to, sizeof to) == 1);
    assert(strcmp(to, "Disk:Trash") == 0);
}

/* --- walking a listing --------------------------------------------------
   Flat key lookup cannot read an array of objects, and a lookup that
   runs past its object silently answers with a sibling's value. */
static void test_array_walking(void)
{
    const char listing[] =
        "{\"type\":\"file.listing\",\"path\":\"\",\"entries\":["
        "{\"name\":\"Docs\",\"kind\":\"folder\",\"modified\":1},"
        "{\"name\":\"Notes\",\"kind\":\"file\",\"dataBytes\":66}],"
        "\"more\":false,\"cursor\":3}";
    char object[128];
    char name[32];
    const char *p;

    p = now_json_array(listing, "entries");
    assert(p != NULL);

    p = now_json_next_object(p, object, sizeof object);
    assert(p != NULL);
    assert(now_json_find_text(object, "name", name, sizeof name) == 1);
    assert(strcmp(name, "Docs") == 0);
    /* The key belongs to the NEXT object: reading it here would be
       reading a sibling. */
    assert(now_json_find_int(object, "dataBytes", -1) == -1);

    p = now_json_next_object(p, object, sizeof object);
    assert(p != NULL);
    assert(now_json_find_text(object, "name", name, sizeof name) == 1);
    assert(strcmp(name, "Notes") == 0);
    assert(now_json_find_int(object, "dataBytes", -1) == 66);

    assert(now_json_next_object(p, object, sizeof object) == NULL);

    /* An empty array ends immediately rather than reporting an object. */
    assert(now_json_next_object(now_json_array("{\"entries\":[]}",
                                               "entries"),
                                object, sizeof object) == NULL);

    /* A name containing a brace must not end the object early. */
    {
        const char tricky[] = "{\"entries\":[{\"name\":\"a}b{c\"},"
                              "{\"name\":\"second\"}]}";

        p = now_json_array(tricky, "entries");
        p = now_json_next_object(p, object, sizeof object);
        assert(p != NULL);
        assert(now_json_find_text(object, "name", name, sizeof name) == 1);
        assert(strcmp(name, "a}b{c") == 0);
        p = now_json_next_object(p, object, sizeof object);
        assert(p != NULL);
        assert(now_json_find_text(object, "name", name, sizeof name) == 1);
        assert(strcmp(name, "second") == 0);
    }

    /* A truncated array refuses rather than handing back half an
       object: a half-read name is a wrong name, not a shorter one. */
    {
        const char cut[] = "{\"entries\":[{\"name\":\"Docs\"";

        assert(now_json_next_object(now_json_array(cut, "entries"),
                                    object, sizeof object) == NULL);
    }
}

int main(void)
{
    char buf[64];
    char tiny[4];

    /* Compact encoding — the common case. */
    assert(now_json_find_string("{\"type\":\"pong\",\"id\":7}", "type",
                                buf, sizeof buf) == 1);
    assert(strcmp(buf, "pong") == 0);
    assert(now_json_find_int("{\"type\":\"pong\",\"id\":7}", "id", -1) == 7);
    assert(now_json_type_is("{\"type\":\"pong\"}", "pong") == 1);
    assert(now_json_type_is("{\"type\":\"pong\"}", "ping") == 0);

    /* Whitespace around the colon — the divergence that bit twice. */
    assert(now_json_find_string("{\"name\" : \"Q950\"}", "name",
                                buf, sizeof buf) == 1);
    assert(strcmp(buf, "Q950") == 0);
    assert(now_json_find_string("{\"name\"\t:\t\"Q950\"}", "name",
                                buf, sizeof buf) == 1);
    assert(strcmp(buf, "Q950") == 0);
    assert(now_json_find_string("{\n  \"name\" :\r\n  \"Q950\"\n}", "name",
                                buf, sizeof buf) == 1);
    assert(strcmp(buf, "Q950") == 0);
    assert(now_json_find_int("{\"id\" : 42}", "id", -1) == 42);
    assert(now_json_find_int("{\"id\"\n:\n-3}", "id", 0) == -3);
    assert(now_json_type_is("{ \"type\" : \"hello\" }", "hello") == 1);

    /* Missing key: find_string returns 0 and leaves out untouched;
       find_int returns the fallback. */
    strcpy(buf, "sentinel");
    assert(now_json_find_string("{\"a\":\"b\"}", "missing",
                                buf, sizeof buf) == 0);
    assert(strcmp(buf, "sentinel") == 0);
    assert(now_json_find_int("{\"a\":1}", "missing", -99) == -99);

    /* Type mismatch: a non-string value is not a string hit. */
    assert(now_json_find_string("{\"id\":42}", "id", buf, sizeof buf) == 0);
    assert(now_json_find_string("{\"ok\":true}", "ok", buf, sizeof buf) == 0);

    /* Bounded copy: cap - 1 characters plus the NUL, never more. */
    memset(tiny, 'X', sizeof tiny);
    assert(now_json_find_string("{\"name\":\"longvalue\"}", "name",
                                tiny, sizeof tiny) == 1);
    assert(strcmp(tiny, "lon") == 0);

    /* Unterminated string still stays inside the buffer. */
    assert(now_json_find_string("{\"name\":\"runaway", "name",
                                buf, sizeof buf) == 1);
    assert(strcmp(buf, "runaway") == 0);

    /* Keys past the first are found wherever they sit in the message. */
    assert(now_json_find_int("{\"id\":5,\"depth\":8}", "depth", -1) == 8);

    /* NULL safety. */
    assert(now_json_value(NULL, "k") == NULL);
    assert(now_json_value("{}", NULL) == NULL);
    assert(now_json_find_string(NULL, "k", buf, sizeof buf) == 0);
    assert(now_json_find_string("{\"k\":\"v\"}", "k", NULL, 8) == 0);
    assert(now_json_find_int(NULL, "k", 13) == 13);
    assert(now_json_type_is(NULL, "hello") == 0);
    assert(now_json_type_is("{\"type\":\"x\"}", NULL) == 0);

    /* Escaping: a classic volume root holds "Icon\r" and accented
       names, and raw bytes there are both invalid JSON and invalid
       UTF-8 - the failure mode is a listing the modern side silently
       cannot decode. */
    {
        char out[256];

        now_json_escape("Read Me", out, sizeof out);
        assert(strcmp(out, "Read Me") == 0);

        now_json_escape("Icon\r", out, sizeof out);
        assert(strcmp(out, "Icon\\u000D") == 0);

        now_json_escape("say \"hi\"", out, sizeof out);
        assert(strcmp(out, "say \\\"hi\\\"") == 0);

        now_json_escape("back\\slash", out, sizeof out);
        assert(strcmp(out, "back\\\\slash") == 0);

        /* MacRoman 0x8E is e-acute; Latin-1 would be wrong here. */
        now_json_escape("caf\x8e", out, sizeof out);
        assert(strcmp(out, "caf\\u00E9") == 0);

        /* 0xF0 is the Apple logo, in the private use area. */
        now_json_escape("\xf0", out, sizeof out);
        assert(strcmp(out, "\\uF8FF") == 0);

        /* Bounded: a truncated escape must never be emitted. */
        now_json_escape("caf\x8e", out, 8);
        assert(strlen(out) <= 7);
        assert(strcmp(out, "caf") == 0);

        now_json_escape(NULL, out, sizeof out);
        assert(out[0] == '\0');
    }

    printf("json_native_test: all assertions passed\n");
    test_booleans_are_not_integers();
    test_text_decoding();
    test_inbound_hfs_path();
    test_array_walking();

    return 0;
}
