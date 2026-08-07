/* Native test for the `desktop` reply serializer - runs on the host:
   cc -Wall -Wextra -Werror -I ../src desktop_report_test.c \
      ../src/machine/desktop_report.c ../src/core/json.c -o t && ./t
   Pure C on both sides, the census_report_test.c pattern.

   What it is guarding: the desktop answer is the one place the renderer
   is told whether a pattern is even VISIBLE, and the failure this whole
   lane exists to stop is a confident wrong answer. So the assertions are
   about honesty under pressure - a full answer must not truncate onto the
   wire, an absent pattern must not read as a present one, and the hex
   must be the bytes the machine gave rather than a prettified form. */

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "desktop.h"
#include "json.h"

static void test_source_names(void)
{
    assert(strcmp(now_desktop_source_name(kDesktopSourcePattern), "pattern") == 0);
    assert(strcmp(now_desktop_source_name(kDesktopSourcePicture), "picture") == 0);
    assert(strcmp(now_desktop_source_name(kDesktopSourceUnknown), "unknown") == 0);
    /* A value from a future guest is unknown, never a guess. */
    assert(strcmp(now_desktop_source_name((DesktopSource)99), "unknown") == 0);
}

static void test_hex_is_the_bytes(void)
{
    unsigned char bytes[4];
    char out[16];

    bytes[0] = 0x00;
    bytes[1] = 0x0f;
    bytes[2] = 0xa5;
    bytes[3] = 0xff;
    now_desktop_hex(bytes, 4, out, sizeof out);
    assert(strcmp(out, "000fa5ff") == 0);

    /* A buffer too small stops on a byte boundary rather than emitting
       half a byte - half a hex pair is a number that never existed. */
    now_desktop_hex(bytes, 4, out, 5);
    assert(strcmp(out, "0000") == 0 || strcmp(out, "000f") == 0);
    assert(strlen(out) % 2 == 0);
}

static void test_basic_shape(void)
{
    DesktopAnswer answer;
    char out[3072];
    char text[64];
    long n;

    memset(&answer, 0, sizeof answer);
    answer.source = kDesktopSourcePattern;
    answer.has_pattern = 1;
    answer.pattern_bytes = 40;
    answer.pattern_carried = 40;
    assert(now_desktop_add_row(&answer, "theme", "Apple platinum",
                               "Str255, 15 bytes stored") == 0);
    assert(now_desktop_add_row(&answer, "pattern.0", "00ff00ff",
                               "4 bytes, hex") == 0);
    assert(answer.count == 2);

    n = now_desktop_result_json(11, &answer, out, sizeof out);
    assert(n > 0);
    assert(n == (long)strlen(out));
    assert(now_json_type_is(out, "command.result"));
    assert(now_json_find_int(out, "id", -1) == 11);
    assert(now_json_find_bool(out, "ok", 0));
    assert(now_json_find_string(out, "source", text, sizeof text));
    assert(strcmp(text, "pattern") == 0);
    assert(now_json_find_bool(out, "hasPattern", 0));
    assert(now_json_find_int(out, "patternBytes", -1) == 40);
    assert(strstr(out, "\"desktop\":[[\"theme\",\"Apple platinum\","
                       "\"Str255, 15 bytes stored\"],"
                       "[\"pattern.0\",\"00ff00ff\",\"4 bytes, hex\"]]") != NULL);
    /* Every successful PowerPC reply carries an output object - the
       console renderer rests on it (CommandParityTests pins the rule). */
    assert(strstr(out, "\"output\":{") != NULL);
}

static void test_absent_pattern_does_not_read_as_present(void)
{
    DesktopAnswer answer;
    char out[3072];
    char text[64];

    memset(&answer, 0, sizeof answer);
    answer.source = kDesktopSourceUnknown;
    answer.has_pattern = 0;
    answer.pattern_bytes = -1;
    answer.pattern_carried = 0;
    now_desktop_add_row(&answer, "getTheme", "-43", "OSStatus; refused");
    snprintf(answer.note, sizeof answer.note, "GetTheme refused");

    assert(now_desktop_result_json(3, &answer, out, sizeof out) > 0);
    assert(!now_json_find_bool(out, "hasPattern", 1));
    assert(now_json_find_int(out, "patternBytes", 0) == -1);
    assert(now_json_find_string(out, "source", text, sizeof text));
    assert(strcmp(text, "unknown") == 0);
    assert(now_json_find_string(out, "note", text, sizeof text));
    assert(strcmp(text, "GetTheme refused") == 0);
}

/* The one that pays for the caps in desktop.h. A full answer of
   worst-case rows must fit kNowCommandResultCap with room for the frame;
   if it does not, the guest drops rows at run time and the person reading
   the console loses the hex it was asked for. Watched failing by
   mutation: widening kDesktopRowRawCap to 160 makes this fail. */
static void test_a_full_answer_fits_the_command_result(void)
{
    DesktopAnswer answer;
    char out[3072];               /* kNowCommandResultCap */
    char raw[kDesktopRowRawCap];
    char note[kDesktopRowNoteCap];
    char name[kDesktopRowNameCap];
    int i;

    memset(&answer, 0, sizeof answer);
    answer.source = kDesktopSourcePicture;
    answer.has_pattern = 1;
    answer.pattern_bytes = 999999;
    answer.pattern_carried = 240;
    memset(raw, 'f', sizeof raw);
    raw[sizeof raw - 1] = '\0';
    memset(note, 'n', sizeof note);
    note[sizeof note - 1] = '\0';
    memset(name, 'm', sizeof name);
    name[sizeof name - 1] = '\0';
    for (i = 0; i < kDesktopRowMax; i++) {
        assert(now_desktop_add_row(&answer, name, raw, note) == 0);
    }
    assert(answer.count == kDesktopRowMax);
    /* One row past the cap is refused and SAYS so, rather than silently
       vanishing - a page that loses a row reads as a machine that did not
       have it. */
    assert(now_desktop_add_row(&answer, name, raw, note) == -1);
    assert(strstr(answer.note, "dropped") != NULL);

    assert(now_desktop_result_json(999999, &answer, out, sizeof out) > 0);
}

/* A cap the answer cannot fit produces -1, never a truncated frame. */
static void test_a_short_buffer_refuses_rather_than_truncating(void)
{
    DesktopAnswer answer;
    char out[64];

    memset(&answer, 0, sizeof answer);
    answer.pattern_bytes = -1;
    now_desktop_add_row(&answer, "theme", "Apple platinum", "Str255");
    assert(now_desktop_result_json(1, &answer, out, sizeof out) == -1);
}

/* Fields longer than their caps are truncated into the row rather than
   overrunning it - the gather builds names and hex with snprintf, but the
   row store is the last line of defence. */
static void test_over_long_fields_are_capped(void)
{
    DesktopAnswer answer;
    char big[512];

    memset(&answer, 0, sizeof answer);
    memset(big, 'x', sizeof big);
    big[sizeof big - 1] = '\0';
    assert(now_desktop_add_row(&answer, big, big, big) == 0);
    assert(strlen(answer.rows[0].name) == kDesktopRowNameCap - 1);
    assert(strlen(answer.rows[0].raw) == kDesktopRowRawCap - 1);
    assert(strlen(answer.rows[0].note) == kDesktopRowNoteCap - 1);
}

int main(void)
{
    test_source_names();
    test_hex_is_the_bytes();
    test_basic_shape();
    test_absent_pattern_does_not_read_as_present();
    test_a_full_answer_fits_the_command_result();
    test_a_short_buffer_refuses_rather_than_truncating();
    test_over_long_fields_are_capped();
    printf("ok\n");
    return 0;
}
