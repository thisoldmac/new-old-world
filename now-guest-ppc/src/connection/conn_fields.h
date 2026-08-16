#ifndef NOW_CONN_FIELDS_H
#define NOW_CONN_FIELDS_H

/* Validation and mapping for the Connection page's fields. Pure C, no
   Toolbox, so now-guest-ppc/tests/conn_fields_test.c runs it under the host cc
   - the json.c pattern. Wire revision 1 dials dotted IPv4 only; these
   are the rules the page enforces before anything is saved or dialed. */

/* 1 for a strict dotted quad (four decimal octets, each 0-255, nothing
   else); 0 otherwise. */
int now_conn_ipv4_valid(const char *text);

/* The port number in 1-65535, or -1 when the text is not one. */
long now_conn_port_parse(const char *text);

/* The Retry pop-up: item 1 automatic backoff, then 2, 5, 10 seconds. */
short now_conn_retry_secs_for_item(short item);
short now_conn_retry_item_for_secs(short secs);

/* The action button's cached title.

   The page caches this so an idle tick can skip the redraw, and the
   cache must record what the BUTTON READS - not what the wire last
   said. Seeding it from the wire is how a page created while already
   connected came up reading "Connect" and stayed that way forever:
   cache and title disagreed from birth, and the only thing that
   restamps a title is a disagreement with the cache. */
typedef struct {
    const char *shown;                /* never NULL after init */
} NowConnActionTitle;

/* The words for a connection state; the one place that decides them. */
const char *now_conn_action_title(int connected);

/* Record the title the button was created with. */
void now_conn_action_title_init(NowConnActionTitle *st, const char *created);

/* The title to stamp now, or NULL when the button already reads right. */
const char *now_conn_action_title_next(NowConnActionTitle *st, int connected);

#endif /* NOW_CONN_FIELDS_H */
