#!/usr/bin/env python3
"""`key` must not post before it has been told the request is postable.

The whole honesty of this verb is one ordering: `now_key_check` runs, its
status is examined, and ONLY then does anything reach the Event Manager.
A handler that posted first and reported the status afterwards would type
the keystroke and then explain that it could not - which for a dropped
command modifier is precisely the upstream defect this verb exists not to
repeat (a literal character in a document, and a reply that said success).

That ordering is invisible to the native test. `input_args_test.c` proves
`now_key_check` returns kNowKeyModifiers for a modified request, and it
cannot prove the caller stopped: `PostEvent` is Toolbox and does not exist
on a host cc, so there is no way to observe from there whether the post
happened. So it is gated where it IS legible - as text.

Two assertions, and the second is the durable one:

  1. The key handler's early return on a non-ok status comes BEFORE the
     only call that posts.
  2. Nothing in the application names `PPostEvent`. That is the call that
     WOULD carry modifiers, it is CALL_NOT_IN_CARBON, and someone reading
     "this guest cannot post modifiers" will eventually try it. Today the
     Carbon build refuses it at compile time; this says so in a sentence
     rather than in a link error, and it keeps saying so if the
     application is ever built against a non-Carbon target.

Run with: python3 key_refusal_source_test.py
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src" / "input" / "input_cmds.c"

failures = []


def check(ok: bool, what: str) -> None:
    if not ok:
        failures.append(what)


text = SRC.read_text()


def body(signature: str) -> str:
    start = text.index(signature)
    end = text.index("\n}\n", start)
    return text[start:end]


# 1. The wire face.
wire = body("void now_input_run_key(")
check("now_key_check(" in wire, "the wire face still gates on now_key_check")
check("key_post(" in wire, "the wire face still posts through key_post")
check(wire.index("now_key_check(") < wire.index("key_post("),
      "now_input_run_key posts BEFORE it checks the request. A modified "
      "keystroke would be typed without its modifier and then refused")
refusal = wire.index("reply_error(out, cap, id, now_key_status_code(")
check(refusal < wire.index("key_post("),
      "now_input_run_key's refusal path no longer precedes the post, so a "
      "refused request can still reach the event queue")

# 2. The console face, which is a second caller of the same two halves and
#    is exactly where a shortcut would be taken.
console = body("void now_input_key_console(")
check("now_key_parse_line(" in console,
      "the console face still gates on now_key_parse_line")
check(console.index("now_key_parse_line(") < console.index("key_post("),
      "now_input_key_console posts before it parses")
check(console.index("!= kNowKeyOk") < console.index("key_post("),
      "now_input_key_console no longer returns on a refusal before posting")

def code_only(source: str) -> str:
    """The source with /* */ comments and "..." literals removed.

    Required here and not in the ordering checks above: every header that
    explains the modifier wall says the word `PPostEvent`, and so does the
    refusal MESSAGE the verb sends - naming the missing call is the whole
    point of that message. A gate that could not tell the explanation from
    the call would have to be deleted the first time anyone explained it,
    which is the opposite of what it is for."""
    out = []
    i = 0
    n = len(source)
    while i < n:
        if source.startswith("/*", i):
            end = source.find("*/", i + 2)
            i = n if end < 0 else end + 2
            continue
        if source[i] == '"':
            i += 1
            while i < n and source[i] != '"':
                i += 2 if source[i] == "\\" else 1
            i += 1
            continue
        out.append(source[i])
        i += 1
    return "".join(out)


# 3. The call that would carry modifiers, anywhere in the application.
for path in sorted((ROOT / "src").rglob("*.c")) + \
        sorted((ROOT / "src").rglob("*.h")):
    body_text = code_only(path.read_text())
    if "PPostEvent" in body_text:
        check(False,
              f"{path.relative_to(ROOT)} names PPostEvent. It is "
              "CALL_NOT_IN_CARBON and this application is Carbon; the "
              "modifier reach lives in the 68K resident half "
              "(ext/src/now_ext_act.c) and nowhere else")

if failures:
    for f in failures:
        print(f"FAIL: {f}")
    raise SystemExit(f"{len(failures)} failure(s)")
print("key_refusal_source: ok")
