import XCTest

/// **The mirror renders a MODEL. Guest pixels reach the screen only through
/// the asset pack.**
///
/// Michelle's rule, stated 2026-08-07 and gated here the same day:
///
/// > the only time we should be using pixels from the guest is when we have
/// > imported those assets as part of our assets pack, so the pixels are
/// > provided by the host and not the wire.
///
/// ## Why this needs a gate and not a note
///
/// "Make it a high-fidelity mirror of the guest" has a cheapest solution, and
/// it is **show the real pixels**. That route scores perfectly against every
/// fidelity measure anyone can write and destroys the product, because the
/// product is a model of the machine and not a photograph of it. Worse, it
/// destroys the measurement too: where the render IS the guest's framebuffer,
/// comparing the render against the guest compares the guest's bytes with
/// themselves, and every score taken over such a window is unfalsifiable.
///
/// That is not hypothetical here. `PixelIsland` did exactly this from 1 August
/// to 7 August 2026 — `ScenePoller` fetched framebuffer bytes with
/// `wire.captureRegion` and `SceneRenderer` drew them in place of the content
/// for any window without a named item roster. Nobody decided to do it: it
/// arrived as a passenger inside a wholesale vendoring of the Mirror
/// subproject, and no individual diff looked wrong.
/// (`archive/pixel-islands-2026-08-07/`, `docs/the-drive-and-the-islands.md`.)
///
/// ## Both sets are derived from source
///
/// There is no list of forbidden call sites in this file, deliberately: a
/// hand-kept list of violations rots, and this repository was bitten three
/// separate times in one day by enumerations that were true when written.
/// `CommandParityTests` is the shape being copied — read the source, build
/// both sides, compare.
///
/// ## What it covers
///
/// 1. **Origin.** No file on the render path may both build a bitmap out of
///    bytes and hold the guest wire. Those are the two halves of a
///    photograph; keeping them in different files is not the point, keeping
///    them from meeting is.
/// 2. **Carriage.** No type the scene can reach may carry a raw byte buffer.
///    This is the one that names `PixelIsland` the moment it returns, because
///    that struct's whole substance is `rgba: Data`.
/// 3. **Separation.** The screenshot path — which shows guest pixels on
///    purpose, labelled as a photograph, in the Screenshots and Processes
///    modules — must never be referenced from the mirror's own render.
///
/// ## What it does NOT cover, stated plainly
///
/// - It is **file-granular**, not dataflow. Splitting a capture across two
///   files that never name each other's markers would pass. It raises the
///   cost of the mistake from "nobody noticed" to "somebody worked at it".
/// - It reads **text**, so a wire call assembled from string fragments, or a
///   pixel buffer typed through a generic, is invisible to it.
/// - It says nothing about **whether the pack's own art is right**. Wrong art
///   from the pack is a fidelity bug; guest art off the wire is this one.
/// - It cannot see the **guest side** at all. A guest that volunteered pixels
///   in a scene field would be caught by rule 2 only once the host declared
///   somewhere to put them.
/// - IR membership is deliberately **not** the test. `Scene.Window.island` was
///   excluded from the frozen IR and never encoded, and still reached the
///   screen every frame — being off the wire is not being out of the render.
///
/// ## The override is hers
///
/// `NOW_ALLOW_GUEST_PIXELS=1` with `NOW_ALLOW_GUEST_PIXELS_REASON="…"` lets a
/// deliberate crossing through, and writes the reason into
/// `docs/guest-pixel-overrides.json` so it lands in the same commit as the
/// work it excuses — the shape `TBT_DEFER_EXT_BAKE` already uses here. The
/// flag **without** a reason still refuses: an override whose reason is
/// missing is indistinguishable from the mistake it would be excusing.
final class GuestPixelsGateTests: XCTestCase {

    // MARK: - The tree

