"""Small QMP/RSP-independent memory substrate for the development oracle."""

from __future__ import annotations

from contextlib import contextmanager
import json
import os
from pathlib import Path
import socket
import tempfile
import time


class OracleError(RuntimeError):
    pass


class QMPClient:
    def __init__(self, socket_path: str, timeout: float = 15.0):
        self.socket_path = os.path.realpath(socket_path)
        self._socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._socket.settimeout(timeout)
        try:
            self._socket.connect(self.socket_path)
        except OSError as exc:
            raise OracleError(f"cannot connect to QMP socket {socket_path}: {exc}")
        self._file = self._socket.makefile("rw", encoding="utf-8", newline="\n")
        self._receive()
        self.execute("qmp_capabilities")

    def close(self) -> None:
        self._file.close()
        self._socket.close()

    def _send(self, value: dict) -> None:
        self._file.write(json.dumps(value) + "\r\n")
        self._file.flush()

    def _receive(self) -> dict:
        line = self._file.readline()
        if not line:
            raise OracleError("QMP connection closed before a reply")
        try:
            return json.loads(line)
        except ValueError as exc:
            raise OracleError(f"QMP returned invalid JSON: {exc}")

    def execute(self, command: str, arguments: dict | None = None):
        request = {"execute": command}
        if arguments is not None:
            request["arguments"] = arguments
        self._send(request)
        while True:
            response = self._receive()
            if "error" in response:
                detail = response["error"].get("desc", response["error"])
                raise OracleError(f"QMP {command} failed: {detail}")
            if "return" in response:
                return response["return"]

    def hmp(self, command_line: str) -> str:
        result = self.execute(
            "human-monitor-command", {"command-line": command_line})
        if not isinstance(result, str):
            raise OracleError("QMP human-monitor-command returned no text")
        lowered = result.lstrip().lower()
        if lowered.startswith(("error:", "invalid ")):
            raise OracleError(result.strip())
        return result


class VirtualMemory:
    """MMU-translated reads in the CPU context held by a stopped QEMU."""

    page_size = 4096

    def __init__(self, qmp: QMPClient, scratch: Path):
        self.qmp = qmp
        self.scratch = scratch
        self._cache: dict[int, bytes] = {}

    def clear(self) -> None:
        self._cache.clear()

    def _load_page(self, base: int) -> bytes:
        cached = self._cache.get(base)
        if cached is not None:
            return cached
        path = self.scratch / f"page-{base:08x}.bin"
        self.qmp.hmp(
            f'memsave 0x{base:x} 0x{self.page_size:x} "{path}"')
        try:
            data = path.read_bytes()
        except OSError as exc:
            raise OracleError(f"QEMU did not write memory page 0x{base:08x}: {exc}")
        if len(data) != self.page_size:
            raise OracleError(
                f"short QEMU memory page at 0x{base:08x}: {len(data)} bytes")
        self._cache[base] = data
        return data

    def read(self, address: int, length: int) -> bytes:
        if address < 0 or length < 0 or address + length > 0x1_0000_0000:
            raise OracleError("invalid 32-bit guest memory range")
        output = bytearray()
        cursor = address
        remaining = length
        while remaining:
            base = cursor & ~(self.page_size - 1)
            page = self._load_page(base)
            offset = cursor - base
            count = min(remaining, self.page_size - offset)
            output.extend(page[offset:offset + count])
            cursor += count
            remaining -= count
        return bytes(output)


def read_identity(path: str, supplied_socket: str) -> dict:
    try:
        identity = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise OracleError(f"oracle identity is not readable JSON: {exc}")
    if identity.get("schema") != "now-mirror-oracle-identity/v1":
        raise OracleError("oracle identity has the wrong schema")
    for field in ("guest", "session", "build", "vmName", "qmpSocket"):
        if not isinstance(identity.get(field), str) or not identity[field]:
            raise OracleError(f"oracle identity requires non-empty {field}")
    if os.path.realpath(identity["qmpSocket"]) != os.path.realpath(supplied_socket):
        raise OracleError("explicit QMP socket does not match oracle identity")
    return identity


def current_app_name(memory: VirtualMemory) -> str:
    raw = memory.read(0x910, 32)
    length = min(raw[0], 31)
    return raw[1:1 + length].decode("mac_roman", errors="replace")


@contextmanager
def coherent_context(qmp: QMPClient, memory: VirtualMemory,
                     expected_app: str, attempts: int = 80,
                     interval: float = 0.05):
    status = qmp.execute("query-status")
    was_running = status.get("status") == "running"
    stopped_by_us = False
    matched_attempt = 0
    try:
        count = attempts if was_running else 1
        for attempt in range(1, count + 1):
            if was_running:
                qmp.execute("stop")
                stopped_by_us = True
            memory.clear()
            actual = current_app_name(memory)
            if actual.casefold() == expected_app.casefold():
                matched_attempt = attempt
                break
            if not was_running:
                raise OracleError(
                    f"VM is already paused in {actual!r}, not {expected_app!r}")
            qmp.execute("cont")
            stopped_by_us = False
            time.sleep(interval)
        if not matched_attempt:
            raise OracleError(
                f"could not sample target context {expected_app!r} in "
                f"{attempts} attempts")
        yield {"attempt": matched_attempt, "app": actual}
    finally:
        if stopped_by_us:
            qmp.execute("cont")
