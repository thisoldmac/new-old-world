<!-- now-doc-provenance: generated reviewed=false -->

# NOW Web Bridge

NOW Web Bridge translates a modern web page into bounded HTML for a browser on
a classic Macintosh. TLS, contemporary JavaScript and optional local-model
work stay on the macOS host. The classic browser receives plain HTTP/1.0 with
an explicit `Content-Length` and ASCII HTML appropriate to its selected
profile.

This directory is NOW-owned code graduated from the TimBotTu Web experiments.
See [PROVENANCE.md](PROVENANCE.md) for the exact source revisions and the
corpus/model distribution boundary.

The Xcode app target copies this directory into
`New Old World.app/Contents/Resources/WebBridge`. The host prefers that bundled
copy in an installed app and falls back to the repository tree for SwiftPM and
development runs.

## Development run

The deterministic static engine has no third-party Python dependency:

```sh
cp web-bridge/config.example.json /tmp/now-web.json
PYTHONPATH=web-bridge python3 -m nowweb --config /tmp/now-web.json
```

This command exposes a development-only HTTP listener. The product launches the
same renderer on an ephemeral host-loopback port, accepts browser traffic at
`127.0.0.1:5180` inside the guest application, and carries requests and bounded
response chunks over NOW's existing wire. The helper port is intentionally not
part of the product UI. Product requests carry only method and target; the host
module owns the browser profile, lens, handlers, and outbound policy applied by
the renderer.

For direct helper development, open:

```text
http://127.0.0.1:5180/go?u=https%3A%2F%2Fexample.com&profile=classilla
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

The product's browser-facing listener binds classic-Mac loopback only. It cannot
be reached from the guest LAN; requests leave the machine only through the
existing NOW connection. The standalone development command retains the helper
listener controls and must remain on loopback unless a developer deliberately
tests it on a trusted network.

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
