#!/usr/bin/env bash
# Spin up the mirror end-to-end against a fresh, isolated mac99 clone: boot,
# stage the extension + agent, cold reboot to load the INIT, launch the agent,
# and prove the wire answers.
#
#   tools/spin-up.sh                    # headless, boot + stage + reboot + verify
#   MIRROR_DISPLAY=1 tools/spin-up.sh   # cocoa display + open the MirrorApp window
#
# Two roots are in play and they are not the same (AGENTS.md): MIRROR is this
# repo, which owns the artifacts; LAB is the parent TimBotTu checkout, whose
# emulator, QMP tool, and anchor-harness client are INSTRUMENTS we borrow to
# drive a deploy and never ship.
#
# The clone is a throwaway (cp -c, removed by stop-mirror.sh) and the shared base
# image stays pristine. If another VM is already running it belongs to another
# session — this script picks its own free ports rather than attaching to it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIRROR="$(cd "$HERE/.." && pwd)"
LAB="$(cd "$MIRROR/.." && pwd)"
cd "$LAB"                                 # lib.sh, tools/qmp, and mcp are lab-relative
. tools/lib.sh

QEMU="${TIMBOTTU_QEMU:-$LAB/qemu/build/qemu-system-ppc}"
BASE="${MIRROR_BASE:-$HOME/Lab/Assets/os91-qemu/os91-runner.qcow2}"
RUN="$MIRROR/run"
DISK="$RUN/session.qcow2"
QMP="$RUN/qmp.sock"
APP="$MIRROR/host/MirrorKit/.build/release/MirrorApp"
EXT="$MIRROR/guest/extensions/axpeek/build/AXPeek.bin"
QDEXT="$MIRROR/guest/extensions/qdpeek/build/QDPeek.bin"
PTEXT="$MIRROR/guest/extensions/portal/build/Portal.bin"
AGENT="$MIRROR/guest/app/build/mirror-agent.bin"

[ -x "$QEMU" ] || { echo "no qemu-system-ppc at $QEMU (set TIMBOTTU_QEMU)"; exit 1; }
[ -f "$BASE" ] || { echo "no base image at $BASE (set MIRROR_BASE)"; exit 1; }


export TBT_MACHINE_PROFILE=mac99
tbt_select_machine_profile mac99
mkdir -p "$RUN"

# --- pick a FREE (anchor, agent) host-port pair --------------------------------
# Advance in steps of 2 rather than attach to whatever already holds the port —
# the collision that once had a run reading, and nearly writing to, a
# neighbouring session's guest.
port_free () { ! lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }
ANCHOR="${MIRROR_ANCHOR:-1700}"
AGENT_PORT="${MIRROR_AGENT_PORT:-1720}"
if [ -z "${MIRROR_ANCHOR:-}${MIRROR_AGENT_PORT:-}" ]; then
    tries=0
    while ! { port_free "$ANCHOR" && port_free "$AGENT_PORT"; }; do
        ANCHOR=$((ANCHOR + 2)); AGENT_PORT=$((AGENT_PORT + 2)); tries=$((tries + 1))
        [ "$tries" -gt 20 ] && { echo "no free anchor/agent port pair"; exit 1; }
    done
elif ! { port_free "$ANCHOR" && port_free "$AGENT_PORT"; }; then
    echo "requested ports $ANCHOR/$AGENT_PORT are in use (another session?)"; exit 1
fi
# Guest 1400 = the base image's baked anchor worker (our deploy channel).
# Guest 1420 = the mirror agent's default listen port.
HOSTFWD="hostfwd=tcp:127.0.0.1:${ANCHOR}-:1400,hostfwd=tcp:127.0.0.1:${AGENT_PORT}-:1420"
printf '%s %s\n' "$ANCHOR" "$AGENT_PORT" > "$RUN/ports"   # stop-mirror.sh reads this
export MIRROR_ANCHOR_PORT="$ANCHOR"
echo "ports: anchor=$ANCHOR agent=$AGENT_PORT"

DISPLAY_KIND=none
[ "${MIRROR_DISPLAY:-0}" = "1" ] && DISPLAY_KIND=cocoa

boot () {  # $1 = "fresh" | "cold"
    [ "$1" = fresh ] && tbt_clone_disk "$BASE" "$DISK"
    TIMBOTTU_QEMU="$QEMU" tbt_qemu_boot "TBT Mirror" "$DISPLAY_KIND" "$DISK" \
        "$HOSTFWD" "" "$QMP" "$RUN/qemu.pid" "$RUN/qemu.log"
}

# Poll the anchor with a real hello, dismissing the boot-time Disk First Aid
# modal with Return — a fresh clone always shows it after a hard power-off.
wait_anchor () {
    python3 - "$QMP" "$ANCHOR" "$LAB" <<'PY'
import sys, time, subprocess
qmp, anchor, lab = sys.argv[1], int(sys.argv[2]), sys.argv[3]
sys.path.insert(0, f"{lab}/mcp-classic")
from timbottu_mcp_classic.harness import Harness
t0 = time.time()
while time.time() - t0 < 280:
    try:
        if Harness(host="127.0.0.1", port=anchor,
                   expect_backing={"worker"}).request("hello", {}).get("policyDigest"):
            print(f"anchor ready ({int(time.time()-t0)}s)"); sys.exit(0)
    except Exception:
        pass
    subprocess.run([f"{lab}/tools/qmp", qmp, "send-key",
                    '{"keys":[{"type":"qcode","data":"ret"}]}'], capture_output=True)
    time.sleep(6)
sys.exit("anchor timeout")
PY
}

