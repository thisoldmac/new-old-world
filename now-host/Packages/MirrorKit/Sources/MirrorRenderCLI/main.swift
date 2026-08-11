import Foundation
import Darwin
import MirrorKit
import MirrorKitUI

private struct Arguments {
    var scene: URL?
    var output: URL?
    var openMenu: Int?
    var hoveredItem: Int?

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
            default: throw ArgumentError("unknown argument \(option)")
            }
            index += 2
        }
        guard scene != nil, output != nil else {
            throw ArgumentError("usage: mirror-render --scene FILE --output FILE [--open-menu N] [--hovered-item N]")
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
            let scene = try JSONDecoder().decode(Scene.self, from: sceneData)
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
