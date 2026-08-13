import Foundation
import Network

/// Runs the resident lease heartbeat on the UDP queue rather than the UI
/// actor. A classic modal tracking loop may starve the guest application and
/// its acknowledgements; neither that nor a busy host UI may silently stop the
/// resident's bounded release clock.
final class ContinuityKeepaliveClock: @unchecked Sendable {
    struct Stats {
        var sent: UInt32 = 0
        var delayedTicks: UInt32 = 0
        var maxGap: TimeInterval = 0
        var lastSendAge: TimeInterval?
    }

    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var connection: NWConnection?
    private var payload = Data()
    private var sent: UInt32 = 0
    private var delayedTicks: UInt32 = 0
    private var lastSendUptime: TimeInterval?
    private var maxGap: TimeInterval = 0
    private let interval: TimeInterval = 0.5

    init(queue: DispatchQueue) { self.queue = queue }

    func start(connection: NWConnection, payload: Data) {
        queue.async { [self] in
            timer?.cancel()
            self.connection = connection
            self.payload = payload
            sent = 0
            delayedTicks = 0
            lastSendUptime = nil
            maxGap = 0
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + interval,
                            repeating: interval, leeway: .milliseconds(25))
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source
            source.resume()
        }
    }

    func update(payload: Data) {
        queue.async { [weak self] in self?.payload = payload }
    }

    func stop() -> Stats {
        queue.sync {
            let result = stats()
            timer?.cancel()
            timer = nil
            connection = nil
            payload = Data()
            return result
        }
    }

    private func tick() {
        guard let connection else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastSendUptime {
            let gap = now - lastSendUptime
            maxGap = max(maxGap, gap)
            if gap > interval * 1.75 { delayedTicks &+= 1 }
        }
        lastSendUptime = now
        sent &+= 1
        connection.send(content: payload, completion: .idempotent)
    }

    private func stats() -> Stats {
        Stats(sent: sent, delayedTicks: delayedTicks, maxGap: maxGap,
              lastSendAge: lastSendUptime.map {
                  max(0, ProcessInfo.processInfo.systemUptime - $0)
              })
    }
}
