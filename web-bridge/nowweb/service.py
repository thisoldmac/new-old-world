"""Request orchestration over one deterministic semantic document model."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import secrets
import time

from .document import (Document, PlanError, apply_plan, assemble_pages,
                       command_plan, parse_document, reader)
from .handlers import HANDLERS
from .policy import OutboundPolicy
from .profile import BrowserProfile


@dataclass(frozen=True)
class RenderedPage:
    body: bytes
    profile: BrowserProfile
    token: str
    page_number: int
    page_count: int
    fallback: str = ""


class RenderCache:
    def __init__(self, entries: int = 64, ttl: int = 900):
        self.entries = entries
        self.ttl = ttl
        self._items: dict[str, tuple[float, list[bytes], BrowserProfile]] = {}

    def put(self, pages: list[bytes], profile: BrowserProfile) -> str:
        self.expire()
        while len(self._items) >= self.entries:
            oldest = min(self._items, key=lambda key: self._items[key][0])
            del self._items[oldest]
        token = secrets.token_urlsafe(18)
        self._items[token] = (time.monotonic(), pages, profile)
        return token

    def get(self, token: str, number: int) -> RenderedPage | None:
        self.expire()
        item = self._items.get(token)
        if item is None:
            return None
        _, pages, profile = item
        if number < 1 or number > len(pages):
            return None
        return RenderedPage(pages[number - 1], profile, token, number, len(pages))

    def expire(self) -> None:
        now = time.monotonic()
        self._items = {key: item for key, item in self._items.items()
                       if now - item[0] <= self.ttl}


class WebService:
    def __init__(self, engine, policy: OutboundPolicy | None = None,
                 planner_command: list[str] | None = None,
                 planner_timeout: float = 8.0):
        self.engine = engine
        self.policy = policy or OutboundPolicy()
        self.planner_command = planner_command
        self.planner_timeout = planner_timeout
        self.cache = RenderCache()

    def _document(self, url: str, handlers: bool) -> Document:
        if handlers:
            for handler in HANDLERS:
                if handler.matches(url):
                    try:
                        return handler.fetch(url)
                    except Exception:
                        break
        fetched = self.engine.fetch(url)
        return parse_document(fetched.source, fetched.url)

    def render(self, url: str, profile: BrowserProfile,
               lens: str = "compatible", handlers: bool = True) -> RenderedPage:
        self.policy.validate(url)
        document = self._document(url, handlers)
        fallback = ""
        if lens == "reader":
            document = reader(document)
        elif lens == "ai":
            if not self.planner_command:
                fallback = "AI Layout is unavailable; showing Compatible Page."
                lens = "compatible"
            else:
                try:
                    plan = command_plan(document, self.planner_command,
                                        self.planner_timeout)
                    document = apply_plan(document, plan)
                except Exception as exc:
                    fallback = "AI Layout failed; showing Compatible Page (%s)." % type(exc).__name__
                    lens = "compatible"
        elif lens != "compatible":
            raise ValueError("unknown rendering lens: %s" % lens)
        pages = assemble_pages(document, profile, lens, handlers)
        if fallback:
            marker = ("<p><i>%s</i></p>" % fallback).encode("ascii", "replace")
            pages[0] = pages[0].replace(b"<hr>", b"<hr>" + marker, 1)
        token = self.cache.put(pages, profile)
        return RenderedPage(pages[0], profile, token, 1, len(pages), fallback)

    def cached(self, token: str, number: int) -> RenderedPage | None:
        return self.cache.get(token, number)
