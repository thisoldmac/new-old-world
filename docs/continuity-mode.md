# Continuity mode

Continuity is an optional input mode on top of Mirror. It does not replace
Mirror's semantic scene or act planes. When enabled, moving the host pointer
over the Mirror asks the PowerPC guest for temporary ownership of its pointer;
after the guest accepts, v0 mirrors movement only. Primary clicks still use
Mirror's semantic path. Direct click and drag delivery remain the separate
v0.5a and v0.5b stages.

It is off by default and its enable switch is session-only. The update rate is
user-selectable at 15, 30, or 60 Hz; 30 Hz is the default, and the selection is
remembered per stable guest identity.

## Ownership and transport

The existing wire port is used in both protocol namespaces:

- TCP on port N carries `continuity.arm`, `continuity.report`, and
  `continuity.disarm`. The arm grants a random 64-bit nonce and a monotonically
  changing epoch. All three messages carry control-contract version `1`; a
  missing or different version is refused as `wrong-version`. UDP alone can
  never create authority.
- UDP on port N carries fixed 40-byte latest-state datagrams and fixed 44-byte
  acknowledgements. A QEMU run forwards TCP/N and UDP/N separately. The host
  uses an ephemeral UDP source port, so it does not compete with its TCP
  listener.

The PowerPC application's Open Transport notifier performs only bounded,
preallocated decode, shared-cell publication, and publication of one pending
reply address. It never sends. The ordinary task-time wire pump coalesces that
debt to the latest acknowledgement and makes at most one `OTSndUData` attempt
per pass. P9 in the NOW Extension owns arbitration and native-input takeover.
Continuity V3 has the resident publish one requested point and return. The PPC
application owns one synthetic absolute Cursor Device and applies that point
through Apple's `CursorDevicesGlue`, then publishes the exact result for a
second resident call to commit. The resident never owns a Cursor Device and
never enters Cursor Device Manager after boot. Continuity also has no Time
Manager task, global jGNE service, Event Manager call, QuickDraw call, or
downstream mouse-global write.
It shares one input-owner arbiter with P7 drag, so the two resident vehicles
cannot hold the mouse together.

Movement is replaceable latest state. Button edges are not: the host repeats a
down generation until the resident acknowledges applying it and does not emit
the later up generation before that acknowledgement. The resident also has a
fixed five-second arming grace before the first accepted UDP state. Once input
is live it switches to the clamped 0.25–10 second lease; the host currently
requests 90 ticks (1.5 s). Setup therefore cannot spend the dead-man that
protects a held live button.

## Yielding to the guest

Continuity does not disable the guest's physical pointing device. P9 samples
`RawMouse` and the low-memory button state immediately before each cooperative
host placement. Recent points reported through its owned Cursor Device are
excluded. Any other motion or button change ends the epoch, relinquishes the
shared input owner, and reports `guest-input` before another host point is
applied.

Leaving the Mirror, stopping it, losing host focus, switching guest, losing the
TCP session, UDP failure, or lease expiry also releases ownership at the next
cooperative service pass. v0 holds no button and does not suppress physical
input, so a starved application cannot leave an Event Manager or cursor-global
release debt behind it; it simply makes no further placements.

## Versions

- **v0:** hover/move mirrors the host point to the guest.
- **v0.5a:** primary down/up bypass Mirror's semantic click gesture after the
  Continuity arm is active.
- **v0.5b:** motion continues while primary is held, using the same acknowledged
  edge stream, so guest tracking loops receive a real drag.

Secondary click, scroll, keyboard input, MCP, agent integration, the guest
console, and NOW-68K are not Continuity surfaces.

## Evidence and remaining work

**Continuity is isolated on its feature branch and will enter the product only
through a release-candidate branch.** It does not land independently on
`main`. On 2026-08-11 an attended PowerBook 1400c run of the V3 route moved the
guest pointer accurately without wedging the machine. Motion was somewhat
jittery and changing 15/30/60 Hz did not produce a clearly different cadence.
That is the first positive metal result for the corrected route; it proves the
bounded v0 movement session that was observed, not sustained-motion stability
or update-rate fidelity.

Six earlier PowerBook 1400c runs wedged the machine after resident pointer
placement. They separately ruled out
cursor-task reentry, reporting through the physical ADB device, global jGNE
settlement, and direct Time Manager writes to the downstream mouse globals.
Native clicks and both NOW TCP sessions stopped, and Force Quit could show its
frame without rendering the modal's contents. Those were system-wide Event
Manager liveness failures, not cursor-shape or held-button-only defects.

