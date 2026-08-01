import Foundation

/// The host's decoder for the scene document a guest sends over the bulk
/// lane — Mirror's IR v1, described in `mirror/docs/IR-V1.md`.
///
/// Two rules shape every line of this file, and both are the opposite of
/// what a Codable model normally does.
///
/// **1. Absence is load-bearing.** NOW's producer omits `menus`,
/// `controls`, `text`, `kind`, `display`, `desktopItems` and `items`
/// rather than emitting them empty, because an empty array asserts *"I
/// looked and there were none"* and absence says *"this producer does not
/// report them"*. Those are different claims about the machine and the
/// difference is the entire point. So every field below that a partial
/// producer may omit is **optional**, and a missing key decodes to `nil`
/// rather than to a default — never to `[]`.
///
/// That is not a hypothetical hazard. Upstream's own `Scene.Window.controls`
/// is a non-optional `[Control]` with no custom `init(from:)`, so a scene
/// that omits the key **fails to decode there** — a document this guest
/// legitimately produces is undecodable by MirrorKit as it stands. NOW does
/// not copy that shape. Upstream needs the same relaxation; this file is
/// not the place to make it.
///
/// **2. The version gate runs before the payload.** IR-V1.md states the
/// consumer duty in order — read `irVersion`, refuse an unknown major,
/// *then* decode — and `NOWSceneCodec.decode` is written in that order on
/// purpose. A gate after the decode is not a gate: it lets an unknown
/// major's body through the parser first, which is exactly the moment a
/// breaking change does its damage.
public struct NOWSceneDocument: Codable, Equatable, Sendable {

    /// The IR's self-stamp. The same number as the result envelope's
    /// `irVersion` — one constant on the guest feeds both — and the one
    /// field here that is never optional, because a document that does not
    /// say what it is cannot be read safely at all.
    public var version: Int

    /// The producer's monotonic counter, and the guest-clock moment of the
    /// walk. Together they are how a consumer says "same scene, newer
    /// moment" without diffing the body.
    public var seq: Int?
    public var capturedAt: Double?

    /// The plane the scene was walked from ("peek" for NOW). IR v1 promoted
    /// it precisely so a consumer can tell "no windows" from "windows not
    /// visible from here".
    public var source: String?

    public var screen: ScreenSize?
    public var apps: [AppRef]?
    public var processes: [ProcessRef]?
    public var menubar: Menubar?
    public var windows: [Window]?
    public var desktopItems: [DesktopItem]?
    public var meta: Meta?

    public init(version: Int,
                seq: Int? = nil,
                capturedAt: Double? = nil,
                source: String? = nil,
                screen: ScreenSize? = nil,
                apps: [AppRef]? = nil,
                processes: [ProcessRef]? = nil,
                menubar: Menubar? = nil,
                windows: [Window]? = nil,
                desktopItems: [DesktopItem]? = nil,
                meta: Meta? = nil) {
        self.version = version
        self.seq = seq
        self.capturedAt = capturedAt
        self.source = source
        self.screen = screen
        self.apps = apps
        self.processes = processes
        self.menubar = menubar
        self.windows = windows
        self.desktopItems = desktopItems
        self.meta = meta
    }

    public struct ScreenSize: Codable, Equatable, Sendable {
        public var w: Int
        public var h: Int

        public init(w: Int, h: Int) {
            self.w = w
            self.h = h
        }
    }

    /// The app plane. `error` carries the anchor oracle's verdict for this
    /// partition and is **absent when nothing is wrong** — the key says
    /// something happened, and its absence says nothing did.
    ///
    /// The five verdicts reach the wire as distinct tokens and stay
    /// distinct here. A process whose anchor was ambiguous is not a process
    /// with no windows, and flattening the two is the failure the oracle
    /// exists to prevent.
    public struct AppRef: Codable, Equatable, Sendable {
        public var psn: String
        public var name: String
        public var front: Bool
        public var error: String?

        public init(psn: String, name: String, front: Bool,
                    error: String? = nil) {
            self.psn = psn
            self.name = name
            self.front = front
            self.error = error
        }
    }

    public struct ProcessRef: Codable, Equatable, Sendable {
        public var psn: String
        public var name: String
        public var front: Bool
        /// The creator OSType as four characters. An empty string means the
        /// signature could not be read — the guest writes `""` rather than
        /// inventing four characters — and is not the same as the key being
        /// absent, which would mean this producer does not report it.
        public var signature: String?

