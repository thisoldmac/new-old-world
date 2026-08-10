"""Optional site adapters that return ordinary semantic documents."""

from __future__ import annotations

import json
import html
import re
import time
from urllib.parse import parse_qs, quote, urlsplit
import urllib.request
import xml.etree.ElementTree as ET

from .document import Block, Document, Node, parse_document


class WikipediaHandler:
    name = "wikipedia"

    def matches(self, url: str) -> bool:
        parsed = urlsplit(url)
        if parse_qs(parsed.query).get("nowwebfull") == ["1"]:
            return False
        host = (parsed.hostname or "").lower()
        return host == "wikipedia.org" or host.endswith(".wikipedia.org")

    def fetch(self, url: str) -> Document:
        parsed = urlsplit(url)
        match = re.match(r"^/wiki/([^?#]+)$", parsed.path)
        if not match:
            raise ValueError("Wikipedia adapter only handles article URLs")
        title = match.group(1).replace("_", " ")
        endpoint = "%s://%s/w/api.php?action=parse&page=%s&prop=text&format=json" % (
            parsed.scheme or "https", parsed.netloc, quote(title))
        request = urllib.request.Request(
            endpoint, headers={"User-Agent": "NOW-Web-Bridge/0.1"})
        with urllib.request.urlopen(request, timeout=20) as response:
            value = json.load(response)
        source = value["parse"]["text"]["*"]
        document = parse_document(source, url)
        document.title = value["parse"].get("title", document.title)
        separator = "&" if "?" in url else "?"
        document.blocks.append(Block(
            "b%d" % (len(document.blocks) + 1),
            Node("p", children=[Node(
                "a", attrs={"href": url + separator + "nowwebfull=1"},
                children=["Generic View"])])))
        return document


class RedditHandler:
    """Read-only Reddit listings through its public Atom surface.

    The preserved 68K work established that unauthenticated JSON and old
    Reddit are not reliable entry points, while `.rss` remains useful but
    rate-limited. Cache every feed and let any exception fall through to the
    generic engine; a site adapter must never lower the fidelity floor.
    """

    name = "reddit"
    _atom = "{http://www.w3.org/2005/Atom}"

    def __init__(self, ttl: int = 300):
        self.ttl = ttl
        self.cache: dict[str, tuple[float, bytes]] = {}

    def matches(self, url: str) -> bool:
        parsed = urlsplit(url)
        if parse_qs(parsed.query).get("nowwebfull") == ["1"]:
            return False
        host = (parsed.hostname or "").lower()
        return host in {"reddit.com", "www.reddit.com", "old.reddit.com",
                        "np.reddit.com"} or host.endswith(".reddit.com")

    def _feed_url(self, url: str) -> str:
        parsed = urlsplit(url)
        path = parsed.path or "/r/popular/"
        if "/comments/" in path or path.startswith("/r/"):
            return "https://www.reddit.com%s/.rss?limit=60" % path.rstrip("/")
        if path in {"", "/"}:
            return "https://www.reddit.com/r/popular/.rss?limit=25"
        raise ValueError("Reddit adapter only handles listings and posts")

    def _read(self, feed_url: str) -> bytes:
        hit = self.cache.get(feed_url)
        now = time.monotonic()
        if hit and now - hit[0] <= self.ttl:
            return hit[1]
        request = urllib.request.Request(
            feed_url, headers={"User-Agent": "NOW-Web-Bridge/0.1"})
        with urllib.request.urlopen(request, timeout=20) as response:
            raw = response.read(2 * 1024 * 1024 + 1)
        if len(raw) > 2 * 1024 * 1024:
            raise ValueError("Reddit feed exceeds the adapter byte limit")
        if len(self.cache) >= 64:
            self.cache.clear()
        self.cache[feed_url] = (now, raw)
        return raw

    def from_atom(self, raw: bytes, source_url: str) -> Document:
        root = ET.fromstring(raw)
        feed_title = (root.findtext(self._atom + "title") or "Reddit").strip()
        escaped_feed_title = html.escape(feed_title)
        parts = ["<html><head><title>%s</title></head><body><h1>%s</h1>" %
                 (escaped_feed_title, escaped_feed_title)]
        for entry in root.findall(self._atom + "entry")[:60]:
            title = (entry.findtext(self._atom + "title") or "(untitled)").strip()
            author = (entry.findtext(
                self._atom + "author/" + self._atom + "name") or "").strip()
            link = entry.find(self._atom + "link")
            href = link.get("href", "") if link is not None else ""
            parts.append('<p><a href="%s">%s</a>%s</p>' %
                         (html.escape(href, quote=True), html.escape(title),
                          " - " + html.escape(author) if author else ""))
        separator = "&" if "?" in source_url else "?"
        generic_url = source_url + separator + "nowwebfull=1"
        parts.append('<hr><p><a href="%s">Generic View</a></p></body></html>' %
                     html.escape(generic_url, quote=True))
        return parse_document("".join(parts), source_url)

    def fetch(self, url: str) -> Document:
        return self.from_atom(self._read(self._feed_url(url)), url)


HANDLERS = (WikipediaHandler(), RedditHandler())
