/*
 * n68_cmdresult.h - what a NOW-68K command DID, before anyone decides who
 * is reading it.
 *
 * THIS FILE EXISTS TO STOP A SECOND COMMAND TABLE FROM BEING WRITTEN.
 *
 * commands68.c used to run a command and build its command.result JSON in
 * one pass: run_launch() called proc_launch_named() and then immediately
 * called finish_ok_row1(), which emitted contract bytes. That is fine while
 * the only consumer is the wire. The moment a second consumer appears - the
 * interactive console window (conwin.h), which needs the same commands
 * rendered as text for a human sitting at the PowerBook - a fused
 * run-and-render has exactly two outs, and both are bad:
 *
 *   1. give the console its own launch/quit implementation, or
 *   2. have the console build JSON and then parse it back out.
 *
 * (1) is the defect class this project has paid the most for; the parent
 * corpus carries it as the finding `two-halves-never-met-in-a-test`, and
 * the PowerPC guest's design note for its own console is that "the same
 * command table runs locally on the guest and as a remote shell from the
 * host". (2) puts a JSON parser on the 68K to read bytes it just wrote.
 *
 * So the seam is here instead: a command produces an N68CmdResult - the
 * facts, no formatting - and this file holds BOTH renderers side by side,
 * where they cannot drift without someone editing them together. The JSON
 * renderer is byte-for-byte the one commands68.c used to carry inline; the
 * text renderer is new and reads the same struct.
 *
 * No Toolbox calls, no malloc/NewPtr/NewHandle, no printf family (numfmt.h
 * only, matching wire68.c and commands68.c) - this file compiles and tests
 * on the host, and guest68k/tests/test_cmdresult.c does exactly that.
 */
#ifndef NOW68K_N68_CMDRESULT_H
#define NOW68K_N68_CMDRESULT_H

enum {
    /* proc68.h: "a short ASCII sentence for the human" - both
     * proc_launch_named and proc_quit_named are handed a buffer this size,
     * so this is the widest text either renderer will ever be asked to
     * carry. Same number as commands68.c's kDetailCap, which is now stated
     * here and included there rather than declared twice. */
    kN68CmdTextCap  = 160,
    kN68CmdCodeCap  = 32,   /* "quit-undeliverable" is the longest today */
    kN68CmdKeyCap   = 12,   /* the output object's key: "launch", "quit" */
    kN68CmdLabelCap = 12,   /* a row label: "Launch", "Quit", "Outcome" */
    kN68CmdStateCap = 24    /* "sent-unconfirmed" is the longest today */
};

/*
 * One command's outcome. Exactly one of the two halves below is populated:
 *
 *   ok != 0   key/label/text describe row 0 of output.<key>, and - if
 *             state[0] != '\0' - label2/state describe row 1. code is "".
 *   ok == 0   code names the failure and text is the human sentence;
 *             key/label/label2/state are "".
 *
 * Fixed-size members rather than pointers on purpose: a command's `detail`
 * lives in a stack buffer inside the function that ran it, so a struct of
 * borrowed pointers would dangle the moment that frame returned. 256 bytes
 * copied once beats a lifetime rule nobody can see at the call site.
 *
 * STATIC BUDGET: 4 + 32 + 12 + 12 + 12 + 160 + 24 = 256 bytes, and it is
 * always a stack local - this file owns no BSS. wire68.c's command path
 * already carries a 512-byte reply buffer in the same frame; 256 more is
 * inside a 68K frame's normal headroom and there is no recursion here.
 */
typedef struct {
    int  ok;
    char code[kN68CmdCodeCap];
    char key[kN68CmdKeyCap];
    char label[kN68CmdLabelCap];
    char label2[kN68CmdLabelCap];
    char text[kN68CmdTextCap];
    char state[kN68CmdStateCap];
} N68CmdResult;

/* Zeroes every field, so a command that fills only what it needs cannot
 * leave a stale row behind. Call before filling. */
void n68_cmdresult_init(N68CmdResult *r);

