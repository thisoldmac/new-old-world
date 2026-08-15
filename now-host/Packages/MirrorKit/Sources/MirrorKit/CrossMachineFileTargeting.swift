import Foundation

/// Resolves cross-machine file drags against the same scene and hit tester
/// that draw and drive Mirror.  It deliberately carries semantic identities,
/// not a guessed mouse gesture: transfer code can therefore refuse a stale
/// Finder path or process instead of filing a document somewhere merely near
/// the release point.
public enum CrossMachineFileTargeting {
    public struct FileIdentity: Equatable, Sendable {
        public var name: String
        public var kind: String
        public var fileType: String?
        public var creator: String?

        public init(name: String, kind: String, fileType: String?,
                    creator: String?) {
            self.name = name
            self.kind = kind
            self.fileType = fileType
            self.creator = creator
        }
    }

    /// One exact guest item that may become a host file promise.
    public enum Source: Equatable, Sendable {
        case desktop(FileIdentity)
        case finderWindow(path: String, file: FileIdentity)

        public var file: FileIdentity {
            switch self {
            case .desktop(let file), .finderWindow(_, let file): return file
            }
        }
    }

    /// Where a host file should settle after it crosses the wire.
    public enum Destination: Equatable, Sendable {
        case desktop
        case finderFolder(path: String)
        case applicationProcess(psn: String, name: String)
        case applicationCreator(creator: String, name: String)
    }

    public enum Refusal: Error, Equatable, Sendable {
        case notAFile(String)
        case sourcePathUnknown(String)
        case notADropTarget(String)
        case destinationPathUnknown(String)
        case applicationIdentityUnknown(String)

        public var message: String {
            switch self {
            case .notAFile(let name):
                return "\(name) is not a file that can be copied"
            case .sourcePathUnknown(let name):
                return "the mirror does not know the exact folder containing \(name)"
            case .notADropTarget(let what):
                return "\(what) is not a file drop target"
            case .destinationPathUnknown(let name):
                return "the mirror does not know the exact Finder path for \(name)"
            case .applicationIdentityUnknown(let name):
                return "the mirror cannot identify the application \(name)"
            }
        }
    }

    public static func source(_ scene: Scene, x: Int, y: Int)
        -> Result<Source, Refusal> {
        guard case .success(let subject) = DragTargeting.subject(
            scene, x: x, y: y) else {
            return .failure(.notAFile("that part of the mirror"))
        }
        return source(subject, in: scene)
    }

    /// Resolves an already-picked item without hit-testing a second point.
    /// This is the handoff used when a drag crosses the mirror edge: the
    /// pointer is outside by then, but the source remains the item selected
    /// at mouse-down.
    public static func source(_ subject: DragTargeting.Subject,
                              in scene: Scene) -> Result<Source, Refusal> {
        switch subject {
        case .desktopItem(let item):
            return source(item, folderPath: nil)
        case .windowItem(let windowID, let item):
            guard let window = scene.windows.last(where: {
                $0.id == windowID
            }), let path = window.finder?.path, !path.isEmpty else {
                return .failure(.sourcePathUnknown(item.name))
            }
            return source(item, folderPath: path)
        }
    }

    public static func destination(_ scene: Scene, x: Int, y: Int)
        -> Result<Destination, Refusal> {
        switch HitTester.hitTest(scene, x: x, y: y) {
        case .desktop:
            return .success(.desktop)

        case .content(let windowID, let psn, _, _, _):
            guard let window = scene.windows.last(where: {
                $0.id == windowID
            }) else {
                return .failure(.notADropTarget("a window that has closed"))
            }
            if FinderItems.isFolderWindow(window) {
                guard let path = window.finder?.path, !path.isEmpty else {
                    return .failure(.destinationPathUnknown(window.title))
                }
                return .success(.finderFolder(path: path))
            }
            guard !psn.isEmpty else {
                return .failure(.applicationIdentityUnknown(window.app))
            }
            return .success(.applicationProcess(psn: psn, name: window.app))

        case .desktopItem(let name, _, _):
            guard let item = scene.desktopItems?.last(where: {
                $0.name == name
            }) else { return .failure(.notADropTarget(name)) }
            if let application = applicationIdentity(item) {
                return application
            }
            /* A document or ordinary folder icon on the desktop files a
               dropped item onto the desktop.  Folder-icon traversal needs
               an exact alias/catalog identity and is intentionally not
               guessed from the visible name. */
            return .success(.desktop)

        case .windowItem(let windowID, let name, _, _):
            guard let window = scene.windows.last(where: {
                $0.id == windowID
            }), let item = window.items?.last(where: { $0.name == name })
            else { return .failure(.notADropTarget(name)) }
            if let application = applicationIdentity(item) {
                return application
            }
            guard let path = window.finder?.path, !path.isEmpty else {
                return .failure(.destinationPathUnknown(window.title))
            }
            if item.kind == "folder" {
                return .success(.finderFolder(path: join(path, item.name)))
            }
            return .success(.finderFolder(path: path))

        default:
            return .failure(.notADropTarget(
                DragTargeting.describe(HitTester.hitTest(scene, x: x, y: y))))
        }
    }

    private static func source(_ item: Scene.DesktopItem,
                               folderPath: String?)
        -> Result<Source, Refusal> {
        guard item.kind != "folder", item.kind != "disk" else {
            return .failure(.notAFile(item.name))
        }
        let file = FileIdentity(name: item.name, kind: item.kind,
                                fileType: item.type,
                                creator: item.creator)
        if let folderPath {
            return .success(.finderWindow(path: folderPath, file: file))
        }
        return .success(.desktop(file))
    }

    private static func applicationIdentity(_ item: Scene.DesktopItem)
        -> Result<Destination, Refusal>? {
        let identity: (name: String, kind: String, creator: String?)
        if let target = item.aliasTarget {
            identity = (target.name, target.kind, target.creator)
        } else {
            identity = (item.name, item.kind, item.creator)
        }
        guard identity.kind == "application" else { return nil }
        guard let creator = identity.creator, creator.utf8.count == 4 else {
            return .failure(.applicationIdentityUnknown(identity.name))
        }
        return .success(.applicationCreator(creator: creator,
                                            name: identity.name))
    }

    private static func join(_ folder: String, _ name: String) -> String {
        folder.hasSuffix(":") ? folder + name : folder + ":" + name
    }
}
