import http.client
import html
import json
from pathlib import Path
import sys
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from nowweb.document import (PlanError, apply_plan, assemble_pages,
                             gateway_url, parse_document, reader)
from nowweb.engine import FetchedPage
from nowweb.handlers import RedditHandler
from nowweb.model_planner import order_from_output
from nowweb.policy import OutboundPolicy, PeerPolicy, PolicyError
from nowweb.profile import PROFILES, ProfileError, choose
from nowweb.server import Config, Handler, Server
from nowweb.service import WebService


class FakeEngine:
    def fetch(self, url):
        return FetchedPage(url, """<html><head><title>Café</title></head><body>
          <nav><a href='/menu'>Menu</a></nav><h1>Hello</h1>
          <p>Modern <a href='https://example.com/next'>next page</a>.</p>
          <form><input value='Search'></form></body></html>""")


class AllowPolicy:
    def validate(self, url):
        return url


class ProfileTests(unittest.TestCase):
    def test_user_agent_selects_macweb(self):
        self.assertEqual(choose(user_agent="MacWeb/2.0").name, "macweb")

    def test_explicit_profile_wins(self):
        self.assertEqual(choose("generic68k", "Classilla").name, "generic68k")

    def test_unknown_profile_is_a_typed_error(self):
        with self.assertRaises(ProfileError):
            choose("netscape")


class PolicyTests(unittest.TestCase):
    def test_local_destinations_are_blocked(self):
        with self.assertRaises(PolicyError):
            OutboundPolicy().validate("http://127.0.0.1/private")

    def test_peer_allowlist_is_exact(self):
        policy = PeerPolicy(frozenset({"10.0.0.7"}))
        self.assertTrue(policy.allows("10.0.0.7"))
        self.assertFalse(policy.allows("10.0.0.8"))


class DocumentTests(unittest.TestCase):
    def setUp(self):
        self.document = parse_document(FakeEngine().fetch("http://source.test").source,
                                       "http://source.test")

    def test_links_are_rewritten_through_gateway(self):
        body = assemble_pages(self.document, PROFILES["classilla"],
                              "compatible")[0]
        rewritten = html.escape(gateway_url("https://example.com/next",
                                             "classilla", "compatible"),
                                quote=True).encode("ascii")
        self.assertIn(rewritten, body)

    def test_macweb_output_is_ascii(self):
        body = assemble_pages(self.document, PROFILES["macweb"],
                              "compatible")[0]
        body.decode("ascii")
        self.assertIn(b"Cafe", body)

    def test_reader_removes_nav_and_forms(self):
        result = reader(self.document)
        self.assertNotIn("nav", [block.node.tag for block in result.blocks])
        self.assertNotIn("form", [block.node.tag for block in result.blocks])

    def test_ai_plan_cannot_lose_a_block(self):
        with self.assertRaises(PlanError):
            apply_plan(self.document, {"order": [self.document.blocks[0].identifier]})


class ServiceTests(unittest.TestCase):
    def test_unavailable_ai_falls_back_to_compatible(self):
        service = WebService(FakeEngine(), policy=AllowPolicy())
        result = service.render("http://source.test", PROFILES["classilla"], "ai")
        self.assertIn(b"AI Layout is unavailable", result.body)

    def test_pagination_has_stable_cache_identity(self):
        service = WebService(FakeEngine(), policy=AllowPolicy())
        tiny = PROFILES["macweb"].override(page_bytes=400, page_budget=1200)
        result = service.render("http://source.test", tiny)
        cached = service.cached(result.token, 1)
        self.assertIsNotNone(cached)
        self.assertEqual(cached.body, result.body)


class HandlerTests(unittest.TestCase):
    def test_reddit_atom_becomes_the_shared_document_model(self):
        atom = b'''<feed xmlns="http://www.w3.org/2005/Atom">
          <title>r/classicmac</title><entry><title>SE/30 day</title>
          <author><name>alice</name></author>
          <link href="https://www.reddit.com/r/classicmac/comments/1/x"/>
          </entry></feed>'''
        document = RedditHandler().from_atom(
            atom, "https://www.reddit.com/r/classicmac/")
        self.assertEqual(document.title, "r/classicmac")
        self.assertIn("SE/30 day", " ".join(item.text()
                                             for item in document.blocks))


class ModelPlannerTests(unittest.TestCase):
    def test_model_plan_cannot_drop_or_invent_blocks(self):
        self.assertEqual(order_from_output(
            "NAV: B3 B99 B3\nB1", ["b1", "b2", "b3"]),
            ["b3", "b1", "b2"])


class ServerTests(unittest.TestCase):
    def test_spawned_gateway_and_health(self):
        service = WebService(FakeEngine(), policy=AllowPolicy())
        server = Server(("127.0.0.1", 0), Handler, service, PeerPolicy())
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            connection = http.client.HTTPConnection("127.0.0.1",
                                                    server.server_port, timeout=2)
            connection.request("GET", "/health")
            response = connection.getresponse()
            payload = json.loads(response.read())
            self.assertEqual(response.status, 200)
            self.assertEqual(payload["protocol"], "now-web-bridge/1")
            connection.request("GET", "/go?u=http%3A%2F%2Fsource.test&profile=macweb")
            response = connection.getresponse()
            body = response.read()
            self.assertEqual(response.status, 200)
            self.assertIn(b"Hello", body)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
