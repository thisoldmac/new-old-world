import Foundation
import Combine
import MirrorKit
import MirrorKitUI

/// Legacy emulator controller. QMP-backed dispatch and stale-window
/// composition live in the development oracle product, never in the core
/// package linked by NOW Host.
public final class LiveMirrorController: MirrorSceneSource {
    @Published public private(set) var scene: Scene?
    @Published public private(set) var status: String = "connecting…"

    public let target: MirrorTarget
    public var planes: ActionPlanes { dispatcher.actionPlanes }
    private let queue = DispatchQueue(label: "mirror.wire")
    private var poller: ScenePoller
    private let dispatcher: ActionDispatcher
    private var timer: DispatchSourceTimer?
    private var lastWindows: [String: [Scene.Window]] = [:]
    public let screen: Scene.ScreenSize

    public init(target: MirrorTarget,
                qmpSocket: String? = nil,
                display: Bool = false, islands: Bool = false) {
        self.target = target
        let wire = WireClient(target: target)
        var poller = ScenePoller(target: target, wire: wire)
        poller.includeDesktopItems = true
        poller.includeDisplay = display
        poller.includeIslands = islands
        screen = poller.detectScreen()
        self.poller = poller
        dispatcher = ActionDispatcher(target: target, qmpSocket: qmpSocket,
                                      wire: wire)
    }

    public func start(interval: Double = 0.5) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        do {
            let scene = composite(try poller.poll())
            DispatchQueue.main.async {
                self.scene = scene
                self.status = String(
                    format: "seq %d · %d windows · %.0f ms · %@:%d%@",
                    scene.seq, scene.windows.count,
                    scene.meta.latencyMs ?? -1, self.target.host,
                    self.target.port,
                    scene.meta.errors.isEmpty
                        ? "" : " · stale: \(scene.meta.errors.count) app(s)")
            }
        } catch {
            DispatchQueue.main.async {
                self.status = "poll failed: \(error) (retrying)"
            }
        }
    }

    private func composite(_ scene: Scene) -> Scene {
        var scene = scene
        var byApp: [String: [Scene.Window]] = [:]
        for window in scene.windows {
            byApp[window.psn, default: []].append(window)
        }
        for app in scene.apps {
            if app.error == nil {
                lastWindows[app.psn] = byApp[app.psn] ?? []
            } else if var cached = lastWindows[app.psn], !cached.isEmpty {
                for index in cached.indices { cached[index].front = false }
                scene.windows.append(contentsOf: cached)
            }
        }
        for (z, index) in scene.windows.indices.enumerated() {
            scene.windows[index].z = z
        }
        return scene
    }

    public func note(_ message: String) {
        guard !message.isEmpty else { return }
        status = message
    }

    public func perform(_ actions: [MirrorAction], label: String) {
        guard !actions.isEmpty else { return }
        for action in actions {
            let availability = dispatcher.availability(action)
            guard availability == .available else {
                status = "\(label): \(availability)"
                return
            }
        }
        status = label + "…"
        queue.async {
            do {
                try self.dispatcher.perform(actions)
                DispatchQueue.main.async { self.status = label }
            } catch {
                DispatchQueue.main.async {
                    self.status = "\(label) FAILED: \(error)"
                }
            }
            self.tick()
        }
    }
}
