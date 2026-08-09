# Onboarding a PowerPC Macintosh

NOW's host can temporarily serve the PPC application and its setup files to
an old browser on the local network. This is distribution, not a new NOW wire
message, so it does not change `contract/asyncapi.yaml`.

## Use it

1. Open **Connections** in the host and choose **Set Up a New Mac…**.
2. The host starts its configured NOW listener if necessary, then starts a
   separate HTTP server on an available temporary port and builds the initial
   install image.
3. Connect the classic Mac to the same LAN. In its browser, open the exact
   `http://<address>:<temporary-port>/now` address shown by the host.
4. Installed package rows are checked by default. Uncheck any optional item
   that should not be on the disk, then choose **Rebuild Install Image**. The
   Install Image card shows the filename, disk and transfer sizes, build time,
   and the exact contents currently served. Changed selections do not replace
   the live download until the rebuild succeeds.
5. Choose **Download the complete setup disk**. A MacBinary-aware browser
   leaves `New Old World Setup.img`; open it with the system's Disk Copy and
   copy the native files from the mounted **NOW Setup** volume. If the browser
   leaves a `.bin`, enable its automatic MacBinary decoding and try again.
6. Put `New Old World Prefs` from the setup disk in
   `System Folder:Preferences` before launching New Old World.
7. Launch New Old World. The preference file already names the host interface
   that served the download and the NOW listener port shown in Connections.
   Setup is complete when the guest's real handshake puts the Mac under
   **Active**, not when the browser finishes a download.
8. Stop onboarding from the sheet or the Connections page.

The recommended download is one dynamically generated HFS Plus volume inside
an uncompressed NDIF image, the disk-image format read by the system Disk Copy
6.3.3. The image itself is a two-fork classic file, so HTTP carries it in a
MacBinary envelope. `/now/setup.img` advertises `application/x-macbinary` and
does not force a `.bin` attachment name, allowing a classic browser's built-in
MacBinary decoder to reconstruct `New Old World Setup.img`. The page also
links the same bytes at `/now/setup.img.bin` for an explicitly MacBinary-aware
fallback path. This is the unavoidable first bootstrap boundary: HTTP itself
cannot create a Finder type or resource fork on the receiving HFS volume.

The setup volume contains the application, generated preferences, optional
extension and whichever prepared dependencies are selected, as native classic
files. New Old World itself is required; every optional installed row is a
checkbox. The host decodes their MacBinary envelopes while constructing the
HFS Plus filesystem, so no archive or fork-restoration utility is required on
the guest after Disk Copy mounts it. **Save a Copy…** saves the exact currently
served image as `New Old World Setup.img.bin` for a separate
MacBinary-preserving transfer.

The builder keeps one completed image in memory. `/now/setup.img` and its
explicit `.bin` fallback serve those exact cached bytes; changing a checkbox
marks the image as having pending changes, and **Rebuild Install Image** swaps
in the replacement only after it finishes. For the shipped application,
extension and native CarbonLib package, the raw HFS disk is calculated from
the native files after their forks have been restored. The builder measures
that prepared directory, lets HFS account for its catalog and allocation
structures, and then measures the formatted volume's free blocks and tightens
it to at most 64 KiB free. If the filesystem refuses the first size, the host
grows it in 32 KiB steps until the contents fit; there is no package-size floor
or MiB rounding. The representative test payload produces a 5,607,424-byte
disk with 36,864 bytes free, rather than the former 19 MiB and then 8 MiB
carriers. When native CarbonLib and its StuffIt download are both present, the
native file wins and the archive is not included a second time.

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
| `Dependencies/CarbonLib.bin` | optional host-prepared native CarbonLib; avoids archive extraction at image-build time |
| `Dependencies/CarbonLib_161.sit.bin` | checksum-verified CarbonLib StuffIt archive in a MacBinary envelope |
| `Dependencies/*` | other operator-provided dependencies, each listed separately and served as supplied |