echo "== boot (fresh clone) =="; boot fresh; wait_anchor
echo "== stage AXPeek + QDPeek + mirror agent =="
MIRROR_EXT="$EXT" MIRROR_QDEXT="$QDEXT" MIRROR_PTEXT="$PTEXT" MIRROR_AGENT="$AGENT" python3 "$HERE/stage-agent.py"

# Staging writes go through the baked anchor worker; give OS 9's periodic volume
# flush time to reach the qcow2 before the QMP power-off. The post-reboot check
# below is the real guardrail — if the writes did not land, it fails loudly.
echo "== let OS 9 flush staged writes (${MIRROR_FLUSH_WAIT:-20}s) =="
sleep "${MIRROR_FLUSH_WAIT:-20}"

# INITs load at boot ONLY, and OS 9 ignores QMP system_powerdown — so the reboot
# is a hard quit and a relaunch without -loadvm.
echo "== cold reboot (load the INIT) =="
"$LAB/tools/qmp" "$QMP" quit >/dev/null 2>&1 || true; sleep 2; boot cold; wait_anchor

echo "== verify the INIT survived, launch the agent, prove the wire =="
python3 - "$ANCHOR" "$AGENT_PORT" "$LAB" <<'PY'
import sys, time, json
anchor, agent_port, lab = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
sys.path.insert(0, f"{lab}/mcp-classic")
from timbottu_mcp_classic.harness import Harness

A = Harness(host="127.0.0.1", port=anchor, expect_backing={"worker"})
for name in ("AXPeek", "QDPeek", "Portal"):
    st = A.request("stat", {"path": f"Macintosh HD:System Folder:Extensions:{name}"})
    if not st.get("exists"):
        sys.exit(f"{name} did NOT survive the cold reboot — staged write never flushed")
    print(f"  {name} survived: type={st.get('type')}")

A.request("launch", {"path": "Macintosh HD:TimBotTu:mirror-dev:mirror-agent"})

# The agent is ours, so it does not answer the lab's backing contract — talk to
# it as a plain line-JSON socket rather than through the harness client.
#
# RETRY, always. The guest serves ONE connection serially; a fresh socket per
# request races its accept and the transport refuses the indication, which
# arrives here as a bare connection reset. Its contract is that the client
# reconnects. This verifier lacked the retry long after tests/trials.py gained
# it, and it duly failed the whole spin-up at the very last step with the guest
# perfectly healthy (2026-07-30).
import socket
def call(verb, args=None, timeout=20, tries=5):
    req = {"proto": 1, "id": 1, "verb": verb}
    if args:
        req.update(args)
    last = None
    for _ in range(tries):
        try:
            s = socket.create_connection(("127.0.0.1", agent_port), timeout=timeout)
            try:
                s.sendall((json.dumps(req) + "\n").encode())
                buf = b""
                while not buf.endswith(b"\n"):
                    chunk = s.recv(65536)
                    if not chunk:
                        break
                    buf += chunk
            finally:
                s.close()
            if not buf:
                raise RuntimeError("closed without data")
            # Guest JSON carries raw MacRoman bytes: repair-decode.
            return json.loads(buf.decode("utf-8", "replace"))
        except Exception as e:
            last = e
            time.sleep(1.5)
    raise last

for attempt in range(20):
    try:
        hello = call("hello")["result"]
        break
    except Exception:
        time.sleep(3)
else:
    sys.exit(f"the agent never answered on {agent_port}")

print(f"  agent up: v{hello['version']} build={hello['build']}")
print(f"  oracle={hello['oracle']} status={hello['oracleStatus']} "
      f"v{hello['oracleVersion']}")
if not hello["oracle"]:
    sys.exit(f"the agent is live but the oracle is {hello['oracleStatus']} — "
             f"the scene would be empty; fix this before rendering")

obs = call("observe")["result"]
procs = obs.get("processes", [])
# observe flags the front process per-row; there is no top-level front object.
front = next((p.get("name") for p in procs if p.get("front")), None)
print(f"  observe: {len(procs)} processes, front={front!r}")
tree = call("axtree", {"scope": "front"})["result"]
print(f"  axtree(front): {json.dumps(tree)[:220]}")
PY

echo
echo "READY.  anchor=host:$ANCHOR  agent=host:$AGENT_PORT  qmp=$QMP"
echo "  live window:"
echo "    $APP --host 127.0.0.1 --port $AGENT_PORT --machine mac99 --scope all \\"
echo "      --qmp $QMP --window --display --islands --interval 0.7 &"
echo "  ONE MirrorApp owns the agent port — never open a 2nd client to it."
echo "  stop:  $HERE/stop-mirror.sh"

if [ "${MIRROR_DISPLAY:-0}" = "1" ]; then
    [ -x "$APP" ] || { echo "MirrorApp not built (swift build -c release)"; exit 0; }
        # --scope all, not front: `front` walks only the FRONT APPLICATION, so every
    # other app's windows are absent from the scene entirely and the mirror shows
    # a desktop that is missing windows the guest is plainly displaying. That
    # looked like a rendering regression once and was this flag.
    # --islands fills window interiors with real pixels.
    "$APP" --host 127.0.0.1 --port "$AGENT_PORT" --machine mac99 --scope all \
           --qmp "$QMP" --window --display --islands --interval 0.7 &
    echo "MirrorApp (headed, +display) PID $!"
fi
