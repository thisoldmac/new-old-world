"""Minimal, dependency-free Classic Mac OS resource-fork reader.

The resource fork layout is documented in *Inside Macintosh: More Macintosh
Toolbox*, "Resource Manager". All integers are big-endian. This reads a fork
that has been saved to a plain file (e.g. the `rsrc_fork` bytes a Harness
`pull_file(fork="rsrc")` returns), which is exactly the on-disk fork image.

Only reading is implemented; we never write resources back.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass


@dataclass(frozen=True)
class Resource:
    type: str          # four-char type, e.g. "NFNT"
    id: int            # signed 16-bit resource id
    name: str | None   # resource name, or None
    attrs: int         # resource attribute byte
    data: bytes        # the resource body


class ResourceFork:
    """Parsed resource fork; index by type then id."""

    def __init__(self, raw: bytes):
        self.raw = raw
        self._by_type: dict[str, dict[int, Resource]] = {}
        self._parse()

    def _parse(self) -> None:
        raw = self.raw
        if len(raw) < 16:
            raise ValueError("resource fork too short for header")
        data_off, map_off, data_len, map_len = struct.unpack_from(">IIII", raw, 0)
        if map_off + map_len > len(raw) or data_off + data_len > len(raw):
            raise ValueError("resource header offsets exceed file size")

        # Resource map: skip 16-byte header copy, 4-byte next-map, 2 file ref,
        # 2 attrs -> then the two list offsets (relative to map start).
        type_list_off = struct.unpack_from(">H", raw, map_off + 24)[0]
        name_list_off = struct.unpack_from(">H", raw, map_off + 26)[0]
        type_list_base = map_off + type_list_off
        name_list_base = map_off + name_list_off

        num_types = struct.unpack_from(">h", raw, type_list_base)[0] + 1
        for i in range(num_types):
            entry = type_list_base + 2 + i * 8
            rtype = raw[entry:entry + 4].decode("mac_roman")
            count = struct.unpack_from(">h", raw, entry + 4)[0] + 1
            ref_off = struct.unpack_from(">H", raw, entry + 6)[0]
            ref_base = type_list_base + ref_off
            bucket: dict[int, Resource] = {}
            for j in range(count):
                ref = ref_base + j * 12
                rid = struct.unpack_from(">h", raw, ref)[0]
                name_off = struct.unpack_from(">h", raw, ref + 2)[0]
                attr_and_off = struct.unpack_from(">I", raw, ref + 4)[0]
                attrs = (attr_and_off >> 24) & 0xFF
                body_off = attr_and_off & 0xFFFFFF
                # resource name
                name = None
                if name_off != -1:
                    npos = name_list_base + name_off
                    nlen = raw[npos]
                    name = raw[npos + 1:npos + 1 + nlen].decode("mac_roman")
                # resource data: 4-byte length prefix at data_off + body_off
                dpos = data_off + body_off
                dlen = struct.unpack_from(">I", raw, dpos)[0]
                body = raw[dpos + 4:dpos + 4 + dlen]
                bucket[rid] = Resource(rtype, rid, name, attrs, body)
            self._by_type[rtype] = bucket

    # -- access ------------------------------------------------------------
    def types(self) -> list[str]:
        return list(self._by_type.keys())

    def census(self) -> dict[str, int]:
        return {t: len(b) for t, b in self._by_type.items()}

    def ids(self, rtype: str) -> list[int]:
        return sorted(self._by_type.get(rtype, {}).keys())

    def get(self, rtype: str, rid: int) -> Resource | None:
        return self._by_type.get(rtype, {}).get(rid)

    def of_type(self, rtype: str) -> list[Resource]:
        return [self._by_type[rtype][i] for i in self.ids(rtype)]


def load(path: str) -> ResourceFork:
    with open(path, "rb") as fh:
        return ResourceFork(fh.read())


if __name__ == "__main__":
    import sys
    fork = load(sys.argv[1])
    for t, n in sorted(fork.census().items(), key=lambda kv: -kv[1]):
        print(f"{n:4d}  {t!r}")
