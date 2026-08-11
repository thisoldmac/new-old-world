#!/bin/sh
# main-guardrail (Claude Code PreToolUse hook): keep an agent from dirtying or
# committing to the protected branch. A new thread must branch BEFORE its first
# edit, so main never gets touched in the first place. See AGENTS.md > Git.
#
# Wired from .claude/settings.json for Write|Edit|NotebookEdit and Bash.
#
# WHY THERE ARE TWO COPIES OF THIS FILE, and it is not laziness. The
# original lives in the parent TimBotTu checkout. `now/` is EXCLUDED from
# that repository (.git/info/exclude), so it is a separate repo and a NOW
# session's $CLAUDE_PROJECT_DIR is this tree — the parent's .claude/ is
# never loaded. There is no cross-repository scope for a Claude Code hook,
# so the only honest options are "duplicate it deliberately, naming the
# source" or "have no guard here at all". AGENTS.md:316 has claimed this
# guard existed since before it did; docs/rule-scopes.md carries the
# reasoning. Keep the two in step: the parent's copy is the source.
# Blocks (exit 2) when HEAD is main/master and the action would write a repo
# file or run `git commit`. Escape hatch: TBT_ALLOW_MAIN (env, or as a
# `TBT_ALLOW_MAIN=1 ...` prefix on the Bash command).
#
# Reads the PreToolUse event JSON on stdin: {tool_name, tool_input{...}, cwd}.

set -eu

payload=$(cat)
proj="${CLAUDE_PROJECT_DIR:-$(pwd)}"

branch=$(git -C "$proj" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")
case "$branch" in
    main|master) ;;          # protected — keep checking
    *) exit 0 ;;             # any topic branch: nothing to guard
esac

[ -n "${TBT_ALLOW_MAIN:-}" ] && exit 0

field() {   # field <dotted.path> — pull a string out of the event JSON
    printf '%s' "$payload" | python3 -c '
import sys, json
d = json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d = d.get(k, {}) if isinstance(d, dict) else {}
print(d if isinstance(d, str) else "")
' "$1" 2>/dev/null || echo ""
}

tool=$(field tool_name)

case "$tool" in
    Write|Edit|NotebookEdit)
        fp=$(field tool_input.file_path)
        [ -n "$fp" ] || fp=$(field tool_input.notebook_path)
        case "$fp" in
            "$proj"/*) ;;    # inside the repo -> guard it
            *) exit 0 ;;     # scratchpad / tmp / elsewhere -> allowed
        esac
        ;;
    Bash)
        cmd=$(field tool_input.command)
        printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+commit' || exit 0
        case "$cmd" in *TBT_ALLOW_MAIN=*) exit 0 ;; esac
        ;;
    *)
        exit 0
        ;;
esac

cat >&2 <<EOF
[main-guardrail] You are on '$branch'. This repo keeps main clean: start a
branch BEFORE writing or committing, so main never gets dirtied.

  New thread:  git checkout -b thread/<short-slug>
  Fork:        git checkout -b fork/<slug> <parent-branch>

Create the branch, then retry this action. Deliberate main change: prefix the
command with TBT_ALLOW_MAIN=1, or export TBT_ALLOW_MAIN=1 for the session.
(See AGENTS.md > Git.)
EOF
exit 2
