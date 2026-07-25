#ifndef NOW_CMD_LINE_H
#define NOW_CMD_LINE_H

/* The console line, parsed on the machine that serves the command.
   ------------------------------------------------------------------
   A console cannot know any command's grammar. There are two guests with
   different command tables (this one and NOW-68K), so a console-side list
   or parser would be wrong for both — the host console therefore relays the
   line a human typed, verbatim, as the envelope's `line`, and every
   argument grammar is implemented exactly once, here, next to the command
   that owns it. See CommandRequest.line and each command's `x-line` in
   contract/asyncapi.yaml.

   A TYPED caller — a host module, an agent — sends the named arg instead,
   and it wins when both arrive: a caller that filled in the typed field
   asked for something specific.

   Toolbox-free on purpose, like proc_quit_args.c: the host cc compiles it,
   so the bounds get watched failing in guest/tests/cmd_line_test.c rather
   than discovered on the PowerBook. */

/* Did a console send a line at all, and if so what was it?
   An EMPTY line is still a line — it says "a human typed this command
   bare", which is NOT the same request as a typed call with no args. That
   distinction is the whole of gestalt's console behaviour: absent line =
   every group (what a module wants), empty line = the snapshot a human
   wants to read.
   Returns 1 when the field was present, 0 otherwise; `out` is always
   NUL-terminated (empty when absent). */
int now_cmd_line(const char *request_json, char *out, long cap);

/* The named arg, else the WHOLE line, trimmed: for the commands whose
   argument is the rest of the line, spaces and all. An HFS name has spaces
   in it and quoting them would be a second grammar; leading flags (launch's
   -v, quit's --all) belong to that command's own parser, not to this. */
void now_cmd_arg_rest(const char *request_json, const char *key,
                      char *out, long cap);

/* The named arg, else the first word on the line that is NOT a flag: for
   the commands whose argument is one token from a closed set (a census
   probe, a software domain). */
void now_cmd_arg_word(const char *request_json, const char *key,
                      char *out, long cap);

/* The line's first word, flag or not — for the one command whose argument
   IS a flag (gestalt's --cpu). */
void now_cmd_first_word(const char *line, char *out, long cap);

/* Is `word` on the line, as a whole word? ("--no-save", "--full") */
int now_cmd_line_word(const char *line, const char *word);

/* The word after `flag` ("--depth 8"). 0 when the flag is absent or ends
   the line; `out` is NUL-terminated either way. */
int now_cmd_line_flag_value(const char *line, const char *flag,
                            char *out, long cap);

/* The first integer on the line ("tail 40"). 0 when there is none. */
int now_cmd_line_int(const char *line, long *out);

#endif
