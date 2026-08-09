/*
 * wire.h - JSON-over-TCP envelope helpers for the harness (see
 * docs/08-wire-protocol.md). Minimal key-scanning parse (we control both ends),
 * plus JSON string escaping for building responses.
 */
#ifndef TIMBOTTU_WIRE_H
#define TIMBOTTU_WIRE_H

#include <stddef.h>
#include <stdint.h>

/* Which app is answering. Every response envelope stamps "backing":"<this>" so
   the host client's honesty guard (Harness expect_backing) can tell a harness
   from a worker from a runner on the same wire. Compile-time because the apps
   are separate builds: the harness build takes the default, the worker/runner
   builds inject -DTBT_BACKING="worker"/"runner" (docs/harness-cutover.md). */
#ifndef TBT_BACKING
#define TBT_BACKING "harness"
#endif

/* Extract an integer value for top-level key `key` from [json, json+len).
   Returns 1 and sets *out on success, 0 otherwise. */
int wire_find_int(const char *json, size_t len, const char *key, long *out);

/* Extract one strict unsigned 32-bit integer. Unlike wire_find_int, this
   rejects overflow, signs, fractional/trailing text, and malformed JSON token
   boundaries instead of saturating. Use it for exact wire identities such as
   ProcessSerialNumber halves. */
int wire_find_u32(const char *json, size_t len, const char *key, uint32_t *out);

/* Extract a boolean value for `key`: JSON true/false (and, leniently, nonzero /
   zero digits). Returns 1 and sets *out (0/1) on success, 0 if the key is
   missing or the value isn't a recognizable boolean. */
int wire_find_bool(const char *json, size_t len, const char *key, int *out);

/* Negative wire_find_str results. Handlers must keep these apart: absent is
   routinely "optional arg, use the default", but overflow is a client error
   and must surface as one (error code "overflow") — never silently read as
   absent/empty (the 2026-07-07 TX/RX audit caught `echo` doing exactly that
   with an oversized msg). */
enum {
    kWireAbsent   = -1,   /* key missing, or its value is not a string */
    kWireOverflow = -2    /* value exceeds outcap; out holds a NUL-terminated
                             truncated prefix (safe to log, not to use) */
};

/* Extract a string value for `key` into out[0..outcap), NUL-terminated, with
   minimal unescaping (\n \t \r \" \\). Returns the length, kWireAbsent if the
   key is missing (or its value malformed), or kWireOverflow if the value does
   not fit outcap. */
int wire_find_str(const char *json, size_t len, const char *key,
                  char *out, size_t outcap);

/* JSON-escape in[0..inlen) into out (NUL-terminated, WITHOUT surrounding
   quotes): " \ and control chars become \" \\ \n \r \t or \uXXXX. Bytes >= 0x20
   pass through (v1: non-ASCII not transcoded). Returns length or -1 on overflow. */
int wire_escape(const char *in, size_t inlen, char *out, size_t outcap);

/* Validate a nonempty comma/space-separated list of ASCII wire tokens. Tokens
   use the verb-name alphabet [A-Za-z0-9_-] and must be shorter than
   max_token_len. Shared by Runner and Worker so launch-time and startup scope
   validation cannot drift. */
int wire_valid_token_list(const char *list, size_t max_token_len);

/* Base64-encode in[0..inlen) into out (NUL-terminated, standard alphabet with
   '=' padding). For binary payloads (e.g. screenshot pixels) - 4/3 expansion vs
   JSON-escape's up-to-6x. Returns length or -1 on overflow. */
int wire_base64(const unsigned char *in, size_t inlen, char *out, size_t outcap);

/* Write a full error-response envelope ({"proto":1,"id":…,"ok":false,…}\n) into
   out[0..cap). `code` and `message` must be JSON-safe literals (no escaping is
   done — they are ours, not the caller's data). Returns the response length, or
   -1 on overflow. The canonical error shape from docs/08; shared so verb modules
   outside verbs.c don't grow their own copy. */
int wire_resp_error(char *out, size_t cap, long id,
                    const char *code, const char *message);

/* CRC-32 (IEEE 802.3, the zlib/PNG variant: reflected, init 0xFFFFFFFF, final
   XOR 0xFFFFFFFF) over in[0..inlen). Transfer-integrity + ETag for the paged
   channel (docs/18-file-transfer.md); matches Python's zlib.crc32 so the host
   verifies the byte stream. Check value: crc32("123456789") == 0xCBF43926. */
unsigned long wire_crc32(const unsigned char *in, size_t inlen);

/* Streaming CRC-32: fold in[0..inlen) into a running crc. Seed the first call
   with 0xFFFFFFFF and XOR the final result with 0xFFFFFFFF (wire_crc32 does that
   for a one-shot buffer). Lets a large upload be CRC'd chunk-by-chunk off disk
   without holding it in RAM. */
unsigned long wire_crc32_update(unsigned long crc, const unsigned char *in,
                                size_t inlen);

/* Base64-decode in[0..inlen) into out[0..outcap). Standard alphabet; `=` padding
   ends the data; non-alphabet bytes (whitespace) are skipped. Returns the decoded
   byte count, or -1 on overflow. The inverse of wire_base64, for `put` upload. */
int wire_unbase64(const char *in, size_t inlen, unsigned char *out, size_t outcap);

#endif /* TIMBOTTU_WIRE_H */
