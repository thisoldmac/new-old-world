#ifndef NOW_CLOUD_MODEL_H
#define NOW_CLOUD_MODEL_H

/* The iCloud page's store and parsers: everything the page knows,
   filled from raw cloud.* reply frames and read by the drawing code.
   Toolbox-free on purpose — the parsing half of the module is the half
   worth testing with the host cc (json_native_test.c is the pattern),
   so nothing here may include Carbon. */

#if TARGET_API_MAC_CARBON
#include <MacTypes.h>
#else
typedef unsigned char Boolean;
#endif

enum {
    kCloudMaxServices = 8,
    kCloudMaxRows = 128,              /* the Files browser's bound */
    kCloudMaxCardRows = 16
};

typedef struct {
    char service[24];                 /* registry key: ASCII by contract */
    char label[32];                   /* MacRoman, drawn in the popup */
    char state[16];                   /* serving | off | no-access | ... */
    char detail[96];                  /* MacRoman, drawn under the list */
} CloudService;

typedef struct {
    char item[64];                    /* opaque id, sent back verbatim */
    char title[64];                   /* MacRoman */
    char subtitle[48];                /* MacRoman */
    long bytes;                       /* 0 = unstated */
    unsigned long modified;           /* classic seconds; 0 = unstated */
} CloudRow;

typedef struct {
    char label[24];
    char value[128];
} CloudCardRow;

typedef struct {
    /* cloud.report */
    CloudService services[kCloudMaxServices];
    int service_count;

    /* cloud.listing, accumulated across pages like the Files browser */
    char listed_service[24];          /* whose rows these are */
    CloudRow rows[kCloudMaxRows];
    int row_count;
    Boolean more;
    long cursor;

    /* cloud.card */
    char card_item[64];               /* whose card this is */
    CloudCardRow card[kCloudMaxCardRows];
    int card_count;
} CloudStore;

void cloud_store_reset(CloudStore *store);
void cloud_store_reset_rows(CloudStore *store, const char *service);
void cloud_store_reset_card(CloudStore *store);

/* Each parser fills its slice of the store from one raw reply frame
   and returns the number of things it read (services, rows appended,
   card rows). A malformed frame reads as zero, never as a crash. */
int cloud_parse_report(const char *reply, CloudStore *store);
int cloud_parse_listing(const char *reply, CloudStore *store);
int cloud_parse_card(const char *reply, CloudStore *store);

/* The first service whose state is "serving" and that has rows to ask
   for (not drive, whose browsing lives in Files); -1 when none. The
   dropdown's initial selection. */
int cloud_first_listable(const CloudStore *store);

/* Whether this service answers cloud.list at all. */
Boolean cloud_service_listable(const char *service);

/* The status line for a page that has finished landing (the cap was
   hit, the host said no more, or the page is empty) — never for a page
   still auto-paging, which sets no status of its own. kCloudMaxRows is
   a wire/memory bound, not a claim that the store holds everything:
   a service whose "more" survives to the cap must read as a bounded
   PREFIX of a larger list, not as the whole of it. Pure and therefore
   host-cc testable (cloud_model_test.c) — the wording is a decision,
   not a drawing detail. */
void cloud_listing_status(const CloudStore *store, char *out, long cap);

#endif /* NOW_CLOUD_MODEL_H */
