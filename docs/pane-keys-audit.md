<!-- now-doc-provenance: generated reviewed=false -->

# Pane keystrokes → guest front app (audit lane)

Lane owner: `audit/pane-keys`. Status: **built, unit-tested by compile,
NOT run against a Macintosh or the built app.**

## Starting facts (gathered before the first edit)

- `now-guest-ppc/src/input/input_cmds.c` (`now_input_run_key`) already
  implements the wire's `key` verb: `PostEvent(keyDown, ...)` then
  `PostEvent(keyUp, ...)`, keyDown's `OSErr` load-bearing, keyUp's
  `evtNotEnb` reported as a row and never treated as failure, and `mods`
  refused with anything but 0 (`now_key_check`, `input_args.c:158-159`).
  This matches every upstream fact in the brief for the guest half, and
  none of it needed to change.
- The wire's parameter name is `mods` (`contract/asyncapi.yaml:3079`,
  `input_cmds.c:227`) — the upstream `{key, modifiers}` naming bug this
  brief warned about does not exist here.
- **The command-modifier path does not exist in NOW at all, and this is
  a NOW fact rather than a gap this lane could close.** Upstream's guest
  was not Carbon and could call `PPostEvent`, which hands back the queue
  element a modifier is stamped on. NOW's PowerPC guest is a Carbon
  application; `PPostEvent` is `CALL_NOT_IN_CARBON`. So `key` refuses
  `mods != 0` outright (`now-guest-ppc/src/input/input_args.c:158-159`,
  `contract/asyncapi.yaml:key`), and the only place in this repository
  that reaches a *modified* keystroke is `ext/src/now_ext_act.c`, a 68K
  resident that calls `PPostEvent` for a mouse press/release — not for a
  key. There is no code path, host or guest, that can post a Command-held
  keystroke here. Upstream's three modifier facts (code-not-char
  matching, the down/pause/up beat, keyUp's normal `evtNotEnb`) are
  therefore facts about a mechanism NOW does not have; I have not invented
  one to make the brief's "hard part" have an answer, because inventing
  it would mean either (a) a second, undocumented resident act, well
  beyond this lane, or (b) posting a modifier NOW's own contract was
  written to refuse — the exact defect this whole design exists to avoid.
