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

#endif /* NOW_CONN_FIELDS_H */
