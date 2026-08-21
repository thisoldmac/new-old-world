---
page_id: use-now-cli-how-to
title: Use the NOW command line
description: Install the official CLI and operate guests, connections, console commands, files, transfers, events, and scripts.
doc_type: how-to
audience: user
lifecycle: current
authority: [contract/now-api.openapi.json, now-cli/now_cli/main.py]
source_dependencies: [contract/now-api.openapi.json, now-cli/now, now-cli/install-now-cli, now-cli/now_cli/main.py, now-cli/now_cli/_generated.py]
media_ids: []
last_verified: 2026-08-20
---

<!-- now-doc-provenance: generated reviewed=false -->

# Use the NOW command line

## Install `now`

The release app bundles the CLI at:

```text
/Applications/New Old World.app/Contents/Resources/bin/now
```

Copy **New Old World.app** into `/Applications` before installing the command;
a symlink into the mounted DMG stops working after ejecting it. Then run:

```sh
"/Applications/New Old World.app/Contents/Resources/bin/install-now-cli"
```

This creates `~/.local/bin/now` and refuses to replace an unrelated command.
Add `~/.local/bin` to `PATH` if the installer asks. `--prefix /absolute/path`
selects another prefix; `--force` is required to replace a destination the
installer does not own.

From a repository checkout, run `now-cli/install-now-cli`. The development
entry point `now-cli/now` remains directly executable too. The CLI requires
Python 3.9 or newer and uses only the standard library.

Start the HTTP service in NOW. The CLI uses the host's private application key
automatically. `NOW_API_KEY` or `--api-key` supplies an invocation-specific
key; `NOW_API_ENDPOINT` or `--endpoint` selects another loopback endpoint.
V1 refuses non-loopback endpoints.

## Choose and inspect a guest

```sh
now guests list
now guests status pb1400c
now guests use pb1400c
```

`guests use` stores only the stable preferred guest ID. Mutations still fetch
and send the exact live session ID, so a reconnect cannot silently retarget an
operation.

## Manage connections

```sh
now connections list
now connections start
now connections disconnect <guest-session-id>
now connections stop
```

`start` starts the host listener so guests may dial in. It does not initiate an
outbound connection. `disconnect` closes one exact session; an auto-reconnecting
guest may return. `stop` stops accepting and closes all current sessions.
Disruptive commands prompt on a terminal; use `--yes` only in an intentional
non-interactive workflow.

## Run console commands

```sh
now --guest pb1400c console gestalt
now --guest pb1400c console catalog applications
now --guest pb1400c console catalog --arguments '{"domain":"applications"}'
```

The command must be advertised by that live guest. Choose either one raw
argument line or a typed JSON object. NOW uses the guest's existing console
dispatcher and watchdog; this is not a host shell.

## Work with guest files

```sh
now --guest pb1400c files list 'Macintosh HD:Lab:'
now --guest pb1400c files stat 'Macintosh HD:Lab:Report'
now --guest pb1400c files mkdir 'Macintosh HD:Lab:Exports:'
now --guest pb1400c files move 'Macintosh HD:Lab:Old' 'Macintosh HD:Lab:New'
now --guest pb1400c files trash 'Macintosh HD:Lab:Old'
now --guest pb1400c files restore 'Old' 'Macintosh HD:Lab:Old'
now --guest pb1400c files put ./DiskCopy.img 'Macintosh HD:Lab:DiskCopy.img'
now --guest pb1400c files get 'Macintosh HD:Lab:Report' ./Report.bin
```

`files get` refuses to overwrite a local destination unless `--force` is
present. Downloads use a mode-0600 same-directory temporary file and replace
the destination only after completion. Uploads are hashed first and sent in
bounded chunks. Ctrl-C attempts to cancel the transfer and removes an
unfinished local download.

Use `--container macbinary` when the source is a MacBinary container whose
forks and Finder metadata must be restored. A single transfer is limited to
32 MiB.

## Inspect and cancel transfers

```sh
now transfers list
now transfers status <transfer-id>
now transfers cancel <transfer-id>
now events watch
```

There is no separate `transfers watch` command in v1. Use `events watch` for
live change hints, then refetch `transfers status`; events are not complete
transfer state and are not replayed after reconnect.

## Script safely

Add `--json` for the API response shape:

```sh
now --json guests list
now --json --guest pb1400c console gestalt
now --json api operations
now --json api call guests.facts --session <guest-session-id> \
  --json-arguments '{}'
```

Generic mutating operations require `--session` with an exact guest session.
The CLI refuses an unsupported API major before mutation. Exit status `0`
means completed; `2` invalid invocation or refusal, `3` unavailable, `4`
transport/authentication failure, `5` incompatible API response, and `6`
failed operation. An interrupted event or transfer watch exits `130`.

Bash completion lives at
`New Old World.app/Contents/Resources/completions/now.bash`; Zsh completion is
the sibling `_now` file. Repository copies live under `now-cli/completion/`.
