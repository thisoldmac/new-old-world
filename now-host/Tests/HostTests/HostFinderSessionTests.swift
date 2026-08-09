import XCTest
import MirrorKit
@testable import Host

@MainActor
final class HostFinderSessionTests: XCTestCase {
    private var listener: GuestListener!
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() async throws {
        listener = GuestListener(
            identity: .init(version: "test", name: "Host"),
            timing: .init(idleTimeout: 60))
        listener.start(port: 0)
        try await waitUntil("listener") {
            if case .listening = self.listener.state { return true }
            return false
        }
        suiteName = "HostFinderSessionTests.\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: HostFinderSession.preferenceKey)
        defaults.set(false, forKey: HostFinderSession.lifecycleSyncPreferenceKey)
        defaults.set(false, forKey: HostFinderSession.geometrySyncPreferenceKey)
    }

    override func tearDown() async throws {
        listener.stop()
        listener = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = ""
    }

    func testFolderNavigationStaysOnFileListAndSelectionProjectsLocally()
        async throws {
        let guest = try await connectedGuest()
        let session = HostFinderSession(listener: listener, defaults: defaults)
        session.observe(screen: .init(w: 640, h: 480))

        let root = try await answerNextList(
            guest, path: "",
            entries: [entry("Applications", kind: "folder"),
                      entry("Read Me", kind: "file")])
        try await waitUntil("root entries") {
            session.windows.first?.entries.count == 2
        }
        let rootID = try XCTUnwrap(session.windows.first?.id)

        session.select(["Read Me"], in: rootID)
        var projected = session.project(scene())
        XCTAssertEqual(projected.windows.first?.finder?.selectedNames,
                       ["Read Me"])

        session.open(["Applications"], in: rootID)
        _ = try await answerNextList(guest, path: "Applications", entries: [])
        try await waitUntil("folder window") {
            session.windows.first?.path == "Applications"
                && session.windows.first?.complete == true
        }

        XCTAssertFalse(guest.received.contains { message in
            if case .commandRequest = message { return true }
            return false
        }, "opening a folder must not ask the guest Finder to open it")
        XCTAssertNotEqual(root.id, 0)
        projected = session.project(scene())
        XCTAssertEqual(projected.windows.filter(
            FinderItems.isHostOwnedWindow).count, 2)
    }

    func testViewSortAndScrollDoNotSendGuestActs() async throws {
        let guest = try await connectedGuest()
        let session = HostFinderSession(listener: listener, defaults: defaults)
        session.observe(screen: .init(w: 640, h: 480))
        _ = try await answerNextList(
            guest, path: "",
            entries: [entry("z", kind: "file"), entry("a", kind: "file")])
        try await waitUntil("root") { session.windows.first?.complete == true }
        let id = try XCTUnwrap(session.windows.first?.id)
        let before = guest.received.count

        session.setView(.name, in: id)
        session.sort(.name, in: id)
        session.scroll(windowID: id, part: .lineDown)

        XCTAssertEqual(session.windows.first?.view, .name)
        XCTAssertFalse(session.windows.first?.ascending ?? true)
        XCTAssertEqual(guest.received.count, before)
    }

    func testDesktopAndGuestWindowCatalogsProjectWithoutFinderRoster()
        async throws {
        defaults.set(false, forKey: HostFinderSession.preferenceKey)
        let guest = try await connectedGuest()
        let session = HostFinderSession(listener: listener, defaults: defaults)
        let folder = finderWindow(path: "Macintosh HD:Control Panels")
        session.observe(scene: scene(windows: [folder]))

        _ = try await answerNextList(
            guest, path: "Desktop Folder",
            entries: [entry("Read Me", kind: "file")])
        _ = try await answerNextList(
            guest, path: "Control Panels",
            entries: [entry("Mouse", kind: "file")])
        try await waitUntil("semantic catalogs") {
            let projected = session.project(self.scene(windows: [folder]))
            return projected.desktopItems?.contains { $0.name == "Read Me" }
                == true
                && projected.windows.first?.items?.contains {
                    $0.name == "Mouse"
                } == true
        }

        let projected = session.project(scene(windows: [folder]))
        XCTAssertEqual(projected.desktopItems?.first?.name, "Macintosh HD")
        XCTAssertEqual(projected.windows.first?.items?.map(\.name), ["Mouse"])
    }

