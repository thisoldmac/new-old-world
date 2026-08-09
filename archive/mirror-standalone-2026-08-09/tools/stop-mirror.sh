#!/usr/bin/env bash
# Stop the live mirror cleanly: kill any MirrorApp for this run, quit the VM via
# QMP (never pkill/SIGKILL — a hard kill triggers the macOS crash dialog), and
# remove the throwaway clone.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIRROR="$(cd "$HERE/.." && pwd)"          # this repo
# The TimBotTu lab checkout, whose tools/qmp is how the VM is quit. Found the
# same way spin-up.sh finds it, and for the same reason (AGENTS.md): the lab
# stopped being Mirror's parent when Mirror was vendored into NOW.
LAB="${MIRROR_LAB_ROOT:-}"
if [ -z "$LAB" ]; then
    LAB="$(cd "$MIRROR/.." && pwd)"
    while [ "$LAB" != "/" ] && [ ! -f "$LAB/tools/lib.sh" ]; do
        LAB="$(dirname "$LAB")"
    done
fi
# Stop rather than carry on without qmp. Without this the quit fails into its
# own `||` branch, reports the VM as "may already be down", and the rm below
# then unlinks the disk out from under a QEMU that is still running it.
[ -x "$LAB/tools/qmp" ] || {
    echo "stop-mirror: no lab checkout above $MIRROR — set MIRROR_LAB_ROOT to the" >&2
    echo "             TimBotTu clone carrying tools/qmp. Refusing to remove the" >&2
    echo "             session disk while the VM may still be up." >&2
    exit 1
}
RUN="$MIRROR/run"

# Kill only the MirrorApp pointed at THIS run's toolkit port (spin-up.sh recorded
# the chosen pair in run/ports) — never a bare `pkill MirrorApp`, which would hit
# another session's live mirror.
TOOLKIT="$(awk '{print $2}' "$RUN/ports" 2>/dev/null)"
if [ -n "$TOOLKIT" ]; then
    for pid in $(pgrep -f "MirrorApp .*--port $TOOLKIT" 2>/dev/null || true); do
        kill "$pid" 2>/dev/null && echo "stopped MirrorApp $pid (port $TOOLKIT)" || true
    done
fi

if [ -S "$RUN/qmp.sock" ]; then
    "$LAB/tools/qmp" "$RUN/qmp.sock" quit >/dev/null 2>&1 && echo "VM quit (QMP)" || \
        echo "QMP quit failed (VM may already be down)"
    sleep 2
fi
rm -f "$RUN/session.qcow2"
echo "cleaned $RUN/session.qcow2"