        public init(psn: String, name: String, front: Bool,
                    signature: String? = nil) {
            self.psn = psn
            self.name = name
            self.front = front
            self.signature = signature
        }
    }

    public struct Menubar: Codable, Equatable, Sendable {
        public var app: String?
        public var menus: [Menu]?

        public init(app: String? = nil, menus: [Menu]? = nil) {
            self.app = app
            self.menus = menus
        }
    }

    public struct Menu: Codable, Equatable, Sendable {
        public var title: String?
        public var apple: Bool?
        public var left: Int?
        public var id: Int?
        public var items: [MenuItem]?

        public init(title: String? = nil, apple: Bool? = nil,
                    left: Int? = nil, id: Int? = nil,
                    items: [MenuItem]? = nil) {
            self.title = title
            self.apple = apple
            self.left = left
            self.id = id
            self.items = items
        }
    }

    public struct MenuItem: Codable, Equatable, Sendable {
        public var title: String?
        public var index: Int?
        public var separator: Bool?
        public var enabled: Bool?
        public var mark: Bool?
        public var cmd: String?

        public init(title: String? = nil, index: Int? = nil,
                    separator: Bool? = nil, enabled: Bool? = nil,
                    mark: Bool? = nil, cmd: String? = nil) {
            self.title = title
            self.index = index
            self.separator = separator
            self.enabled = enabled
            self.mark = mark
            self.cmd = cmd
        }
    }

    /// A window. `id`, `app`, `psn`, `title`, `rect`, `front`, `z` and
    /// `visible` are what NOW's producer reports today.
    ///
    /// `kind`, `controls`, `text` and `items` are optional **for the
    /// absence reason above, not for convenience**: NOW omits all four, and
    /// a consumer that reads `controls == nil` as "this window has no
    /// controls" has been told something the guest never said.
    ///
    /// `display` is deliberately not modelled **here**, and the reason is
    /// narrower than it used to read. NOW has a content plane —
    /// `now-guest-ppc/src/content/`, the `qdtrace` verb — but it is not part
    /// of a scene: a drain is a bounded control answer and a scene is a
    /// transfer (`qdtrace.h` argues the distinction at length), so NOW's
    /// SCENE producer (`scene/scene_json.c`) does not emit a `display` key
    /// and never will. A half-modelled one on this struct would be a shelf
    /// nothing fills.
    ///
    /// The op stream reaches a window through `MirrorContentJoin`, after the
    /// scene lands. Unknown keys still decode harmlessly here; if a scene
    /// producer ever does emit one, that is the moment to model it against a
    /// fixture rather than a table.
    public struct Window: Codable, Equatable, Sendable {
        public var id: String
        public var app: String
        public var psn: String
        public var title: String
        public var rect: NOWSceneRect
        public var front: Bool
        public var z: Int
        public var visible: Bool
        public var kind: Int?
        public var controls: [Control]?
        public var text: TextContent?
        public var items: [DesktopItem]?

        public init(id: String, app: String, psn: String, title: String,
                    rect: NOWSceneRect, front: Bool, z: Int, visible: Bool,
                    kind: Int? = nil, controls: [Control]? = nil,
                    text: TextContent? = nil,
                    items: [DesktopItem]? = nil) {
            self.id = id
            self.app = app
            self.psn = psn
            self.title = title
            self.rect = rect
            self.front = front
            self.z = z
            self.visible = visible
            self.kind = kind
            self.controls = controls
            self.text = text
            self.items = items
        }
    }

    public struct Control: Codable, Equatable, Sendable {
        public var ref: String?
        public var role: String?
        public var title: String?
        public var rect: NOWSceneRect?
        public var enabled: Bool?
        public var visible: Bool?
        public var value: Int?
        public var min: Int?
        public var max: Int?
        public var checked: Bool?

        public init(ref: String? = nil, role: String? = nil,
                    title: String? = nil, rect: NOWSceneRect? = nil,
                    enabled: Bool? = nil, visible: Bool? = nil,
                    value: Int? = nil, min: Int? = nil, max: Int? = nil,
                    checked: Bool? = nil) {
            self.ref = ref
            self.role = role
            self.title = title
            self.rect = rect
            self.enabled = enabled
            self.visible = visible
            self.value = value
            self.min = min
            self.max = max
            self.checked = checked
        }
    }