Resident 1.14 first completed one host position and one physical takeover, but
its next 30 Hz run wedged the PowerBook after about one second. That invalidated
the bounded result as a general safety claim and revoked both operations still
present: timer-context `CursorDeviceMoveTo` and PPC-pump
`HideCursor`/`ShowCursor`. Resident 1.16 removed both but still used a generic
PPC-to-68K transition to reach raw resident Cursor Device Manager code. It
briefly moved twice around a host-leave/re-enter cycle and then caused the
sixth system-wide wedge. Resident 1.17 replaces that route with Apple's
required PPC glue. Its first attended movement run is the positive metal result
above; release/recovery and sustained-motion evidence remain release-candidate
gates.

### Historical 1.11 safety contract (later falsified)

The PowerBook 1400 is not a generic “PMU mouse” counterexample. Its trackpad
translates movement into ADB commands, and its 68HC05 power-management
controller carries the ADB path ([PowerBook 1400 Developer Note](https://www.macdat.net/files/pdf/apple/developer_notes/powerbook_1400.pdf)).
The failed resident asked `CursorDeviceNextDevice(NULL)` for the first device
at boot and retained that pointer. It never created a virtual device with
`CursorDeviceNewDevice`. On this machine, `CursorDeviceMoveTo` therefore acted
through the physical ADB trackpad's manager record from a Time Manager
interrupt. The claim that this was safe because an ADB driver can call the
same selector from its own interrupt was an analogy, not an established
calling contract, and the two metal wedges falsified it as a product safety
argument.

The failure also defeated both recovery owners at once. Once the foreign
manager call stopped returning, the same timer could not reach its next lease
check or button release, while the cooperatively scheduled PowerPC application
could no longer service the TCP disconnect that would withdraw authority.
Closing and recreating the asynchronous Open Transport UDP endpoint had
already reproduced a separate partial wedge in the emulator, so synchronous
transport teardown is treated as an amplifier rather than the root cause.

The next candidate has these non-negotiable boundaries:

- The Time Manager callback performs only bounded reads and writes of
  preallocated resident state and documented low-memory mouse globals. It
  calls no Cursor Device, Event, QuickDraw, Open Transport, Memory, or Resource
  Manager routine.
- Cursor Device and QuickDraw work happens only from task time. Continuity
  never mutates the first physical device from interrupt context. During a
  classic tracking loop, low-memory position and button state remain the
  safety/behavior path; drawing may settle on the next task-time pass.
- Every arm epoch owns a reset generation. Disarm, local guest input, host
  departure, lease expiry, and TCP loss cancel an unposted down, force the
  low-memory button up immediately, and leave an Event Manager mouse-up debt
  only when a down was actually posted.
- `PPostEvent` results are checked. A failed up remains owed and retryable; a
  stale down can never be posted after its epoch resets. No recovery path
  flushes the global event queue, because that would discard unrelated native
  input.
- UDP authority is revoked before any transport cleanup. The application logs
  arm, reset, disconnect, endpoint-close stage and error; the resident exposes
  bounded counters for task-time applies, forced resets, down/up posts, and
  post failures. Nothing writes a file from interrupt context.

An emulator pass can establish the absence of forbidden calls, correct reset
ordering, Event Manager settlement, transport recovery, and native-input
return. Only an attended PowerBook run can establish that the ADB/PMU hardware
row is safe.

### Task-time candidate: resident 1.11

The next candidate implements that boundary. Its Time Manager callback writes
only resident scalars and low-memory mouse state. `CursorDeviceMoveTo`,
`HideCursor`/`ShowCursor`, and `PPostEvent` run only from the jGNE task-time
pass. Reset forces low-memory mouse-up immediately, cancels an unposted down,
retains mouse-up debt only after a successful down post, detects a reset racing
`PPostEvent`, retries a failed up, and never calls `FlushEvents`. Disarm and TCP
loss also cancel stale task-time cursor debt before it can move the pointer
again.

The emulator campaign found a second whole-system liveness mechanism outside
the INIT. Calling `OTSndUData` from the asynchronous UDP notifier eventually
stopped both NOW and the unrelated anchor process, first after 84 acknowledged
positions and again after 78. The framebuffer still rendered and no modal was
present. Merely retaining a pending ACK for `T_GODATA` was timing-dependent: one
run reached 180 positions and the next wedged. The app now publishes ACK debt
from the notifier and sends only from the task-time wire pump, with a sequence
check protecting the notifier/task address handoff. This is the same safety
rule as the resident split: foreign manager/provider work does not run inside
an arbitrary callback.

At commit `f72b9358`, guest build `7b6806dca802` and resident 1.11 reported
source manifest `59430281706f707090a95431ac74121ba0c3b5a8`, fingerprint
`69fabb4c571826b5d1224a4964981cbf7bcd4a5f`, and capabilities `1023`.
Independent PMU/USB and CUDA/ADB cold boots each completed 180 positions at
30 Hz, synthetic down/up, movement-triggered `guest-input`, held-button
disarm, native motion after reset, held-button TCP loss, wire reconnect,
native motion after reconnect, and a fresh arm/apply/disarm epoch. Each run
needed four state retries, rejected no datagrams, left the independent anchor
responsive, and shut down through Finder. CUDA input control was proven on a
separate cold boot before its Continuity run: movement reached Mac OS,
`CursorData.buttonCount` transitioned 1 to 0, and the wire remained live.

Input-device preflight and Continuity are deliberately separate cold boots.
The preflight's real click can enter an application tracking loop; running the
fault campaign behind it once made that loop look like a resident liveness
failure. A test that wants to prove both must shut down cleanly between them.

The private image
`agent-stage/now-stage-continuity-1.11-tasktime-safe.qcow2`, SHA-256
`7c7f64af5da9d42bca2160d51b1e9fc2c74c81df877e46e1cfb1751d05c07783`,
passed guest-reported identity/capability, ABI, all 14 census probes,
guest-clean shutdown, clean HFS-volume inspection, and `qemu-img check`. The
shared oracle was not changed. This is emulator-tested, not metal-verified.

The quarantine itself is emulator-verified. The guest reported lifecycle
`active`, capability word `511` (all prior resident planes, P9 absent), source
manifest `6c9a1df22adc407e70afdb463ebdef3ad891f17d`, and fingerprint
`0c81a3cc5cc18c08f90331788cd1ed2833a69db1`. The private image
`agent-stage/now-stage-continuity-quarantined.qcow2`, SHA-256
`f2de4f653451be46adde69a76248404307fe23c4b1a944303b772d055bac95cd`,
passed the ABI and full census gates, guest-clean shutdown, clean HFS-volume
check, and `qemu-img check`. It exists to verify containment, not to invite a
third PowerBook test.

The fixed-layout C and Swift codecs, input arbitration, takeover/lease decisions,
TCP authority routing, and host generation ordering are tested. The host ordering
test runs a real loopback TCP control conversation and a same-numbered UDP lane.
The first PowerBook run on 2026-08-10 is negative metal evidence. It connected
and moved a few times, then left the machine on the wristwatch with clicks
unresponsive; physical trackpad movement still moved the arrow, but did not
recover the cooperative UI. The unsafe candidate called `JCrsrTask` from its
Time Manager callback. That foreign call and its assembly trampoline are now
removed: interrupt time performs bounded position work and records redraw
debt, while task-time jGNE pays the QuickDraw debt.

The repaired resident cross-builds and a fresh private mac99/OS 9.1 clone
reported source manifest `e2a48cb67346fce9496e6ed7bb9dd07c1a3ca026`,
fingerprint `c4b55adcdcdb7435c7239f3a68d08105516bef5f`, and capability word
`1023`. Guest build `64345c292ce4 2026-08-10T05:20:23Z` kept separate 15,
30, and 60 Hz epochs active with zero rejects. It acknowledged click down/up
generations 1/2, a held drag and release at generations 3/4, then released a
separate held generation after `lease-expired`. The app answered `mouseloc`
after expiry and accepted a new epoch; repeated disarm/re-arm required zero UDP
retries. The exact final drag point read back as `(552,436)`.

This verified the now-rejected emulator data path and resident/application
lifecycle, not physical safety. The exact unsafe source had also been baked
into the branch-private image now quarantined as
`agent-stage/now-stage-continuity-cursor-safe-UNSAFE-DO-NOT-DEPLOY.qcow2`, SHA-256
`2800a280d3c1835bf9cb7bf42ff633906f39e75a4e06a5fd8e4045d8de1e55e3`.
The bake passed the resident identity/capability gate, ABI self-test, all 14
census probes, `qemu-img check`, guest-clean shutdown, and clean HFS-volume
check. The shared oracle remains unchanged. No image or binary from that
candidate is eligible for promotion.

The input-controller comparison on 2026-08-10 kept that exact unsafe resident
(`3106e39ad9a6`, capabilities `1023`) and changed the emulated pointing-device
path first. `mac99,via=pmu` with its default relative USB mouse moved the
guest-observed pointer from `(15,15)` to `(196,162)` and changed the live
`CursorData.buttonCount` from `1` to `0`; `mac99,via=cuda` with its ADB mouse
made the same movement/button proof. The 180-position, 30 Hz Continuity trial
then completed on both controllers with zero rejected datagrams, disarmed, and
returned to native input: PMU/USB moved `(610,460)` to `(429,336)`, while
CUDA/ADB moved `(610,460)` to `(455,362)`. Neither emulator rig reproduced the
PowerBook's system-wide wedge.

The explicit `mac99,via=pmu-adb` diagnostic is not a third passing rig. QEMU's
ADB mouse accumulated the relative event, PMU raised its autopoll interrupt,
and Mac OS acknowledged the correctly shaped `0x14, 0x3c, dy, dx` packet, but
the guest cursor did not move. The unsafe Continuity path was therefore not
armed on that profile. `tools/emulator-pointer-control.py` records the basic
device proof before `tools/emulator-continuity-fault.py` may exercise P9, and
both tools distinguish PMU/USB, PMU/ADB, and CUDA/ADB explicitly.

This is negative emulator evidence, not evidence that the unsafe resident is
safe. Two independent emulated input paths failing to reproduce a physical
machine's whole-system liveness failure strengthens the quarantine boundary:
the next design still has to remove manager calls from interrupt time and earn
fresh metal evidence before P9 can be advertised.

The preserved research rig and its measurements live under
`spikes/cursor-latency/`. Its documents and history are evidence; its binaries
remain measurement-only and are not part of the NOW product.

### Third metal failure: jGNE is not a safe application context

Resident 1.11 falsified the phrase “task-time pass” as a sufficient safety
boundary. On 2026-08-10 at 15:58:01, host candidate `486f156a` opened its UDP
lane to the PowerBook and Network.framework reported it ready on `en7`; Local
Network permission and transport establishment were therefore not the defect.
The UDP lane cancelled about 4.8 seconds later, but the guest did not recover.
The resident TCP channel was lost at 15:58:48 and the PPC application channel
at 15:58:55. On the machine, the cursor became the wristwatch, clicks from the
native trackpad stopped reaching applications, and Force Quit drew an empty
modal frame before stalling.

The 1.11 timer itself no longer called Cursor Device Manager or QuickDraw. It
published a redraw debt, and the extension's global `GetNextEvent` filter paid
that debt by calling `CursorDeviceMoveTo`, `HideCursor`, and `ShowCursor` while
Event Manager was already dispatching an application's event request. That is
task time in the scheduling sense, but it is still reentrant Event Manager
context. The empty Force Quit modal is direct negative evidence against using
that filter as Continuity's cursor-settlement owner.

The next source candidate therefore changes the ownership boundary rather than
moving the same calls again:

- v0 is movement only. The host sends button generation zero, returns clicks
  to Mirror's semantic path, and the resident never writes `MBState` or calls
  `PPostEvent`. The fixed wire reserves those slots for v0.5a.
- The resident timer writes only preallocated state and mouse-position low
  memory. It does not enqueue Continuity work for the global jGNE filter.
- The PPC NOW application performs the balanced `HideCursor`/`ShowCursor`
  redraw from its own cooperative pump. It does not call Cursor Device Manager.
- Native takeover observes `RawMouse` only. The physical CursorDevice record
  belonging to the PowerBook's ADB trackpad is neither read nor mutated by
  Continuity.

The source guard was mutation-proved against three exact regressions: adding a
button-global write, adding a Cursor Device call to the timer, and removing the
application-redraw flag so the timer recreated global jGNE debt. Each mutated
tree failed for the named invariant.

Cold-boot campaigns then passed on both `mac99,via=pmu` (USB mouse) and
`mac99,via=cuda` (ADB mouse) with resident 1.12 fingerprint
`d0ef99d20320b8352a6472764414cfc6e71d1ec5`. Each rig independently proved its
native device first, then completed 180 movement positions at 30 Hz, kept the
wire live across a native click, exited optimistically on native motion,
disarmed a fresh epoch, accepted native motion after release, recovered from a
TCP authority-lane loss, armed again, and disarmed cleanly. The PMU receipt is
`run/continuity-v0-pmu-1.12-r2/continuity-r3/continuity-fault.json`; CUDA is
`run/continuity-v0-cuda-1.12/continuity/continuity-fault.json`.

Those runs also caught two harness defects rather than laundering them into
resident findings. Evidence capture initially consumed most of the 90-tick
lease before the native-motion stimulus, so it was moved after the liveness
checks. A physical device already clamped at the chosen edge could not move
farther in that direction, so the rig now retries toward the opposite edge.
The earlier PMU false takeover was a resident defect: after dropping physical
CursorDevice reads, the sampler initially classified the timer's own RawMouse
write as native input. Resident 1.12 now remembers recent owned low-memory
points and samples RawMouse immediately before the timer overwrites it, which
preserves optimistic ADB/USB escape without inspecting the physical device.

This is emulator-tested, not metal-verified. The first branch-private bake
attempt stopped safely when the staging boot's anchor reset; its orphan was
recovered through its owning QMP socket and guest-cleanly shut down. A second
attempt baked the exact fingerprint into
`agent-stage/now-stage-continuity-v0-1.12-no-event-manager.qcow2`, SHA-256
`55bdb4237d46ce11d223f41834a7c5e03f5604ac5c33fb9cc582ea80abaa0eae`.
The guest reported resident 1.12 with capabilities `1023`, the full census
survived, `qemu-img check` passed, shutdown was guest-clean, and the HFS volume
was cleanly unmounted. The shared oracle was not touched by this lane.

### First 1.12 handoff refused by Local Network privacy

The first signed 1.12 host handoff did not reach Continuity. At 17:22:05 its
app-owned permission browser reported `.ready` and the host log called Local
Network access ready. At 17:25:25 the real UDP lane was nevertheless refused
with `Network.NWError` 50 and an unsatisfied path naming `Local network
prohibited` on `en7`. Bundle inspection showed the expected
`NSLocalNetworkUsageDescription`, `_newoldworld._tcp` declaration, team
`B93A9CG7F9`, and application identifier. The false claim was therefore our
probe contract: `NWBrowser.State.ready` is not proof that privacy admitted LAN
traffic on this macOS build.

The first repair published a uniquely named `_newoldworld._tcp` listener and
browsed for that same service. A later 1.16 handoff proved that even observing
the app's own Bonjour publication was not useful permission evidence: at
21:48:18 the probe completed, while at 21:48:26 the real unicast UDP lane was
still refused with `Local network prohibited` on `en7`.

That replacement handoff also exposed a second request failure.
At 17:40:17 its `NWListener` failed before publication with POSIX `EINVAL`:
the no-payload TCP probe had no `newConnectionHandler`, which
Network.framework requires before `start`. The probe now installs a bounded
handler that immediately cancelled unexpected connections. Its focused
runtime test reproduced the exact `EINVAL` when that handler was removed.

The 14:45 signed handoff established that solicitation and proof are two
different operations. It queued a real datagram to the guest, and macOS still
returned `Local network prohibited` on `en7` without presenting a prompt. The
next correction therefore restores the app-owned Bonjour browse/advertise
operation solely as Apple's privacy-prompt trigger; discovering that service,
browser readiness, and listener readiness never confirm access. In parallel,
the host opens the UDP path to the active guest and queues a small discard-port
datagram. Only that direct path reaching `.ready` confirms access.

Network.framework chooses the interface from the route; the code does not name
`en0`, `en7`, Wi-Fi, or Ethernet. Both operations remain alive while macOS
presents its prompt, and their states plus the selected path/interface are
logged. **Open Settings…** remains necessary after a saved denial because
macOS has no public API to reset this privilege to undetermined. Source,
manifest, signed-build, and injected-operation gates require both sides of the
split: app launch solicits without a guest, while direct verification requires
one. They refuse interface pinning and prevent prompt readiness from becoming
authorization evidence. The full invariant is in the
[Local Network access contract](local-network-access.md). This is tested host
behavior; the PowerBook run remains the metal gate.

The 14:59 run of signed build `1db72e80` did **not** isolate the remaining
failure outside NOW. Although macOS 27 beta 4 build `26A5388g` has Apple-known
Local Network privacy defect `r. 181140179`, this same development machine had
already presented NOW's prompt successfully. The application history exposed
the regression: `f46c18fd` and `96513cc6` requested the app capability at
launch, independent of Continuity and of whether a guest was connected;
`33d19759` removed that request, made Continuity own solicitation, removed the
Bonjour declarations, and changed the gate to reject the previously working
shape. `1db72e80` restored Bonjour but left ownership inside Continuity.

The corrected invariant is structural and is stated once in the
[Local Network access contract](local-network-access.md): launch performs the
app-owned prompt operation without a guest target; Continuity separately
verifies its real UDP path and can never own the privacy request. The build
gate now requires that split. The beta-4 OS defect remains a test-environment
risk to recheck on newer
build `26A5406e`, not an explanation that closes the NOW regression. An
unsupported privacy-state reset is not part of the test procedure.

### Fourth metal failure: low-memory mouse globals are not an injection API

The fresh-identity 1.12 handoff reached the PowerBook cleanly. Its host log
confirmed Local Network access at 17:58:45, the PPC application at 17:58:46,
resident 1.12 at 17:58:56, and a ready UDP pointer lane at 17:59:07. The person
then observed the same whole-machine input wedge as the preceding candidates.
The resident liveness channel stopped answering at 18:00:11 and the PPC
application connection was lost at 18:00:19. Permission and connection setup
are therefore ruled out again.

This run falsifies the last mechanism inherited from the cursor-latency spike.
Although 1.12 called no Cursor Device, Event, QuickDraw, or Event Manager API
from its timer, it still wrote `MTemp`, `RawMouse`, and `MouseLocation` directly
from an unrelated Time Manager interrupt. Those globals are downstream of the
PowerBook's ADB/PMU input path; emulator position fidelity was not evidence
that racing that hardware-owned path was safe. Resident 1.13 quarantines P9
again and exposes no Continuity capability.

The next mechanism had to own the device it reports through. It could neither
reuse the first physical Cursor Device nor bypass the manager by writing its
downstream low-memory globals. The resulting safety contract requires an
extension-owned absolute `CursorDeviceNewDevice` record, capability publication
only after creation and configuration succeed, and native ADB motion retaining
optimistic takeover authority. Resident 1.14 implements that contract; the
bounded metal result below covers one placement and one takeover, not the
complete matrix.

### Resident 1.14: extension-owned absolute device

Resident 1.14 implements that ownership boundary. P8 may still discover the
first physical cursor record for its existing task-time visual service, but P9
never stores or reports through it. At boot the extension creates a separate
record with `CursorDeviceNewDevice`, marks it absolute, configures one button
and 72 dpi, and publishes P9 only after every step succeeds. Partial setup is
disposed and remains unsupported. During an epoch the timer calls only
`CursorDeviceMoveTo` on that owned record; it no longer writes `MTemp`,
`RawMouse`, `MouseLocation`, cursor globals, or any physical-device field.

The owned-device source guard was mutation-proved by retargeting the report to
the first physical device and watching both ownership assertions fail. It also
pins the absence of downstream low-memory writes, device allocation and
configuration, QuickDraw, and Event Manager from the timer path. The four new
68K selector shims plus setup increased the INIT resource fork from 84,148 to
84,612 bytes in the final candidate build.

Cold PMU/USB and CUDA/ADB rigs each first proved native movement and a real
`CursorData.buttonCount` down/up transition, then exercised resident 1.14
fingerprint `1d5317ff7380bda7891d9c27de08fff9d307343d` with capabilities
`1023`. Each completed 180 absolute positions at 30 Hz, exited guest-side on a
physical button press while the wire remained live, re-armed and exited on
physical motion, explicitly disarmed another epoch, returned to native motion,
recovered from TCP authority loss, armed once more, and disarmed cleanly. Both
had zero rejected datagrams; PMU needed two state retries and CUDA needed none.
Both guests shut down through Finder.

The receipts are
`run/continuity-owned-pmu-1.14-button/continuity/continuity-fault.json` and
`run/continuity-owned-cuda-1.14-button/continuity/continuity-fault.json`.
The tools now canonicalize QMP evidence paths after relative `pmemsave` and
`screendump` targets exposed that QEMU resolves them in its own working
directory. Before the attended handoff this was emulator evidence only; it did
not erase the four PowerBook failures or authorize a metal claim by itself.

The exact resident was then baked into the branch-private image
`agent-stage/now-stage-continuity-owned-1.14.qcow2`, SHA-256
`e383b794bdf862cde2aced7135663a0df186adc0e15762e9138e9c5cc3c27a8a`.
The guest reported the expected fingerprint and all capabilities, survived all
14 census probes, shut down through Finder, passed `qemu-img check`, and left a
clean HFS volume. The shared oracle was not touched.

### First bounded PowerBook result

On 2026-08-10 the attended PowerBook 1400c test installed the matched PPC guest
and resident 1.14 from commit `e81b2155`. One host-pointer movement completed
successfully. Physical trackpad input then reclaimed control guest-side, and
native control returned. This is the first Continuity candidate to cross both
steps on the PowerBook after four wedging predecessors.

The honest status is **bounded metal evidence**, not full metal verification.
The run covered exactly one remote position and one native takeover. Next are
small repeated movements with takeover between each group, then sustained
15 Hz before 30/60 Hz, followed by lease and TCP-loss recovery. Click-only
takeover, host click pass-through, drag, repeated cold boot/shutdown, disable,
and removal remain unverified.

### Fifth PowerBook wedge: the bounded pass did not generalize

The next attended run used the same exact guest and resident at the configured
30 Hz. It produced about one second of smooth host-driven motion, then the
PowerBook wedged with the ordinary pointer cursor still drawn. Native pointer
movement, clicks, and keyboard input stopped; the application connection later
dropped, followed by resident liveness. The host log identifies PPC build
`aed6759c668e`, resident 1.14, a ready UDP lane at 19:19:09, application loss at
19:20:11, and resident loss at 19:20:17.

This invalidates the preceding one-position result as a general safety claim.
It remains evidence that one placement and one takeover completed, but repeated
placement is unsafe. Resident 1.14 still had two manager operations in its
route: `CursorDeviceMoveTo` on the extension-owned device from the Time Manager
task, followed by a legacy balanced `HideCursor`/`ShowCursor` in the PPC pump.
The run does not discriminate between them, so both are revoked. Resident 1.15
clears P9 again. A replacement must perform the owned-device move only through
an explicit PPC cooperative-pump-to-resident call and must not redraw with
`HideCursor`/`ShowCursor`.

### Resident 1.16: cooperative app-pump service

Resident 1.16 implements that replacement at commit `623f1634`. Continuity V2
appends a raw relocated 68K service address to the shared cell. The PPC app
resolves `CallUniversalProc` from InterfaceLib, wraps the address in a
`kM68kISA | kOld68kRTA` descriptor, and enters it with no arguments from every
ordinary and nested wire pump. The resident consumes the shared cell, samples
native input, applies at most the newest point to its owned absolute Cursor
Device, publishes status, and returns. V1 is refused by the new app.

The exact physical-device retarget and missing-pump-call mutations each made
their guards fail by name. `scripts/test-all` then passed all documentation,
image-discipline, 162 native, MirrorKit, guest/extension cross-build, and host
Debug/Release stages.

Independent cold PMU/USB and CUDA/ADB preflights proved native movement, a
real `CursorData.buttonCount` 1-to-0 transition, and wire liveness. Separate
fresh boots then each applied 900 positions over 30 seconds at 30 Hz, exited
on a native click with the wire live, exited independently on native motion,
disarmed, returned to native motion, survived TCP loss/reconnect, armed a fresh
epoch, disarmed again, and shut down through Finder. PMU used four state
retries, CUDA one; both rejected zero datagrams. The receipts are
`run/continuity-app-pump-pmu-1.16/continuity/continuity-fault.json` and
`run/continuity-app-pump-cuda-1.16/continuity/continuity-fault.json`.

This is stronger emulator evidence than 1.14's 180-position runs, but every
failed PowerBook candidate also passed an emulator campaign. The exact resident
was privately baked into
`agent-stage/now-stage-continuity-app-pump-1.16.qcow2`, SHA-256
`5c62381f29a42929a6dbfc71115bf48819cee102358cecf100ea1a969b00e6f7`.
The guest reported fingerprint `17b5b866d60e62866b2098d4b8cf827c822d69e9`
and capabilities `1023`, survived all 14 census probes, shut down through
Finder, passed `qemu-img check`, and left a clean HFS volume. The shared oracle
was untouched. Resident 1.16 is not metal-verified and is not ready for
promotion until an attended PowerBook test widens exposure from a single
movement deliberately.

### Sixth PowerBook wedge: generic Mixed Mode was not the PPC CDM ABI

That attended resident 1.16 run falsified the cooperative resident-call route.
The pointer moved briefly, the host left and re-entered Mirror, and another
brief movement ended on the wristwatch with native pointer, click, and keyboard
input unresponsive and both NOW connections lost. This was the same
system-wide liveness failure, even though the route had no Continuity timer,
global jGNE service, low-memory writes, or QuickDraw redraw.

The missing constraint is explicit in Apple Universal Interfaces'
`CursorDevices.h`: PowerPC clients must link `CursorDevicesGlue.o` and the
appropriate InterfaceLib because the original ROM Mixed Mode transition for
Cursor Device Manager was incorrect. Resident 1.16 instead crossed a generic
`kM68kISA | kOld68kRTA` descriptor and then issued the raw AADB dispatch from
resident C. QEMU accepting that transition did not establish the hardware ABI.

Resident 1.17 introduces Continuity V3. The Extension now owns only bounded
arbitration, native-input observation, a request/result cell, and an
allocation-free eight-entry trace ring. The cooperative PPC app creates,
configures, retains, moves, and finally disposes the synthetic absolute device
through the corrected fallback transition disassembled from Apple's supplied
`CursorDevicesGlue.o`: runtime-resolved `NGetTrapAddress($AADB, ToolTrap)` and
`CallUniversalProc`, with Apple's exact selector-specific `ProcInfoType`
values. Linking that object plus Retro68's monolithic `libInterfaceLib.a`
directly made this Carbon CFM application unload before `main` on Mac OS 9.1,
so both entry points are resolved from InterfaceLib by name and the final PEF
is required to import CarbonLib but not InterfaceLib. It writes sampled and
volume-flushed `move begin`/`move return` breadcrumbs around the manager call.
Thus a future fault can distinguish "manager did not return" from "manager
returned and resident commit stalled" without logging from foreign or
interrupt context.

The first PMU run after that correction also fixed the fault instrument: it
had waited for every UDP acknowledgement before sending the next absolute
state. One coalesced ACK therefore stopped keepalives and correctly exercised
the 90-tick deadman lease, not sustained cursor motion. The rig now streams at
30 Hz like the host and drains ACKs observationally. A 900-position PMU run
then passed click takeover, movement takeover, disarm, TCP reconnect,
re-arm/disarm, and native return.

The next clean-boot PMU run then reproduced the system wedge at streamed
sequence 416. Its power-cut clone retained the decisive platter trace: every
UDP packet emitted `writer: REFUSED - binary is not 'New Old World'` before
the final sampled `move begin n=120 seq=413`, which had no return. The notifier
was calling `cell()`, and `cell()` called `now_peek_table()`; that task-time
path validates Process Manager identity, renews the writer lease, and logs.
Thus the supposedly bounded OT callback was re-entering Process Manager and
filesystem work at packet rate, including during the Cursor Device call. The
notifier now receives only a stable cell pointer cached during task-time arm;
the source guard rejects table resolution, logging, allocation, Process
Manager calls, or volume flushes in `accept_datagram`. Application shutdown
revokes the epoch and cached pointer before removing and closing the notifier.
Exact app build `55302ed3deef` and resident fingerprint
`31fba85add055dfed4c7581af559c42904d916b1` subsequently passed independent
cold PMU/USB (`/private/tmp/c117-pmu-i6`) and CUDA/ADB
(`/private/tmp/c117-cuda-i1`) campaigns. Each streamed 900 positions over 30
seconds at 30 Hz, exercised click and movement takeover, disarmed, lost and
reconnected the TCP authority lane, armed a fresh epoch, returned to native
input, rejected zero datagrams, and shut down through Finder. CUDA's platter
log recorded 19 sampled `move begin` lines and 19 returns with zero
`writer: REFUSED` lines. A final 180-position PMU run after the one-shot
terminal-report correction repeated the same lifecycle on the exact app build.
This is negative emulator evidence against the repaired callback boundary, not
evidence that a PowerBook cannot still expose a different hardware fault.
The complete native/host gate passed, and the branch-private bake at commit
`286104bb` verified that resident in
`agent-stage/now-stage-continuity-1.17-callback-safe.qcow2`, SHA-256
`6dd741efe4f31ab29ed9b32236fd8adcbc10bd6c7d3b50c0d29f6ed4185014e1`.
The guest reported the exact fingerprint and all 1023 capabilities, survived a
full census, shut down through Finder, left a clean HFS volume, and passed
`qemu-img check`. Nothing shared was baked or promoted. These prerequisites
permit a bounded seventh attended run; they do not make it metal-verified.

### The first 1.17 metal handoff did not reach the resident

The 2026-08-11 host/guest logs separate the next failed handoff from the six
wedges above. TCP arm succeeded and the host queued 70 UDP states, but the
guest reported zero accepted, stale, or malformed packets, zero ACK attempts,
and zero resident applies before its five-second arming grace expired. The
resident was never called with a host point, so that run is negative transport
evidence rather than another cursor-placement failure.

The application had been reporting the requested TCP preference as
`udpPort`, not the address returned by `OTBind`. XTI may return an alternate
bound address. The corrected guest validates the returned Internet address,
retains its actual nonzero port, reports that port in all three Continuity
report shapes, and logs requested/bound together. Whether the PowerBook's OT
provider actually substituted a port remains a metal question; the correction
removes the false `armed` contract either way.

Commit `b0c9386b` cross-builds without InterfaceLib. The mutation guard fails
if any Continuity report returns `g.port` again. A private mac99/OS 9.1 clone
then identified guest source hash `0a971610715f`, resident source manifest
`333cbb2c57b1`, and fingerprint `31fba85add05`. The dedicated
`tools/continuity-probe.py` arm reported UDP 15465, sent one fixed-size state
through QEMU's same-numbered UDP forward, received an active ACK for position
sequence 1 with zero rejects, and disarmed with one accepted and applied
packet. Finder powered the guest off and QEMU exited. This is emulator-tested
transport and lifecycle, not a PowerBook safety result; quarantine remains.

### Seventh PowerBook run: accurate movement, cadence still open

The corrected transport then reached resident 1.17 on the PowerBook 1400c.
The attended 2026-08-11 run produced accurate host-driven pointer movement
without the immediate whole-system wedge seen in the six preceding routes.
This is the first metal verification of repeated v0 movement through the V3
PPC Cursor Device Manager path. It does not verify clicks or dragging, which
remain later stages.

Motion was visibly jittery, and changing the configured host rate among 15,
30, and 60 Hz produced roughly the same perceived smoothness. That makes the
next investigation a measured cadence problem rather than another safety-route
rewrite: record host states queued, UDP states accepted, resident service
calls, PPC applies, ACK coalescing, and inter-apply timing for each selected
rate. The current observation does not establish that the requested rates
reach the guest distinctly, nor does this bounded run establish long-duration
stability, lease/TCP-loss recovery, repeated native takeover, reboot/disable,
or removal behavior.
