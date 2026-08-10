"""Plain HTTP/1.0 gateway and proxy-form listener for classic browsers."""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shlex
from urllib.parse import parse_qs, urlsplit

from . import PROTOCOL_VERSION, VERSION
from .engine import PlaywrightEngine, StaticEngine
from .policy import OutboundPolicy, PeerPolicy, PolicyError
from .profile import ProfileError, choose
from .service import WebService


@dataclass
class Config:
    host: str = "127.0.0.1"
    port: int = 5180
    engine: str = "static"
    settle_ms: int = 3000
    allowed_clients: list[str] = field(default_factory=list)
    allow_private_destinations: bool = False
    ai_plan_command: list[str] = field(default_factory=list)


def load_config(path: Path | None) -> Config:
    config = Config()
    if path is None:
        return config
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("config must be a JSON object")
    for key in value:
        if not hasattr(config, key):
            raise ValueError("unknown config field: %s" % key)
    for key, item in value.items():
        setattr(config, key, item)
    if not isinstance(config.port, int) or not 1 <= config.port <= 65535:
        raise ValueError("port must be between 1 and 65535")
    if config.engine not in {"static", "playwright"}:
        raise ValueError("engine must be static or playwright")
    return config


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    server_version = "NOWWeb/%s" % VERSION

    @property
    def bridge(self):
        return self.server.bridge

    def log_message(self, format, *args):
        # Never write request paths: they may carry query strings or page data.
        status = args[1] if len(args) > 1 else "event"
        print("NOW Web: %s - response %s" % (self.client_address[0], status))

    def _send(self, status: int, body: bytes, content_type: str = "text/html"):
        self.send_response(status)
        self.send_header("Content-Type", content_type + "; charset=us-ascii")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        for offset in range(0, len(body), self._chunk_bytes):
            self.wfile.write(body[offset:offset + self._chunk_bytes])

    @property
    def _chunk_bytes(self) -> int:
        return getattr(self, "rendered_profile", None).chunk_bytes if \
            getattr(self, "rendered_profile", None) else 4096

    def _error(self, status: int, message: str):
        body = ("<html><head><title>NOW Web Error</title></head><body>"
                "<h1>NOW Web could not load this page</h1><p>%s</p>"
                "<p><a href=\"/\">Return to NOW Web</a></p></body></html>" %
                message).encode("ascii", "replace")
        self._send(status, body)

    def do_CONNECT(self):
        self._error(501, "HTTPS tunneling is not supported. Use the NOW Web gateway; it handles HTTPS on the host.")

    def do_HEAD(self):
        self.do_GET(head_only=True)

    def do_GET(self, head_only: bool = False):
        if not self.server.peer_policy.allows(self.client_address[0]):
            self._error(403, "This listener is restricted to another classic Mac.")
            return
        try:
            path = self.path
            if path.startswith(("http://", "https://")):
                url = path
                query = {}
            else:
                parsed = urlsplit(path)
                query = parse_qs(parsed.query)
                if parsed.path == "/health":
                    payload = json.dumps({"protocol": PROTOCOL_VERSION,
                                          "version": VERSION,
                                          "engine": type(self.bridge.engine).__name__}).encode("ascii")
                    self._send(200, b"" if head_only else payload, "application/json")
                    return
                if parsed.path == "/page":
                    token = query.get("token", [""])[0]
                    number = int(query.get("n", ["1"])[0])
                    rendered = self.bridge.cached(token, number)
                    if rendered is None:
                        self._error(410, "That rendered page has expired. Reload the original address.")
                        return
                    self.rendered_profile = rendered.profile
                    self._send(200, b"" if head_only else rendered.body)
                    return
                if parsed.path == "/":
                    body = ("<html><head><title>NOW Web</title></head><body>"
                            "<h1>NOW Web</h1><form action=\"/go\" method=\"get\">"
                            "<p>Address: <input name=\"u\" size=\"60\"></p>"
                            "<p>Browser: <select name=\"profile\">"
                            "<option value=\"classilla\">Classilla</option>"
                            "<option value=\"macweb\">MacWeb</option>"
                            "<option value=\"generic68k\">Generic 68K</option>"
                            "</select></p><p><input type=\"submit\" value=\"Open\"></p>"
                            "</form></body></html>").encode("ascii")
                    self._send(200, b"" if head_only else body)
                    return
                if parsed.path != "/go":
                    self._error(404, "Unknown NOW Web route.")
                    return
                url = query.get("u", [""])[0]
            requested = query.get("profile", [""])[0]
            lens = query.get("lens", ["compatible"])[0]
            handlers = query.get("handlers", ["on"])[0] != "off"
            profile = choose(requested, self.headers.get("User-Agent", ""))
            rendered = self.bridge.render(url, profile, lens, handlers)
            self.rendered_profile = rendered.profile
            body = rendered.body
            if rendered.page_count > 1:
                links = ['<a href="/page?token=%s&amp;n=%d">%d</a>' %
                         (rendered.token, item, item)
                         for item in range(1, rendered.page_count + 1)]
                body = body.replace(b"</body>",
                    ("<hr><p>Pages: %s</p></body>" % " ".join(links)).encode("ascii"), 1)
            self._send(200, b"" if head_only else body)
        except (ProfileError, PolicyError, ValueError) as exc:
            self._error(400, str(exc))
        except Exception as exc:
            self._error(502, "The host-side renderer failed (%s)." % type(exc).__name__)


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, handler, bridge, peer_policy):
        super().__init__(address, handler)
        self.bridge = bridge
        self.peer_policy = peer_policy


def build(config: Config) -> Server:
    engine = (PlaywrightEngine(config.settle_ms) if config.engine == "playwright"
              else StaticEngine())
    bridge = WebService(
        engine, policy=OutboundPolicy(config.allow_private_destinations),
        planner_command=config.ai_plan_command or None)
    return Server((config.host, config.port), Handler, bridge,
                  PeerPolicy(frozenset(config.allowed_clients)))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="NOW Web Bridge")
    parser.add_argument("--config", type=Path)
    args = parser.parse_args(argv)
    config = load_config(args.config)
    server = build(config)
    address, port = server.server_address[:2]
    print("NOW_WEB_READY %s %s:%d" % (PROTOCOL_VERSION, address, port), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        close = getattr(server.bridge.engine, "close", None)
        if close:
            close()
    return 0
