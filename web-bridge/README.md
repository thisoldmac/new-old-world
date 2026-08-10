# NOW Web Bridge

NOW Web Bridge translates a modern web page into bounded HTML for a browser on
a classic Macintosh. TLS, contemporary JavaScript and optional local-model
work stay on the macOS host. The classic browser receives plain HTTP/1.0 with
an explicit `Content-Length` and ASCII HTML appropriate to its selected
profile.

This directory is NOW-owned code graduated from the TimBotTu Web experiments.
See [PROVENANCE.md](PROVENANCE.md) for the exact source revisions and the
corpus/model distribution boundary.

## Development run

The deterministic static engine has no third-party Python dependency:

```sh
cp web-bridge/config.example.json /tmp/now-web.json
PYTHONPATH=web-bridge python3 -m nowweb --config /tmp/now-web.json
```

The default binds host loopback only. A classic Mac cannot reach that listener.
To browse from another machine, edit the copied config to bind one explicit LAN
address and add that classic Mac's address to `allowed_clients`. An empty
allowlist admits the whole selected interface and is inappropriate on an
untrusted network.

Configure the classic browser to use the displayed host address and port as an
HTTP proxy, or open:

```text
http://HOST:5180/go?u=https%3A%2F%2Fexample.com&profile=classilla
```

Supported profiles are `classilla`, `macweb`, and `generic68k`. Supported
lenses are `compatible`, `reader`, and `ai`. AI is optional: without an
explicit `ai_plan_command`, the request visibly falls back to Compatible Page.

The host module also accepts a local model directory. For the preserved
`layout-lfm-v1` artifact, choose that directory and install `mlx-lm` in the
same Python environment that runs the helper. NOW then invokes
`nowweb.model_planner`: the model produces only block IDs, the adapter removes
unknown and repeated IDs, and it appends every omitted original block before
the normal renderer runs. This first adapter cold-loads the model for each AI
request; a persistent oMLX service remains the natural performance follow-up.

The static engine parses source HTML. Set `engine` to `playwright` only after
installing Playwright and Chromium in an environment owned by the helper. The
bridge will not install or download either during a request.

## Security boundary

The browser-facing listener has no bearer authentication because the target
browsers cannot supply it consistently. Its boundary is therefore the selected
bind address plus `allowed_clients`.

Outbound loopback, private, link-local and special-use addresses are blocked by
default. `allow_private_destinations` is an unsafe development switch; enabling
it allows the proxy to reach services on the host's private network.

Ordinary logs record peer and response status only. They do not record request
paths, URL query strings, fragments, cookies, authorization or page bodies.

Known-site handlers currently include Wikipedia's parse API and Reddit's
bounded, five-minute-cached public Atom listings. Any handler exception falls
back to the generic engine, and each adapted page provides a Generic View.

## Gate

```sh
scripts/test-web-bridge
```

The gate is also an explicit stage of `scripts/test-all` so the imported
subsystem cannot silently sit outside the repository's release gate.