- **What DID need building: the plain (`mods == 0`) path had a guest verb
  and no host lane at all.** `docs/mcp-coverage.md` (`key`, row **W3**,
  marked "planned") and `docs/open-issues.md` ("`key`, `type` and `click`
  are unavailable by design") both already recorded this before I touched
  anything: `ActionModel.availability(.key)` answered `.unavailable`
  unconditionally, `MirrorActionDriver` grouped `.key` into its
  unreachable catch-all, and there was no `AgentIntegrationHostAdapter`
  method, no `AgentIntegrationActControl` wire call, and no pane keyDown
  capture anywhere in `now-host/Sources/MirrorKitUI` or `Sources/Host`.

## What this lane built

1. `AgentIntegrationKeyRequest` / `Receipt` / `Result`
   (`now-host/Sources/NOWAgentIntegration/Projection/AgentIntegrationKeyModels.swift`).
2. `AgentIntegrationActControl.key(_:)` — the wire call. Reads the input
   plane's own **lower-case** rows (`code`, `char`, `posted`) rather than
   the act plane's capitalized `Dispatch`/`Window` rows the shared
   `dispatch()` helper reads, because `key` answers no `Dispatch` row at
   all (`now-guest-ppc/src/input/input_cmds.c:now_input_run_key`).
3. `AgentIntegrationHostAdapter.key(_:)` — a one-line passthrough, same
   shape as `menuAct`/`controlAct` beside it.
4. `ActionModel.availability(.key)` — no longer a blanket
   `.unavailable`. `mods == 0` → `.available(command: "key")`; `mods !=
   0` → `.unavailable` with the CarbonLib reason. `MirrorAction.key`
   gained a `name: String?` field alongside `code`/`char`/`mods` so a
   named key (Return, Tab, the arrows, …) can be sent by name — the
   guest's own vocabulary — rather than this host deriving the guest's
   `g_key_named` code/char pairs itself.
5. `ActionModel.paneKeystroke(virtualKeyCode:characters:command:option:
   control:)` — the pure translation from an ordinary key press to a
   `MirrorAction.key` or `nil`. **Shift is folded into the character, not
   into `mods`** — matching the guest's own case-sensitive key table
   (`g_key_chars`'s own comment: "the character is the UNSHIFTED one …
   what it can do is carry the character the caller sent … unchanged").
   A key this vocabulary cannot express (a function key, a non-ASCII
   input) returns `nil` — an honest "nothing to send" rather than a
   guessed code.
6. `MirrorActionDriver`'s `.key` case — dispatches through the adapter
   when `mods == 0` (re-checked, the same discipline `.axdo`'s reference
   gets), refuses otherwise.
7. `MirrorModuleModel.key(...)` — mirrors `click(x:y:)`: gated on a
   scene being shown, asks `ActionModel.availability` first, reports
   `.asking` → `.dispatched`/`.refused`/`.unavailable` the same way.
8. `MirrorKeyCaptureView` (`now-host/Sources/Host/MirrorKeyCaptureView.swift`)
   — an `NSViewRepresentable`, AppKit rather than SwiftUI's `.onKeyPress`
   for the same reason `ConsoleInputField` states: `.onKeyPress` needs
   macOS 14 and `Package.swift` declares `.macOS(.v13)`. Wired into
   `MirrorModuleView.drawing(_:)` as an overlay whose `hitTest` always
   returns `nil`, so it cannot intercept the drawing's existing
   `DragGesture`-based click; `press(at:in:scene:)` calls a focus
   closure explicitly, after its own gesture has already run.

Unit tests added: `ActionModel.paneKeystroke` (ordinary letter, Shift
folded into the char, Command becomes `mods`, a named key, an unmappable
key returns `nil`) in `HitActionTests.swift`; `MirrorActionDriver`'s new
`key`/named-key dispatch and a "a modified keystroke never reaches the
wire" check in `MirrorActionDriverTests.swift`. Three existing `.key(...)`
call sites and one stale test name/comment were updated for the new
`name:` parameter and the no-longer-blanket availability.

## Verification performed

- `swift build` — passes, no new errors or warnings.
- `swift build --build-tests` — passes (compiles the test target; does
  **not** run it). `swift test` was deliberately **not run** — the gate
  for this fan-out: only one `swift test` may run on this Mac at a time,
  and the orchestrator runs the real gate centrally.
- Read-through of every changed line against the guest source
  (`now-guest-ppc/src/input/input_cmds.c`, `input_args.c`, `input_args.h`)
  and the contract (`contract/asyncapi.yaml:key`) to confirm the wire
  shape, row names and casing, and the `mods` rule match exactly.

## What is NOT verified, and why

**Nothing here has run against a Macintosh, real or emulated. Nothing
has run in the built host app either — no display was attached to this
work.** Concretely, unverified:

1. **Whether a keystroke actually reaches the guest's front application.**
   This lane never had an emulator or a paired guest to test against. The
   `AgentIntegrationActControl.key` wire call is read against the guest's
   own C source and the contract, not measured live.
2. **The AppKit/SwiftUI integration in `MirrorKeyCaptureView`.** The
   `hitTest`-returns-nil design is argued for in the file's own header
   comment, not measured: it should leave the existing `DragGesture`
   click path untouched and should let the overlay still receive
   `keyDown` once it is first responder, but AppKit's exact event
   ordering when a `hitTest`-refusing view sits in a SwiftUI `ZStack`
   over a `Canvas`-hosted gesture has not been exercised. Likewise, the
   `DispatchQueue.main.async` handoff of `focusRequest` out of
   `makeNSView` (needed because the closure has to be built after the
   `NSView` exists) has not been watched actually firing.
3. **The command-modifier path — because there is not one to test.** The
   brief asks for "proof by effect" (Command-W closes a window, it does
   not type a w) as a documented, unrun emulator probe. That probe cannot
   be written honestly for NOW as it stands: NOW's `key` verb refuses
   every modified keystroke before it reaches the queue, so there is no
   "Command-W" call this project will make at all — the effect it would
   have is exactly the thing being refused, on purpose, and the correct
   observation is "nothing was sent", not a window closing. The probe
   below is for the path that DOES exist.

## The documented, unrun probe (for the plain-keystroke path)

To run once a guest is paired and a display is attached:

1. Boot the guest, launch SimpleText (or any editor with a visible
   document window), click its document to give it Mac focus.
2. In the NOW host app, open the Mirror pane, click once anywhere on the
   drawing (any point — even the letterbox, per `clickedOffScreen`, is
   sufficient to give `MirrorKeyCaptureView` first responder via the
   focus-after-click wiring).
3. Type the letter `n`. **Proof by effect**: re-fetch the scene (`Look
   Again`) and confirm the document's text now contains an `n` — not the
   driver's `.dispatched` outcome, which only means `PostEvent` returned
   `noErr`.
4. Type Return, then an arrow key. Confirm by effect: a new line in the
   document; the caret's reported position (if `textget` on the field
   changes) moves.
5. Hold ⌘ and press `n` (or any letter) while the pane has focus.
   **Expected**: `ActionModel.availability` refuses it locally — nothing
   should appear in the guest's own log
   (`AgentIntegrationActControl.audit`) as a `key` request at all. This is
   the negative control for fact 3 above: proof that NOW never asks the
   guest to do the thing it cannot safely do, rather than proof of an
   effect that cannot happen by this project's own design.

## Refusals, stated plainly

- I did not build the MCP/`appIntents`-facing `key` row (`KeyProjection
  .swift`, a `key` case on the `AgentIntegrationClient` protocol, wiring
  through `AgentIntegrationLocalServer`/`LocalClient`/the socket client).
  `mcp-coverage.md`'s W3 stays open for that face. Reason: the lane's
  acceptance is about the PANE — a human typing while the mirror has
  focus — which reaches the guest through `AgentIntegrationHostAdapter`
  directly (`MirrorActionDriver.adapter` is that concrete type, not the
  `AgentIntegrationClient` protocol the MCP/socket surface uses); building
  the full agent-facing plumbing as well would have roughly tripled the
  surface area touched with no way to verify either half against a real
  machine in this session.
- I did not invent a command-modifier keystroke mechanism. See "starting
  facts" above — NOW has none, and building one was out of scope for a
  lane whose brief is to route the pane through "the existing key verb".