Set `NOW_ONBOARDING_ASSETS` to an alternate root for a development or test
run. When it is set, that root is the only package store.

Dependencies are explicit, selectable rows rather than one aggregate status.
A missing known dependency has **Source…** and **Get…** buttons. **Get…**
downloads into the local `Dependencies/` folder; a package is admitted only if
its bytes match the catalogued checksum. A newly acquired dependency is
selected for the next build by default.

The repository does not redistribute CarbonLib. Its catalog entry downloads
the 1.6.1 StuffIt archive from the Macintosh Garden mirror and requires SHA-1
`8a80248cb9acd2b26a3c7cf7af5dbde56b96fa3e`, which is also published by
[Macintosh Repository](https://www.macintoshrepository.org/17069-carbonlib).
NOW then puts those unchanged `.sit` bytes in the data fork of
`CarbonLib_161.sit.bin`, with Finder type `SIT5` and creator `SIT!`. Decoding
the MacBinary therefore yields a native StuffIt archive.
The **Source…** button remains available because this is still a third-party
download, not an Apple redistribution grant.

## StuffIt and BinHex boundary

MacBinary is a preservation envelope, not compression. NOW can reliably
create it itself and uses it for the application, extension, generated
preferences and catalog-acquired CarbonLib package.

The setup-image builder uses the open-source
[unar and XADMaster](https://theunarchiver.com/command-line) when `unar` is
bundled in the host app or installed at its usual Homebrew path. StuffIt
dependencies are extracted directly onto the temporary HFS Plus volume, where
their data forks, resource forks and Finder metadata remain native. A package
already supplied as a native MacBinary, such as `CarbonLib.bin`, needs no
extractor at image-build time. If neither is available, the original archive
is included honestly in the Dependencies folder rather than silently losing
its forks; that fallback does require a guest archive handler.

The test kit prepares CarbonLib as `CarbonLib.bin`, so its complete setup disk
does not depend on StuffIt or `unar` at runtime. A distributable host release
can either carry similarly prepared licensed packages outside Git or bundle a
pinned open-source `unar` build. The latter packaging and update policy is not
settled yet.

NOW does not currently create StuffIt archives. The open-source
[stuffit-rs](https://github.com/benletchford/stuffit-rs) can write StuffIt 5,
but it is young and has not been checked against the range of StuffIt Expander
versions on NOW's supported Macs. A single-archive button would encode a
compatibility promise, so the old pass-through **StuffIt archive** row has
been removed until a writer passes that matrix on real guests.

## Server and preference contract

The onboarding listener is temporary and app-owned. It stops explicitly or
when the host quits. It accepts only `GET` and `HEAD`, caps request headers,
uses HTTP/1.0 responses with a content length and connection close, and serves
only these fixed route families:

- `/now` and `/`
- `/now/setup.img` (MacBinary MIME decoding path)
- `/now/setup.img.bin` (explicit envelope fallback)
- `/now/application.bin`
- `/now/settings.bin`
- `/now/extension.bin`
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

The host tests exercise the real temporary listener over loopback, both setup
image routes and their headers, application and generated-settings downloads,
method and unknown-route refusals, package precedence, explicit dependency
enumeration, selection and cached-image replacement, checksum refusal, and
MacBinary fork boundaries plus preference bytes. A macOS integration test
builds a realistically sized HFS Plus volume, decodes the NDIF's MacBinary
envelope, mounts the raw disk read-only, and verifies native application,
extension and CarbonLib resource forks plus preferences and instructions. It
also asserts a sub-6-MiB carrier with less than 128 KiB free, and proves that a
native CarbonLib supersedes the matching StuffIt representation.

Separately, the generated NDIF image was transferred into a Mac OS 9.1 QEMU
guest and mounted by its stock Disk Copy 6.3.3. That proves the carrier and its
contents are compatible with the target OS; it does not prove that every
classic browser configuration automatically decodes the outer MacBinary.
The `/now/setup.img` browser step and a first launch/`hello` on physical
PowerPC hardware remain not Metal-verified.