/* Bounded copies into the fixed members above - the callers in commands68.c
 * have a `detail` buffer and a literal, not a formatter. They truncate at
 * the destination's capacity.
 *
 * THE ONE BEHAVIOURAL DIFFERENCE THE MOVE INTRODUCED, stated because it was
 * found by differential test rather than by reading. The old finish_* took
 * `message` as a pointer with no length bound, so a message longer than
 * this struct's text field would have gone out in full (or, if it did not
 * fit the wire buffer, fallen back to "(reply did not fit)"). Copying into
 * a fixed member instead means such a message is TRUNCATED.
 *
 * That case is unreachable, and structurally so rather than by luck: every
 * message commands68.c produces comes from a buffer declared kDetailCap
 * (160) or kMsgMax (80) bytes, and kDetailCap is *defined as*
 * kN68CmdTextCap - the same symbol, not a second number that agrees today.
 * The old and new renderers were compared over 1092 (shape x message x
 * code x capacity) combinations at message lengths up to 159 bytes and
 * agreed on every byte and every returned length; they diverge only above
 * that, where no caller can go. If a future command formats its own longer
 * sentence, this is the paragraph that says what happens to it. */
void n68_cmdresult_set_error(N68CmdResult *r, const char *code,
                              const char *message);
void n68_cmdresult_set_ok1(N68CmdResult *r, const char *key,
                            const char *label, const char *value);
void n68_cmdresult_set_ok2(N68CmdResult *r, const char *key,
                            const char *label1, const char *value1,
                            const char *label2, const char *value2);

/*
 * Renders `r` as one complete, NUL-terminated command.result JSON object
 * for the wire, echoing `id` per the CommandResult schema.
 *
 * Returns the number of bytes written before the terminator - `pos`, not
 * strlen(out), because that is what wire68.c's send path enqueues. Returns
 * 0 with out[0] = '\0' (when cap > 0) if even the compact fallback did not
 * fit, and the caller must treat that as nothing-to-send.
 *
 * The truth of a reply is never sacrificed to make it fit: when the full
 * text does not fit, the SAME ok bit and the SAME code come back with a
 * fixed "(reply did not fit)" note in place of the message, exactly once,
 * rather than a chain of ever-shorter attempts racing the buffer. See
 * NOW68K_COMMAND_RESULT_CAP in commands68.h for how big `cap` must be.
 */
long n68_cmdresult_render_json(const N68CmdResult *r, long id,
                                char *out, long cap);

/*
 * Renders `r` as console text for a human, into a NUL-terminated buffer,
 * returning the byte count (0 if nothing fit). Lines are separated by CR -
 * the terminator n68_linesplit.h already splits on - so the caller can feed
 * the whole buffer to an N68ConsoleRing in one call.
 *
 *   ok, one row    "Launch: SimpleText launched"
 *   ok, two rows   "Quit: asked NetPresenz to quit" CR "Outcome: gone"
 *   not ok         "! launch-refused: nothing named Foo is on this disk"
 *
 * The leading "! " is the one piece of formatting that is load-bearing
 * rather than decorative: on a 1-bit 640x480 panel in Monaco 9 there is no
 * color to lose, so failure has to be legible from the first character of
 * the line, not from reading to the end of the sentence.
 *
 * Unlike the JSON renderer there is no escaping here and none is wanted:
 * this text goes to QuickDraw's DrawText, where a MacRoman high byte is the
 * accented character the human typed, not a UTF-8 hazard. Control bytes are
 * dropped rather than escaped, because a stray CR inside `text` would
 * otherwise forge an extra console line. Truncation is plain: what fits is
 * shown, and - like the JSON renderer - the ok/failure marker and the code
 * are emitted BEFORE the message, so a shortened line still says what
 * happened even when it cannot say the details.
 */
long n68_cmdresult_render_text(const N68CmdResult *r, char *out, long cap);

/* Appends `s` into buf[*pos, cap) as the BODY of a JSON string - the
 * caller writes the surrounding quotes. See the definition in
 * n68_cmdresult.c for what each byte class becomes and why '?' is not an
 * acceptable answer for any of them.
 *
 * Published from this file, which is an odd home for it, because the
 * alternative is worse. Every message this guest sends with a
 * human-supplied string in it needs exactly this escaping, and the second
 * copy of a MacRoman-to-\u table is the kind of drift that presents as
 * "the 68K guest corrupts accented filenames" while the bytes on disk are
 * perfect. One implementation, and the file that already had it keeps it.
 *
 * Returns 1 if the whole string fit, 0 if it did not - and on 0 nothing
 * half-escaped is left behind, matching numfmt.h's append contract. No NUL
 * is written; the caller terminates once its whole chain succeeds. */
int now68k_json_append_escaped(char *buf, long cap, long *pos, const char *s);

#endif /* NOW68K_N68_CMDRESULT_H */
