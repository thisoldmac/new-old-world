/* Native test for the ported dialog-text reader.

       cc -Wall -Wextra -Werror -I ../src/axwalk -I ../src/peek -I . \
          axtext_test.c ../src/axwalk/axtext.c ../src/axwalk/axwalk.c \
          ../src/peek/peek_validate.c -o axtext_test && ./axtext_test

   Pins textH's offset in the DialogRecord and the five TERec fields the
   reader uses, and checks the coherence rule that is the parser's own
   lie detector: a selection outside the text means the offsets are
   wrong, and the honest response is to refuse rather than to report a
   plausible-looking string. */

#include <stdio.h>
#include <string.h>

#include "axfixture.h"
#include "axtext.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

enum {
    kWin = 0x00101000,
    kTeH = 0x00102000,
    kTeRec = 0x00102100,
    kTextH = 0x00103000,
    kTextData = 0x00103100
};

static void build(AxFixture *f, const char *text, unsigned len,
                  unsigned sel_start, unsigned sel_end, int active)
{
    unsigned i;

    axfix_put32(f, kWin + 160, kTeH);
    axfix_put_handle(f, kTeH, kTeRec);
    axfix_put16(f, kTeRec + 32, (int)sel_start);
    axfix_put16(f, kTeRec + 34, (int)sel_end);
    axfix_put16(f, kTeRec + 36, active ? -1 : 0);
    axfix_put16(f, kTeRec + 60, (int)len);
    axfix_put32(f, kTeRec + 62, kTextH);
    axfix_put_handle(f, kTextH, kTextData);
    for (i = 0; i < len; i++) {
        axfix_put8(f, kTextData + i, (unsigned char)text[i % strlen(text)]);
    }
}

static void reads_text(void)
{
    AxFixture f;
    NowAxMemory m;
    NowAxText t;

    axfix_init(&f, &m);
    build(&f, "Untitled", 8, 2, 5, 1);

    check(now_ax_read_dialog_text(&m, kWin, &t) == kNowAxOk, "text reads");
    check(t.length == 8 && t.returned == 8, "teLength @60");
    check(strcmp(t.text, "Untitled") == 0, "hText @62 -> the bytes");
    check(t.selection_start == 2 && t.selection_end == 5,
          "selStart/selEnd @32/34");
    check(t.active == 1, "teActive @36");
    check(t.truncated == 0, "nothing was dropped");

    axfix_put16(&f, kTeRec + 36, 0);
    check(now_ax_read_dialog_text(&m, kWin, &t) == kNowAxOk && t.active == 0,
          "an inactive TERec reads as inactive");
}

static void empty_and_absent(void)
{
    AxFixture f;
    NowAxMemory m;
    NowAxText t;

    axfix_init(&f, &m);
    build(&f, "x", 0, 0, 0, 1);
    check(now_ax_read_dialog_text(&m, kWin, &t) == kNowAxOk,
          "an empty TERec is not a failure");
    check(t.length == 0 && t.text[0] == '\0', "and reports empty");
    /* With no text, hText is never followed - a null one must not turn
       an empty field into an error. */
    axfix_put32(&f, kTeRec + 62, 0);
    check(now_ax_read_dialog_text(&m, kWin, &t) == kNowAxOk,
          "an empty TERec with a null hText still reads");

    axfix_init(&f, &m);
    axfix_put32(&f, kWin + 160, 0);
    check(now_ax_read_dialog_text(&m, kWin, &t) == kNowAxNotFound,
          "a window with no TEHandle is NotFound, not an error");
}

static void truncation(void)
{
    AxFixture f;
    NowAxMemory m;
    NowAxText t;

    axfix_init(&f, &m);
    build(&f, "abcdefgh", kNowAxTextMax + 10, 0, 0, 1);
    check(now_ax_read_dialog_text(&m, kWin, &t) == kNowAxOk,
          "an over-long text still reads");
    check(t.length == kNowAxTextMax + 10, "the FULL length is reported");
    check(t.returned == kNowAxTextMax, "only what fits is returned");
    check(t.truncated == 1, "and the difference is flagged");
    check(t.text[kNowAxTextMax] == '\0', "the buffer is terminated");
}

static void incoherent_records_are_refused(void)
{
    AxFixture f;
    NowAxMemory m;
    NowAxText t;

    axfix_init(&f, &m);
    build(&f, "Untitled", 8, 0, 0, 1);
    axfix_put16(&f, kTeRec + 34, 9);      /* selEnd past the end */
    check(now_ax_read_dialog_text(&m, kWin, &t) == kNowAxInvalid,
          "a selection past the text is refused");

    build(&f, "Untitled", 8, 5, 2, 1);    /* selStart > selEnd */
    check(now_ax_read_dialog_text(&m, kWin, &t) == kNowAxInvalid,
          "an inverted selection is refused");

    build(&f, "Untitled", 8, 0, 0, 1);
    axfix_put16(&f, kTeRec + 60, -1);     /* 0xFFFF: the sign bit set */
    check(now_ax_read_dialog_text(&m, kWin, &t) == kNowAxInvalid,
          "a length with the sign bit set is not a teLength");

    build(&f, "Untitled", 8, 0, 0, 1);
    axfix_put_handle(&f, kTeH, 0x00900000UL);
    check(now_ax_read_dialog_text(&m, kWin, &t) == kNowAxInvalid,
          "a TERec outside both zones is refused");

    build(&f, "Untitled", 8, 0, 0, 1);
    axfix_put_handle(&f, kTextH, 0x00900000UL);
    check(now_ax_read_dialog_text(&m, kWin, &t) == kNowAxInvalid,
          "text bytes outside both zones are refused");
    check(f.refused == 0, "every refusal came before the seam");
}

int main(void)
{
    reads_text();
    empty_and_absent();
    truncation();
    incoherent_records_are_refused();

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("axtext_test: ok\n");
    return 0;
}
