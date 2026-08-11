# Local Network access contract

This page is the authority for who owns NOW's macOS Local Network request and
what may count as proof. Continuity consumes the capability; it does not own
it. When implementation notes elsewhere disagree with this page, this page and
the executable guards named below win.

## Ownership

| Concern | Owner | Operation | What it proves |
| --- | --- | --- | --- |
| Ask macOS for Local Network access | Application lifecycle | Start the declared `_newoldworld._tcp` Bonjour listener and browser at launch | Nothing; it only gives macOS a documented opportunity to present privacy UI |
| Repeat the request | Connections page | Restart the same app-owned Bonjour operation, without requiring a guest | Nothing; macOS may retain an earlier decision and expose no reset API |
| Verify unicast LAN traffic | The feature using it | Open an unpinned UDP path to the active guest and queue content | Only `.ready` on that guest-targeted path confirms direct access |
| Choose Wi-Fi or Ethernet | Network.framework and the routing table | No `requiredInterface` or `requiredInterfaceType` | The selected path may use `en0`, `en7`, or another viable interface |
| Revoke or change a prior decision | macOS | Open Privacy & Security > Local Network | NOW cannot revoke or reset the system decision itself |

The app requests access once from `applicationDidFinishLaunching`, before it
starts its other network services. The operation takes no guest address. A
connected guest is required only for direct-path verification. Repeating the
app request must not erase a direct-path result that has already reached
`.ready`.

## Evidence rules

The prompt operation and the proof operation are deliberately separate state
machines.

- Browser readiness is not authorization evidence.
- Listener readiness is not authorization evidence.
- Discovering the app's own Bonjour publication is not authorization evidence.
- A queued-send callback is diagnostic evidence, not a permission verdict.
- A real guest-targeted UDP path reaching `.ready` is the only positive proof.
- `waiting` or `failed` is reported with the Network.framework path and error;
  it is not rewritten into a guessed macOS privacy state.

## Identity and packaging

macOS associates privacy state with the signed application identity. Candidate
builds therefore use the single reviewed `continuity` identity profile rather
than minting a suffix per build. The profile fixes the bundle identifier,
display name, Team ID, application identifier, Bonjour declaration, and usage
description. Canonical and candidate identities remain distinct until the
feature lands; builds replace the same profile-specific application instead of
creating another identity.

The two active profiles are defined once in `tools/host-build-identity`:

- `canonical`: `dev.newoldworld.now`, displayed as **New Old World**
- `continuity`: `dev.newoldworld.now.continuity`, displayed as
  **NOW Continuity**, packaged as `NOW Continuity.app`

The filename and install directory are part of the test rig on the current
macOS build. Its Local Network pane showed five indistinguishable
`New Old World.app` registrations, all enabled, while the running candidate
still had no admitted path. Renaming that bundle inside `/private/tmp` did not
repair it: Launch Services marked the otherwise valid record `in-temp-dir`,
and `neagent` logged that it could not find `dev.newoldworld.now.continuity`,
then cached zero executable UUIDs. With no UUID, macOS created neither a Local
Network row nor a prompt. Xcode now builds the reviewed product name directly,
and the signed Continuity build refuses a temporary output directory. Metal
candidates replace `~/Applications/NOW Continuity.app`; a temp bundle is a
build artifact, never a permission test.

`scripts/verify-host-signature` verifies the signed result rather than trusting
build settings.

## Regression history

The ownership boundary was established in `f46c18fd` and retained by
`96513cc6`: launch performed an app-owned, guest-independent request.
`33d19759` removed that request, transferred solicitation to Continuity,
removed the Bonjour declarations, and inverted the guard to reject the
previously working ownership shape. `1db72e80` restored the Bonjour mechanism
but not application ownership. `c26d86e4` restored ownership; the follow-up
reconciliation separated prompt state from direct-path evidence and made the
old guest-targeted `request(to:)` API a gated regression.

A macOS beta privacy defect may complicate a particular run. It cannot explain
away an application regression when the live history shows that NOW changed
the owner or identity.

## Executable guards

`scripts/test-host-build-identity` requires:

- both plists to declare the same Bonjour service and usage text;
- an app-owned, no-argument `request()` call at launch;
- a distinct `verifyDirectAccess(to:)` call from Continuity;
- no guest-targeted `request(to:)` API;
- no Continuity call to the app-owned request;
- no interface pinning; and
- stable canonical and Continuity build identities.

`LocalNetworkAccessControllerTests` exercises the two state machines with
injected prompt and direct-path adapters, including the rule that repeating the
prompt cannot erase an already proven path. New guards are mutation-tested
against the exact ownership change they claim to catch.

This is a source-and-test contract. It does not make a build metal-verified;
the signed application still needs an attended launch and direct-path check on
the current macOS installation.
