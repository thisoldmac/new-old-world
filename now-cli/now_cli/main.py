"""Production CLI for the loopback NOW v1 API, using only Python's stdlib."""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import http.client
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
from typing import Any
from urllib.parse import quote, urlencode, urlsplit

from ._generated import API_MAJOR, OPERATION_IDS, OPERATION_METADATA

EXIT_INVALID = 2
EXIT_UNAVAILABLE = 3
EXIT_TRANSPORT = 4
EXIT_INCOMPATIBLE = 5
EXIT_FAILED = 6


class CLIError(Exception):
    def __init__(self, message: str, code: int, response: Any = None):
        super().__init__(message)
        self.code = code
        self.response = response


def state_dir() -> Path:
    return Path.home() / "Library" / "Application Support" / "New Old World"


class State:
    def __init__(self) -> None:
        self.path = state_dir() / "now-cli.json"
        try:
            self.value = json.loads(self.path.read_text())
        except (OSError, ValueError):
            self.value = {}

    def save(self) -> None:
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        temporary = self.path.with_suffix(".tmp")
        temporary.write_text(json.dumps(self.value, indent=2, sort_keys=True) + "\n")
        temporary.chmod(0o600)
        temporary.replace(self.path)


class API:
    def __init__(self, endpoint: str, key: str):
        parts = urlsplit(endpoint.rstrip("/"))
        if parts.scheme != "http" or parts.hostname not in {"127.0.0.1", "localhost", "::1"}:
            raise CLIError("v1 accepts only a loopback http endpoint", EXIT_INVALID)
        self.host = parts.hostname or "127.0.0.1"
        self.port = parts.port or 80
        self.base = parts.path.rstrip("/") or "/api/v1"
        self.key = key
        self._major_checked = False

    def _connection(self) -> http.client.HTTPConnection:
        return http.client.HTTPConnection(self.host, self.port, timeout=15)

    def request(self, method: str, path: str, body: Any = None,
                headers: dict[str, str] | None = None,
                *, mutation: bool = False) -> tuple[int, dict[str, str], bytes]:
        if mutation:
            self.ensure_major()
        data: bytes | None
        actual = {"X-API-Key": self.key, "Accept": "application/json"}
        actual.update(headers or {})
        if body is None:
            data = None
        elif isinstance(body, bytes):
            data = body
        else:
            data = json.dumps(body, separators=(",", ":")).encode()
            actual["Content-Type"] = "application/json"
        connection = self._connection()
        try:
            connection.request(method, self.base + path, body=data, headers=actual)
            response = connection.getresponse()
            payload = response.read()
            result_headers = {k.lower(): v for k, v in response.getheaders()}
            status = response.status
        except (OSError, http.client.HTTPException) as error:
            raise CLIError(f"NOW API transport failed: {error}", EXIT_TRANSPORT) from error
        finally:
            connection.close()
        if status == 401:
            raise CLIError("NOW API rejected X-API-Key", EXIT_TRANSPORT)
        return status, result_headers, payload

    def json(self, method: str, path: str, body: Any = None,
             *, mutation: bool = False,
             headers: dict[str, str] | None = None) -> Any:
        status, _, payload = self.request(
            method, path, body, headers=headers, mutation=mutation)
        try:
            value = json.loads(payload)
        except ValueError as error:
            raise CLIError("NOW API returned malformed JSON", EXIT_INCOMPATIBLE) from error
        if status >= 400:
            problem = value.get("error", {}) if isinstance(value, dict) else {}
            message = problem.get("message") or f"NOW API returned HTTP {status}"
            code = EXIT_UNAVAILABLE if status in {404, 409, 503} else EXIT_INVALID
            raise CLIError(message, code)
        if isinstance(value, dict):
            disposition = value.get("disposition")
            exit_code = {
                "refused": EXIT_INVALID,
                "unavailable": EXIT_UNAVAILABLE,
                "failed": EXIT_FAILED,
            }.get(disposition)
            if exit_code is not None:
                problem = value.get("error")
                message = (problem.get("message")
                           if isinstance(problem, dict) else None)
                raise CLIError(
                    message or f"operation {disposition}",
                    exit_code, response=value)
        return value

    def download(self, path: str, destination: Path, *, force: bool = False) -> int:
        self.ensure_major()
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary: Path | None = None
        connection = self._connection()
        try:
            connection.request("GET", self.base + path,
                               headers={"X-API-Key": self.key})
            response = connection.getresponse()
            if response.status >= 400:
                response.read()
                raise CLIError(
                    f"download content returned HTTP {response.status}",
                    EXIT_UNAVAILABLE)
            descriptor, raw = tempfile.mkstemp(
                prefix=".now-download-", dir=destination.parent)
            temporary = Path(raw)
            os.chmod(raw, 0o600)
            written = 0
            with os.fdopen(descriptor, "wb") as output:
                while chunk := response.read(64 * 1024):
                    output.write(chunk); written += len(chunk)
                output.flush(); os.fsync(output.fileno())
            if force:
                os.replace(temporary, destination)
            else:
                try:
                    os.link(temporary, destination)
                except FileExistsError as error:
                    raise CLIError(
                        f"destination exists (use --force): {destination}",
                        EXIT_INVALID) from error
                temporary.unlink()
            temporary = None
            return written
        except (OSError, http.client.HTTPException) as error:
            raise CLIError(f"download failed: {error}", EXIT_TRANSPORT) from error
        finally:
            connection.close()
            if temporary is not None:
                with contextlib.suppress(OSError): temporary.unlink()

    def identity(self) -> dict[str, Any]:
        value = self.json("GET", "")
        major = value.get("apiMajor")
        if major != API_MAJOR:
            raise CLIError(
                f"unsupported NOW API major {major!r}; this CLI supports {API_MAJOR}",
                EXIT_INCOMPATIBLE)
        self._major_checked = True
        return value

    def ensure_major(self) -> None:
        if not self._major_checked:
            self.identity()


