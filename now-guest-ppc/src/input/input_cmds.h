#ifndef NOW_INPUT_CMDS_H
#define NOW_INPUT_CMDS_H

/* The input plane's four commands, as the wire sees them.

   All four are declared in contract/asyncapi.yaml, answered by
   commands.c and listed in cmd_help.c. Those three are one surface and a
   verb that reaches only two of them is invisible to every gate while
   they all stay green, so they move together or not at all.

   WHAT THEY ARE FOR, and they are four different kinds of thing:

     mouseloc  A READ, and the instrument the act plane is measured with
               rather than a part of it. Every hop calibration in
               scripts/probes/nohijack-probe.py is a closed loop against
               it, because QMP can say where it ASKED the pointer to go
               and pointer acceleration means that is not where it went.
               Getting this one wrong quietly poisons every hijack
               number, which is why it is a read and stays a read: there
               is no mouse-move verb here, on purpose.

     key       ONE keystroke, posted into this Mac's event queue - the
               mechanism `textset` is not. textset writes an addressed
               element's text directly, so it reaches a field without
               focus and never reaches a dialog that only answers
               keystrokes, or Return, or Escape.

               And it cannot say what was held down. An event's modifiers
               live on the QUEUE ELEMENT; the only call that hands that
               element back is PPostEvent, which CarbonLib does not have,
               and this application is Carbon. A `mods` request is
               refused rather than posted bare - see input_args.h, which
               carries the whole argument.

     script    One AppleScript, through OSADoScript. The verb with the
               most scar tissue in this repo - see input_args.h.

     aesend    One of FOUR core Apple Events, to a process named by its
               serial. Not a class/id pipe; see input_args.h on why the
               vocabulary is closed.

   Each handler writes the whole command.result envelope into `out`, the
   way every other command in this guest does. */

void now_input_run_mouseloc(const char *request_json, long id,
                            char *out, long cap);
void now_input_run_key(const char *request_json, long id,
                       char *out, long cap);

/* The Console page's face for `key`, writing one line into `msg`.
   The parse is now_key_parse_line's and the post is this file's, so the
   typed face and the wire's cannot disagree about what a key is - only
   about how the answer is spelled. A person at the machine can reach
   this verb; that is a property of its arguments, and it is why `key`
   has a console face where mouseloc and aesend still owe one. */
void now_input_key_console(const char *args, char *msg, long cap);
void now_input_run_script(const char *request_json, long id,
                          char *out, long cap);
void now_input_run_aesend(const char *request_json, long id,
                          char *out, long cap);

#endif /* NOW_INPUT_CMDS_H */
