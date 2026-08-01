#!/usr/bin/env bash
# Stop the live mirror cleanly: kill any MirrorApp for this run, quit the VM via
# QMP (never pkill/SIGKILL — a hard kill triggers the macOS crash dialog), and
# remove the throwaway clone.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIRROR="$(cd "$HERE/.." && pwd)"          # this repo
LAB="${MIRROR_LAB_ROOT:-}"
if [ -z "$LAB" ]; then
    LAB="$(cd "$MIRROR/.." && pwd)"
    while [ "$LAB" != "/" ] && [ ! -f "$LAB/tools/lib.sh" ]; do
        LAB="$(dirname "$LAB")"
    done
fi           # the TimBotTu lab checkout (tools/qmp)
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
