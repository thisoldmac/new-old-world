#ifndef NOW_WIRESTAT_CMD_H
#define NOW_WIRESTAT_CMD_H

/* `wirestat`'s grammar, once, for both of its faces.

   The verb has to be typeable at the machine as well as callable over
   the wire (docs/command-parity.md), and the two faces hand it its
   argument differently: a console sends the raw line, a typed caller
   sends `action` and `value`. What must NOT differ is what the words
   mean - so the splitting and the meaning live here, Toolbox-free, with
   a native test, and each face only renders.

   The trap this closes is specific. now_cmd_arg_word answers the named
   arg for a typed caller but the line's FIRST word for a console, so
   asking it for `action` and then `value` returns "sleep" twice and
   `wirestat sleep 3` silently becomes `wirestat sleep 0` - clamped to
   one tick, which is a real and wrong setting rather than an error. */

typedef struct {
    int reset;              /* clear the counts */
    int set_wake;           /* the wake was named... */
    int wake_on;            /* ...and this is what it was set to */
    int set_sleep;          /* the idle sleep was named... */
    long sleep_ticks;       /* ...and this is the number given */
} WireStatRequest;

/* The first two whitespace-separated words of `line`. Both outputs are
   always NUL-terminated, empty when the line has no such word. */
void now_wirestat_split(const char *line, char *action, long acap,
                        char *value, long vcap);

/* What those two words ask for. An unrecognised action asks for nothing,
   which is how a bare `wirestat` reports without changing anything. */
void now_wirestat_parse(const char *action, const char *value,
                        WireStatRequest *out);

#endif
