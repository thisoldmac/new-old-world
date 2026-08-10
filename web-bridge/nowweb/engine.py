"""Fetch engines: stdlib static HTML and optional post-JS Playwright DOM."""

from __future__ import annotations

from dataclasses import dataclass
import urllib.request


class EngineError(RuntimeError):
    pass


@dataclass(frozen=True)
class FetchedPage:
    url: str
    source: str


class StaticEngine:
    def __init__(self, timeout: float = 20.0, max_bytes: int = 2 * 1024 * 1024):
        self.timeout = timeout
        self.max_bytes = max_bytes

    def fetch(self, url: str) -> FetchedPage:
        request = urllib.request.Request(
            url, headers={"User-Agent": "Mozilla/5.0 NOW-Web-Bridge/0.1",
                          "Accept": "text/html,application/xhtml+xml"})
        with urllib.request.urlopen(request, timeout=self.timeout) as response:
            content_type = response.headers.get_content_type()
            if content_type not in {"text/html", "application/xhtml+xml"}:
                raise EngineError("destination did not return an HTML document")
            data = response.read(self.max_bytes + 1)
            if len(data) > self.max_bytes:
                raise EngineError("source document exceeded the fetch limit")
            charset = response.headers.get_content_charset() or "utf-8"
            try:
                source = data.decode(charset, errors="replace")
            except LookupError:
                source = data.decode("utf-8", errors="replace")
            return FetchedPage(response.geturl(), source)


class PlaywrightEngine:
    def __init__(self, settle_ms: int = 3000):
        try:
            from playwright.sync_api import sync_playwright
        except ImportError as exc:
            raise EngineError("Playwright is not installed") from exc
        self._runtime = sync_playwright().start()
        self._browser = self._runtime.chromium.launch(headless=True)
        self._settle_ms = settle_ms

    def fetch(self, url: str) -> FetchedPage:
        page = self._browser.new_page()
        try:
            page.goto(url, wait_until="domcontentloaded", timeout=30000)
            page.wait_for_timeout(self._settle_ms)
            return FetchedPage(page.url, page.content())
        finally:
            page.close()

    def close(self) -> None:
        self._browser.close()
        self._runtime.stop()
