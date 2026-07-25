#ifndef NOW68K_JSON_SCAN_H
#define NOW68K_JSON_SCAN_H

#include <stddef.h>

/* Flat, allocation-free scanner for NOW control payloads. No JSON library,
 * no heap: this looks for a `"key":` substring and returns a pointer just
 * past the colon and any whitespace.
 *
 * Every function here takes an explicit json_len and never assumes json is
 * NUL-terminated. The frame layer hands the caller an exact payload
 * length, not a C string -- a receive buffer reused across frames can
 * hold a previous, longer payload's trailing bytes right past that
 * length, and a scan that trusted strstr/strlen instead of the given
 * length would run straight through the boundary into them. The PPC
 * guest sidesteps this by writing its own terminator after each payload
 * (now/guest/src/wire.c, on_frame_ready()); this codec makes no such
 * assumption about its caller's buffer and takes the length instead.
 *
 * Why a dumb linear scan is otherwise safe here: contract/asyncapi.yaml's
 * preamble (the "Commands:" paragraph) states control payloads are
 * scanned FLAT, first-occurrence-wins, and derives a RULE from it -- an
 * arg key must never reuse an envelope key name (type, id, name, args),
 * because a shadowing arg is exactly what a first-occurrence scanner
 * would read instead of the real field ("launch shipped that bug to
 * metal with an arg named 'name'; the family uses 'target'"). The
 * contract polices this by naming discipline on every message it
 * declares, not by forbidding nested objects outright -- so this scanner
 * trusts that discipline the same way the existing PPC guest's scanner
 * does (now_json_value in now/guest/src/json.c), and no differently. For
 * the two message shapes this deliverable actually reads (pong, and
 * "type"+"id" off an arbitrary inbound control message), that is moot:
 * Ping/Pong/Refuse/Error all declare `id` as a top-level scalar with no
 * nested object in the schema at all, so there is nothing to shadow it
 * with.
 *
 * A "first occurrence" match is judged by the presence of `key` AS A
 * QUOTED KEY (followed by optional whitespace then ':'), not merely by
 * the pattern `"key"` appearing anywhere in the text -- a string VALUE
 * that happens to equal the key name (e.g. "note":"id") produces a false
 * pattern match, and the scanner resumes searching past it rather than
 * giving up. Confirmed defect this fixes: a payload with such a value
 * ahead of the real key (e.g. {"type":"pong","note":"id","id":42}) used
 * to make the scanner return NULL instead of finding "id":42.
 */

/* Finds `"key":` within json[0, json_len) and returns a pointer just past
 * the colon and any whitespace, bounded to that same range -- it may
 * equal json + json_len if the colon and its trailing whitespace ran to
 * the very end. Returns NULL if no quoted occurrence of `key` followed by
 * ':' exists in range. A quoted occurrence not followed by ':' (a string
 * VALUE equal to key) is a false match: the search resumes just past it
 * rather than aborting. */
const char *now68k_json_value(const char *json, size_t json_len,
                               const char *key);

/* Copies the string value of `key` into out (NUL-terminated, truncated
 * to fit cap). Returns 1 on a well-formed string that both opens and
 * closes within json[0, json_len); 0 if `key` is absent, is not a
 * string, or never closes before cap or json_len runs out.
 *
 * NO ESCAPE HANDLING, deliberately, and the callers are why it is safe:
 * every string this guest reads off the wire is an identifier the
 * contract already constrains - a message type, a container token, a
 * four-character file type, or an HFS leaf name the SENDER has already
 * sanitized ("<= 31 characters, no colons, MacRoman-encodable",
 * FileOffer). A backslash in any of those is a malformed message, and
 * the truncation-or-reject behaviour above turns it into a refusal
 * rather than a wrong file name. If a field ever arrives that can
 * legitimately carry one, this is the function that has to grow, and
 * this paragraph is the thing to delete. */
int now68k_json_find_string(const char *json, size_t json_len,
                             const char *key, char *out, long cap);

/* The same for "type", which every control payload carries. Kept as its
 * own name because every caller reads it and the call site says what it
 * is doing; it is now68k_json_find_string with the key filled in, not a
 * second implementation. */
int now68k_json_read_type(const char *json, size_t json_len, char *out,
                           long cap);

/* Reads the integer value of `key`, scanned only within json[0,
 * json_len), into *out. Returns 1 if `key` was found and looked like a
 * number, 0 otherwise (out is left untouched). */
int now68k_json_find_int(const char *json, size_t json_len, const char *key,
                          long *out);

#endif
