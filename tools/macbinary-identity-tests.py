#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "tools/macbinary-identity.py"
SPEC = importlib.util.spec_from_file_location("macbinary_identity", TOOL)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def fixture(name: str = "New Old World", creator: bytes = b"NOWo") -> bytes:
    data = b"PowerPC PEF"
    resource = b"resource fork"
    header = bytearray(128)
    encoded = name.encode("mac_roman")
    header[1] = len(encoded)
    header[2 : 2 + len(encoded)] = encoded
    header[65:69] = b"APPL"
    header[69:73] = creator
    header[83:87] = len(data).to_bytes(4, "big")
    header[87:91] = len(resource).to_bytes(4, "big")
    header[122] = 130
    header[123] = 129
    header[124:126] = MODULE.crc16_xmodem(header[:124]).to_bytes(2, "big")
    return (
        bytes(header)
        + data.ljust(MODULE.padded(len(data)), b"\0")
        + resource.ljust(MODULE.padded(len(resource)), b"\0")
    )


def invoke(path: Path, *expectations: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(TOOL), str(path), *expectations], text=True, capture_output=True
    )


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="now-macbinary-identity-") as raw:
        root = Path(raw)
        valid = root / "NOW.bin"
        valid.write_bytes(fixture())
        result = invoke(
            valid,
            "--expect-name", "New Old World",
            "--expect-type", "APPL",
            "--expect-creator", "NOWo",
        )
        assert result.returncode == 0, result.stderr
        assert "resource=13" in result.stdout

        native = root / "native"
        native.mkdir()
        result = invoke(valid, "--install-to", str(native))
        installed = native / "New Old World"
        assert result.returncode == 0, result.stderr
        assert installed.read_bytes() == b"PowerPC PEF"
        assert Path(str(installed) + "/..namedfork/rsrc").read_bytes() \
            == b"resource fork"
        finder_info = bytes.fromhex(subprocess.check_output(
            ["xattr", "-px", "com.apple.FinderInfo", str(installed)],
            text=True).replace(" ", "").replace("\n", ""))
        assert finder_info[:8] == b"APPLNOWo"

        wrong = invoke(valid, "--expect-creator", "O9ID")
        assert wrong.returncode == 1 and "expected creator" in wrong.stderr

        corrupt = root / "corrupt.bin"
        damaged = bytearray(fixture())
        damaged[65] ^= 1
        corrupt.write_bytes(damaged)
        result = invoke(corrupt)
        assert result.returncode == 1 and "CRC mismatch" in result.stderr

        truncated = root / "truncated.bin"
        truncated.write_bytes(fixture()[:-100])
        result = invoke(truncated)
        assert result.returncode == 1 and "truncated forks" in result.stderr

    print("MacBinary identity: 5 envelope, product, and native-fork behaviors passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
