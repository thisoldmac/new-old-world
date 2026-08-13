from __future__ import annotations

import plistlib
import struct
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

from .artifacts import copy_exact
from .profile import ReleaseRefusal


def _crc16(data: bytes) -> int:
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (
                crc << 1) & 0xFFFF
    return crc


def _padded(length: int) -> int:
    return (length + 127) // 128 * 128


@dataclass(frozen=True)
class MacBinaryFile:
    name: str
    file_type: bytes
    creator: bytes
    finder_flags: int
    data_fork: bytes
    resource_fork: bytes

    @classmethod
    def decode(cls, raw: bytes) -> "MacBinaryFile":
        if len(raw) < 128 or raw[0] != 0 or not 1 <= raw[1] <= 63:
            raise ReleaseRefusal("input is not a complete MacBinary file")
        name_end = 2 + raw[1]
        name = raw[2:name_end].decode("mac_roman")
        data_length = struct.unpack_from(">I", raw, 83)[0]
        resource_length = struct.unpack_from(">I", raw, 87)[0]
        data_start = 128
        resource_start = data_start + _padded(data_length)
        expected = resource_start + _padded(resource_length)
        if len(raw) != expected:
            raise ReleaseRefusal("MacBinary fork lengths do not match the file")
        if raw[122] >= 129 and _crc16(raw[:124]) != struct.unpack_from(">H", raw, 124)[0]:
            raise ReleaseRefusal("MacBinary header checksum is invalid")
        return cls(
            name=name, file_type=raw[65:69], creator=raw[69:73],
            finder_flags=(raw[73] << 8) | raw[101],
            data_fork=raw[data_start:data_start + data_length],
            resource_fork=raw[resource_start:resource_start + resource_length],
        )

    def encode(self) -> bytes:
        name = self.name.encode("mac_roman")
        if not 1 <= len(name) <= 63 or len(self.file_type) != 4 or len(self.creator) != 4:
            raise ReleaseRefusal("classic filename, type, or creator is invalid")
        header = bytearray(128)
        header[1] = len(name)
        header[2:2 + len(name)] = name
        header[65:69] = self.file_type
        header[69:73] = self.creator
        header[73] = self.finder_flags >> 8
        header[101] = self.finder_flags & 0xFF
        struct.pack_into(">I", header, 83, len(self.data_fork))
        struct.pack_into(">I", header, 87, len(self.resource_fork))
        header[122] = 129
        header[123] = 129
        struct.pack_into(">H", header, 124, _crc16(header[:124]))
        return bytes(header) + self.data_fork + bytes(
            _padded(len(self.data_fork)) - len(self.data_fork)
        ) + self.resource_fork + bytes(
            _padded(len(self.resource_fork)) - len(self.resource_fork)
        )

    def write_native(self, directory: Path, name: str | None = None) -> Path:
        output = directory / (name or self.name)
        output.write_bytes(self.data_fork)
        if self.resource_fork:
            resource_path = Path(str(output) + "/..namedfork/rsrc")
            resource_path.write_bytes(self.resource_fork)
        finder_info = bytearray(32)
        finder_info[0:4] = self.file_type
        finder_info[4:8] = self.creator
        struct.pack_into(">H", finder_info, 8, self.finder_flags)
        completed = subprocess.run([
            "/usr/bin/xattr", "-wx", "com.apple.FinderInfo",
            bytes(finder_info).hex(), str(output),
        ], capture_output=True)
        if completed.returncode:
            detail = completed.stderr.decode("utf-8", errors="replace").strip()
            raise ReleaseRefusal(
                f"could not preserve Finder metadata for {output}: {detail}")
        return output


def populate_generic(directory: Path, application: Path, extension: Path,
                     carbonlib: Path, license_files: tuple[Path, ...]) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    MacBinaryFile.decode(application.read_bytes()).write_native(
        directory, "New Old World")
    MacBinaryFile.decode(extension.read_bytes()).write_native(
        directory, "NOW Extension")
    dependencies = directory / "Dependencies"
    dependencies.mkdir()
    try:
        MacBinaryFile.decode(carbonlib.read_bytes()).write_native(dependencies)
    except ReleaseRefusal:
        copy_exact(carbonlib, dependencies / carbonlib.name)
    licenses = dependencies / "License Material"
    licenses.mkdir()
    for path in license_files:
        copy_exact(path, licenses / path.name)
    (directory / "Read Me First.txt").write_bytes(
        b"NEW OLD WORLD SETUP\r\r"
        b"Copy New Old World to your hard disk. This release image has no "
        b"saved host address; enter the modern Mac's address in Connection.\r\r"
        b"OPTIONAL\rPut NOW Extension in System Folder:Extensions and restart.\r"
        b"The Apple CarbonLib installer and its license material are in "
        b"Dependencies. Run the installer and accept Apple's license if "
        b"CarbonLib 1.6 is not already installed.\r"
    )


