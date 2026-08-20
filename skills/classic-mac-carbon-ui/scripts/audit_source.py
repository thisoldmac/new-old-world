#!/usr/bin/env python3
"""Report common source-level hazards for Mac OS 8.6-9.2.2 Carbon UI work."""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


@dataclass(frozen=True)
class Rule:
    name: str
    pattern: re.Pattern[str]
    guidance: str


@dataclass(frozen=True)
class FunctionBlock:
    name: str
    line: int
    text: str


RULES = (
    Rule("quartz-or-aqua", re.compile(r"\b(CGContext|HIView|HIToolbar|HISearchField|CreateNewWindowWithAttributes|kWindowSheetWindowClass)\b"), "Verify the CarbonLib annotation; this is commonly Mac OS X-only or outside the classic UI path."),
    Rule("classic-invalidation", re.compile(r"\b(InvalRect|InvalRgn|ValidRect|ValidRgn)\s*\("), "Carbon source must use the window-qualified InvalWindowRect/InvalWindowRgn or ValidWindowRect/ValidWindowRgn APIs."),
    Rule("raw-rgb-ui", re.compile(r"\b(RGBForeColor|RGBBackColor|BackColor|ForeColor)\s*\("), "Use Appearance Manager brushes and colors for UI chrome unless this is application content."),
    Rule("raw-upp-cast", re.compile(r"\([^\n)]*UPP\s*\)\s*[A-Za-z_]\w*"), "Create callbacks with the matching New...UPP routine and own their lifetime."),
    Rule("modal-dialog", re.compile(r"\b(ModalDialog|StandardAlert|NavGetFile|NavPutFile|NavChooseFolder)\s*\("), "Inventory this nested loop and provide a bounded pump callback where the API permits."),
    Rule("control-tracking", re.compile(r"\b(TrackControl|MenuSelect|DragWindow|GrowWindow)\s*\("), "Check cooperative liveness during tracking and use an action callback where available."),
    Rule("txn-update-owner", re.compile(r"\bTXNUpdate\s*\("), "TXNUpdate owns BeginUpdate/EndUpdate and is only appropriate when the window contains nothing besides that TXNObject; composite windows use TXNDraw inside the window update owner."),
    Rule("whole-window-erase", re.compile(r"\bEraseRect\s*\(\s*&?\s*[A-Za-z_]\w*\s*(?:->|\.)\s*portRect\s*\)"), "Verify background ownership. Do not turn a local update into an unconditional white whole-window repaint; use the theme/window background and content-specific white surfaces."),
    Rule("fixed-system-font", re.compile(r"\b(TextFont|TextSize)\s*\(\s*(0|1|3|12)\s*\)"), "Prefer the Appearance or system font role and measure dynamically."),
    Rule("data-browser", re.compile(r"\bCreateDataBrowserControl\s*\("), "Verify creation, callback ownership, error paths, low-memory behavior, and target runtime."),
    Rule("disclosure-title", re.compile(r"\bCreateDisclosureTriangleControl\s*\("), "Classic Carbon does not draw the control title; place a separate label and verify orientation support."),
    Rule("relevance-bar", re.compile(r"\bCreateRelevanceBarControl\s*\("), "This API is unavailable in CarbonLib 1.x."),
)

# Calls that make a manager-owned control repaint on its own schedule,
# outside the caller's invalidation discipline (redraw-and-damage.md,
# "Manager-Owned Controls Amplify Mutation Damage").
CONTROL_MUTATION = re.compile(
    r"\b(?:AddDataBrowserItems|RemoveDataBrowserItems|UpdateDataBrowserItems|"
    r"SetControlTitle|HiliteControl|SetControlValue|SetControlMaximum|"
    r"SetControl32BitValue|SetControl32BitMaximum)\s*\("
)
# Function names that suggest a per-message or transport-delivery callback:
# the path where one answer arrives as several parts and each part is
# tempted to mutate the control.
WIRE_CALLBACK_NAME = re.compile(
    r"(?:listing|reply|response|receive|arrive|note|page|wire|stream|"
    r"network|completion|callback)",
    re.IGNORECASE,
)
# Function names that suggest an idle, timer, or polling path: the path
# that runs when nothing changed and must therefore prove something did.
IDLE_PATH_NAME = re.compile(r"(?:idle|timer|tick|poll|pump)", re.IGNORECASE)
# This codebase documents its redraw rules beside the code they govern, so
# the mutation checks strip comments first: a comment SAYING SetControlTitle
# redraws is not a call to it.
C_COMMENT = re.compile(r"/\*.*?\*/|//[^\n]*", re.DOTALL)

FUNCTION_START = re.compile(
    r"(?m)^[ \t]*(?:static[ \t]+)?(?:pascal[ \t]+)?"
    r"(?:[A-Za-z_]\w*[ \t\*\n]+)+"
    r"(?P<name>[A-Za-z_]\w*)[ \t]*\([^;{}]*\)[ \t\r\n]*\{"
)
CONTROL_WORDS = {"if", "for", "while", "switch"}
DIRECT_DRAW = re.compile(
    r"\b(?:DrawControls|UpdateControls|Draw1Control|TXNDraw|TEUpdate|LUpdate|"
    r"EraseRect|PaintRect|FrameRect|DrawString|DrawText|DrawTheme[A-Za-z0-9_]*)\s*\("
)
INVALIDATE = re.compile(r"\b(?:InvalWindowRect|InvalWindowRgn|TXNForceUpdate)\s*\(")


