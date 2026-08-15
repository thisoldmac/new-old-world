#!/usr/bin/env python3
"""Pin relay ownership and teardown around the Open Transport proxy."""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
PROXY = (ROOT / "now-guest-ppc/src/web/web_proxy_ot.c").read_text()
WIRE = (ROOT / "now-guest-ppc/src/core/wire.c").read_text()
MODULE = (ROOT / "now-guest-ppc/src/web/web_module.c").read_text()

close = re.search(r"static void close_endpoint.*?\n\}", PROXY, re.DOTALL)
if close is None or close.group(0).find("removeNotifier") > close.group(0).find("closeProvider"):
    raise SystemExit("proxy endpoint closes before removing its OT notifier")

finish = re.search(r"static void finish_client.*?\n\}", PROXY, re.DOTALL)
if finish is None or "now_wire_web_cancel(g_web.request_id)" not in finish.group(0):
    raise SystemExit("browser disconnect does not cancel its active host request")
if finish.group(0).find("now_wire_web_cancel") > finish.group(0).find("clear_exchange"):
    raise SystemExit("browser request id is cleared before host cancellation")
stop = re.search(r"void now_web_proxy_stop.*?\n\}", PROXY, re.DOTALL)
if stop is None or "now_wire_web_cancel(g_web.request_id)" not in stop.group(0):
    raise SystemExit("stopping the proxy does not cancel its active host request")

request = re.search(r"int now_wire_web_request.*?\n\}", WIRE, re.DOTALL)
if request is None:
    raise SystemExit("could not isolate now_wire_web_request")
for guest_owned in ("web_profile", "web_lens", '"handlers"'):
    if guest_owned in request.group(0):
        raise SystemExit(f"guest still overrides host rendering choice: {guest_owned}")
if "g_profile" in MODULE or "g_lens" in MODULE:
    raise SystemExit("guest Web page still presents host-owned rendering controls")