def build_generic_image(output: Path, application: Path, extension: Path,
                        carbonlib: Path,
                        license_files: tuple[Path, ...]) -> None:
    with tempfile.TemporaryDirectory(prefix="now-generic-image-") as raw_temp:
        workspace = Path(raw_temp)
        contents = workspace / "contents"
        populate_generic(contents, application, extension, carbonlib,
                         license_files)
        image = workspace / "filesystem.dmg"
        allocated_kib = int(_run(["/usr/bin/du", "-sk", str(contents)]).split()[0])
        size = max(2 * 1024 * 1024, (allocated_kib + 1024) * 1024)
        if size > 128 * 1024 * 1024:
            raise ReleaseRefusal("generic setup image exceeds the 128 MiB cap")
        _run([
            "/usr/bin/hdiutil", "create", "-srcfolder", str(contents),
            "-size", str(size), "-fs", "HFS+", "-volname", "NOW Setup",
            "-layout", "NONE", "-format", "UDRW", str(image),
        ])
        attach = plistlib.loads(_run_bytes([
            "/usr/bin/hdiutil", "attach", "-plist", "-nobrowse", "-nomount",
            str(image),
        ]))
        entities = attach.get("system-entities", [])
        devices = [row.get("dev-entry") for row in entities if row.get("dev-entry")]
        if not devices:
            raise ReleaseRefusal("hdiutil did not return a device for the setup image")
        device = devices[0]
        raw_disk = workspace / "filesystem.raw"
        try:
            _run([
                "/bin/dd", f"if=/dev/r{Path(device).name}", f"of={raw_disk}",
                "bs=1048576",
            ])
        finally:
            _run(["/usr/bin/hdiutil", "detach", device])
        output.write_bytes(ndif_macbinary(
            "New Old World Setup.img", "NOW Setup", raw_disk.read_bytes()))


def ndif_macbinary(name: str, volume_name: str, disk: bytes) -> bytes:
    if not disk or len(disk) % 512 or len(disk) > 0xFFFFFFFF:
        raise ReleaseRefusal("raw HFS disk must contain complete 512-byte sectors")
    name_bytes = volume_name.encode("mac_roman")
    if not 1 <= len(name_bytes) <= 63:
        raise ReleaseRefusal("NDIF volume name is invalid")
    sectors = len(disk) // 512
    block_map = bytearray(128)
    struct.pack_into(">H", block_map, 0, 11)
    block_map[4] = len(name_bytes)
    block_map[5:5 + len(name_bytes)] = name_bytes
    struct.pack_into(">I", block_map, 68, sectors)
    struct.pack_into(">I", block_map, 72, 0x201)
    struct.pack_into(">I", block_map, 124, 2)
    block_map.extend(struct.pack(">III", 0x02, 0, len(disk)))
    block_map.extend(struct.pack(">III", (sectors << 8) | 0xFF, 0, 0))
    resource = _single_resource(b"bcem", 128, volume_name, bytes(block_map))
    return MacBinaryFile(
        name=name, file_type=b"rohd", creator=b"ddsk", finder_flags=0,
        data_fork=disk, resource_fork=resource,
    ).encode()


def _single_resource(resource_type: bytes, resource_id: int, name: str,
                     payload: bytes) -> bytes:
    name_bytes = name.encode("mac_roman")
    data_offset = 256
    resource_data = struct.pack(">I", len(payload)) + payload
    map_offset = (data_offset + len(resource_data) + 255) // 256 * 256
    resource_map = bytearray(28)
    struct.pack_into(">H", resource_map, 24, 28)
    struct.pack_into(">H", resource_map, 26, 50)
    resource_map.extend(struct.pack(">H", 0))
    resource_map.extend(resource_type)
    resource_map.extend(struct.pack(">HH", 0, 10))
    resource_map.extend(struct.pack(">hH", resource_id, 0))
    resource_map.extend(b"\0\0\0\0\0\0\0\0")
    resource_map.append(len(name_bytes))
    resource_map.extend(name_bytes)
    header = struct.pack(">IIII", data_offset, map_offset,
                         len(resource_data), len(resource_map))
    resource_map[0:16] = header
    return (header + bytes(data_offset - len(header)) + resource_data
            + bytes(map_offset - data_offset - len(resource_data))
            + bytes(resource_map))


def _run(arguments: list[str]) -> str:
    return _run_bytes(arguments).decode("utf-8", errors="replace")


def _run_bytes(arguments: list[str]) -> bytes:
    completed = subprocess.run(arguments, capture_output=True)
    if completed.returncode:
        detail = completed.stderr.decode("utf-8", errors="replace").strip()
        raise ReleaseRefusal(detail or f"command failed: {arguments[0]}")
    return completed.stdout
