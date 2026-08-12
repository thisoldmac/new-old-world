<!-- now-doc-provenance: generated reviewed=false -->

# Security

## The threat model, stated plainly

NOW is designed for a **trusted local network** — typically a classic Mac
and a modern Mac on the same LAN, often the same desk. It is not hardened
for a hostile network, and the design does not pretend otherwise.

What that means concretely, today:

- **The wire is plaintext TCP.** There is no encryption. The contract
  reserves a future pinned-key TLS wrapper below the frame layer, and
  explicitly forbids any in-band STARTTLS-style upgrade — but that
  transport is not implemented. Anything crossing the wire, including
  file contents and screen captures, is readable by anything on the path.
- **There is no authentication.** The host gates a connection on a
  `hello` handshake, which establishes *what* is connecting, not *who*.
  Any peer that can reach the port and speak the contract is served.
- **The host listens on all interfaces.** It binds a TCP port for the
  guest to dial. On an untrusted network, that port is reachable by
  anything that can route to it.
- **The connected peer can act on the machine.** Within the shared
  folder each side publishes, a peer may browse, read, write, rename,
  move and trash files. It may also capture the screen, list running
  processes, and — on the guest — launch, front and quit applications.
  These are the product's features, not defects, and they are exactly
  why the network boundary matters.
- **The shared folder is the boundary.** Path resolution is root-scoped
  and rejects escapes; `HostShareTests` covers that. That scoping is the
  security-relevant control in the file family, and the one worth
  scrutinising.

Run NOW on a network you control. Do not expose its port to the internet
or forward it through a router.

## Vintage-platform caveats

The guests run on operating systems that predate modern security
engineering entirely — System 7.1 and Mac OS 9 have no process isolation,
no memory protection worth the name, and no vendor patches. A classic Mac
running NOW should be treated as a machine on a trusted segment, and
generally already is.

`docs/resident-components.md` governs the optional NOW Extension, which
executes in foreign contexts on the guest. Each resident component sits
behind a versioned in-memory contract and is always optional: the product
degrades honestly without it.

## Reporting a vulnerability

Open a GitHub issue for anything already covered above — those are known,
documented properties, and a public issue is the right place to discuss
tightening them.

For a finding that is **not** in the list above — a shared-folder escape,
a frame-parsing memory bug, a way for a peer to reach outside its
declared scope — please report it privately using GitHub's **Report a
vulnerability** button under this repository's Security tab, rather than
opening a public issue. If private vulnerability reporting is not available,
email `github@shelbel.net` instead.

Please include what you did, what happened, and which side and build you
were running. As with everything in this project, say whether you watched
it happen on real hardware or in an emulator — it changes what the report
means.

There is no bounty and no formal SLA. This is a personal project about
old computers, and responses come when they come.
