#include "sha256.h"

#include <string.h>

#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
#define CH(x, y, z) (((x) & (y)) ^ (~(x) & (z)))
#define MAJ(x, y, z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))
#define S0(x) (ROR((x), 2) ^ ROR((x), 13) ^ ROR((x), 22))
#define S1(x) (ROR((x), 6) ^ ROR((x), 11) ^ ROR((x), 25))
#define G0(x) (ROR((x), 7) ^ ROR((x), 18) ^ ((x) >> 3))
#define G1(x) (ROR((x), 17) ^ ROR((x), 19) ^ ((x) >> 10))

static const unsigned int k[64] = {
    0x428a2f98UL, 0x71374491UL, 0xb5c0fbcfUL, 0xe9b5dba5UL,
    0x3956c25bUL, 0x59f111f1UL, 0x923f82a4UL, 0xab1c5ed5UL,
    0xd807aa98UL, 0x12835b01UL, 0x243185beUL, 0x550c7dc3UL,
    0x72be5d74UL, 0x80deb1feUL, 0x9bdc06a7UL, 0xc19bf174UL,
    0xe49b69c1UL, 0xefbe4786UL, 0x0fc19dc6UL, 0x240ca1ccUL,
    0x2de92c6fUL, 0x4a7484aaUL, 0x5cb0a9dcUL, 0x76f988daUL,
    0x983e5152UL, 0xa831c66dUL, 0xb00327c8UL, 0xbf597fc7UL,
    0xc6e00bf3UL, 0xd5a79147UL, 0x06ca6351UL, 0x14292967UL,
    0x27b70a85UL, 0x2e1b2138UL, 0x4d2c6dfcUL, 0x53380d13UL,
    0x650a7354UL, 0x766a0abbUL, 0x81c2c92eUL, 0x92722c85UL,
    0xa2bfe8a1UL, 0xa81a664bUL, 0xc24b8b70UL, 0xc76c51a3UL,
    0xd192e819UL, 0xd6990624UL, 0xf40e3585UL, 0x106aa070UL,
    0x19a4c116UL, 0x1e376c08UL, 0x2748774cUL, 0x34b0bcb5UL,
    0x391c0cb3UL, 0x4ed8aa4aUL, 0x5b9cca4fUL, 0x682e6ff3UL,
    0x748f82eeUL, 0x78a5636fUL, 0x84c87814UL, 0x8cc70208UL,
    0x90befffaUL, 0xa4506cebUL, 0xbef9a3f7UL, 0xc67178f2UL
};

static void transform(NowSHA256 *ctx, const unsigned char block[64])
{
    unsigned int w[64], a, b, c, d, e, f, g, h, t1, t2;
    int i;

    for (i = 0; i < 16; ++i) {
        const unsigned char *p = block + i * 4;
        w[i] = ((unsigned int)p[0] << 24) | ((unsigned int)p[1] << 16)
             | ((unsigned int)p[2] << 8) | (unsigned int)p[3];
    }
    for (i = 16; i < 64; ++i) {
        w[i] = (G1(w[i - 2]) + w[i - 7] + G0(w[i - 15]) + w[i - 16])
             & 0xFFFFFFFFUL;
    }
    a = ctx->state[0]; b = ctx->state[1]; c = ctx->state[2];
    d = ctx->state[3]; e = ctx->state[4]; f = ctx->state[5];
    g = ctx->state[6]; h = ctx->state[7];
    for (i = 0; i < 64; ++i) {
        t1 = (h + S1(e) + CH(e, f, g) + k[i] + w[i]) & 0xFFFFFFFFUL;
        t2 = (S0(a) + MAJ(a, b, c)) & 0xFFFFFFFFUL;
        h = g; g = f; f = e; e = (d + t1) & 0xFFFFFFFFUL;
        d = c; c = b; b = a; a = (t1 + t2) & 0xFFFFFFFFUL;
    }
    ctx->state[0] = (ctx->state[0] + a) & 0xFFFFFFFFUL;
    ctx->state[1] = (ctx->state[1] + b) & 0xFFFFFFFFUL;
    ctx->state[2] = (ctx->state[2] + c) & 0xFFFFFFFFUL;
    ctx->state[3] = (ctx->state[3] + d) & 0xFFFFFFFFUL;
    ctx->state[4] = (ctx->state[4] + e) & 0xFFFFFFFFUL;
    ctx->state[5] = (ctx->state[5] + f) & 0xFFFFFFFFUL;
    ctx->state[6] = (ctx->state[6] + g) & 0xFFFFFFFFUL;
    ctx->state[7] = (ctx->state[7] + h) & 0xFFFFFFFFUL;
}

void now_sha256_init(NowSHA256 *ctx)
{
    static const unsigned int initial[8] = {
        0x6a09e667UL, 0xbb67ae85UL, 0x3c6ef372UL, 0xa54ff53aUL,
        0x510e527fUL, 0x9b05688cUL, 0x1f83d9abUL, 0x5be0cd19UL
    };
    memset(ctx, 0, sizeof *ctx);
    memcpy(ctx->state, initial, sizeof initial);
}

void now_sha256_update(NowSHA256 *ctx, const void *bytes, long len)
{
    const unsigned char *p = (const unsigned char *)bytes;
    unsigned int bits;

    if (len <= 0) return;
    bits = (unsigned int)len << 3;
    ctx->count_lo += bits;
    if (ctx->count_lo < bits) ++ctx->count_hi;
    ctx->count_hi += (unsigned int)((unsigned long)len >> 29);
    while (len > 0) {
        unsigned int take = 64 - ctx->block_len;
        if (take > (unsigned long)len) take = (unsigned long)len;
        memcpy(ctx->block + ctx->block_len, p, take);
        ctx->block_len += take;
        p += take;
        len -= (long)take;
        if (ctx->block_len == 64) {
            transform(ctx, ctx->block);
            ctx->block_len = 0;
        }
    }
}

void now_sha256_final(NowSHA256 *ctx, unsigned char digest[32])
{
    unsigned char tail[72];
    unsigned int hi = ctx->count_hi, lo = ctx->count_lo;
    unsigned int pad = ctx->block_len < 56 ? 56 - ctx->block_len
                                           : 120 - ctx->block_len;
    int i;

    memset(tail, 0, sizeof tail);
    tail[0] = 0x80;
    now_sha256_update(ctx, tail, (long)pad);
    tail[0] = (unsigned char)(hi >> 24); tail[1] = (unsigned char)(hi >> 16);
    tail[2] = (unsigned char)(hi >> 8);  tail[3] = (unsigned char)hi;
    tail[4] = (unsigned char)(lo >> 24); tail[5] = (unsigned char)(lo >> 16);
    tail[6] = (unsigned char)(lo >> 8);  tail[7] = (unsigned char)lo;
    now_sha256_update(ctx, tail, 8);
    for (i = 0; i < 8; ++i) {
        digest[i * 4] = (unsigned char)(ctx->state[i] >> 24);
        digest[i * 4 + 1] = (unsigned char)(ctx->state[i] >> 16);
        digest[i * 4 + 2] = (unsigned char)(ctx->state[i] >> 8);
        digest[i * 4 + 3] = (unsigned char)ctx->state[i];
    }
    memset(ctx, 0, sizeof *ctx);
}

void now_sha256_hex(const unsigned char digest[32], char out[65])
{
    static const char hex[] = "0123456789abcdef";
    int i;
    for (i = 0; i < 32; ++i) {
        out[i * 2] = hex[digest[i] >> 4];
        out[i * 2 + 1] = hex[digest[i] & 15];
    }
    out[64] = '\0';
}
