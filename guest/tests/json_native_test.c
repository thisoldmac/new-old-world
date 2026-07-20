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

    printf("json_native_test: all assertions passed\n");
    return 0;
}
