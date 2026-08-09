#include "development_sha256.h"

#include <assert.h>
#include <string.h>

static void check(const char *text, const char *expected)
{
    DevSHA256 sha;
    unsigned char digest[32];
    char hex[65];
    dev_sha256_init(&sha);
    dev_sha256_update(&sha, text, strlen(text));
    dev_sha256_final(&sha, digest);
    dev_sha256_hex(digest, hex);
    assert(strcmp(hex, expected) == 0);
}

int main(void)
{
    check("", "e3b0c44298fc1c149afbf4c8996fb924"
              "27ae41e4649b934ca495991b7852b855");
    check("abc", "ba7816bf8f01cfea414140de5dae2223"
                 "b00361a396177a9cb410ff61f20015ad");
    check("The quick brown fox jumps over the lazy dog",
          "d7a8fbb307d7809469ca9abcb0082e4f"
          "8d5651e46d3cdb762d02d0bf37c9e592");
    return 0;
}
