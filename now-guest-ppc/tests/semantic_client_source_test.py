from pathlib import Path
root = Path(__file__).resolve().parents[2]
client = (root / "now-guest-ppc/src/peek/semantic_client.c").read_text()
collect = (root / "now-guest-ppc/src/scene/scene_collect.c").read_text()
walk = (root / "now-guest-ppc/src/scene/scene_walk.c").read_text()
assert client.index("request_deadline_ticks") < client.index("*commit = g_generation")
assert "now_semantic_copy_response" in client
assert "now_semantic_policy_ingest" in client
assert "response_writer_epoch" not in client
assert "void now_semantic_client_end" in client
assert "offer(kPrioritySystemMenu, kNowPeekSemanticOpSystemMenu" in client

# The priorities used to be bare numbers and were exactly backwards:
# class 10 lost the single cell to list 20 forever, so 121 of 122 controls
# in the ten-panel corpus never carried a kind. Assert the ORDERING rather
# than the literals - a class fact is the prerequisite for a list request
# and must outrank it, and a terminal menu may still outrank both.
import re
_prio = {}
for _name in ("kPriorityControlClass", "kPriorityListCells",
              "kPrioritySystemMenu"):
    _m = re.search(r"\b" + _name + r"\s*=\s*(\d+)", client)
    assert _m, "priority " + _name + " is not a named constant any more"
    _prio[_name] = int(_m.group(1))
# offer() keeps the HIGHEST number, so "outranks" means "is greater".
assert _prio["kPriorityListCells"] < _prio["kPriorityControlClass"], _prio
assert _prio["kPriorityControlClass"] <= _prio["kPrioritySystemMenu"], _prio

# The batch is preferred over the per-control op, which is the whole point:
# one request types a window instead of one control per scene.
assert "now_semantic_policy_batch_plan" in client
assert "now_semantic_batch_copy_response" in client
assert "now_semantic_policy_ingest_batch" in client
assert "now_semantic_batch_pending(table, TickCount())" in client
assert client.index("offer_batch(") < client.index(
    "offer(kPriorityControlClass"), "the batch is offered before the fallback"

# The batch cell has its OWN lease, so a background process is no longer
# barred from it - that gate is what left background panels permanently
# blank. The single cell keeps its front-only gate.
assert "kBatchPriorityBackground" in client and "kBatchPriorityFront" in client
assert "!g_requestable" in client
assert "!g_batch_requestable" not in client

# An undetermined kind must not be published as a decoded Apple control.
assert 'case kNowPeekSemanticControlOtherSystem: role = "systemControl"' in client
assert 'default: role = NULL' in client
assert "Control kind undetermined" in client

assert "Unsupported custom control" in client
assert "System menu unavailable" in client
assert "now_semantic_client_begin" in collect and "now_semantic_client_aim" in collect
assert "s->procs[row].front != 0" in collect
assert "now_semantic_request_pending(table, TickCount())" in client
assert "now_semantic_client_join_control" in walk and "now_semantic_client_join_menu" in walk
assert walk.index("now_semantic_client_join_control") < walk.index("walk_dialog_items")
print("semantic client scheduling/join source guard: ok")
