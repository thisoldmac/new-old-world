#ifndef NOW_CENSUS_DECODE_H
#define NOW_CENSUS_DECODE_H

/* The census decoder: raw Gestalt values into human words, and into the
   full breakdown the detail pane draws. Pure C - no Toolbox - so it
   compiles under the host cc and the readings are provable off the
   machine (census_decode_test.c). The selector table in
   census_selectors.h supplies the data; this file supplies the meaning.

   The raw value always survives beside the decode: the summary is what
   the list shows, the detail is what the pane shows, and neither ever
   discards a value it cannot name - an unrecognized attr bit is reported
   by number as a candidate, never dropped. */

/* How to read a selector's response. */
enum {
    kCensusSelNum = 0,      /* plain number (fourcc-looking values shown so) */
    kCensusSelAttr,         /* bit mask; bits named, unknown ones called out */
    kCensusSelVersion,      /* BCD word or NumVersion long */
    kCensusSelSize,         /* bytes */
    kCensusSelCount,        /* a count */
    kCensusSelAddr,         /* an address; hex */
    kCensusSelHz            /* a frequency in Hz */
};

typedef struct {
    unsigned long selector;
    const char *name;       /* Apple symbol minus the gestalt prefix */
    short kind;
    const char *comment;    /* Apple's header comment, or "" */
} NowCensusSelector;

typedef struct {
    unsigned long selector;
    short bit;
    const char *name;
} NowCensusAttrBit;

/* One-line summary for the Meaning column. `bits`/`nbits` is the whole
   attr-bit table; the decoder scans it for rows matching `selector`. */
void census_summarize(short kind, unsigned long selector, unsigned long raw,
                      const NowCensusAttrBit *bits, int nbits,
                      char *out, long cap);

/* Full detail for the pane: raw in hex and decimal, the decoded reading,
   and for an attr the set bits one per line (named or numbered). Writes
   up to `max_lines` lines of `line_cap` each into `out` (a flat
   line_cap-strided buffer); returns the line count. */
int census_detail(const NowCensusSelector *sel, unsigned long raw,
                  const NowCensusAttrBit *bits, int nbits,
                  char *out, int max_lines, long line_cap);

#endif /* NOW_CENSUS_DECODE_H */
