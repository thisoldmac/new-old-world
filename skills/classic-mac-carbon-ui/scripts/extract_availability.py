#!/usr/bin/env python3
"""Extract Apple Universal Interfaces availability blocks from C headers."""

from __future__ import annotations

import argparse
import csv
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


COMMENT_RE = re.compile(r"/\*.*?\*/", re.DOTALL)
SYMBOL_RE = re.compile(r"^\s*\*?\s*([A-Za-z_]\w*)\s*\(\s*\)\s*$", re.MULTILINE)
FIELD_RE = re.compile(
    r"^\s*\*?\s*(Non-Carbon CFM|CarbonLib|Mac OS X):\s*(.*?)\s*$",
    re.MULTILINE,
)


@dataclass(frozen=True)
class Availability:
    symbol: str
    header: Path
    line: int
    non_carbon_cfm: str
    carbonlib: str
    mac_os_x: str


def iter_headers(paths: Iterable[Path]) -> Iterable[Path]:
    seen: set[Path] = set()
    for path in paths:
        candidates = path.rglob("*.h") if path.is_dir() else (path,)
        for candidate in candidates:
            resolved = candidate.resolve()
            if resolved not in seen and candidate.suffix.lower() == ".h":
                seen.add(resolved)
                yield candidate


def parse_header(path: Path) -> Iterable[Availability]:
    text = path.read_text(encoding="mac_roman", errors="replace")
    for comment in COMMENT_RE.finditer(text):
        body = comment.group(0)
        if "Availability:" not in body:
            continue

        symbol_match = SYMBOL_RE.search(body)
        if not symbol_match:
            continue

        fields = {name: value for name, value in FIELD_RE.findall(body)}
        if not fields:
            continue

        yield Availability(
            symbol=symbol_match.group(1),
            header=path,
            line=text.count("\n", 0, comment.start()) + 1,
            non_carbon_cfm=fields.get("Non-Carbon CFM", ""),
            carbonlib=fields.get("CarbonLib", ""),
            mac_os_x=fields.get("Mac OS X", ""),
        )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Extract availability annotations from Universal Interfaces headers."
    )
    parser.add_argument("paths", nargs="+", type=Path, help="Header files or directories")
    parser.add_argument(
        "--symbol",
        help="Case-insensitive regular expression used to filter function names",
    )
    parser.add_argument(
        "--format",
        choices=("tsv", "markdown"),
        default="tsv",
        help="Output format (default: tsv)",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    symbol_filter = re.compile(args.symbol, re.IGNORECASE) if args.symbol else None
    rows = sorted(
        (
            row
            for header in iter_headers(args.paths)
            for row in parse_header(header)
            if symbol_filter is None or symbol_filter.search(row.symbol)
        ),
        key=lambda row: (str(row.header), row.line, row.symbol),
    )

    if args.format == "markdown":
        print("| Symbol | Header | Line | Non-Carbon CFM | CarbonLib | Mac OS X |")
        print("|---|---|---:|---|---|---|")
        for row in rows:
            values = (
                row.symbol,
                str(row.header),
                str(row.line),
                row.non_carbon_cfm,
                row.carbonlib,
                row.mac_os_x,
            )
            print("| " + " | ".join(value.replace("|", "\\|") for value in values) + " |")
    else:
        writer = csv.writer(sys.stdout, dialect="excel-tab", lineterminator="\n")
        writer.writerow(
            ("symbol", "header", "line", "non_carbon_cfm", "carbonlib", "mac_os_x")
        )
        for row in rows:
            writer.writerow(
                (
                    row.symbol,
                    row.header,
                    row.line,
                    row.non_carbon_cfm,
                    row.carbonlib,
                    row.mac_os_x,
                )
            )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
