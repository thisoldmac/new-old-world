#!/usr/bin/env python3
"""Pin the handler-reply evidence behind ckproject.open-receipt/1."""

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
RUNTIME = (ROOT / "now-guest-ppc/src/development/development_runtime.c").read_text()
PUMP = (ROOT / "now-guest-ppc/src/core/pump.c").read_text()
CONTRACT = (ROOT / "contract/asyncapi.yaml").read_text()
FIXTURE = json.loads(
    (ROOT / "contract/project/fixtures/open-receipt.json").read_text()
)

start = RUNTIME.index("void now_development_open_command")
end = RUNTIME.index("void now_development_runtime_cancel", start)
open_command = RUNTIME[start:end]

assert "kAEWaitReply | kAENeverInteract" in open_command
assert "kAENoReply" not in open_command
assert "now_pump_ae_idle()" in open_command
assert "AEGetParamPtr(&reply, keyErrorNumber" in open_command
assert "dev_open_classify(err, errAETimeout" in open_command
assert '"codekitten-outcome-unknown"' in open_command

assert "NewAEIdleUPP(pump_ae_idle)" in PUMP
pump_start = PUMP.index("static pascal Boolean pump_ae_idle")
pump_end = PUMP.index("ModalFilterUPP now_pump_modal_filter", pump_start)
assert "now_wire_pump();" in PUMP[pump_start:pump_end]
assert "return false;" in PUMP[pump_start:pump_end]

contract_words = " ".join(CONTRACT.split())
assert "ckproject.open-receipt/1" in CONTRACT
assert "handler returned noErr" in contract_words
assert FIXTURE == {
    "schema": "ckproject.open-receipt/1",
    "projectID": "0123456789abcdef0123456789abcdef",
    "applicationCreator": "O9ID",
    "event": "odoc",
    "document": "Project.ckp",
    "state": "accepted",
    "acceptance": "appleevent-handler-reply",
}
for literal in (FIXTURE["schema"], FIXTURE["applicationCreator"],
                FIXTURE["document"], FIXTURE["state"],
                FIXTURE["acceptance"]):
    assert literal in open_command
