#!/usr/bin/env python3
"""Report common redraw hazards in normal non-Carbon classic Mac UI source."""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


@dataclass(frozen=True)
class FunctionBlock:
    name: str
    line: int
    text: str
    source: Path | None = None
    is_static: bool = False


FUNCTION_START = re.compile(
    r"(?m)^[ \t]*(?:static[ \t]+)?(?:pascal[ \t]+)?"
    r"(?:[A-Za-z_]\w*[ \t\*\n]+)+"
    r"(?P<name>[A-Za-z_]\w*)[ \t]*\([^;{}]*\)[ \t\r\n]*\{"
)
CONTROL_WORDS = {"if", "for", "while", "switch"}
DIRECT_DRAW = re.compile(
    r"\b(?:DrawControls|UpdateControls|Draw1Control|TEUpdate|LUpdate|"
    r"EraseRect|PaintRect|FrameRect|DrawString|DrawText|DrawTheme[A-Za-z0-9_]*)\s*\("
)
INVALIDATE = re.compile(r"\b(?:InvalRect|InvalRgn|InvalWindowRect|InvalWindowRgn)\s*\(")
WHOLE_WINDOW_ERASE = re.compile(
    r"\bEraseRect\s*\(\s*&?\s*[A-Za-z_]\w*\s*(?:->|\.)\s*portRect\s*\)"
)
CALL = re.compile(r"\b([A-Za-z_]\w*)\s*\(")


def files(paths: Iterable[Path]) -> Iterable[Path]:
    for path in paths:
        if path.is_dir():
            yield from (
                item
                for item in path.rglob("*")
                if item.suffix.lower() in {".c", ".cc", ".cpp", ".h", ".r"}
            )
        elif path.is_file():
            yield path


def function_blocks(text: str, source: Path | None = None) -> Iterable[FunctionBlock]:
    """Yield approximate C function bodies for ownership-oriented diagnostics."""
    for match in FUNCTION_START.finditer(text):
        name = match.group("name")
        if name in CONTROL_WORDS:
            continue
        start = match.start()
        brace = text.find("{", match.start(), match.end())
        depth = 0
        index = brace
        while index < len(text):
            char = text[index]
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    yield FunctionBlock(
                        name=name,
                        line=text.count("\n", 0, start) + 1,
                        text=text[start:index + 1],
                        source=source,
                        is_static=bool(re.match(r"\s*static\b", text[start:match.end()])),
                    )
                    break
            index += 1


def findings(
    path: Path,
    text: str,
    function_index: dict[str, list[FunctionBlock]] | None = None,
) -> Iterable[str]:
    for line_number, line in enumerate(text.splitlines(), 1):
        if WHOLE_WINDOW_ERASE.search(line):
            yield (
                f"{path}:{line_number}: [whole-window-erase] Verify background "
                "ownership. Preserve the base window or dialog background and use "
                "white only for content surfaces that require it."
            )

    for function in function_blocks(text, path):
        begin_count = len(re.findall(r"\bBeginUpdate\s*\(", function.text))
        end_count = len(re.findall(r"\bEndUpdate\s*\(", function.text))
        if begin_count != end_count:
            yield (
                f"{path}:{function.line}: [unbalanced-update-owner] "
                f"{function.name} contains {begin_count} BeginUpdate call(s) and "
                f"{end_count} EndUpdate call(s). Verify every path and owner."
            )

        if "updateEvt" in function.text and not (
            re.search(r"\bBeginUpdate\s*\(", function.text)
            and re.search(r"\bEndUpdate\s*\(", function.text)
        ):
            if function_index and delegates_to_update_owner(function, function_index):
                continue
            yield (
                f"{path}:{function.line}: [update-event-delegation-lead] "
                f"{function.name} handles updateEvt without an in-function or "
                "bounded reachable balanced update owner. Trace dispatcher-to-window "
                "ownership manually; this lexical lead is not a confirmed defect."
            )

        is_tracking = re.search(
            r"(?:track|action|scroll)", function.name, re.IGNORECASE
        )
        is_nonpaint_callback = re.search(
            r"(?:idle|timer|tick|pump|command|bounds|resize|network|receive|completion)",
            function.name,
            re.IGNORECASE,
        )
        if (
            is_nonpaint_callback
            and not is_tracking
            and DIRECT_DRAW.search(function.text)
            and not INVALIDATE.search(function.text)
        ):
            yield (
                f"{path}:{function.line}: [nonpaint-callback-draw] "
                f"{function.name} appears to draw directly from a state, timer, "
                "service, or layout callback. Mutate and invalidate unless this is "
                "an explicitly bounded tracking-feedback exception."
            )


def build_function_index(sources: Iterable[tuple[Path, str]]) -> dict[str, list[FunctionBlock]]:
    index: dict[str, list[FunctionBlock]] = {}
    for _path, text in sources:
        for function in function_blocks(text, _path):
            index.setdefault(function.name, []).append(function)
    return index


def delegates_to_update_owner(
    function: FunctionBlock,
    function_index: dict[str, list[FunctionBlock]],
    *,
    depth: int = 3,
    seen: frozenset[str] = frozenset(),
) -> bool:
    if depth < 0 or function.name in seen:
        return False
    next_seen = seen | {function.name}
    for callee_name in CALL.findall(function.text):
        if callee_name in CONTROL_WORDS or callee_name == function.name:
            continue
        for callee in function_index.get(callee_name, []):
            if callee.is_static and callee.source != function.source:
                continue
            begin_count = len(re.findall(r"\bBeginUpdate\s*\(", callee.text))
            end_count = len(re.findall(r"\bEndUpdate\s*\(", callee.text))
            if begin_count and begin_count == end_count:
                return True
            if delegates_to_update_owner(
                callee, function_index, depth=depth - 1, seen=next_seen
            ):
                return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path)
    args = parser.parse_args()
    sources = [
        (path, path.read_text(encoding="mac_roman", errors="replace"))
        for path in files(args.paths)
    ]
    function_index = build_function_index(sources)
    count = 0
    for path, text in sources:
        for finding in findings(path, text, function_index):
            print(finding)
            count += 1
    print(f"classic-mac-toolbox-ui redraw audit: {count} finding(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
