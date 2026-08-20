from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import tempfile
import threading
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
import sys
sys.path.insert(0, str(ROOT / "now-cli"))

from now_cli import main as cli
from now_cli._generated import OPERATION_IDS, OPERATION_METADATA


class Server:
    def __init__(self, major=1):
        self.requests = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self): self.answer()
            def do_PUT(self): self.answer()
            def do_POST(self): self.answer()
            def do_DELETE(self): self.answer()
            def answer(self):
                owner.requests.append((self.command, self.path, self.headers.get("X-API-Key")))
                if self.path == "/api/v1": body = {"apiMajor": major}
                elif self.path == "/api/v1/listener": body = {"state": "listening"}
                else: body = {"operations": []}
                encoded = json.dumps(body).encode()
                self.send_response(200); self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded))); self.end_headers(); self.wfile.write(encoded)
            def log_message(self, *_): pass

        self.http = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()

    @property
    def endpoint(self):
        return f"http://127.0.0.1:{self.http.server_port}/api/v1"

    def close(self):
        self.http.shutdown(); self.thread.join(); self.http.server_close()


class CLITests(unittest.TestCase):
    def test_load_key_reads_only_the_application_api_credential(self):
        with tempfile.TemporaryDirectory() as home:
            support = Path(home) / "Library" / "Application Support" / "New Old World"
            support.mkdir(parents=True)
            mcp_key = support / "now-api-key"
            mcp_key.write_text("mcp-secret\n")
            mcp_key.chmod(0o600)
            application_key = support / "now-application-api-key"
            application_key.write_text("api-secret\n")
            application_key.chmod(0o600)
            with mock.patch.dict(os.environ, {"HOME": home}, clear=True):
                self.assertEqual(cli.load_key(None), "api-secret")

    @staticmethod
    def empty_state():
        state = object.__new__(cli.State); state.value = {}
        return state
    def invoke(self, arguments, home):
        output, errors = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, {"HOME": home, "NOW_API_KEY": "secret"}, clear=False), redirect_stdout(output), redirect_stderr(errors):
            code = cli.main(arguments)
        return code, output.getvalue(), errors.getvalue()

    def test_refuses_unknown_major_before_mutation(self):
        server = Server(major=2)
        try:
            with tempfile.TemporaryDirectory() as home:
                code, _, error = self.invoke(["--endpoint", server.endpoint, "connections", "start"], home)
            self.assertEqual(code, 5); self.assertIn("unsupported NOW API major", error)
            self.assertEqual(server.requests, [("GET", "/api/v1", "secret")])
        finally: server.close()

    def test_network_trace_is_api_v1_only(self):
        server = Server()
        try:
            with tempfile.TemporaryDirectory() as home:
                code, _, _ = self.invoke(["--endpoint", server.endpoint, "connections", "start"], home)
            self.assertEqual(code, 0)
            self.assertTrue(all(path.startswith("/api/v1") for _, path, _ in server.requests))
            self.assertEqual([method for method, _, _ in server.requests], ["GET", "PUT"])
        finally: server.close()

    def test_successful_http_dispositions_have_stable_exit_mapping(self):
        api = object.__new__(cli.API)
        for disposition, expected in [
            ("completed", 0),
            ("refused", 2),
            ("unavailable", 3),
            ("failed", 6),
        ]:
            payload = {"disposition": disposition, "value": {"kept": True}}
            api.request = mock.Mock(return_value=(
                200, {}, json.dumps(payload).encode()))
            if expected == 0:
                self.assertEqual(api.json("POST", "/operations/test"), payload)
            else:
                with self.assertRaises(cli.CLIError) as raised:
                    api.json("POST", "/operations/test")
                self.assertEqual(raised.exception.code, expected)
                self.assertEqual(raised.exception.response, payload)

        resource = {"guest": {"id": "pb1400c"}}
        api.request = mock.Mock(return_value=(
            200, {}, json.dumps(resource).encode()))
        self.assertEqual(api.json("GET", "/guests/pb1400c"), resource)

    def test_http_429_is_unavailable(self):
        api = object.__new__(cli.API)
        api.request = mock.Mock(return_value=(
            429, {}, json.dumps({"error": {"message": "capacity reached"}}).encode()))
        with self.assertRaises(cli.CLIError) as raised:
            api.json("GET", "/events")
        self.assertEqual(raised.exception.code, cli.EXIT_UNAVAILABLE)
        self.assertEqual(str(raised.exception), "capacity reached")

    def test_file_query_encodes_spaces_as_percent_twenty(self):
        class FakeAPI:
            def json(self, method, path, body=None, mutation=False, headers=None):
                self.path = path
                return {"entries": []}
        api = FakeAPI()
        args = cli.parser().parse_args([
            "--guest", "pb", "files", "list", "Desktop Folder:My File"])
        cli.run(args, api, self.empty_state())
        self.assertEqual(
            api.path, "/guests/pb/files?path=Desktop%20Folder%3AMy%20File")
        self.assertNotIn("+", api.path)

    def test_download_requires_exact_declared_content_length_before_install(self):
        class Response:
            status = 200
            def getheader(self, name):
                return "4" if name == "Content-Length" else None
            def read(self, _size=None):
                if hasattr(self, "done"): return b""
                self.done = True
                return b"abc"
        class Connection:
            def request(self, *_args, **_kwargs): pass
            def getresponse(self): return Response()
            def close(self): pass
        api = cli.API("http://127.0.0.1:1/api/v1", "key")
        api.identity = mock.Mock(return_value={"apiMajor": 1})
        api._connection = mock.Mock(return_value=Connection())
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "answer"
            with self.assertRaises(cli.CLIError) as raised:
                api.download("/transfers/id/content", destination)
            self.assertFalse(destination.exists())
        self.assertEqual(raised.exception.code, cli.EXIT_TRANSPORT)
        self.assertIn("expected 4, got 3", str(raised.exception))

    def test_event_429_is_unavailable_and_watch_has_no_read_deadline(self):
        class Response:
            status = 429
            def read(self):
                return json.dumps({"error": {"message": "stream limit"}}).encode()
        class Connection:
            def request(self, *_args, **_kwargs): pass
            def getresponse(self): return Response()
            def close(self): pass
        api = cli.API("http://127.0.0.1:1/api/v1", "key")
        api.identity = mock.Mock(return_value={"apiMajor": 1})
        api._connection = mock.Mock(return_value=Connection())
        args = cli.parser().parse_args(["events", "watch"])
        with self.assertRaises(cli.CLIError) as raised:
            cli.run(args, api, self.empty_state())
        self.assertEqual(raised.exception.code, cli.EXIT_UNAVAILABLE)
        self.assertEqual(str(raised.exception), "stream limit")
        api._connection.assert_called_once_with(timeout=None)

    def test_json_mode_preserves_refused_payload_and_nonzero_exit(self):
        payload = {
            "operationId": "processes.list",
            "disposition": "refused",
            "value": {"kept": True},
            "error": {"message": "the guest declined"},
        }
        api = object.__new__(cli.API)
        api.request = mock.Mock(return_value=(
            200, {}, json.dumps(payload).encode()))
        with tempfile.TemporaryDirectory() as home, \
             mock.patch.object(cli, "API", return_value=api):
            code, output, error = self.invoke(
                ["--json", "api", "call", "processes.list"], home)
        self.assertEqual(code, 2)
        self.assertEqual(json.loads(output), payload)
        self.assertEqual(error, "")

    def test_human_mode_reports_semantic_failure_on_stderr(self):
        payload = {
            "operationId": "processes.list",
            "disposition": "unavailable",
            "error": {"message": "no guest is connected"},
        }
        api = object.__new__(cli.API)
        api.request = mock.Mock(return_value=(
            200, {}, json.dumps(payload).encode()))
        with tempfile.TemporaryDirectory() as home, \
             mock.patch.object(cli, "API", return_value=api):
            code, output, error = self.invoke(
                ["api", "call", "processes.list"], home)
        self.assertEqual(code, 3)
        self.assertEqual(output, "")
        self.assertIn("no guest is connected", error)

    def test_cli_source_has_no_mcp_or_private_protocol_fallback(self):
        source = (ROOT / "now-cli" / "now_cli" / "main.py").read_text().lower()
        self.assertNotIn("/mcp", source)
        self.assertNotIn("local protocol", source)
        self.assertNotIn("unix socket", source)

    def test_generated_operation_set_matches_openapi(self):
        document = json.loads((ROOT / "contract" / "now-api.openapi.json").read_text())
        self.assertEqual(OPERATION_IDS, frozenset(document["x-now-operation-catalog"]))
        expected = {row["operationId"]: {key: row[key] for key in ("effect", "addressing", "rendering")}
                    for row in document["x-now-cli-operation-metadata"]}
        self.assertEqual(OPERATION_METADATA, expected)

    def test_generated_shell_completion_covers_parser_grammar(self):
        root = cli.parser()
        domains = next(action for action in root._actions
                       if isinstance(action, cli.argparse._SubParsersAction))
        expected = {}
        for domain, domain_parser in domains.choices.items():
            subcommands = next((action for action in domain_parser._actions
                                if isinstance(
                                    action, cli.argparse._SubParsersAction)),
                               None)
            expected[domain] = tuple(subcommands.choices) if subcommands else ()

        bash = (ROOT / "now-cli" / "completion" / "now.bash").read_text()
        zsh = (ROOT / "now-cli" / "completion" / "_now").read_text()
        bash_rows = {domain: tuple(words.split()) for domain, words in
                     re.findall(r'^    (\w+)\) candidates="([^"]*)"',
                                bash, re.MULTILINE)}
        zsh_rows = {domain: tuple(words.split()) for domain, words in
                    re.findall(r'^    (\w+)\) candidates=\(([^)]*)\)',
                               zsh, re.MULTILINE)}
        self.assertEqual(bash_rows, expected)
        self.assertEqual(zsh_rows, expected)

        generic_ids = tuple(sorted(OPERATION_METADATA))
        bash_ids = re.search(
            r'generic_operations="([^"]*)"', bash).group(1).split()
        zsh_ids = re.search(
            r'generic_operations=\(([^)]*)\)', zsh).group(1).split()
        self.assertEqual(tuple(bash_ids), generic_ids)
        self.assertEqual(tuple(zsh_ids), generic_ids)
        self.assertIn('"data macbinary"', bash)
        self.assertIn('candidates=(data macbinary)', zsh)

        api_parser = domains.choices["api"]
        api_commands = next(action for action in api_parser._actions
                            if isinstance(
                                action, cli.argparse._SubParsersAction))
        call_parser = api_commands.choices["call"]
        operation = next(action for action in call_parser._actions
                         if action.dest == "operation")
        self.assertEqual(tuple(operation.choices), generic_ids)
        self.assertLess(len(operation.choices), len(OPERATION_IDS))

    def test_nonsecret_state_never_contains_api_key(self):
        with tempfile.TemporaryDirectory() as home:
            state = cli.State(); state.path = Path(home) / "state.json"
            state.value["endpoint"] = "http://127.0.0.1:1/api/v1"
            state.value["preferredGuest"] = "pb1400c"; state.save()
            text = state.path.read_text()
            self.assertNotIn("secret", text); self.assertNotIn("apiKey", text)

    def test_generic_mutation_requires_exact_session_before_post(self):
        class FakeAPI:
            calls = []
            def json(self, method, path, body=None, mutation=False):
                self.calls.append((method, path))
                return {"operations": [{"operationId": "processes.quit", "rendering": "generic", "effect": "boundedMutation"}]}
        args = cli.parser().parse_args(["--guest", "pb1400c", "api", "call", "processes.quit"])
        with self.assertRaises(cli.CLIError) as raised:
            cli.run(args, FakeAPI(), self.empty_state())
        self.assertEqual(raised.exception.code, 2)
        self.assertEqual(FakeAPI.calls, [])

    def test_upload_interrupt_attempts_cancel_and_returns_130(self):
        class FakeAPI:
            calls = []
            def json(self, method, path, body=None, mutation=False, headers=None):
                self.calls.append((method, path))
                if path.startswith("/guests/") and method == "GET": return {"sessionId": "pb-uuid"}
                if path.endswith("/transfers/uploads"): return {"id": "transfer-1"}
                if method == "PUT": raise KeyboardInterrupt()
                return {"state": "cancelled"}
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source"; source.write_bytes(b"abc")
            args = cli.parser().parse_args(["--guest", "pb", "files", "put", str(source), "Drop Box:source"])
            with self.assertRaises(cli.CLIError) as raised:
                cli.run(args, FakeAPI(), self.empty_state())
        self.assertEqual(raised.exception.code, 130)
        self.assertIn(("DELETE", "/transfers/transfer-1"), FakeAPI.calls)

    def test_download_interrupt_cleans_partial_and_attempts_cancel(self):
        class FakeAPI:
            calls = []
            def json(self, method, path, body=None, mutation=False, headers=None):
                self.calls.append((method, path))
                if path.startswith("/guests/") and method == "GET": return {"sessionId": "pb-uuid"}
                if path.endswith("/transfers/downloads"): return {"id": "transfer-2"}
                return {"state": "cancelled"}
            def download(self, path, destination, force=False):
                destination.with_name(".now-download-partial").write_bytes(b"partial")
                destination.with_name(".now-download-partial").unlink()
                raise KeyboardInterrupt()
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "answer.bin"
            args = cli.parser().parse_args(["--guest", "pb", "files", "get", "Drop Box:answer", str(destination)])
            with self.assertRaises(cli.CLIError) as raised:
                cli.run(args, FakeAPI(), self.empty_state())
            self.assertFalse(destination.exists())
        self.assertEqual(raised.exception.code, 130)
        self.assertIn(("DELETE", "/transfers/transfer-2"), FakeAPI.calls)

    def test_download_refuses_existing_destination_before_transfer(self):
        class FakeAPI:
            calls = []
            def json(self, method, path, body=None, mutation=False, headers=None):
                self.calls.append((method, path))
                if path.startswith("/guests/"): return {"sessionId": "pb-session"}
                return {"id": "should-not-start"}
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "answer.bin"
            destination.write_bytes(b"keep")
            args = cli.parser().parse_args(["--guest", "pb", "files", "get", "Drop Box:answer", str(destination)])
            with self.assertRaises(cli.CLIError) as raised:
                cli.run(args, FakeAPI(), self.empty_state())
            self.assertEqual(destination.read_bytes(), b"keep")
        self.assertEqual(raised.exception.code, 2)
        self.assertEqual(FakeAPI.calls, [("GET", "/guests/pb")])


if __name__ == "__main__": unittest.main()
