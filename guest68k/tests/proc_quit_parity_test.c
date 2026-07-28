/* The PowerPC guest's `quit` grammar test, run against NOW-68K's copy.
 *
 *     cc -Wall -Wextra -Werror -I ../src proc_quit_parity_test.c \
 *        ../src/proc_quit_args.c ../src/numfmt.c -o t && ./t
 *
 * WHY THIS FILE IS ONE LINE OF INCLUDE.
 *
 * guest68k/src/proc_quit_args.c is a copy of the PowerPC guest's, and its
 * own header says so: the parsing grammar is unchanged "character for
 * character", and only the message building was rewritten, because this
 * target forbids the printf family (snprintf drags ~42 KB of newlib
 * float formatting into a 384 KB partition - numfmt.h).
 *
 * So the rewritten half is the half most likely to have drifted, and it
 * was the half with no test: the PowerPC copy had proc_quit_args_test.c
 * and this one had nothing. "Character for character the same" was a
 * claim in a comment that nothing checked - which is the arrangement
 * AGENTS.md calls two-halves-never-met-in-a-test, and the same shape as
 * the share-path rule (contract/share_path.h) found in the same sweep.
 *
 * Rather than copy the test - which would reproduce exactly the defect
 * being fixed, two copies drifting apart - this compiles the ORIGINAL
 * test source against THIS guest's implementation. One test, two
 * implementations. If the grammars ever diverge, this fails, and it
 * fails naming the case.
 *
 * The two headers are identical apart from a provenance comment, so the
 * include resolves to this guest's by include path alone.
 */
#include "../../guest/tests/proc_quit_args_test.c"
