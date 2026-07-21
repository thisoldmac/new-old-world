#ifndef NOW_CENSUS_H
#define NOW_CENSUS_H

/* The hardware census: passive, typed-fill probes of tables this machine's
   OS maintains, paged so one census.request never does more than one page
   of work (contract: censusExchange). This header is deliberately
   Toolbox-free - the page types and the report serializer compile under
   the host's cc for the native test, the way workshop_layout.h and json.h
   do. The gatherers themselves live in census_probes.c and are declared
   here behind the same guard workshop_layout.h uses. */

/* One page of rows. 16 mirrors the contract's maxItems on census.report
   (rows), which exists because control frames cap at 4 KB. */
enum { kCensusPageMax = 16 };

enum {
    kCensusRowNameCap = 32,
    kCensusRowRawCap = 48,
    kCensusRowMeaningCap = 64,
    kCensusNoteCap = 96
};

/* [name, raw, meaning]: the raw value always survives beside the decoded
   meaning; a value we cannot decode keeps its raw form and says so in the
   meaning column rather than being dropped. */
typedef struct {
    char name[kCensusRowNameCap];
    char raw[kCensusRowRawCap];
    char meaning[kCensusRowMeaningCap];
} CensusRow;

/* The contract's outcome vocabulary. absent (the machine said no) is
   never conflated with refused (the responder declined to look). */
typedef enum {
    kCensusPresent = 0,
    kCensusAbsent,
    kCensusPartial,
    kCensusRefused,
    kCensusFailed,
    kCensusNotAttempted
} CensusOutcome;

typedef struct {
    CensusRow rows[kCensusPageMax];
    int count;
    CensusOutcome outcome;
    int more;               /* nonzero: ask again with cursor = next_cursor */
    long next_cursor;
    long total;             /* total rows the probe will yield; -1 unknown */
    char note[kCensusNoteCap];  /* one human sentence, or empty */
} CensusPage;

/* --- pure (census_report.c; native-tested) ------------------------------- */

const char *census_outcome_name(CensusOutcome outcome);

/* Serialize one census.report frame. Returns the JSON length, or -1 when
   it cannot fit in cap - the caller sized the page wrong, and a truncated
   frame must never go on the wire. */
long census_report_json(const char *probe, long id, const CensusPage *page,
                        char *out, long cap);

/* --- Toolbox gatherers (census_probes.c) --------------------------------- */

#if TARGET_API_MAC_CARBON

/* Fill one page of `probe` starting at `cursor` (0 starts over). Returns
   0 with the page filled - the outcome rides inside it - or -1 for a
   probe this build does not know (the caller answers refused). */
int now_census_gather(const char *probe, long cursor, CensusPage *out);

/* The probes this build serves, for the module's list pane. */
int now_census_probe_count(void);
const char *now_census_probe_name(int index);

#endif /* TARGET_API_MAC_CARBON */

#endif /* NOW_CENSUS_H */