def load_key(explicit: str | None) -> str:
    if explicit:
        return explicit
    if os.environ.get("NOW_API_KEY"):
        return os.environ["NOW_API_KEY"]
    token = state_dir() / "now-api-key"
    try:
        mode = token.stat().st_mode & 0o777
        if mode & 0o077:
            raise CLIError(f"refusing credential with permissions {mode:o}: {token}", EXIT_TRANSPORT)
        value = token.read_text().strip()
    except OSError as error:
        raise CLIError(
            "no API key; start HTTP in NOW or set NOW_API_KEY/--api-key",
            EXIT_TRANSPORT) from error
    if not value:
        raise CLIError("the saved NOW API key is empty", EXIT_TRANSPORT)
    return value


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(prog="now", description="Control classic guests through the NOW v1 API")
    root.add_argument("--endpoint")
    root.add_argument("--api-key", help="use for this invocation only; never saved")
    root.add_argument("--json", action="store_true", dest="as_json")
    root.add_argument("--guest", help="stable guest ID (or use `now guests use`)")
    commands = root.add_subparsers(dest="domain", required=True)

    guests = commands.add_parser("guests")
    guest_commands = guests.add_subparsers(dest="verb", required=True)
    guest_commands.add_parser("list")
    status = guest_commands.add_parser("status"); status.add_argument("guest", nargs="?")
    use = guest_commands.add_parser("use"); use.add_argument("guest")

    connections = commands.add_parser("connections")
    connection_commands = connections.add_subparsers(dest="verb", required=True)
    for name in ("list", "start", "stop"):
        item = connection_commands.add_parser(name)
        if name == "stop": item.add_argument("--yes", action="store_true")
    disconnect = connection_commands.add_parser("disconnect")
    disconnect.add_argument("session"); disconnect.add_argument("--yes", action="store_true")

    console = commands.add_parser("console")
    console.add_argument("command"); console.add_argument("argument_line", nargs="?")
    console.add_argument("--arguments", help="typed JSON object")

    files = commands.add_parser("files")
    file_commands = files.add_subparsers(dest="verb", required=True)
    listing = file_commands.add_parser("list"); listing.add_argument("path", nargs="?", default="")
    stat = file_commands.add_parser("stat"); stat.add_argument("path")
    mkdir = file_commands.add_parser("mkdir"); mkdir.add_argument("path")
    move = file_commands.add_parser("move"); move.add_argument("path"); move.add_argument("destination")
    trash = file_commands.add_parser("trash"); trash.add_argument("path")
    restore = file_commands.add_parser("restore"); restore.add_argument("trashed_as"); restore.add_argument("path")
    get = file_commands.add_parser("get"); get.add_argument("path"); get.add_argument("destination", type=Path)
    get.add_argument("--force", action="store_true")
    put = file_commands.add_parser("put"); put.add_argument("source", type=Path); put.add_argument("path")
    put.add_argument("--container", choices=("data", "macbinary"), default="data")

    transfers = commands.add_parser("transfers")
    transfer_commands = transfers.add_subparsers(dest="verb", required=True)
    transfer_commands.add_parser("list")
    show = transfer_commands.add_parser("status"); show.add_argument("transfer")
    cancel = transfer_commands.add_parser("cancel"); cancel.add_argument("transfer")

    events = commands.add_parser("events")
    events.add_subparsers(dest="verb", required=True).add_parser("watch")

    api = commands.add_parser("api")
    api_commands = api.add_subparsers(dest="verb", required=True)
    api_commands.add_parser("operations")
    call = api_commands.add_parser("call")
    call.add_argument("operation", choices=sorted(OPERATION_METADATA))
    call.add_argument("--json-arguments", default="{}")
    call.add_argument("--session", help="exact guest session for mutations")
    return root


