/* Native test for the preview's pure half. Run by scripts/test-native;
   the manifest there is the reason this file cannot be forgotten. */

#include <stdio.h>
#include <string.h>

#include "cloud_preview.h"

static int failures;

#define CHECK(cond, name) \
    do { \
        if (cond) { \
            printf("  ok: %s\n", name); \
        } else { \
            printf("FAIL: %s (line %d)\n", name, __LINE__); \
            ++failures; \
        } \
    } while (0)

static void test_parse_good(void)
{
    CloudPreviewBegin b;
    const char *frame =
        "{\"type\":\"preview.begin\",\"id\":41,\"transfer\":3,"
        "\"width\":266,\"height\":200,\"depth\":8,\"rowBytes\":266,"
        "\"bytes\":53200}";

    CHECK(cloud_preview_parse_begin(frame, &b) == 1, "good 8-bit parses");
    CHECK(b.id == 41 && b.transfer == 3, "identity fields");
    CHECK(b.width == 266 && b.height == 200 && b.row_bytes == 266,
          "geometry fields");
    CHECK(b.depth == 8 && b.bytes == 53200, "depth and total");
}

static void test_parse_one_bit(void)
{
    CloudPreviewBegin b;
    const char *frame =
        "{\"type\":\"preview.begin\",\"id\":7,\"transfer\":9,"
        "\"width\":30,\"height\":9,\"depth\":1,\"rowBytes\":4,"
        "\"bytes\":36}";

    CHECK(cloud_preview_parse_begin(frame, &b) == 1,
          "1-bit with ceil(30/8)=4 parses");
}

static void test_parse_rejects(void)
{
    CloudPreviewBegin b;

    CHECK(cloud_preview_parse_begin(
              "{\"id\":1,\"transfer\":1,\"width\":10,\"height\":10,"
              "\"depth\":4,\"rowBytes\":10,\"bytes\":100}", &b) == 0,
          "depth 4 is refused, not guessed at");
    CHECK(cloud_preview_parse_begin(
              "{\"id\":1,\"transfer\":1,\"width\":10,\"height\":10,"
              "\"depth\":8,\"rowBytes\":9,\"bytes\":90}", &b) == 0,
          "rowBytes under the width is incoherent");
    CHECK(cloud_preview_parse_begin(
              "{\"id\":1,\"transfer\":1,\"width\":10,\"height\":10,"
              "\"depth\":8,\"rowBytes\":10,\"bytes\":99}", &b) == 0,
          "bytes must equal rowBytes * height");
    CHECK(cloud_preview_parse_begin(
              "{\"id\":1,\"transfer\":0,\"width\":10,\"height\":10,"
              "\"depth\":8,\"rowBytes\":10,\"bytes\":100}", &b) == 0,
          "transfer 0 is not a transfer");
    CHECK(cloud_preview_parse_begin(
              "{\"id\":1,\"transfer\":1,\"width\":641,\"height\":481,"
              "\"depth\":8,\"rowBytes\":641,\"bytes\":308321}", &b) == 0,
          "a begin past the ceiling is a peer, not a preview");
    CHECK(cloud_preview_parse_begin("{\"type\":\"preview.begin\"}",
                                    &b) == 0,
          "missing fields read as malformed, never as zeroes to trust");
}

static void test_ask_depth(void)
{
    CHECK(cloud_preview_ask_depth(32) == 8, "32-bit screen asks 8");
    CHECK(cloud_preview_ask_depth(16) == 8, "16-bit screen asks 8");
    CHECK(cloud_preview_ask_depth(8) == 8, "8-bit screen asks 8");
    CHECK(cloud_preview_ask_depth(4) == 1, "4-bit screen asks 1");
    CHECK(cloud_preview_ask_depth(2) == 1, "2-bit screen asks 1");
    CHECK(cloud_preview_ask_depth(1) == 1, "1-bit screen asks 1");
}

static void test_fit(void)
{
    long dw, dh;

    cloud_preview_fit(266, 200, 266, 200, &dw, &dh);
    CHECK(dw == 266 && dh == 200, "exact fit stays put");
    cloud_preview_fit(400, 300, 200, 200, &dw, &dh);
    CHECK(dw == 200 && dh == 150, "wide source fits by width");
    cloud_preview_fit(300, 400, 200, 200, &dw, &dh);
    CHECK(dh == 200 && dw == 150, "tall source fits by height");
    cloud_preview_fit(100, 75, 200, 200, &dw, &dh);
    CHECK(dw == 200 && dh == 150, "small source zooms to fit the pane");
    cloud_preview_fit(0, 0, 200, 200, &dw, &dh);
    CHECK(dw == 1 && dh == 1, "degenerate input cannot divide by zero");
}

int main(void)
{
    test_parse_good();
    test_parse_one_bit();
    test_parse_rejects();
    test_ask_depth();
    test_fit();
    if (failures > 0) {
        printf("%d failure%s\n", failures, failures == 1 ? "" : "s");
        return 1;
    }
    printf("all ok\n");
    return 0;
}
