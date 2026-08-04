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
assert "offer(30, kNowPeekSemanticOpSystemMenu" in client
assert "Unsupported custom control" in client
assert "System menu unavailable" in client
assert "now_semantic_client_begin" in collect and "now_semantic_client_aim" in collect
assert "source.kind == kNowAxDialogResourceControl" in walk
assert "now_semantic_client_join_control" in walk and "now_semantic_client_join_menu" in walk
print("semantic client scheduling/join source guard: ok")
