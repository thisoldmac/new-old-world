#!/usr/bin/env python3

from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import struct
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = spec_from_file_location("continuity_probe",
                              ROOT / "tools" / "continuity-probe.py")
PROBE = module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class ContinuityProbeCodecTests(unittest.TestCase):
    def test_state_packet_is_the_contracts_fixed_40_bytes(self):
        packet = PROBE.encode_state(
            0x01020304, 0x05060708, 0x11121314, 0x21222324,
            h=0x1234, v=-2, requested_hz=30)
        self.assertEqual(len(packet), 40)
        self.assertEqual(packet[:36].hex(),
            "4e57433100010001010203040506070811121314212223241234fffe"
            "00000000001e0000")

    def test_ack_decoder_rejects_wrong_lease_bytes(self):
        payload = struct.pack(
            ">IHHIIIIIHHIII", PROBE.ACK_MAGIC, 1, 2,
            1, 2, 3, 4, 0, 15, 0, 10, 11, 0)
        ack = PROBE.decode_ack(payload)
        self.assertEqual(ack["state"], 2)
        self.assertEqual(ack["positionSequence"], 4)
        self.assertEqual(ack["applyTicks"], 11)
        with self.assertRaisesRegex(ValueError, "magic or version"):
            PROBE.decode_ack(bytes(44))


if __name__ == "__main__":
    unittest.main()
