#!/usr/bin/env python3
"""Self menu acts must re-enter the application's main event loop."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MAIN = (ROOT / "src" / "main.c").read_text()
ACT = (ROOT / "src" / "act" / "act_cmds.c").read_text()


def main() -> None:
    if "now_act_set_self_menu_handler(queue_menu_choice)" not in MAIN:
        raise SystemExit("self menu acts must enqueue, not run Toolbox UI "
                         "inside the wire callback")
    service = MAIN.index("conn_service();")
    dispatch = MAIN.index("dispatch_pending_menu_choice();", service)
    idle = MAIN.index("workshop_idle();", service)
    if not service < dispatch < idle:
        raise SystemExit("the queued menu choice must run immediately after "
                         "the wire callback returns to the main loop")
    branch_start = ACT.index("if (act_target_is_self(want)")
    branch = ACT[branch_start:ACT.index("st = now_act_ready();", branch_start)]
    if 'row_add(&rows, "Dispatch", "dispatched")' not in branch:
        raise SystemExit("a queued self menu act must report dispatched")
    if 'row_add(&rows, "Dispatch", "performed")' in branch:
        raise SystemExit("the wire callback cannot claim a queued UI effect "
                         "was already performed")

    print("PASS: self menu acts return to the main event loop")


if __name__ == "__main__":
    main()