def emit(value: Any, as_json: bool) -> None:
    if as_json:
        print(json.dumps(value, indent=2, sort_keys=True))
        return
    if isinstance(value, dict):
        if "guests" in value:
            for item in value["guests"]:
                marker = "connected" if item.get("connected") else "offline"
                print(f"{item['id']}\t{marker}\t{item.get('displayName', '')}")
            return
        if "connections" in value:
            for item in value["connections"]:
                guest = item["guest"]
                print(f"{guest['sessionId']}\t{guest['id']}")
            return
        if "operations" in value:
            for item in value["operations"]:
                print(f"{item['operationId']}\t{item.get('effect', item.get('rendering', ''))}")
            return
        if "disposition" in value:
            print(value["disposition"])
            payload = value.get("value") or value.get("output")
            if payload is not None:
                print(json.dumps(payload, indent=2, sort_keys=True))
            if value.get("error"):
                print(value["error"].get("message", "failed"), file=sys.stderr)
            return
        for key, item in value.items():
            print(f"{key}: {item}")
        return
    print(value)


def require_guest(args: argparse.Namespace, state: State) -> str:
    value = args.guest or state.value.get("preferredGuest")
    if not value:
        raise CLIError("select a guest with --guest or `now guests use`", EXIT_INVALID)
    return value


def exact_session(api: API, guest: str) -> str:
    detail = api.json("GET", "/guests/" + quote(guest, safe=""))
    session = detail.get("sessionId")
    if not session:
        raise CLIError("the selected guest has no live session", EXIT_UNAVAILABLE)
    return session


def confirm(message: str, yes: bool) -> None:
    if yes:
        return
    if not sys.stdin.isatty() or input(message + " [y/N] ").strip().lower() != "y":
        raise CLIError("cancelled", EXIT_INVALID)


def transfer_progress(item: dict[str, Any]) -> None:
    if sys.stderr.isatty():
        done = item.get("transferredBytes", 0)
        total = item.get("expectedBytes")
        suffix = f"/{total}" if total is not None else ""
        print(f"transfer {item.get('id', '?')}: {done}{suffix} bytes {item.get('state', '')}", file=sys.stderr)


def cancel_transfer(api: API, transfer: str) -> None:
    with contextlib.suppress(CLIError):
        api.json("DELETE", "/transfers/" + quote(transfer, safe=""), mutation=True)


