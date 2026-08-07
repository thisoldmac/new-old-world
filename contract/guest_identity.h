/* What machine this is, decoded the same way on every side.
 *
 * `hello` carries the guest's system version and machine type as TYPED
 * fields (contract/asyncapi.yaml, Hello.os and Hello.machine). Both
 * guests already had the raw Gestalt responses; what they did not have
 * was one way of turning them into strings.
 *
 * They had two, and the two disagreed in both halves:
 *
 *   - The DECODE. The PowerPC guest read the major version as BCD
 *     (`((v >> 12) & 0xF) * 10 + ((v >> 8) & 0xF)`); NOW-68K read the
 *     same byte as a plain number (`(v >> 8) & 0xFF`). Identical for
 *     every System either has ever run on — 0x0910 is 9 both ways — and
 *     divergent the moment a high byte carries a BCD ten. gestaltSystem-
 *     Version is BCD, so the PowerPC reading is the correct one and this
 *     header takes it.
 *   - The SHAPE. The PowerPC guest omitted a zero bug-fix digit ("9.1"),
 *     NOW-68K always printed three ("7.1.0"). A key built by comparing
 *     those strings would have matched a 9.1.0 pack to a 9.1.0 guest
 *     only when both halves happened to be the same guest.
 *
 * The second one is the reason this file exists rather than a comment.
 * `hello.os` is now a KEY — the asset-pack store compares it — and a
 * field that two senders format differently is the defect AGENTS.md
 * names as the most expensive in this project, arriving in the one
 * message every session begins with.
 *
 * So: one decode, one shape, `major.minor.bugfix`, always three parts.
 * Both guests include this; the host `cc` compiles it for
 * `guest_identity_native_test.c`, which is what stops it drifting back.
 *
 * NO snprintf. NOW-68K formats through its own append helpers rather
 * than pulling in stdio, and this header is included by a 68K build
 * under Retro68 as well as by two hosted compilers. Digits are written
 * by hand for that reason, not out of taste.
 *
 * NOT HERE, deliberately: reading Gestalt. Which selectors a guest may
 * call, and what it does when one refuses, is that guest's business —
 * NOW-68K cannot afford probes the PowerPC guest takes for granted. This
 * header decodes a value somebody else fetched.
 */
#ifndef NOW_CONTRACT_GUEST_IDENTITY_H
#define NOW_CONTRACT_GUEST_IDENTITY_H

/* What a side writes when Gestalt did not answer.
 *
 * A WORD, not an empty string and not a zero. `unknown` means we could
 * not establish it; an absent field means the sender predates the field.
 * Those are different facts and a receiver acts differently on them, so
 * they must not collapse into the same bytes on the wire. */
#define kNowIdentityUnknown "unknown"

/* Longest output: "255.15.15" plus the terminator. Callers size buffers
   from this rather than guessing; `unknown` is shorter. */
#define kNowIdentityVersionCap 16

/* Append `value` as decimal digits. Returns the new position, or -1 if it
   would not fit — the caller checks once at the end rather than at every
   step, which is how both guests' own formatters already read. */
static long now_identity_put_num(char *out, long cap, long pos, long value)
{
    char digits[12];
    long n = 0;

    if (pos < 0) {
        return -1;
    }
    if (value < 0) {
        value = 0;
    }
    do {
        digits[n++] = (char)('0' + (int)(value % 10));
        value /= 10;
    } while (value != 0 && n < (long)sizeof digits);

    if (pos + n >= cap) {
        return -1;
    }
    while (n > 0) {
        out[pos++] = digits[--n];
    }
    return pos;
}

static long now_identity_put_str(char *out, long cap, long pos,
                                 const char *text)
{
    if (pos < 0) {
        return -1;
    }
    while (*text != '\0') {
        if (pos + 1 >= cap) {
            return -1;
        }
        out[pos++] = *text++;
    }
    return pos;
}

/* Decode a `gestaltSystemVersion` response into `major.minor.bugfix`.
 *
 * `raw` is the Gestalt response; pass 0 for "Gestalt did not answer",
 * which is what both guests' `gest_or(sel, 0)` already produces, and
 * which yields `unknown` rather than "0.0.0". A System version of zero
 * is not a version, and writing it as one would be a plausible wrong
 * answer — the kind this project marks rather than prints.
 *
 * Always three components, including a zero bug-fix. The trailing ".0"
 * is not noise: it is what makes two senders' strings comparable, which
 * is the whole point of the field. */
static void now_identity_system_version(long raw, char *out, long cap)
{
    long major;
    long pos;

    if (cap <= 0) {
        return;
    }
    if (raw == 0) {
        pos = now_identity_put_str(out, cap, 0, kNowIdentityUnknown);
        out[pos < 0 ? 0 : pos] = '\0';
        return;
    }

    /* BCD, two digits in the high byte: 0x0910 is 9.1.0, 0x1000 is 10.0.0.
       Reading that byte as a plain number is right up to 9 and wrong at
       ten, which is exactly the sort of boundary nobody tests. */
    major = ((raw >> 12) & 0xF) * 10 + ((raw >> 8) & 0xF);

    pos = now_identity_put_num(out, cap, 0, major);
    pos = now_identity_put_str(out, cap, pos, ".");
    pos = now_identity_put_num(out, cap, pos, (raw >> 4) & 0xF);
    pos = now_identity_put_str(out, cap, pos, ".");
    pos = now_identity_put_num(out, cap, pos, raw & 0xF);

    if (pos < 0) {
        /* Cannot happen at kNowIdentityVersionCap. What matters is what
           it does anyway: never a HALF-WRITTEN version. "9.1" is a
           prefix that parses, and a key that parses to the wrong System
           is worse than one that refuses to parse at all.
           Falls back to `unknown`; where even that will not fit, to the
           empty string, which is the one remaining answer that cannot be
           mistaken for a version. A caller sizing from
           kNowIdentityVersionCap never reaches either. */
        pos = now_identity_put_str(out, cap, 0, kNowIdentityUnknown);
        if (pos < 0) {
            pos = 0;
        }
    }
    out[pos] = '\0';
}

#endif /* NOW_CONTRACT_GUEST_IDENTITY_H */
