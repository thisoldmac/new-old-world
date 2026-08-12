#!/usr/bin/env python3

from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import struct
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = spec_from_file_location("continuity_probe",
                              ROOT / "tools" / "continuity-probe.py")
PROBE = module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)
DIRECT_SPEC = spec_from_file_location(
    "emulator_direct_pointer",
    ROOT / "tools" / "emulator-direct-pointer.py")
DIRECT = module_from_spec(DIRECT_SPEC)
DIRECT_SPEC.loader.exec_module(DIRECT)


class ContinuityProbeCodecTests(unittest.TestCase):
    def test_state_packet_is_the_contracts_fixed_40_bytes(self):
        packet = PROBE.encode_state(
            0x01020304, 0x05060708, 0x11121314, 0x21222324,
            h=0x1234, v=-2, requested_hz=30)
        self.assertEqual(len(packet), 40)
        self.assertEqual(packet[:36].hex(),
            "4e57433100020001010203040506070811121314212223241234fffe"
            "00000000001e0000")

    def test_ack_decoder_rejects_wrong_lease_bytes(self):
        payload = struct.pack(
            ">IHHIIIIIHHIII", PROBE.ACK_MAGIC, 2, 2,
            1, 2, 3, 4, 0, 15, 0, 10, 11, 0)
        ack = PROBE.decode_ack(payload)
        self.assertEqual(ack["state"], 2)
        self.assertEqual(ack["positionSequence"], 4)
        self.assertEqual(ack["applyTicks"], 11)
        with self.assertRaisesRegex(ValueError, "magic or version"):
            PROBE.decode_ack(bytes(44))

    def test_direct_pointer_packet_carries_generation_and_down_state(self):
        payload = DIRECT.encode_state(
            1, 2, 3, 4, 320, 240, 9, True)
        fields = DIRECT.STATE.unpack(payload)
        self.assertEqual(fields[1], 2)
        self.assertEqual(fields[2], DIRECT.INSIDE | DIRECT.PRIMARY_DOWN)
        self.assertEqual(fields[9], 9)

    def test_direct_pointer_instrument_can_opt_into_fast_pump(self):
        class Link:
            def __init__(self):
                self.sent = None

            def _send(self, message):
                self.sent = message

        link = Link()
        original = DIRECT.next_control
        DIRECT.next_control = lambda *_args, **_kwargs: {"state": "armed"}
        try:
            DIRECT.arm(link, 7, (1, 2, 3), fast_pump=True)
        finally:
            DIRECT.next_control = original
        self.assertIs(link.sent["fastPump"], True)

    def test_direct_pointer_visual_oracle_checks_both_endpoints(self):
        def ppm(changed):
            pixels = bytearray(12 * 12 * 3)
            for x, y in changed:
                offset = (y * 12 + x) * 3
                pixels[offset:offset + 3] = b"\xff\xff\xff"
            return b"P6\n12 12\n255\n" + bytes(pixels)

        with tempfile.TemporaryDirectory() as directory:
            before = Path(directory) / "before.ppm"
            after = Path(directory) / "after.ppm"
            before.write_bytes(ppm([]))
            after.write_bytes(ppm([(2, 3), (9, 8)]))
            self.assertEqual(
                DIRECT.changed_near_points(
                    str(before), str(after), ((2, 3), (9, 8)), radius=1),
                [1, 1])


if __name__ == "__main__":
    unittest.main()
