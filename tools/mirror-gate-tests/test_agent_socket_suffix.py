"""The shell client and the host must agree where the socket is.

`NOW_AGENT_SOCKET_SUFFIX` is read inside
`AgentIntegrationEndpoint.currentUser` and nowhere else on the Swift
side, and `AgentEndpointIsolationTests` gates that. But `tools/now-agent`
is a SECOND PROCESS in a second language, and a client that does not know
about the suffix reaches whichever unsuffixed host happens to be up —
which is the collision the suffix exists to prevent, arriving from the
other end. A client that sanitises DIFFERENTLY is worse: it connects to
nothing while a healthy host listens, and says the host is not running.

So the two rules are compared here, against the same inputs the Swift
test uses. This is the only place the duplication is allowed to exist,
and it is the place that would catch it drifting.
"""

import os
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


def _client_sanitiser():
    """`sanitised_suffix` out of tools/now-agent, without running main."""
    source = (ROOT / "tools" / "now-agent").read_text()
    namespace: dict = {}
    exec(source.split("def call(")[0], namespace)   # noqa: S102 — our own file
    return namespace["sanitised_suffix"], namespace["socket_path"]


def _client_protocol_version():
    source = (ROOT / "tools" / "now-agent").read_text()
    namespace: dict = {}
    exec(source.split("def call(")[0], namespace)   # noqa: S102 — our own file
    return namespace["PROTOCOL_VERSION"]


class AgentSocketSuffixParity(unittest.TestCase):

    def test_the_client_uses_the_host_protocol_version(self):
        source = (ROOT / "now-host" / "Sources" / "NOWAgentIntegration"
                  / "AgentIntegrationLocalProtocol.swift").read_text()
        match = re.search(r"public static let version = ([0-9]+)", source)
        self.assertIsNotNone(match, "host protocol version declaration moved")
        self.assertEqual(
            _client_protocol_version(), int(match.group(1)),
            "tools/now-agent would be refused by the running host before "
            "any operation reached it")

    def test_the_client_accepts_exactly_what_the_host_accepts(self):
        sanitise, _ = _client_sanitiser()
        # The same table as AgentEndpointIsolationTests, deliberately.
        self.assertEqual(sanitise(None), "")
        self.assertEqual(sanitise(""), "")
        self.assertEqual(sanitise("019conf"), "-019conf")
        self.assertEqual(sanitise("lane_A-2"), "-lane_A-2")

    def test_the_client_refuses_rather_than_escapes(self):
        sanitise, _ = _client_sanitiser()
        for hostile in ("../elsewhere", "a/b", "with space", "dot.dot",
                        "null\0byte", "x" * 25):
            self.assertEqual(
                sanitise(hostile), "",
                f"{hostile!r} was accepted by the client but is refused by "
                "the host — the client would then dial an endpoint no host "
                "is on and report that nothing is listening")

    def test_the_suffix_actually_moves_the_client_socket(self):
        _, socket_path = _client_sanitiser()
        before = os.environ.get("NOW_AGENT_SOCKET_SUFFIX")
        try:
            os.environ["NOW_AGENT_SOCKET_SUFFIX"] = "lane019"
            with_suffix = socket_path()
            del os.environ["NOW_AGENT_SOCKET_SUFFIX"]
            without = socket_path()
        finally:
            if before is None:
                os.environ.pop("NOW_AGENT_SOCKET_SUFFIX", None)
            else:
                os.environ["NOW_AGENT_SOCKET_SUFFIX"] = before
        self.assertNotEqual(with_suffix, without)
        self.assertTrue(with_suffix.endswith("-lane019/host.sock"))
        self.assertTrue(without.endswith("now-agent-%d/host.sock"
                                         % os.geteuid()),
                        "unset is the PRODUCT's case and must be untouched")


if __name__ == "__main__":
    unittest.main()
