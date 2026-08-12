import Foundation
import Darwin
import MirrorKit
import MirrorKitUI

private struct Arguments {
    var scene: URL?
    var output: URL?
    var openMenu: Int?
    var hoveredItem: Int?
    var finderView: Scene.FinderPresentation.View?
    var finderSelectedName: String?
    var finderMetadata: [String: Scene.FinderPresentation.ItemMetadata] = [:]
    var finderAvailableBytes: Int?
    var finderInactive = false
    var appleMenuProfile: String?

    init(_ values: [String]) throws {
        var index = 0
        while index < values.count {
            let option = values[index]
            guard index + 1 < values.count else {
                throw ArgumentError("missing value for \(option)")
            }
            let value = values[index + 1]
            switch option {
            case "--scene": scene = URL(fileURLWithPath: value)
            case "--output": output = URL(fileURLWithPath: value)
            case "--open-menu":
                guard let parsed = Int(value), parsed >= 0 else {
                    throw ArgumentError("--open-menu must be a non-negative integer")
                }
                openMenu = parsed
            case "--hovered-item":
                guard let parsed = Int(value), parsed >= 0 else {
                    throw ArgumentError("--hovered-item must be a non-negative integer")
                }
                hoveredItem = parsed
            case "--finder-view":
                let parsed = Scene.FinderPresentation.View.finderWord(value)
                guard parsed != .unknown else {
                    throw ArgumentError("--finder-view must be icon, button, name, or small icon")
                }
                finderView = parsed
            case "--finder-selected-name": finderSelectedName = value
            case "--finder-metadata-json":
                guard let data = value.data(using: .utf8) else {
                    throw ArgumentError("--finder-metadata-json must be UTF-8 JSON")
                }
                finderMetadata = try JSONDecoder().decode(
                    [String: Scene.FinderPresentation.ItemMetadata].self,
                    from: data)
            case "--finder-available-bytes":
                guard let parsed = Int(value), parsed >= 0 else {
                    throw ArgumentError("--finder-available-bytes must be a non-negative integer")
                }
                finderAvailableBytes = parsed
            case "--finder-inactive":
                guard let parsed = Bool(value) else {
                    throw ArgumentError("--finder-inactive must be true or false")
                }
                finderInactive = parsed
            case "--apple-menu-profile":
                guard value == "macos-8.6" else {
                    throw ArgumentError("--apple-menu-profile must be macos-8.6")
                }
                appleMenuProfile = value
            default: throw ArgumentError("unknown argument \(option)")
            }
            index += 2
        }
        guard scene != nil, output != nil else {
            throw ArgumentError("usage: mirror-render --scene FILE --output FILE [--open-menu N] [--hovered-item N] [--finder-view VIEW] [--finder-selected-name NAME] [--finder-metadata-json JSON] [--finder-inactive true|false] [--apple-menu-profile macos-8.6]")
        }
    }
}

private struct ArgumentError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@main
private struct MirrorRenderCLI {
    @MainActor
    static func main() {
        do {
            let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
            guard let sceneURL = arguments.scene, let outputURL = arguments.output else {
                throw ArgumentError("scene and output are required")
            }
            guard !FileManager.default.fileExists(atPath: outputURL.path) else {
                throw ArgumentError("output already exists: \(outputURL.path)")
            }
            let sceneData = try Data(contentsOf: sceneURL)
            var scene = try JSONDecoder().decode(Scene.self, from: sceneData)
            if arguments.appleMenuProfile == "macos-8.6",
               var menubar = scene.menubar,
               let index = menubar.menus.firstIndex(where: \.apple) {
                menubar.menus[index] = AppleMenuProfile.macOS86(
                    menubar.menus[index])
                scene.menubar = menubar
            }
            if let finderView = arguments.finderView {
                guard let index = scene.windows.firstIndex(where: {
                    $0.app == "Finder" && $0.front && $0.visible
                }) else {
                    throw ArgumentError("--finder-view requires a visible front Finder window")
                }
                scene.windows[index].finder = .init(
                    path: "", view: finderView,
                    selectedNames: arguments.finderSelectedName.map { [$0] } ?? [],
                    itemMetadata: arguments.finderMetadata,
                    availableBytes: arguments.finderAvailableBytes)
            } else if arguments.finderSelectedName != nil {
                throw ArgumentError("--finder-selected-name requires --finder-view")
            }
            if arguments.finderInactive {
                guard let index = scene.windows.firstIndex(where: {
                    $0.app == "Finder" && $0.visible
                }) else {
                    throw ArgumentError("--finder-inactive requires a visible Finder window")
                }
                scene.windows[index].front = false
            }
            let png = try RenderShot.png(
                scene: scene,
                openMenu: arguments.openMenu,
                hoveredItem: arguments.hoveredItem
            )
            try png.write(to: outputURL, options: .atomic)
            print("mirror-render: \(outputURL.path)")
        } catch {
            FileHandle.standardError.write(Data("mirror-render: \(error)\n".utf8))
            exit(64)
        }
    }
}