def run(args: argparse.Namespace, api: API, state: State) -> Any:
    if args.domain == "guests":
        if args.verb == "list": return api.json("GET", "/guests")
        if args.verb == "use":
            api.json("GET", "/guests/" + quote(args.guest, safe=""))
            state.value["preferredGuest"] = args.guest; state.save()
            return {"preferredGuest": args.guest}
        return api.json("GET", "/guests/" + quote(args.guest or require_guest(args, state), safe=""))
    if args.domain == "connections":
        if args.verb == "list": return api.json("GET", "/connections")
        if args.verb == "start": return api.json("PUT", "/listener", mutation=True)
        if args.verb == "stop":
            confirm("Stop accepting and close all guest connections?", args.yes)
            return api.json("DELETE", "/listener", mutation=True)
        confirm("Disconnect this exact guest session?", args.yes)
        return api.json("DELETE", "/connections/" + quote(args.session, safe=""), mutation=True)
    if args.domain == "console":
        guest = require_guest(args, state); session = exact_session(api, guest)
        if args.arguments and args.argument_line:
            raise CLIError("choose typed --arguments or one raw argument line", EXIT_INVALID)
        body = {"command": args.command}
        if args.arguments: body["arguments"] = json.loads(args.arguments)
        elif args.argument_line is not None: body["argumentLine"] = args.argument_line
        return api.json("POST", f"/guests/{quote(guest, safe='')}/commands",
                        body, mutation=True,
                        headers={"X-NOW-Guest-Session": session})
    if args.domain == "files":
        guest = require_guest(args, state)
        base = f"/guests/{quote(guest, safe='')}"
        if args.verb == "list": return api.json("GET", base + "/files?" + urlencode({"path": args.path}))
        if args.verb == "stat": return api.json("GET", base + "/files/stat?" + urlencode({"path": args.path}))
        session = exact_session(api, guest)
        session_header = {"X-NOW-Guest-Session": session}
        mutations = {
            "mkdir": {"mutation": "mkdir", "path": args.path},
            "move": {"mutation": "move", "path": args.path, "destinationPath": getattr(args, "destination", None)},
            "trash": {"mutation": "trash", "path": args.path},
            "restore": {"mutation": "restore", "trashedAs": getattr(args, "trashed_as", None), "path": args.path},
        }
        if args.verb in mutations:
            return api.json("POST", base + "/files/mutations",
                            mutations[args.verb], mutation=True,
                            headers=session_header)
        if args.verb == "put":
            size = args.source.stat().st_size
            hasher = hashlib.sha256()
            with args.source.open("rb") as source:
                while chunk := source.read(64 * 1024):
                    hasher.update(chunk)
            digest = hasher.hexdigest()
            item = api.json("POST", base + "/transfers/uploads", {"destinationPath": args.path, "bytes": size, "sha256": digest, "container": args.container}, mutation=True, headers=session_header)
            transfer = item["id"]
            try:
                offset = 0
                with args.source.open("rb") as source:
                    while chunk := source.read(8192):
                        item = api.json("PUT", f"/transfers/{transfer}/content?offset={offset}", chunk, mutation=True)
                        offset += len(chunk); transfer_progress(item)
                return api.json("POST", f"/transfers/{transfer}/commit", {}, mutation=True)
            except KeyboardInterrupt:
                cancel_transfer(api, transfer); raise CLIError("interrupted; transfer cancellation attempted", 130)
            except CLIError:
                cancel_transfer(api, transfer); raise
        if args.destination.exists() and not args.force:
            raise CLIError(
                f"destination exists (use --force): {args.destination}",
                EXIT_INVALID)
        item = api.json("POST", base + "/transfers/downloads", {"path": args.path}, mutation=True, headers=session_header)
        transfer = item["id"]
        try:
            api.download(f"/transfers/{transfer}/content", args.destination,
                         force=args.force)
            transfer_progress(item)
            return item
        except KeyboardInterrupt:
            cancel_transfer(api, transfer); raise CLIError("interrupted; transfer cancellation attempted", 130)
        except CLIError:
            cancel_transfer(api, transfer); raise
    if args.domain == "transfers":
        if args.verb == "list": return api.json("GET", "/transfers")
        if args.verb == "status": return api.json("GET", "/transfers/" + quote(args.transfer, safe=""))
        return api.json("DELETE", "/transfers/" + quote(args.transfer, safe=""), mutation=True)
    if args.domain == "events":
        api.identity()
        connection = api._connection()
        try:
            connection.request("GET", api.base + "/events", headers={"X-API-Key": api.key, "Accept": "text/event-stream"})
            response = connection.getresponse()
            if response.status != 200: raise CLIError(f"event stream returned HTTP {response.status}", EXIT_TRANSPORT)
            for raw in response:
                line = raw.decode("utf-8", "replace").rstrip()
                if line.startswith("data:"):
                    value = json.loads(line[5:].strip()); emit(value, args.as_json)
        except KeyboardInterrupt:
            raise CLIError("event watch interrupted", 130)
        finally:
            connection.close()
        return None
    if args.verb == "operations": return api.json("GET", "/operations")
    arguments = json.loads(args.json_arguments)
    metadata = OPERATION_METADATA.get(args.operation)
    if not metadata:
        raise CLIError("that operation has a first-class resource command, not generic invocation", EXIT_INVALID)
    guest = args.session or args.guest or state.value.get("preferredGuest")
    if metadata.get("effect") != "read" and not args.session:
        raise CLIError("mutating generic operations require --session with an exact session ID", EXIT_INVALID)
    body: dict[str, Any] = {"arguments": arguments}
    if guest: body["guest"] = guest
    return api.json("POST", "/operations/" + quote(args.operation, safe=""), body, mutation=metadata.get("effect") != "read")


def main(argv: list[str] | None = None) -> int:
    args: argparse.Namespace | None = None
    try:
        args = parser().parse_args(argv)
        state = State()
        endpoint = args.endpoint or os.environ.get("NOW_API_ENDPOINT") or state.value.get("endpoint") or "http://127.0.0.1:19870/api/v1"
        api = API(endpoint, load_key(args.api_key))
        result = run(args, api, state)
        if result is not None: emit(result, args.as_json)
        return 0
    except json.JSONDecodeError as error:
        print(f"now: invalid JSON: {error}", file=sys.stderr); return EXIT_INVALID
    except CLIError as error:
        if args is not None and args.as_json and error.response is not None:
            emit(error.response, True)
        else:
            print(f"now: {error}", file=sys.stderr)
        return error.code
    except (OSError, ValueError) as error:
        print(f"now: {error}", file=sys.stderr); return EXIT_FAILED


if __name__ == "__main__":
    raise SystemExit(main())
