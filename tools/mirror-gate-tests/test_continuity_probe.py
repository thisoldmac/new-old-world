#!/usr/bin/env python3

from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
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
    def test_state_packet_uses_the_contracts_fixed_layout(self):
        packet = PROBE.encode_state(
            0x01020304, 0x05060708, 0x11121314, 0x21222324,
            h=0x1234, v=-2, requested_hz=30)
        self.assertEqual(len(packet), PROBE.CONTINUITY.state_bytes)
        fields = PROBE.CONTINUITY.state_struct.unpack(packet)
        self.assertEqual(fields[0], PROBE.CONTINUITY.state_magic)
        self.assertEqual(fields[1], PROBE.CONTINUITY.version)
        self.assertEqual(fields[2], PROBE.CONTINUITY.flag_inside)
        self.assertEqual(fields[3:7], (
            0x01020304, 0x05060708, 0x11121314, 0x21222324))
        self.assertEqual(fields[7:12], (0x1234, -2, 0, 30, 0))

    def test_ack_decoder_rejects_wrong_lease_bytes(self):
        payload = PROBE.CONTINUITY.ack_struct.pack(
            PROBE.CONTINUITY.ack_magic, PROBE.CONTINUITY.version,
            PROBE.CONTINUITY.ack_active,
            1, 2, 3, 4, 0, 15, 0, 10, 11, 0)
        ack = PROBE.decode_ack(payload)
        self.assertEqual(ack["state"], PROBE.CONTINUITY.ack_active)
        self.assertEqual(ack["positionSequence"], 4)
        self.assertEqual(ack["applyTicks"], 11)
        with self.assertRaisesRegex(ValueError, "ack header"):
            PROBE.decode_ack(bytes(PROBE.CONTINUITY.ack_bytes))

    def test_direct_pointer_packet_carries_generation_and_down_state(self):
        payload = DIRECT.encode_state(
            1, 2, 3, 4, 320, 240, 9, True)
        fields = DIRECT.CONTINUITY.state_struct.unpack(payload)
        self.assertEqual(fields[1], PROBE.CONTINUITY.version)
        self.assertEqual(fields[2], DIRECT.CONTINUITY.flag_inside
                         | DIRECT.CONTINUITY.flag_primary_down)
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
