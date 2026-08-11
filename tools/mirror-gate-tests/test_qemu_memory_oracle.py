#!/usr/bin/env python3
"""The QEMU microscope decodes guest state without entering production."""

from pathlib import Path
import struct
import unittest


ROOT = Path(__file__).resolve().parents[2]


class Memory:
    def __init__(self):
        self.data = bytearray(0x10000)

    def write(self, address, value):
        self.data[address:address + len(value)] = value

    def read(self, address, length):
        return bytes(self.data[address:address + length])


def put16(memory, address, value):
    memory.write(address, struct.pack(">H", value & 0xFFFF))


def put32(memory, address, value):
    memory.write(address, struct.pack(">I", value))


class QemuMemoryOracleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import sys
        sys.path.insert(0, str(ROOT / "tools"))
        from qemu_oracle import classic, cli
        cls.classic = classic
        cls.cli = cli

    def fixture(self):
        memory = Memory()
        memory.write(0x910, b"\x0bDate & Time")
        put32(memory, 0x904, 0x7100)
        put32(memory, 0x908, 0x7200)
        put32(memory, 0x9D6, 0x2000)

        put16(memory, 0x2000 + 108, 2)
        memory.write(0x2000 + 110, b"\x01")
        put32(memory, 0x2000 + 134, 0x3000)
        put32(memory, 0x2000 + 140, 0x4000)
        put32(memory, 0x2000 + 156, 0x3400)
        put16(memory, 0x2000 + 164, 0xFFFF)
        put16(memory, 0x2000 + 168, 1)

        put32(memory, 0x3000, 0x3100)
        memory.write(0x3100, b"\x0dSet Time Zone")

        put32(memory, 0x3400, 0x3500)
        put16(memory, 0x3500, 0)
        put32(memory, 0x3502, 0x4000)
        for offset, value in zip((0x3506, 0x3508, 0x350A, 0x350C),
                                 (10, 20, 30, 80)):
            put16(memory, offset, value)
        memory.write(0x350E, b"\x04\x02OK")

        put32(memory, 0x4000, 0x4100)
        put32(memory, 0x4100 + 4, 0x2000)
        for offset, value in zip((0x4108, 0x410A, 0x410C, 0x410E),
                                 (10, 20, 30, 80)):
            put16(memory, offset, value)
        memory.write(0x4100 + 16, b"\xff\x00")
        put32(memory, 0x4100 + 24, 0x2DFC)
        put32(memory, 0x4100 + 28, 0x4200)
        memory.write(0x4100 + 40, b"\x02OK")
        put32(memory, 0x4200, 0x4300)
        memory.write(0x4300, b"portable structure provenance")
        return memory

    def test_decodes_dialog_ditl_control_and_private_data_provenance(self):
        state = self.classic.build_snapshot(self.fixture(), "Date & Time")
        self.assertEqual(state["currentA5"], "0x00007100")
        self.assertEqual(state["windows"][0]["title"], "Set Time Zone")
        item = state["windows"][0]["dialog"]["items"][0]
        self.assertEqual((item["kind"], item["text"]), ("pushButton", "OK"))
        control = state["windows"][0]["controls"][0]
        self.assertEqual(control["definition"], "0x00002dfc")
        self.assertEqual(control["dataPointer"], "0x00004300")

    def test_diff_names_the_exact_changed_field(self):
        changes = self.cli.diff_values(
            {"windows": [{"title": "Finder", "front": True}]},
            {"windows": [{"title": "Date & Time", "front": True}]})
        self.assertEqual(changes, [{
            "path": "windows[0].title",
            "before": "Finder",
            "after": "Date & Time",
        }])

    def test_oracle_is_not_a_production_dependency(self):
        host_sources = "\n".join(
            path.read_text(errors="ignore")
            for path in (ROOT / "now-host" / "Sources").rglob("*.swift"))
        guest_sources = "\n".join(
            path.read_text(errors="ignore")
            for tree in ("now-guest-ppc", "ext")
            for path in (ROOT / tree).rglob("*.[ch]"))
        self.assertNotIn("qemu-oracle", host_sources)
        self.assertNotIn("qemu_oracle", host_sources)
        self.assertNotIn("qemu-oracle", guest_sources)
        self.assertNotIn("qemu_oracle", guest_sources)

    def test_qmp_lane_is_read_pause_only(self):
        source = (ROOT / "tools" / "qemu_oracle" / "qmp.py").read_text()
        for forbidden in ("send-key", "input-send-event", "system_reset",
                          "system_powerdown", 'execute("quit")'):
            self.assertNotIn(forbidden, source)
        self.assertIn("memsave", source)
        self.assertIn('execute("stop")', source)
        self.assertIn('execute("cont")', source)


if __name__ == "__main__":
    unittest.main()
