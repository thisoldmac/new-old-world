#ifndef NOW_SHA256_H
#define NOW_SHA256_H

typedef struct {
    unsigned int state[8];
    unsigned int count_hi;
    unsigned int count_lo;
    unsigned char block[64];
    unsigned int block_len;
} NowSHA256;

void now_sha256_init(NowSHA256 *ctx);
void now_sha256_update(NowSHA256 *ctx, const void *bytes, long len);
void now_sha256_final(NowSHA256 *ctx, unsigned char digest[32]);
void now_sha256_hex(const unsigned char digest[32], char out[65]);

#endif
