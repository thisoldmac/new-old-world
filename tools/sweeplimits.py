"""One place where a sweep instrument states what it cannot see, and one
function that writes that statement beside every artifact it produces.

Sweep A (2026-08-07) knew its own blind spot and said so — in the report
a human wrote afterwards. The JSON it emitted said nothing, so a reader
who found `stability: 3` in `sweep-summary.json` a month later would have
no way to learn that the number was measured on a settled capture and is
silent about live flicker. A limitation stated once in prose and not in
the artifact is a limitation that will be forgotten, and this project has
already paid for a derived number that was true when written.

So: the limits are data, they travel with the run, and `write_limits`
drops a plain-text `LIMITS.md` in the output directory as well, for the
reader who opens a folder rather than a JSON file.
"""

import json
import os


def write_limits(outdir, tool, limits):
    """Write LIMITS.md beside the run's artifacts. Appends rather than
    overwrites when two tools write into one directory, because a sweep
    directory holds a capture phase and a live phase and both have
    limits the other does not."""
    path = os.path.join(outdir, "LIMITS.md")
    lines = ["", "## %s" % tool, ""]
    for key, text in limits.items():
        lines.append("- **%s** — %s" % (key, text))
    lines.append("")
    header = "" if os.path.exists(path) else (
        "# What this run cannot tell you\n\n"
        "Written by the instrument, not by a reader. Every score in this\n"
        "directory is bounded by the statements below; a number quoted\n"
        "without them is quoted out of context.\n")
    with open(path, "a") as handle:
        handle.write(header + "\n".join(lines))
    return path


def stamp(obj, limits):
    """Put the limits inside a JSON artifact, so the statement survives
    being copied out of the directory it was written in."""
    obj["limits"] = dict(limits)
    return obj


def render(limits):
    return json.dumps(limits, indent=1)
