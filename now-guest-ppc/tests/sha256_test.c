#include <stdio.h>
#include <string.h>

#include "sha256.h"

static int check(const char *input, const char *want)
{
    NowSHA256 ctx;
    unsigned char digest[32];
    char got[65];

    now_sha256_init(&ctx);
    now_sha256_update(&ctx, input, (long)strlen(input));
    now_sha256_final(&ctx, digest);
    now_sha256_hex(digest, got);
    if (strcmp(got, want) != 0) {
        fprintf(stderr, "sha256(%s): %s != %s\n", input, got, want);
        return 1;
    }
    return 0;
}

int main(void)
{
    return check("", "e3b0c44298fc1c149afbf4c8996fb924"
                     "27ae41e4649b934ca495991b7852b855")
        || check("abc", "ba7816bf8f01cfea414140de5dae2223"
                        "b00361a396177a9cb410ff61f20015ad");
}
