# Onboarding a PowerPC Macintosh

NOW's host can temporarily serve the PPC application and its setup files to
an old browser on the local network. This is distribution, not a new NOW wire
message, so it does not change `contract/asyncapi.yaml`.

## Use it

1. Open **Connections** in the host and choose **Set Up a New Mac…**.
2. The host starts its configured NOW listener if necessary, then starts a
   separate HTTP server on an available temporary port.
3. Connect the classic Mac to the same LAN. In its browser, open the exact
   `http://<address>:<temporary-port>/now` address shown by the host.
4. Download and decode `New Old World.bin` and
   `New Old World Prefs.bin`. Put the decoded `New Old World Prefs` in
   `System Folder:Preferences` before launching New Old World.
5. Launch New Old World. The preference file already names the host interface
   that served the download and the NOW listener port shown in Connections.
   Setup is complete when the guest's real handshake puts the Mac under
   **Active**, not when the browser finishes a download.
6. Stop onboarding from the sheet or the Connections page.

The NOW Extension is optional. Put its decoded file in
`System Folder:Extensions` and restart the classic Mac. The application works
without the resident, with the reduced capability set described in
[resident-components.md](resident-components.md).

This first surface is deliberately PPC/Carbon-only. NOW-68K remains an
experimental sibling with a different artifact and configuration path; the
portal does not imply that it is a supported choice here.

## Package store

Copyrighted or locally licensed dependencies do not belong in Git. The portal
combines two stores, with the local store taking precedence:

1. `~/Library/Application Support/New Old World/Onboarding/`
2. `New Old World.app/Contents/Resources/Onboarding/`

**Open Packages Folder** creates and opens the first. A release packager can
put the second into the application before signing it. The recognized product
names are:

| File | Portal role |
|---|---|
| `New Old World.bin` | canonical PPC MacBinary; required |
| `NowExt.bin` or `NOW Extension.bin` | optional resident |
| `New Old World.sit` or `New Old World Installer.sit` | optional complete archive; served as supplied |
| `Dependencies/*` | optional operator-provided dependencies, listed by file name |

Set `NOW_ONBOARDING_ASSETS` to an alternate root for a development or test
run. When it is set, that root is the only package store.

The host does not manufacture a StuffIt archive. If a verified `.sit` is
present it is offered; if not, the portal presents the individual MacBinary
files. That keeps an unreliable archive-creation path out of the application.

The repository does not redistribute CarbonLib. If no dependency whose name
contains `CarbonLib` is installed, the page links to the
[CarbonLib page on Macintosh Garden](http://macintoshgarden.org/apps/carbonlib).
That HTTP page was reachable on 2026-08-09, but it is an external archive, not
an Apple redistribution grant or a package NOW has verified. A release may
carry an operator-vetted installer in `Dependencies/` without changing code.

## Server and preference contract

The onboarding listener is temporary and app-owned. It stops explicitly or
when the host quits. It accepts only `GET` and `HEAD`, caps request headers,
uses HTTP/1.0 responses with a content length and connection close, and serves
only these fixed route families:

- `/now` and `/`
- `/now/application.bin`
- `/now/settings.bin`
- `/now/extension.bin`
- `/now/archive.sit`
- the exact installed names beneath `/now/dependencies/`

There are no uploads, directory listings, arbitrary file paths, cookies,
JavaScript, TLS, redirects, compression, or chunked transfer.

The generated settings download is a MacBinary II file named
`New Old World Prefs`, with Finder type `pref` and creator `NOWo`. Its data
fork is the guest's existing big-endian format-1 preference record: magic
`NOWp`, format 1, listener port, and a 64-byte dotted-quad host field. The PPC
loader intentionally accepts this connection-only record and keeps all newer
settings at their own compiled defaults. The initially displayed URL uses the
best active LAN IPv4 the host can find; the downloaded settings prefer the
local endpoint of the HTTP connection itself, so Ethernet, Wi-Fi, VPN and
emulator interfaces are not guessed a second time after the browser arrives.

## Evidence and limits

The host tests exercise the real temporary listener over loopback, the page,
application and generated-settings downloads, method and unknown-route
refusals, package precedence, and the MacBinary/preference bytes. This is
**Tested**. It has not yet been used from a classic browser or carried through
a first launch and `hello` on physical PowerPC hardware, so it is not
Metal-verified.
