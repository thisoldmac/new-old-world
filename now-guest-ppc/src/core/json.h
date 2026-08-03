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

/* Returns the boolean value of "key", or fallback if the key is absent.
   Only a literal true reads as true; anything else is false. */
int now_json_find_bool(const char *json, const char *key, int fallback);

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
