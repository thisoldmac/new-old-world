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
long now_json_find_int(const char *json, const char *key, long fallback);

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