def files(paths: Iterable[Path]) -> Iterable[Path]:
    for path in paths:
        if path.is_dir():
            yield from (p for p in path.rglob("*") if p.suffix.lower() in {".c", ".cc", ".cpp", ".h", ".r"})
        elif path.is_file():
            yield path


def function_blocks(text: str) -> Iterable[FunctionBlock]:
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
                    )
                    break
            index += 1


def function_findings(path: Path, text: str) -> Iterable[tuple[str, str, str]]:
    """Yield (check-name, function-name, message) triples."""
    for function in function_blocks(text):
        begin_count = len(re.findall(r"\bBeginUpdate\s*\(", function.text))
        end_count = len(re.findall(r"\bEndUpdate\s*\(", function.text))
        if begin_count != end_count:
            yield (
                "unbalanced-update-owner",
                function.name,
                f"{path}:{function.line}: [unbalanced-update-owner] "
                f"{function.name} contains {begin_count} BeginUpdate call(s) and "
                f"{end_count} EndUpdate call(s). Verify every path and owner.",
            )

        if "kEventWindowDrawContent" in function.text and re.search(
            r"\b(?:BeginUpdate|EndUpdate|DrawControls|UpdateControls)\s*\(",
            function.text,
        ):
            yield (
                "draw-content-ownership",
                function.name,
                f"{path}:{function.line}: [draw-content-ownership] "
                f"{function.name} handles kEventWindowDrawContent while also "
                "calling update-boundary or control-imaging APIs. With the "
                "standard handler, those operations are already owned by the system.",
            )

        if "kEventWindowBoundsChanged" in function.text and DIRECT_DRAW.search(
            function.text
        ):
            yield (
                "bounds-handler-draw",
                function.name,
                f"{path}:{function.line}: [bounds-handler-draw] "
                f"{function.name} appears to draw while handling changed window "
                "bounds. Recompute layout, set control bounds, and invalidate; "
                "paint from the subsequent draw event.",
            )

        if re.search(r"\bTXNDraw\s*\(", function.text) and not (
            re.search(r"\bBeginUpdate\s*\(", function.text)
            or "kEventWindowDrawContent" in function.text
        ):
            yield (
                "txn-draw-context",
                function.name,
                f"{path}:{function.line}: [txn-draw-context] "
                f"{function.name} calls TXNDraw without an obvious enclosing "
                "manual update or draw-content event. Verify that its caller owns "
                "the update cycle and passes NULL for editable text.",
            )

        if re.search(
            r"(?:idle|timer|tick|pump|command|bounds|resize|network|receive|completion)",
            function.name,
            re.IGNORECASE,
        ) and DIRECT_DRAW.search(function.text) and not INVALIDATE.search(function.text):
            yield (
                "nonpaint-callback-draw",
                function.name,
                f"{path}:{function.line}: [nonpaint-callback-draw] "
                f"{function.name} appears to draw directly from a state, timer, "
                "service, or layout callback. Mutate and invalidate unless this is "
                "an explicitly bounded tracking-feedback exception.",
            )

        mutation = CONTROL_MUTATION.search(C_COMMENT.sub("", function.text))
        if mutation is not None:
            call = mutation.group(0).rstrip("(").strip()
            if WIRE_CALLBACK_NAME.search(function.name):
                yield (
                    "per-message-control-mutation",
                    function.name,
                    f"{path}:{function.line}: [per-message-control-mutation] "
                    f"{function.name} mutates a manager-owned control ({call}) "
                    "and is named like a per-message or transport callback. The "
                    "control repaints per mutation, so an answer arriving in "
                    "parts repaints once per part; accumulate the parts in model "
                    "state and mutate once per settled answer. Review manually - "
                    "a single settle-time batch or a deliberate live-progress "
                    "fill is correct and belongs in the acknowledgment record.",
                )
            elif IDLE_PATH_NAME.search(function.name):
                yield (
                    "idle-control-mutation",
                    function.name,
                    f"{path}:{function.line}: [idle-control-mutation] "
                    f"{function.name} mutates a manager-owned control ({call}) "
                    "on what looks like an idle, timer, or polling path. These "
                    "calls redraw even when the new state equals the old; keep a "
                    "last-asserted copy and call only on change. Review manually "
                    "- a change-guarded call is correct and belongs in the "
                    "acknowledgment record.",
                )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument(
        "--select",
        help="comma-separated check names to run (default: every check)",
    )
    parser.add_argument(
        "--porcelain",
        action="store_true",
        help=(
            "print one stable key per finding (path:function:check for "
            "function checks, path:line:check for line checks) with no "
            "guidance and no summary, for consumption by scripts"
        ),
    )
    args = parser.parse_args()
    selected = None
    if args.select:
        selected = {name.strip() for name in args.select.split(",") if name.strip()}
    count = 0
    for path in files(args.paths):
        text = path.read_text(encoding="mac_roman", errors="replace")
        for line_number, line in enumerate(text.splitlines(), 1):
            for rule in RULES:
                if selected is not None and rule.name not in selected:
                    continue
                if rule.pattern.search(line):
                    if args.porcelain:
                        print(f"{path}:{line_number}:{rule.name}")
                    else:
                        print(f"{path}:{line_number}: [{rule.name}] {rule.guidance}")
                    count += 1
        for check, function_name, message in function_findings(path, text):
            if selected is not None and check not in selected:
                continue
            if args.porcelain:
                print(f"{path}:{function_name}:{check}")
            else:
                print(message)
            count += 1
    if not args.porcelain:
        print(f"classic-mac-carbon-ui audit: {count} finding(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
