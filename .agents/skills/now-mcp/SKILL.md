---
name: now-mcp
description: Route tasks that inspect or operate a connected classic Macintosh through the NOW MCP. Use when the user asks about a running Mac OS 7–9 machine, its hardware, software, processes, files, screen, or UI, or asks to act on that machine. Do not use for source-code changes, general classic-Mac history, or emulator setup unless the task also requires interacting with a NOW-connected guest.
---

# NOW MCP

Use NOW as the control plane for the connected classic Macintosh. Keep the
task prompt intact; this skill supplies routing, not task-specific answers or
tool schemas.

## Establish first contact

1. Call `now_list_machines` before any other NOW tool.
2. Select the intended machine deliberately. Prefer its host-owned `name` when
   speaking to the user. Pass its stable machine id when the task should follow
   reconnections, or its exact session id when the task must stay pinned to one
   connection.
3. Treat `reportedName` only as guest-reported evidence. Do not substitute it
   for the host-owned human machine name.
4. A `guest` argument addresses the machine the NOW host is already driving;
   it does not switch the driven machine. If the requested connected machine
   is not driven, report that a person must select it in NOW.
5. If NOW tools are unavailable, say that plainly. Do not silently detour into
   another classic-Mac runtime or emulator harness.

Call `now_session_capabilities` when availability is uncertain and before a
cross-domain or mutating workflow. Trust its live result over assumptions about
the guest type or build.

## Use the evidence ladder

Choose the highest semantic source that answers the question:

1. Structured product state: `now_machine_facts` or `now_hardware_census`,
   `now_list_processes`, `now_software_inventory`, and the
   `now_guest_files_*` read tools.
2. Retained desktop/application state: start or inspect the semantic UI plane,
   then use `now_semantic_ui_snapshot`, `now_semantic_ui_find`, or
   `now_semantic_ui_wait`.
3. Targeted direct observation: `now_observe_elements`, only when retained
   state is incomplete or an action requires a fresh opaque reference.
4. Pixels: `now_capture_screen`, only when the requested fact is visual or the
   semantic sources cannot answer it.

Do not inspect pixels to rediscover facts that a typed or semantic source
already exposes.

## Route actions narrowly

- Software: `now_launch_software` or `now_reveal_item`.
- Processes: obtain a fresh process reference with `now_list_processes`, then
  use `now_bring_to_front` or `now_request_quit`.
- Retained semantic UI: act on a published entity with
  `now_semantic_ui_act`.
- Direct UI: obtain fresh references with `now_observe_elements`, then use
  `now_window_act`, `now_control_act`, `now_menu_act`, `now_text_get`, or
  `now_text_set`. Never invent or reuse a stale reference.
- Guest files: use `now_guest_files_mutate` for one bounded move, trash,
  restore, or mkdir operation.

Artifact delivery has two different authority lanes:

- `now_transfer_approved_artifact` redeems a one-time receipt created when a
  person selects a host file in NOW. Never invent or claim to mint a receipt.
- `now_guest_files_upload_begin`, `now_guest_files_upload_append`, and
  `now_guest_files_upload_commit` transfer caller-owned bytes under the
  full-access policy. They do not use a picker receipt.

Honor every confirmation, consent ceiling, typed refusal, size bound, and
create-only rule exposed by the live tools. Do not weaken or work around one.

## Verify effects

After every mutation, re-read the authoritative domain. For asynchronous UI
state, wait for the expected semantic condition or take a fresh snapshot.
Distinguish accepted from confirmed; do not report success from dispatch alone.

Use the live tool description and schema for arguments and result meaning.
This skill intentionally does not duplicate them.
