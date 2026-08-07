#ifndef NOW_DESKTOP_H
#define NOW_DESKTOP_H

/* What this machine's desktop actually IS, asked of the machine.
 *
 * The renderer used to tile `ppat` 16 unconditionally. Under Appearance
 * that resource is a shipped DEFAULT that the desktop is never chosen
 * from, so it sits at its factory value forever - purple Mac faces beside
 * whatever the person actually picked. A confident wrong answer.
 *
 * The live answer lives in the Appearance Manager's theme collection:
 * GetTheme() fills a Collection, and the desktop tags in it
 * (kThemeDesktopPatternNameTag / kThemeDesktopPatternTag /
 * kThemeDesktopPictureNameTag / kThemeDesktopPictureAlignmentTag) say what
 * the desktop is drawn from. LMGetDeskCPat / SetDeskCPat are NOT in
 * Carbon; the collection is the only route from an application.
 *
 * This header is deliberately Toolbox-free above the guard, the way
 * census.h is: the row types and the report serializer compile under the
 * host cc for the native test, so the wire shape is provable off the
 * machine.
 */

/* Rows are sized so a full answer fits kNowCommandResultCap (3072) with
   room for the frame. The serializer refuses to truncate rather than
   putting a half-JSON on the wire, so these three numbers and that cap
   are one fact stated in two places - if you widen one, widen the test
   that pins the worst case (desktop_report_test.c). */
enum {
    kDesktopRowNameCap = 24,
    kDesktopRowRawCap = 84,
    kDesktopRowNoteCap = 44
};

enum { kDesktopRowMax = 17 };

/* The tag inventory is the raw evidence that everything else is read out
   of, so it is not allowed to be a number alone - but 19 four-char codes
   do not fit one row's raw cap. Two rows do. */
enum { kDesktopTagListRows = 2 };

/* Bytes of the flattened pattern carried back as hex, across at most
   kDesktopHexRows rows of kDesktopHexBytesPerRow each. A pattern longer
   than this reports its true length and says how much was omitted - the
   length is never the amount we could carry. */
enum {
    kDesktopHexBytesPerRow = 40,        /* 80 hex chars, inside the raw cap */
    kDesktopHexRows = 5
};

/* [name, raw, note]: the same discipline as CensusRow. The raw column is
   what the machine said - a four-char tag, a decimal, a hex run - and is
   never prettified; the note says what it means, or says that we do not
   know, which is also an answer. */
typedef struct {
    char name[kDesktopRowNameCap];
    char raw[kDesktopRowRawCap];
    char note[kDesktopRowNoteCap];
} DesktopRow;

/* What the desktop is drawn from, as far as the machine will say.
   `kDesktopSourceUnknown` is a first-class outcome, not an error: a guest
   whose Appearance Manager does not answer has a desktop we cannot
   attribute, and the honest render for that is the marked unknown. */
typedef enum {
    kDesktopSourceUnknown = 0,
    kDesktopSourcePattern,      /* a repeating pattern, and nothing over it */
    kDesktopSourcePicture       /* a picture, drawn OVER the pattern layer */
} DesktopSource;

/* WHICH tag says a picture is set, measured 2026-08-07 rather than
   assumed. On the OS 9.1 runner image, showing a full-screen picture,
   kThemeDesktopPictureNameTag ('dpnm') was ABSENT while
   kThemeDesktopPictureAliasTag ('dpal') carried 154 bytes and
   kThemeDesktopPictureAlignmentTag ('dpan') read 5. So the NAME is not
   the signal - a first version of this file keyed on it and reported
   `pattern` for a machine with a picture on the screen, which is the
   confident wrong answer this lane exists to remove. The ALIAS is the
   signal: it is the file reference the desktop is drawn from, and it is
   present exactly when one is configured. */

typedef struct {
    DesktopRow rows[kDesktopRowMax];
    int count;
    DesktopSource source;
    /* Nonzero when the collection carried a pattern we could read at all.
       A picture desktop still has a pattern underneath it, and that layer
       is what shows wherever the picture does not reach. */
    int has_pattern;
    /* Nonzero when a desktop picture is configured - the alias tag, not
       the name tag; see the note on DesktopSource. */
    int has_picture;
    long pattern_bytes;         /* true length of the flattened pattern; -1 unknown */
    long pattern_carried;       /* how many of those bytes the rows carry */
    char note[kDesktopRowNoteCap];  /* one sentence, or empty */
} DesktopAnswer;

/* THE SAME ANSWER, SIZED FOR A SCENE RATHER THAN FOR A PERSON.
 *
 * `DesktopAnswer` is 17 rows of prose and up to 200 bytes of hex: right
 * for someone typing `desktop` at the console, and about 2.6 KB of stack
 * for something a scene walk does once per sweep on a 68K-era machine.
 * More to the point, a renderer does not want the hex - the flattened
 * `ppat` bytes are an identity, not drawable art, and the art comes from
 * the asset pack either way. What a renderer needs is the NAME the
 * machine chose and the source it chose it from.
 *
 * So the typed facts have a second, small carrier, gathered by the same
 * Toolbox route through the same `read_tag`. One implementation, two
 * shapes - not two producers of one answer, which is the seam this whole
 * lane exists to close.
 *
 * `asked` is the looked-at-all bit, the same idiom as scene.h's
 * `controls_present`: 0 means this producer never asked and a consumer
 * must not read that as "no desktop". */
enum { kDesktopNameCap = 64 };

typedef struct {
    int asked;
    DesktopSource source;
    int has_pattern;
    int has_picture;
    long pattern_bytes;             /* true length; -1 unknown */
    char pattern_name[kDesktopNameCap];   /* empty when the tag was absent */
    char picture_name[kDesktopNameCap];
} NowDesktopFacts;

/* --- pure (desktop_report.c; native-tested) ------------------------------ */

const char *now_desktop_source_name(DesktopSource source);

/* Append one [name, raw, note] row. Fields are truncated to their caps
   rather than dropped; a row that will not fit the page is dropped and
   the answer's note says so, because a page that silently loses a row
   reads as a machine that did not have it. Returns 0 on success. */
int now_desktop_add_row(DesktopAnswer *answer, const char *name,
                        const char *raw, const char *note);

/* Lowercase hex of `len` bytes into `out` (needs 2*len+1). */
void now_desktop_hex(const unsigned char *bytes, long len, char *out, long cap);

/* Serialize the command.result for `desktop`. Returns the JSON length, or
   -1 when it will not fit - the caller sized the answer wrong, and a
   truncated frame must never go on the wire. */
long now_desktop_result_json(long id, const DesktopAnswer *answer,
                             char *out, long cap);

/* --- Toolbox gather (desktop_theme.c) ------------------------------------ */

#if TARGET_API_MAC_CARBON

/* Ask the running machine. Always fills `out` - a machine that refuses
   still produces an answer, with source unknown and rows saying which
   call refused and with what OSStatus. */
void now_desktop_gather(DesktopAnswer *out);

/* The typed facts alone, for the scene's `meta.desktop`. Always fills
   `out`; sets `asked` to 1 even when the machine refuses, because "we
   asked and it would not say" (source unknown) and "nobody asked" are
   different facts and only one of them is a defect. */
void now_desktop_facts_ask(NowDesktopFacts *out);

/* The `desktop` command: gather, then serialize. Writes its own whole
   command.result, like the other verbs that own their reply. */
void now_desktop_command(const char *request_json, long id,
                         char *out, long cap);

#endif /* TARGET_API_MAC_CARBON */

#endif /* NOW_DESKTOP_H */
