#ifndef NOW_INPUT_CMDS_H
#define NOW_INPUT_CMDS_H

/* The input plane's three commands, as the wire sees them.

   None of them is declared in contract/asyncapi.yaml yet and none is
   reachable from commands.c yet - the registration they need is stated
   in this branch's report, not landed here, because the x-commands
   registry, cmd_help.c and commands.c are one shared surface and a
   second writer on it is how two spellings of one capability got shipped
   in a day.

   WHAT THE THREE ARE FOR, and they are three different kinds of thing:

     mouseloc  A READ, and the instrument the act plane is measured with
               rather than a part of it. Every hop calibration in
               scripts/probes/nohijack-probe.py is a closed loop against
               it, because QMP can say where it ASKED the pointer to go
               and pointer acceleration means that is not where it went.
               Getting this one wrong quietly poisons every hijack
               number, which is why it is a read and stays a read: there
               is no mouse-move verb here, on purpose.

     script    One AppleScript, through OSADoScript. The verb with the
               most scar tissue in this repo - see input_args.h.

     aesend    One of FOUR core Apple Events, to a process named by its
               serial. Not a class/id pipe; see input_args.h on why the
               vocabulary is closed.

   Each handler writes the whole command.result envelope into `out`, the
   way every other command in this guest does. */

void now_input_run_mouseloc(const char *request_json, long id,
                            char *out, long cap);
void now_input_run_script(const char *request_json, long id,
                          char *out, long cap);
void now_input_run_aesend(const char *request_json, long id,
                          char *out, long cap);

#endif /* NOW_INPUT_CMDS_H */
