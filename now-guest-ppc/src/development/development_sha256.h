#ifndef NOW_DEVELOPMENT_SHA256_H
#define NOW_DEVELOPMENT_SHA256_H

#include <stddef.h>
#include <stdint.h>

typedef struct DevSHA256 {
    uint32_t state[8];
    uint64_t bits;
    unsigned char block[64];
    size_t used;
} DevSHA256;

void dev_sha256_init(DevSHA256 *sha);
void dev_sha256_update(DevSHA256 *sha, const void *bytes, size_t count);
void dev_sha256_final(DevSHA256 *sha, unsigned char digest[32]);
void dev_sha256_hex(const unsigned char digest[32], char hex[65]);

#endif
