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

/* Copies the OBJECT value of "key" out of `json` into `out`, bounded and
   NUL-terminated; leaves `out` as "" (never untouched) and returns 0 if
   the key is absent, its value is not an object, or the object does not
   fit. Built from now_json_value + now_json_next_object - the same
   object-isolation this file already does once per array element,
   generalized to any single object-valued key.

   THIS IS THE FIX FOR A SHADOWED ARGUMENT. now_json_find_string and its
   siblings scan the WHOLE string handed to them, flat and
   first-occurrence-wins - fine for CommandRequest.args's own keys, which
   the contract's RULE requires to never equal an envelope key (type,
   id, name, args, line), so callers each pass the raw envelope straight
   through today. A verb whose OWN wire argument happens to share an
   envelope key's name (`key`'s `name` is the shipped vocabulary for a
   key-name enum and cannot be renamed away from the collision the way
   `launch`'s `target` was) must search inside the args object alone -
   `now_json_scope_object(json, "args", buf, sizeof buf)` once, then read
   every argument out of `buf` instead of `json`. */
int now_json_scope_object(const char *json, const char *key,
                          char *out, long cap);

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
