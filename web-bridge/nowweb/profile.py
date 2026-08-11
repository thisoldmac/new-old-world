"""Named browser profiles keep guest-cost policy out of rendering code."""

from __future__ import annotations

from dataclasses import dataclass, replace


class ProfileError(ValueError):
    pass


@dataclass(frozen=True)
class BrowserProfile:
    name: str
    dialect: str
    page_bytes: int
    page_budget: int
    paginate: bool
    images: str
    image_max_px: int
    tables: str
    table_max_cells: int
    link_cap: int
    chunk_bytes: int
    entities: str

    def override(self, **values) -> "BrowserProfile":
        result = replace(self, **values)
        validate(result)
        return result


def validate(profile: BrowserProfile) -> None:
    if profile.dialect not in {"html2", "html32"}:
        raise ProfileError("dialect must be html2 or html32")
    if profile.images not in {"off", "thumb", "inline"}:
        raise ProfileError("images must be off, thumb, or inline")
    if profile.tables not in {"keep", "flatten", "pre"}:
        raise ProfileError("tables must be keep, flatten, or pre")
    if profile.entities not in {"ascii", "numeric"}:
        raise ProfileError("entities must be ascii or numeric")
    for field in ("page_bytes", "page_budget", "image_max_px",
                  "table_max_cells", "link_cap", "chunk_bytes"):
        if getattr(profile, field) <= 0:
            raise ProfileError("%s must be positive" % field)
    if profile.page_bytes > profile.page_budget:
        raise ProfileError("page_bytes cannot exceed page_budget")


PROFILES = {
    "classilla": BrowserProfile(
        name="classilla", dialect="html32", page_bytes=49152,
        page_budget=49152, paginate=False, images="off",
        image_max_px=160, tables="keep", table_max_cells=4096,
        link_cap=256, chunk_bytes=8192, entities="numeric"),
    "macweb": BrowserProfile(
        name="macweb", dialect="html2", page_bytes=16384,
        page_budget=32768, paginate=True, images="off",
        image_max_px=96, tables="flatten", table_max_cells=256,
        link_cap=128, chunk_bytes=4096, entities="ascii"),
    "generic68k": BrowserProfile(
        name="generic68k", dialect="html2", page_bytes=8192,
        page_budget=16384, paginate=True, images="off",
        image_max_px=96, tables="flatten", table_max_cells=128,
        link_cap=64, chunk_bytes=4096, entities="ascii"),
}

for _profile in PROFILES.values():
    validate(_profile)


def choose(requested: str = "", user_agent: str = "") -> BrowserProfile:
    if requested:
        try:
            return PROFILES[requested.lower()]
        except KeyError as exc:
            raise ProfileError("unknown browser profile: %s" % requested) from exc
    ua = user_agent.lower()
    if "macweb" in ua:
        return PROFILES["macweb"]
    if "classilla" in ua:
        return PROFILES["classilla"]
    return PROFILES["classilla"]
