"""Parse documentation provenance and expose it to MkDocs templates."""

from __future__ import annotations

from dataclasses import dataclass
import re


TOKEN = "now-doc-provenance:"
MARKER_RE = re.compile(
    r"^<!-- now-doc-provenance: (?P<generated>generated )?"
    r"reviewed=(?P<reviewed>true|false) -->$"
)


@dataclass(frozen=True)
class Provenance:
    generated: bool
    reviewed: bool

    @property
    def marker(self) -> str:
        generated = "generated " if self.generated else ""
        reviewed = "true" if self.reviewed else "false"
        return f"<!-- now-doc-provenance: {generated}reviewed={reviewed} -->"


class ProvenanceError(ValueError):
    """A Markdown source has missing or invalid provenance."""


def marker_lines(text: str) -> list[str]:
    """Return live marker lines, excluding fenced and indented examples."""
    found: list[str] = []
    fence_char = ""
    fence_size = 0
    for line in text.splitlines():
        stripped = line.lstrip()
        fence = re.match(r"^(`{3,}|~{3,})", stripped)
        if fence_char:
            if (fence and fence.group(1)[0] == fence_char
                    and len(fence.group(1)) >= fence_size):
                fence_char = ""
                fence_size = 0
            continue
        if fence:
            fence_char = fence.group(1)[0]
            fence_size = len(fence.group(1))
            continue
        if line.startswith(("    ", "\t")):
            continue
        if TOKEN in line:
            found.append(line.strip())
    return found


def parse(text: str) -> Provenance:
    lines = marker_lines(text)
    if not lines:
        raise ProvenanceError("missing now-doc-provenance marker")
    if len(lines) != 1:
        raise ProvenanceError(
            f"has {len(lines)} now-doc-provenance markers; exactly one is required"
        )

    line = lines[0]
    if "generated=false" in line:
        raise ProvenanceError(
            "generated is a presence marker; generated=false is contradictory"
        )
    reviewed_values = re.findall(r"reviewed=(true|false)", line)
    if len(set(reviewed_values)) > 1 or len(reviewed_values) > 1:
        raise ProvenanceError("has contradictory reviewed values")

    match = MARKER_RE.fullmatch(line)
    if match is None:
        raise ProvenanceError("has malformed now-doc-provenance marker")
    return Provenance(
        generated=match.group("generated") is not None,
        reviewed=match.group("reviewed") == "true",
    )


def on_page_markdown(markdown, page, config, files):
    provenance = parse(markdown)
    page.meta["now_doc_provenance"] = {
        "generated": provenance.generated,
        "reviewed": provenance.reviewed,
    }
    return markdown
