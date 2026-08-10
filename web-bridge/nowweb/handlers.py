"""Optional site adapters that return ordinary semantic documents."""

from __future__ import annotations

import json
import re
from urllib.parse import quote, urlsplit
import urllib.request

from .document import Document, parse_document


class WikipediaHandler:
    name = "wikipedia"

    def matches(self, url: str) -> bool:
        host = (urlsplit(url).hostname or "").lower()
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
        return document


HANDLERS = (WikipediaHandler(),)
