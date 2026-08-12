import XCTest
@testable import MirrorKit

final class CrossMachineFileTargetingTests: XCTestCase {
    private func item(_ name: String, kind: String = "file",
                      type: String? = "TEXT", creator: String? = "ttxt",
                      x: Int = 20, y: Int = 30) -> Scene.DesktopItem {
        .init(name: name, kind: kind, type: type, creator: creator,
              x: x, y: y, placed: true, alias: false, invisible: false,
              w: 32, h: 32, origin: .drawn)
    }

    private func scene(window: Scene.Window? = nil,
                       desktopItems: [Scene.DesktopItem]? = nil) -> Scene {
        .init(version: 2, seq: 1, source: "fixture", capturedAt: 1,
              screen: .init(w: 800, h: 600), apps: [],
              windows: window.map { [$0] } ?? [],
              desktopItems: desktopItems, meta: .init(errors: []))
    }

    private func window(path: String? = "Macintosh HD:Work",
                        app: String = "Finder", psn: String = "0:2",
                        items: [Scene.DesktopItem] = []) -> Scene.Window {
        .init(id: "w1", app: app, psn: psn, title: "Work", kind: 8,
              rect: .init(l: 100, t: 100, r: 500, b: 400), front: true,
              z: 0, visible: true, controls: [], items: items,
              finder: path.map { .init(path: $0, view: .icon) })
    }

    func testFinderSourceCarriesTheExactPresentedPath() throws {
        let file = item("Read Me", x: 10, y: 10)
        let subject = try CrossMachineFileTargeting.source(
            scene(window: window(items: [file])), x: 126, y: 146).get()
        XCTAssertEqual(subject, .finderWindow(
            path: "Macintosh HD:Work",
            file: .init(name: "Read Me", kind: "file",
                        fileType: "TEXT", creator: "ttxt")))
    }

    func testFinderDestinationRefusesATitleWithoutAnExactPath() {
        let result = CrossMachineFileTargeting.destination(
            scene(window: window(path: nil)), x: 200, y: 200)
        XCTAssertEqual(result, .failure(.destinationPathUnknown("Work")))
    }

    func testApplicationWindowTargetsItsLiveProcess() throws {
        let app = window(path: nil, app: "SimpleText", psn: "0:42")
        let target = try CrossMachineFileTargeting.destination(
            scene(window: app), x: 200, y: 200).get()
        XCTAssertEqual(target,
                       .applicationProcess(psn: "0:42", name: "SimpleText"))
    }

    func testApplicationIconUsesTheTargetCreator() throws {
        var alias = item("Mail Alias", kind: "file", type: "adrp",
                         creator: "MACS")
        alias.aliasTarget = .init(name: "Mail", kind: "application",
                                  type: "APPL", creator: "CSOm")
        let target = try CrossMachineFileTargeting.destination(
            scene(desktopItems: [alias]), x: 25, y: 35).get()
        XCTAssertEqual(target,
                       .applicationCreator(creator: "CSOm", name: "Mail"))
    }

    func testFolderIsNotPromisedAsAFile() {
        let folder = item("Projects", kind: "folder")
        XCTAssertEqual(
            CrossMachineFileTargeting.source(
                scene(desktopItems: [folder]), x: 25, y: 35),
            .failure(.notAFile("Projects")))
    }
}