    public struct TextContent: Codable, Equatable, Sendable {
        public var content: String?
        public var active: Bool?

        public init(content: String? = nil, active: Bool? = nil) {
            self.content = content
            self.active = active
        }
    }

    public struct DesktopItem: Codable, Equatable, Sendable {
        public var name: String?
        public var kind: String?
        public var type: String?
        public var creator: String?
        public var x: Int?
        public var y: Int?
        public var placed: Bool?
        public var alias: Bool?
        public var invisible: Bool?

        public init(name: String? = nil, kind: String? = nil,
                    type: String? = nil, creator: String? = nil,
                    x: Int? = nil, y: Int? = nil, placed: Bool? = nil,
                    alias: Bool? = nil, invisible: Bool? = nil) {
            self.name = name
            self.kind = kind
            self.type = type
            self.creator = creator
            self.x = x
            self.y = y
            self.placed = placed
            self.alias = alias
            self.invisible = invisible
        }
    }

    /// `errors` is what the walk could not do, in upstream's
    /// "<name>: <token>" form plus this producer's truncation notices. An
    /// empty array here is a real claim — the walk finished and found
    /// nothing wrong — which is why it is distinguishable from the key
    /// being absent.
    public struct Meta: Codable, Equatable, Sendable {
        public var errors: [String]?
        public var plane: String?
        public var latencyMs: Double?
        public var bytes: Int?

        public init(errors: [String]? = nil, plane: String? = nil,
                    latencyMs: Double? = nil, bytes: Int? = nil) {
            self.errors = errors
            self.plane = plane
            self.latencyMs = latencyMs
            self.bytes = bytes
        }
    }
}

/// A rectangle in the IR's own order and key names.
public struct NOWSceneRect: Codable, Equatable, Sendable {
    public var l: Int
    public var t: Int
    public var r: Int
    public var b: Int

    public var width: Int { r - l }
    public var height: Int { b - t }

    public init(l: Int, t: Int, r: Int, b: Int) {
        self.l = l
        self.t = t
        self.r = r
        self.b = b
    }
}

/// What this host can read.
public enum NOWSceneVersion {
    /// The IR majors this decoder understands. A major outside this set is
    /// **refused, not attempted**: a breaking change is by definition a
    /// document whose fields no longer mean what this code believes, and
    /// decoding it anyway produces a plausible scene that is wrong — which
    /// is worse than no scene at all.
    public static let supportedMajors: Set<Int> = [1]

    public static func isSupported(_ major: Int) -> Bool {
        supportedMajors.contains(major)
    }
}

public enum NOWSceneDecodeError: Error, Equatable {
    /// The envelope announced a major this host does not understand. The
    /// body was NOT parsed.
    case unsupportedMajor(Int)
    /// The envelope and the body disagree about the version. On the guest
    /// these come from one constant and cannot diverge, so a disagreement
    /// means something rewrote one of them in flight — and a document that
    /// cannot agree with itself about what it is does not get read.
    case versionDisagreement(envelope: Int, body: Int)
    case malformed(String)
}

public enum NOWSceneCodec {

    /// Decodes a scene document, gate first.
    ///
    /// The order of the three steps below is the contract, not a style
    /// choice — see `NOWSceneDocument`'s header and IR-V1.md's "Consumer
    /// duty" row. Moving the major check after `decoder.decode` still
    /// rejects an unknown major *most* of the time, which is precisely what
    /// makes the mistake survivable long enough to ship.
    public static func decode(irVersion: Int,
                              document: Data) throws -> NOWSceneDocument {
        // 1. Read the version. 2. Refuse an unknown major — before the
        //    payload is touched at all.
        guard NOWSceneVersion.isSupported(irVersion) else {
            throw NOWSceneDecodeError.unsupportedMajor(irVersion)
        }
        // 3. Only now, decode.
        let scene: NOWSceneDocument
        do {
            scene = try JSONDecoder().decode(NOWSceneDocument.self,
                                             from: document)
        } catch {
            throw NOWSceneDecodeError.malformed("\(error)")
        }
        guard scene.version == irVersion else {
            throw NOWSceneDecodeError.versionDisagreement(
                envelope: irVersion, body: scene.version)
        }
        return scene
    }
}
