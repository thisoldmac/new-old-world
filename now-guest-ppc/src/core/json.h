#ifndef NOW_JSON_H
#define NOW_JSON_H

/* The one tolerant JSON scanner for the guest. Flat key lookup over a
   message buffer: no allocation, bounded output writes, NULL-safe.
   Whitespace (space/tab/CR/LF) is skipped around the colon, so a peer
   using a pretty-printing encoder is never silently ignored — the bug
   the previous three hand-rolled copies each had to be patched for. */

/* Finds "key" and returns the first character of its value, or NULL if
   the key is absent (or json/key is NULL). */
const char *now_json_value(const char *json, const char *key);

/* Copies the string value of "key" into out (NUL-terminated, at most
   cap - 1 characters). Returns 1 on success; 0 if the key is absent or
   its value is not a string, leaving out untouched. */
int now_json_find_string(const char *json, const char *key,
                         char *out, long cap);

/* Returns the integer value of "key", or fallback if the key is absent.
   A present but non-numeric value parses as 0 (strtol semantics). */
enum {
    kNowJsonIntOk = 0,
    kNowJsonIntAbsent = 1,
    /* Present and not a bare number - a quoted one, most often, which is
       what a host sending [String: String] produces. See the note on
       now_json_read_int: this used to read as zero and dispatch. */
    kNowJsonIntUnreadable = 2
};

int now_json_read_int(const char *json, const char *key, long *out);

long now_json_find_int(const char *json, const char *key, long fallback);

/* Returns the UNSIGNED 32-bit value of "key", or fallback if the key is
   absent or does not open with a digit. Use this for a classic file
   date: a classic Mac modification date is unsigned seconds since
   1904, good past this century, and find_int cannot carry one - it is
   strtol into a signed 32-bit long, which saturates at 2^31-1, and a
   date past that (every date after January 1972) comes back as that
   saturated value instead of a parse failure. That is not a type this
   scanner can catch; it looks like a valid, wrong date.
   Digits are accumulated and masked to 32 bits by hand rather than
   handed to strtoul, so the result does not depend on this host's own
   `unsigned long` width - 32 bits on the Mac this file is built for,
   64 on the host cc that runs its native test. No sign handling: the
   fields this is for are never negative on the wire. */
unsigned long now_json_find_u32(const char *json, const char *key,
                                unsigned long fallback);

/* The WIDE forms: a 32-bit value that may arrive as a JSON string, and
   the three-way answer a caller that must refuse malformed input needs.
 *
 * An A5 world and a ring cursor are both 32-bit quantities that routinely
 * have their top bit set, and `long` is 32 bits on the machine this runs
 * on - so neither may ride a signed JSON integer: an A5 of 0x80000000
 * arrives as a negative long. Both are therefore accepted as STRINGS,
 * decimal or 0x-prefixed, with the signed integer form kept as a fallback
 * for the small values a human types by hand.
 *
 * Returns 0 for MALFORMED and leaves *out untouched; returns 1 with
 * *present 0 for ABSENT, and 1 with *present 1 for a value. Those three
 * are different answers and a fallback cannot express them: a caller that
 * refuses a bad cursor rather than reading it as zero needs to tell
 * "absent" from "garbage".
 *
 * Written once here because two verbs parse arguments this way - P3's
 * `qdtrace` and P5's `transitions`, both of which hand an A5 to a
 * resident. Two parsers that disagree about what counts as malformed
 * would arm different things for the same line. */
int now_json_find_wide_u32(const char *json, const char *key,
                           unsigned long *out, int *present);

/* Returns the boolean value of "key", or fallback if the key is absent.
   Only a literal true reads as true; anything else is false. */
int now_json_find_bool(const char *json, const char *key, int fallback);

/* The wide form of the above: a boolean that may arrive as a typed JSON
   boolean or through the host's older string form. Both shapes mean the
   same thing; any other present value is MALFORMED rather than silently
   false. Same three-way answer as now_json_find_wide_u32. */
int now_json_find_wide_bool(const char *json, const char *key,
                            int *out, int *present);

/* Like now_json_find_string, but DECODES: \uXXXX escapes and raw UTF-8
   become MacRoman, which is the only thing this machine can draw or
   store in a file name. A character MacRoman does not have becomes "?"
   rather than vanishing - a name is an identifier, and one character
   shorter is a different file. Use this for anything a person reads;
   use find_string for protocol tokens, which are ASCII by contract. */
int now_json_find_text(const char *json, const char *key, char *out, long cap);

/* Walking an array of objects, which flat key lookup cannot do.
   now_json_array returns a cursor just inside "key": [ , or NULL.
   now_json_next_object copies the next whole object into out (brace
   matched, string aware) and returns the cursor after it, or NULL at
   the end of the array or on a truncated one. Each object is copied so
   a lookup inside it cannot run on into its siblings. */
const char *now_json_array(const char *json, const char *key);
const char *now_json_next_object(const char *p, char *out, long cap);

/* Walking an array of ARRAYS — cloud.card's [label, value] rows. The
   same contract as now_json_next_object, with brackets for braces:
   copies the next whole inner array (bracket matched, string aware)
   into out and returns the cursor after it, or NULL at the end of the
   outer array or on a truncated one. */
const char *now_json_next_array(const char *p, char *out, long cap);

/* The idx-th (0-based) string element of a bare array like
   ["home","555-0100"], DECODED to MacRoman the way find_text decodes.
   Non-string elements still count toward idx. Returns 1 when that
   element exists and is a string. */
int now_json_array_string(const char *array, int idx, char *out, long cap);

/* Returns 1 if the message's "type" string equals type. */
int now_json_type_is(const char *json, const char *type);

/* Escapes a MacRoman string into a JSON string body (no surrounding
   quotes). Quotes, backslashes and control characters become escapes,
   and high MacRoman bytes become \uXXXX for their real Unicode value -
   a classic volume root holds "Icon\r" and accented names, and raw
   bytes there are both invalid JSON and invalid UTF-8, which is exactly
   how a listing silently fails to parse on the modern side. Writes at
   most cap-1 characters plus a terminator. */
void now_json_escape(const char *src, char *out, long cap);

#endif /* NOW_JSON_H */