    private var nowRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HostTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // now-host
            .deletingLastPathComponent()   // now
    }

    /// **The render path**: everything that decides what appears in the
    /// mirror's own drawn canvas. Derived by walking the directories, so a new
    /// file is inside the gate the moment it exists.
    ///
    /// `now-host/Sources/Host/Mirror*.swift` is included because the host's
    /// mirror models sit between the vendored renderer and the app, and a
    /// shelf added there would reach the screen exactly as `island` did.
    private func renderPathSources() throws -> [(name: String, text: String)] {
        var out: [(String, String)] = []
        for dir in ["mirror/host/MirrorKit/Sources/MirrorKit",
                    "mirror/host/MirrorKit/Sources/MirrorKitUI"] {
            let url = nowRoot.appendingPathComponent(dir)
            for file in try FileManager.default
                .contentsOfDirectory(atPath: url.path).sorted()
                where file.hasSuffix(".swift") {
                out.append((dir + "/" + file, try String(
                    contentsOf: url.appendingPathComponent(file),
                    encoding: .utf8)))
            }
        }
        let host = nowRoot.appendingPathComponent("now-host/Sources/Host")
        for file in try FileManager.default
            .contentsOfDirectory(atPath: host.path).sorted()
            where file.hasPrefix("Mirror") && file.hasSuffix(".swift") {
            out.append(("now-host/Sources/Host/" + file, try String(
                contentsOf: host.appendingPathComponent(file),
                encoding: .utf8)))
        }
        XCTAssertGreaterThan(out.count, 40,
                             "the render path came back nearly empty, so "
                             + "every assertion below would pass vacuously — "
                             + "the directories moved, not the rule")
        return out
    }

    /// Turning bytes into a picture. Every one of these takes a buffer and
    /// hands back something drawable; none of them can be reached without a
    /// buffer to hand it.
    ///
    /// This is only half the vocabulary. The other half is derived at test
    /// time from the tree itself — `pixelCarryingTypes()` — because the shape
    /// the violation actually took was not a `CGImage` next to a socket: it
    /// was a struct called `PixelIsland` whose substance was `rgba: Data`,
    /// decoded from the wire in one file and turned into an image three files
    /// away. Naming a pixel-carrying type in a file that holds the wire is
    /// the same offence a step earlier, and it is the step that is legible.
    private static let bitmapFromBytes = [
        "CGDataProvider(data:",
        "CGImageSourceCreateWithData(",
        "NSBitmapImageRep(data:",
    ]

    /// Holding the guest wire. `WireClient` is the only thing in this tree
    /// that speaks to the machine, so naming it — or calling through one — is
    /// what "can obtain guest bytes" means.
    private static let guestWire = [
        "WireClient",
        "wire.request",
        "try wire.",
        "captureRegion",
    ]

    // MARK: - 1. Origin

    /// **A file may build pictures, or hold the wire. Not both.**
    ///
    /// Watched failing by mutation (2026-08-07): restoring `captureRegion`
    /// into `ScenePoller.swift` — which already calls `wire.request` — fails
    /// this naming that file and quoting both halves.
    func testNoRenderFileBothBuildsBitmapsAndHoldsTheGuestWire() throws {
        let carriers = try pixelCarryingTypes()
        var offenders: [String] = []
        for (name, text) in try renderPathSources() {
            var builds = Self.bitmapFromBytes.filter { text.contains($0) }
            builds += carriers.keys.filter { text.contains($0) }
                .map { "the pixel-carrying type `\($0)` (\(carriers[$0]!))" }
            let wires = Self.guestWire.filter { text.contains($0) }
            guard !builds.isEmpty, !wires.isEmpty else { continue }
            offenders.append("""
                \(name)
                    handles pixels:           \(builds.joined(separator: ", "))
                    and holds the guest wire: \(wires.joined(separator: ", "))
                """)
        }
        assertOrPermit(offenders, rule: "origin", """
            A file on the mirror's render path both constructs a bitmap from a \
            byte buffer and can obtain bytes from the guest. Those two halves \
            together are a photograph, and a photograph of the guest is the \
            one thing the mirror must not be: it scores perfectly against the \
            machine because it IS the machine, and every render measurement \
            taken over it is comparing the guest's pixels with themselves. \
            Guest-originated pixels reach the screen through the asset pack \
            (IconAtlas / BitmapFont / DesktopPattern read AssetPack.root) or \
            not at all.
            """)
    }

    // MARK: - 2. Carriage

    /// **Types declared in the vendored MirrorKit that are bitmaps.**
    ///
    /// Derived, not listed — what makes a type a bitmap is visible in its own
    /// declaration, and it is two things together: a raw byte buffer AND the
    /// geometry that says how to read it as pixels. Both halves are required
    /// on purpose. `WireClient` holds a `Data` reply line and is not a
    /// picture; `PixelIsland` held `rgba: Data` beside `width`/`height` and
    /// was nothing else. A gate that flagged every `Data` in the tree would
    /// have to be silenced within the day, and a silenced gate is worse than
    /// none.
    private func pixelCarryingTypes() throws -> [String: String] {
        var carriers: [String: String] = [:]      // type name -> the property
        let dir = nowRoot.appendingPathComponent(
            "mirror/host/MirrorKit/Sources/MirrorKit")
        let decl = try NSRegularExpression(
            pattern: #"(?:struct|final class|class)\s+([A-Z]\w*)"#)
        let buffer = try NSRegularExpression(
            pattern: #"(?:var|let)\s+(\w+)\s*:\s*(Data|\[UInt8\])\??"#)
        let geometry = try NSRegularExpression(
            pattern: #"(?:var|let)\s+(?:width|height|rowBytes)\s*:\s*Int"#)
        for file in try FileManager.default
            .contentsOfDirectory(atPath: dir.path).sorted()
            where file.hasSuffix(".swift") {
            let text = try String(contentsOf: dir.appendingPathComponent(file),
                                  encoding: .utf8)
            let ns = text as NSString
            let decls = decl.matches(in: text, range: NSRange(location: 0,
                                                              length: ns.length))
            for (i, m) in decls.enumerated() {
                let start = m.range.location
                let end = i + 1 < decls.count
                    ? decls[i + 1].range.location : ns.length
                let body = ns.substring(with: NSRange(location: start,
                                                      length: end - start))
                let bodyRange = NSRange(location: 0,
                                        length: (body as NSString).length)
                guard let hit = buffer.firstMatch(in: body, range: bodyRange),
                      geometry.firstMatch(in: body, range: bodyRange) != nil
                else { continue }
                carriers[ns.substring(with: m.range(at: 1))] =
                    (body as NSString).substring(with: hit.range)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return carriers
    }

    /// **Nothing the scene can reach may carry raw pixels.**
    ///
    /// This is the rule `Scene.Window.island` broke, and note what did NOT
    /// catch it: the field was outside the frozen IR and excluded from
    /// `CodingKeys`, so every wire-shaped gate read green while the pixels
    /// went straight to the renderer. Membership of the scene STRUCT is the
    /// test, because the renderer reads the struct.
    ///
    /// Watched failing by mutation (2026-08-07): restoring `PixelIsland.swift`
    /// and `public var island: PixelIsland? = nil` on `Scene.Window` fails
    /// this naming both the field and `rgba: Data`.
    func testNoTypeReachableFromTheSceneCarriesRawPixels() throws {
        let carriers = try pixelCarryingTypes()
        let sceneURL = nowRoot.appendingPathComponent(
            "mirror/host/MirrorKit/Sources/MirrorKit/Scene.swift")
        let scene = try String(contentsOf: sceneURL, encoding: .utf8)
        let property = try NSRegularExpression(
            pattern: #"(?:var|let)\s+(\w+)\s*:\s*\[?([A-Z]\w*)\]?\??"#)
        let ns = scene as NSString
        var offenders: [String] = []
        for m in property.matches(in: scene, range: NSRange(location: 0,
                                                            length: ns.length)) {
            let field = ns.substring(with: m.range(at: 1))
            let type = ns.substring(with: m.range(at: 2))
            if type == "Data" {
                offenders.append("Scene.swift: `\(field): Data` — a raw "
                                 + "buffer directly on the scene")
            } else if let how = carriers[type] {
                offenders.append("Scene.swift: `\(field): \(type)` — and "
                                 + "\(type) carries `\(how)`")
            }
        }
        assertOrPermit(offenders, rule: "carriage", """
            A type the renderer reads off the scene carries a raw byte \
            buffer. Being absent from the frozen IR is not a defence and \
            never was: `Scene.Window.island` was excluded from the IR, \
            excluded from CodingKeys, never encoded once — and drew the \
            guest's own framebuffer into the mirror for a week. The renderer \
            reads the STRUCT.
            """)
    }

    // MARK: - 3. Separation

    /// **The screenshot path is a photograph on purpose, and stays out of the
    /// render.**
    ///
    /// NOW does show guest pixels: the Screenshots and Processes modules
    /// display captures the human asked for, decoded by `CaptureDecoder`, and
    /// they are labelled as what they are. That is not what this gate is
    /// about — a photograph presented as a photograph misleads nobody. What
    /// must not happen is those bytes finding their way into the mirror's own
    /// canvas, where they would be presented as the model.
    func testTheScreenshotPathIsNotReachableFromTheRender() throws {
        var offenders: [String] = []
        for (name, text) in try renderPathSources() {
            for marker in ["CaptureDecoder", "ScreenshotModel",
                           "decodeCapture("] where text.contains(marker) {
                offenders.append("\(name) names `\(marker)`")
            }
        }
        assertOrPermit(offenders, rule: "separation", """
            The mirror's render path reached for the screenshot decoder. \
            Guest captures are a deliberate, labelled product feature in the \
            Screenshots and Processes modules; the moment they are drawable \
            from the render they stop being labelled and start being the \
            answer.
            """)
    }

    // MARK: - The override

    /// Refuse, unless Michelle said otherwise **and said why**.
    ///
    /// The receipt is written on the permitted path rather than printed,
    /// because a reason that exists only in a terminal a session later throws
    /// away is exactly how the islands got in: every commit was honest and
    /// none of them recorded that a decision had been crossed.
    private func assertOrPermit(_ offenders: [String], rule: String,
                                _ why: String,
                                file: StaticString = #filePath,
                                line: UInt = #line) {
        guard !offenders.isEmpty else { return }
        let env = ProcessInfo.processInfo.environment
        let allowed = env["NOW_ALLOW_GUEST_PIXELS"] == "1"
        let reason = (env["NOW_ALLOW_GUEST_PIXELS_REASON"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = why + "\n\n" + offenders.joined(separator: "\n")

        if allowed && !reason.isEmpty {
            recordOverride(rule: rule, reason: reason, offenders: offenders)
            print("""
                ⚠️  GUEST-PIXEL GATE OVERRIDDEN (\(rule)) — \(reason)
                \(body)
                """)
            return
        }
        if allowed {
            return XCTFail("""
                NOW_ALLOW_GUEST_PIXELS=1 with no \
                NOW_ALLOW_GUEST_PIXELS_REASON. The flag alone is not the \
                override — an unexplained crossing reads exactly like the \
                mistake it would be excusing, which is the whole reason this \
                gate exists. Set the reason and it lands in \
                docs/guest-pixel-overrides.json in the same commit.

                \(body)
                """, file: file, line: line)
        }
        XCTFail("""
            GUEST PIXELS ON THE RENDER PATH (\(rule)).

            \(body)

            If this is deliberate it needs Michelle's explicit approval — \
            NOW_ALLOW_GUEST_PIXELS=1 NOW_ALLOW_GUEST_PIXELS_REASON="…". \
            Do not reach for it to get past a block you should have avoided; \
            the enforcement is the floor, not the rule.
            """, file: file, line: line)
    }

    private func recordOverride(rule: String, reason: String,
                                offenders: [String]) {
        let url = nowRoot.appendingPathComponent(
            "docs/guest-pixel-overrides.json")
        var entries = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }
            as? [[String: Any]] ?? []
        entries.append([
            "recordedAt": ISO8601DateFormatter().string(from: Date()),
            "rule": rule,
            "reason": reason,
            "sites": offenders,
        ])
        if let data = try? JSONSerialization.data(
            withJSONObject: entries,
            options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }
}
