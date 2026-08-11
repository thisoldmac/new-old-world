#!/usr/bin/env python3
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
source = (root / "now-guest-ppc/src/act/act_cmds.c").read_text()

plain = re.search(r"static void reply_error\(.*?\n\}", source, re.S)
registered = re.search(r"static void reply_registered_error\(.*?\n\}", source, re.S)
assert plain and registered
assert "now_act_last_settlement" not in plain.group(0), \
    "plain validation errors must never inherit a previous correlation"
assert "now_act_last_settlement" in registered.group(0)

for name in ("winact", "ctlact", "ditemact", "menuact"):
    body = re.search(rf"void now_act_run_{name}\(.*?\n\}}", source, re.S)
    assert body and "now_act_begin_command();" in body.group(0), name

text = re.search(r"static void text_exchange\(.*?\n\}", source, re.S)
assert text and "now_act_begin_command();" in text.group(0)

for phrase in ("kNowActNotArmed", '"act-not-taken"'):
    positions = [m.start() for m in re.finditer(phrase, source)]
    for pos in positions:
        line = source[source.rfind("\n", 0, pos - 120):source.find("\n", pos)]
        assert "registered" in line, f"post-registration {phrase} lost correlation"

print("act correlation source: ok")
