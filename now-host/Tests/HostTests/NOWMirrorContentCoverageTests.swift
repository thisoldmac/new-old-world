import XCTest
import MirrorKit
import MirrorKitUI
@testable import Host

/// The coverage gate for host-side interior composition (plan 013 and its
/// follow-up): every fixture here is a drain captured LIVE off a mac99
/// guest on 2026-08-06, one per surface the mirror must compose —
/// the three Finder views (composited, joined via blitsrc), two
/// non-compositing control panels (window-port drawing, no join needed),
/// and NOW's own window. Each test is the two halves meeting on real
/// bytes; none of it has touched metal.
///
/// The one NEGATIVE from the same runs is documented rather than gated:
/// Appearance builds a transient world per widget blit, which beats the
/// sight→chase→hook cycle (10 misses, 136 small sights) — the case the
/// D0 resident NewGWorld patch exists to close. See open-issues.md.
@MainActor
final class NOWMirrorContentCoverageTests: XCTestCase {
    private func plane() -> NOWMirrorContentPlane {
        NOWMirrorContentPlane(listener: GuestListener(
            identity: .init(version: "test", name: "Test Host")))
    }

    /// The canned scene, with windows[0] re-identified as the CAPTURED
    /// window — address, psn, title, AND geometry.
    ///
    /// Identity alone was not enough, and the render said so: a capture
    /// dropped into another application's window rect drew Sherlock's
    /// 490×448 interior inside a 404×203 Finder window, complete with
    /// the Finder's own scrollbars, which is a picture of a join that
    /// never happened. The window's real content size is carried by the
    /// capture itself — the full-window blit's `dst` IS the content
    /// rect — so `contentSize` takes it from there, and every control
    /// and item belonging to the canned window is cleared, because
    /// those are another application's furniture.
    private func scene(address: UInt32, psn: String, title: String,
                       content: [Int]? = nil) throws -> MirrorKit.Scene {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "now-scene-ir-v1", withExtension: "json",
            subdirectory: "Fixtures"))
        var value = try NOWMirrorSceneDecoder.decode(
            irVersion: 1, document: Data(contentsOf: url))
        for index in value.windows.indices {
            value.windows[index].front = false
            value.windows[index].psn = "0.99999999"
        }
        value.windows[0].front = true
        value.windows[0].addr = address
        value.windows[0].psn = psn
        value.windows[0].title = title
        value.windows[0].display = nil
        value.windows[0].controls = []
        value.windows[0].items = nil
        if let content, content.count == 4 {
            let origin = value.windows[0].rect
            value.windows[0].rect = MirrorKit.Rect(
                l: origin.l, t: origin.t,
                r: origin.l + (content[2] - content[0]),
                b: origin.t + (content[3] - content[1]))
        }
        return value
    }

    /// The captured window's own content size, derived from what the
    /// application actually drew into it: the union of every op's
    /// bounds on the window port.
    ///
    /// The first version took the largest blit's destination, which is
    /// exactly right for a compositing application and NONSENSE for one
    /// that does not composite - Date & Time's biggest blit is an icon,
    /// so its panel rendered as a sliver. A union covers both: a
    /// composite's full-window blit dominates it, and a panel's spread
    /// of controls and labels describes it just as well.
    private func contentSize(_ drain: QDTraceDecode.Drain,
                             window: UInt32) -> [Int]? {
        var right = 0
        var bottom = 0
        for record in drain.records where record.portAddress == window {
            let op = record.op
            for box in [op.dst, op.rect].compactMap({ $0 })
            where box.count == 4 {
                right = max(right, box[2])
                bottom = max(bottom, box[3])
            }
            if op.op == "text", let pen = op.pen, pen.count == 2 {
                right = max(right, pen[0])
                bottom = max(bottom, pen[1])
            }
        }
        guard right > 32, bottom > 32 else { return nil }
        return [0, 0, right, bottom]
    }

    private func capture(_ name: String) throws -> QDTraceDecode.Drain {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "json",
            subdirectory: "Fixtures"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any])
        let drain = try XCTUnwrap(QDTraceDecode.drain(object))
        XCTAssertTrue(drain.recordCountAgrees, "\(name) decodes whole")
        return drain
    }

    private func compose(_ fixture: String, window: UInt32, psn: String,
                         title: String) throws -> [DisplayOp] {
        try composed(fixture, window: window, psn: psn, title: title)
            .windows[0].display ?? []
    }

    /// The whole composed scene, with the window sized from the capture.
    @discardableResult
    private func composed(_ fixture: String, window: UInt32, psn: String,
                          title: String) throws -> MirrorKit.Scene {
        let drain = try capture(fixture)
        let model = plane()
        let update = model.apply(
            drain,
            to: try scene(address: window, psn: psn, title: title,
                          content: contentSize(drain, window: window)))
        XCTAssertNotNil(update.scene.windows[0].display,
                        "\(fixture) composed nothing")
        return update.scene
    }

    private func texts(_ display: [DisplayOp]) -> [String] {
        display.filter { $0.op == "text" }.compactMap(\.text)
    }

    // MARK: - The Finder's three views, all composited and joined

    func testFinderListViewComposesHeadersRowsAndDates() throws {
        let display = try compose("qdtrace-drain-blitsrc-finder-list",
                                  window: 0x00a03580, psn: "0.29949953",
                                  title: "Macintosh HD")
        let labels = texts(display)
        for header in ["Name", "Date Modified", "Size"] {
            XCTAssertTrue(labels.contains(header), "missing header \(header)")
        }
        XCTAssertTrue(labels.contains("System Folder"))
        XCTAssertTrue(labels.contains { $0.hasPrefix("Tue, Jul 14, 2026") },
                      "a row's real modification date crosses")
        XCTAssertFalse(display.contains { $0.op == "bits"
            && ($0.dst?.count == 4) && ($0.dst![2] - $0.dst![0]) > 300 },
            "the full-window blit was replaced by the join")
    }

    func testFinderButtonViewComposesItsLabels() throws {
        let display = try compose("qdtrace-drain-blitsrc-finder-buttons",
                                  window: 0x00a03580, psn: "0.29949953",
                                  title: "Macintosh HD")
        let labels = texts(display)
        for label in ["Applications (Mac OS 9)", "Documents", "TimBotTu"] {
            XCTAssertTrue(labels.contains(label), "missing \(label)")
        }
    }

    // The icon view is the original payoff gate in
    // NOWMirrorContentPlaneTests.testFinderCaptureComposesTheRealInteriorHostSide.

    // MARK: - Control panels: no composite, no join — the window port
    // carries everything, and the plane must pass it through untouched.

    func testDateAndTimePanelRecordsItsInterior() throws {
        let display = try compose("qdtrace-drain-cp-datetime",
                                  window: 0x1f6fd220, psn: "0.35520514",
                                  title: "Date & Time")
        let labels = texts(display)
        for label in ["Current Date", "Current Time", "Time Zone"] {
            XCTAssertTrue(labels.contains(label), "missing \(label)")
        }
    }

    func testMemoryPanelRecordsItsInterior() throws {
        let display = try compose("qdtrace-drain-cp-memory",
                                  window: 0x1e9dffa0, psn: "0.36438017",
                                  title: "Memory")
        XCTAssertTrue(texts(display).contains("Startup Memory Tests"))
    }

    /// Renders every capture at its own size, for eyes rather than
    /// assertions. Opt-in: NOW_RENDER_DIR names a directory.
    func testRenderEveryCapture() throws {
        guard let dir = ProcessInfo.processInfo
            .environment["NOW_RENDER_DIR"] else { return }
        let all: [(String, String, UInt32, String, String)] = [
            ("finder-icon", "qdtrace-drain-blitsrc-finder",
             0x00a01c40, "0.29949953", "Macintosh HD"),
            ("finder-list", "qdtrace-drain-blitsrc-finder-list",
             0x00a03580, "0.29949953", "Macintosh HD"),
            ("finder-buttons", "qdtrace-drain-blitsrc-finder-buttons",
             0x00a03580, "0.29949953", "Macintosh HD"),
            ("cp-datetime", "qdtrace-drain-cp-datetime",
             0x1f6fd220, "0.35520514", "Date & Time"),
            ("cp-memory", "qdtrace-drain-cp-memory",
             0x1e9dffa0, "0.36438017", "Memory"),
            ("now-window", "qdtrace-drain-now-window",
             0x1ecb4550, "0.29360131", "New Old World"),
            ("sherlock", "qdtrace-drain-sherlock-hooked",
             0x1e99ffc0, "0.35520514", "Sherlock 2"),
        ]
        for (name, fixture, window, psn, title) in all {
            let png = try RenderShot.png(scene: try composed(
                fixture, window: window, psn: psn, title: title))
            try png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }

    /// Sherlock 2 WAS the boundary case, and this gate is the boundary
    /// moving. Its whole interior is built in a transient offscreen
    /// world per repaint, which the sight-then-chase route hooked 0 of
    /// 8 times — so none of it could cross. With the resident's
    /// QDExtensions patch hooking every world at CREATION (plan 014),
    /// the same application recorded 77 worlds born, 77 died, 0 missed,
    /// and its interior crosses: this capture is one such world's whole
    /// life, from worldborn through its drawing to the blitsrc+bits
    /// pair that reveals it.
    func testSherlockInteriorComposesFromWorldsHookedAtBirth() throws {
        let display = try compose("qdtrace-drain-sherlock-hooked",
                                  window: 0x1e99ffc0, psn: "0.35520514",
                                  title: "Sherlock 2")
        let labels = texts(display)
        /* The radio labels and column headers the boundary test used to
           assert were UNREACHABLE. */
        for label in ["File Names", "Contents", "Name", "On",
                      "Index Status"] {
            XCTAssertTrue(labels.contains(label),
                          "missing \(label) — the interior stopped crossing")
        }
        /* And the list row, which is content rather than chrome. */
        XCTAssertTrue(labels.contains("Macintosh HD"))
        XCTAssertTrue(labels.contains { $0.hasPrefix("Volume indexed") },
                      "the volume's real index status crosses")
        XCTAssertTrue(update(display), "the composite replaced its hatch")

        if let out = ProcessInfo.processInfo.environment["NOW_RENDER_OUT"] {
            let png = try RenderShot.png(scene: try composed(
                "qdtrace-drain-sherlock-hooked", window: 0x1e99ffc0,
                psn: "0.35520514", title: "Sherlock 2"))
            try png.write(to: URL(fileURLWithPath: out))
        }
    }

    /// The joined blit must not survive as a hatch over the content it
    /// was replaced by.
    private func update(_ display: [DisplayOp]) -> Bool {
        !display.contains {
            $0.op == "bits" && ($0.dst?.count == 4)
                && ($0.dst![2] - $0.dst![0]) >= 490
        }
    }

    // MARK: - NOW's own window, and retention across a retarget

    func testNowWindowComposesItsWorkshop() throws {
        let display = try compose("qdtrace-drain-now-window",
                                  window: 0x1ecb4550, psn: "0.29360131",
                                  title: "New Old World")
        let labels = texts(display)
        XCTAssertTrue(labels.contains("Screenshots"))
        XCTAssertTrue(labels.contains(
            "Capture this Mac, send a still, or stream its screen."))
    }

    /// The hatch behind the Finder: a window captured under one arm must
    /// stay composed (expected-stale) after the plane retargets to
    /// another process — the accumulation is per-arm, the published
    /// display is per-window.
    func testCapturedWindowsStayComposedAcrossARetarget() throws {
        let model = plane()

        /* Each capture composes into a window carrying ITS name: NOW's
           Workshop into the scene's own 'New Old World' window, the
           Finder into a 'Macintosh HD'-titled one. A render that put one
           application's content under another's title read exactly like
           the wrong join this plane exists to refuse. windows[1] (the
           Desktop) attaches a display but renders nowhere, so neither
           capture goes there. */
        var first = try scene(address: 0x00a01c40, psn: "0.29949953",
                              title: "Macintosh HD")
        let nowIndex = try XCTUnwrap(first.windows.indices.first {
            first.windows[$0].title == "New Old World"
        })
        first.windows[nowIndex].addr = 0x1ecb4550
        first.windows[nowIndex].psn = "0.29360131"
        first.windows[0].front = false
        first.windows[nowIndex].front = true
        _ = model.apply(try capture("qdtrace-drain-now-window"), to: first)

        var second = first
        second.windows[nowIndex].front = false
        second.windows[0].front = true
        let update = model.apply(
            try capture("qdtrace-drain-blitsrc-finder"), to: second)

        let now = try XCTUnwrap(update.scene.windows[nowIndex].display,
                                "NOW's window lost its display on retarget")
        XCTAssertTrue(texts(now).contains("Screenshots"))
        let finder = try XCTUnwrap(update.scene.windows[0].display)
        XCTAssertTrue(texts(finder).contains("Documents"))

        if let out = ProcessInfo.processInfo.environment["NOW_RENDER_OUT"] {
            let png = try RenderShot.png(scene: update.scene)
            try png.write(to: URL(fileURLWithPath: out))
        }
    }
}