    func testLifecycleAndGeometryCouplingAreOptimisticAndReconcile()
        async throws {
        defaults.set(true, forKey: HostFinderSession.lifecycleSyncPreferenceKey)
        defaults.set(true, forKey: HostFinderSession.geometrySyncPreferenceKey)
        let guest = try await connectedGuest()
        let session = HostFinderSession(listener: listener, defaults: defaults)
        session.observe(screen: .init(w: 640, h: 480))
        _ = try await answerNextList(guest, path: "", entries: [])

        try await waitUntil("optimistic guest open") {
            guest.received.contains { message in
                guard case .commandRequest(let request) = message else {
                    return false
                }
                return request.name == "script"
            }
        }
        let rootID = try XCTUnwrap(session.windows.first?.id)
        let observed = finderWindow(path: "Macintosh HD", ref: "now-window-42",
                                    rect: Rect(l: 40, t: 50, r: 440, b: 350))
        session.observe(scene: scene(windows: [observed]))
        XCTAssertEqual(session.windows.first?.frame, observed.rect)

        session.windowAct(id: rootID, act: .move(left: 90, top: 100))
        XCTAssertEqual(session.windows.first?.frame.l, 90,
                       "the host moves before the guest answers")
        try await waitUntil("guest geometry act") {
            guest.received.contains { message in
                guard case .commandRequest(let request) = message else {
                    return false
                }
                return request.name == "winact"
            }
        }
    }

    private func connectedGuest() async throws -> FakeGuest {
        let guest = FakeGuest(port: try XCTUnwrap(listener.boundPort))
        guest.start()
        try guest.send(.hello(.init(
            contract: Contract.revision, side: "guest", version: "test",
            name: "PowerBook", os: "9.2.2", chunk: 8192)))
        try await waitUntil("guest") {
            if case .connected = self.listener.state { return true }
            return false
        }
        return guest
    }

    private func answerNextList(_ guest: FakeGuest, path: String,
                                entries: [FileEntry]) async throws
        -> FileList {
        var request: FileList?
        try await waitUntil("file.list \(path)") {
            request = guest.received.compactMap { message in
                if case .fileList(let list) = message, list.path == path {
                    return list
                }
                return nil
            }.last
            return request != nil
        }
        let list = try XCTUnwrap(request)
        try guest.send(.fileListing(.init(
            id: list.id, path: path, entries: entries, more: false,
            cursor: nil, root: "Macintosh HD:")))
        return list
    }

    private func entry(_ name: String, kind: String) -> FileEntry {
        .init(name: name, kind: kind,
              fileType: kind == "file" ? "TEXT" : nil,
              creator: nil, dataBytes: 1, rsrcBytes: 0, modified: 0)
    }

    private func scene(windows: [Scene.Window] = []) -> Scene {
        .init(version: 1, seq: 1, source: "test", capturedAt: 0,
              screen: .init(w: 640, h: 480), apps: [], windows: windows,
              meta: .init())
    }

    private func finderWindow(path: String, ref: String = "now-window-1",
                              rect: Rect = Rect(l: 60, t: 50, r: 500, b: 380))
        -> Scene.Window {
        .init(id: "finder-window", app: "Finder", psn: "0.1",
              title: path.components(separatedBy: ":").last ?? path,
              kind: 20, rect: rect, front: true, z: 0, visible: true,
              controls: [], ref: ref, addr: 42,
              incarnation: "finder-incarnation", closeBox: true,
              zoomBox: true, finder: .init(path: path, view: .icon,
                                           selectedNames: [], pages: 1,
                                           complete: true))
    }

    private struct WaitTimeout: Error {}

    private func waitUntil(_ name: String, timeout: TimeInterval = 5,
                           _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(name)")
                throw WaitTimeout()
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
