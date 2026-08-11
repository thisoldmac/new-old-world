import Foundation

struct WebBridgeLaunchSpec: Equatable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let currentDirectoryURL: URL?
}

/// Owns exactly one helper process. It reports bytes and termination; product
/// meaning such as protocol readiness belongs to `WebBridgeModel`.
@MainActor
final class WebBridgeProcessController {
    var output: ((String) -> Void)?
    var terminated: ((Int32, Bool) -> Void)?

    private var process: Process?
    private var outputPipe: Pipe?
    private var stopRequested = false

    var isRunning: Bool { process?.isRunning == true }

    func start(_ spec: WebBridgeLaunchSpec) throws {
        guard process == nil else {
            throw WebBridgeProcessError.alreadyRunning
        }
        stopRequested = false
        let launched = Process()
        launched.executableURL = spec.executableURL
        launched.arguments = spec.arguments
        launched.environment = spec.environment
        launched.currentDirectoryURL = spec.currentDirectoryURL

        let pipe = Pipe()
        launched.standardOutput = pipe
        launched.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.output?(text) }
        }
        launched.terminationHandler = { [weak self, weak launched] process in
            Task { @MainActor [weak self, weak launched] in
                guard let self, self.process === launched else { return }
                let requested = self.stopRequested
                self.clearProcess()
                self.terminated?(process.terminationStatus, requested)
            }
        }
        process = launched
        outputPipe = pipe
        do {
            try launched.run()
        } catch {
            clearProcess()
            throw error
        }
    }

    func stop() {
        guard let process else { return }
        stopRequested = true
        if process.isRunning {
            process.terminate()
        } else {
            clearProcess()
        }
    }

    private func clearProcess() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        process = nil
    }

    deinit {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if process?.isRunning == true { process?.terminate() }
    }
}

enum WebBridgeProcessError: Error, Equatable {
    case alreadyRunning
}

