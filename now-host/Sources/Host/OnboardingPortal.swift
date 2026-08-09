import Combine
import Foundation
import Network

struct OnboardingEndpoint: Equatable {
    let host: String
    let httpPort: UInt16
    let wirePort: UInt16

    var pageURL: URL? {
        URL(string: "http://\(host):\(httpPort)/now")
    }
}

/// A temporary, fixed-route HTTP server for getting the PPC guest onto a
/// LAN. It is intentionally not a general web server: GET/HEAD only, one
/// page, generated settings, and files already admitted by the catalog.
@MainActor
final class OnboardingPortal: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting
        case running(OnboardingEndpoint)
        case failed(String)
    }

    enum DependencyAcquisitionState: Equatable {
        case downloading
        case failed(String)
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var assets: OnboardingAssetSnapshot = .empty
    @Published private(set) var dependencyAcquisitions:
        [String: DependencyAcquisitionState] = [:]

    private let catalog: OnboardingAssetCatalog
    private let dependencyAcquirer: OnboardingDependencyAcquirer
    private let advertisedAddress: () -> String?
    private var listener: NWListener?
    private var generation = 0
    private var wirePort: UInt16 = SettingsModel.defaultPort

    init(catalog: OnboardingAssetCatalog = .live(),
         dependencyAcquirer: OnboardingDependencyAcquirer? = nil,
         advertisedAddress: @escaping () -> String? = {
             HostAddressDetector.primaryIPv4()
         }) {
        self.catalog = catalog
        self.dependencyAcquirer = dependencyAcquirer ?? .live()
        self.advertisedAddress = advertisedAddress
        refreshAssets()
    }

    var endpoint: OnboardingEndpoint? {
        guard case .running(let endpoint) = state else { return nil }
        return endpoint
    }

    func start(wirePort: UInt16) {
        if let endpoint, endpoint.wirePort == wirePort {
            refreshAssets()
            return
        }
        stop()
        self.wirePort = wirePort
        refreshAssets()
        state = .starting
        generation += 1
        let run = generation

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: .any)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.generation == run else {
                        connection.cancel()
                        return
                    }
                    self.accept(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] value in
                Task { @MainActor in
                    guard let self, self.generation == run else { return }
                    self.listenerStateChanged(value, listener: listener)
                }
            }
            listener.start(queue: .main)
        } catch {
            listener = nil
            state = .failed("Could not start onboarding: "
                            + error.localizedDescription)
        }
    }

    func stop() {
        generation += 1
        let old = listener
        listener = nil
        state = .stopped
        old?.cancel()
    }

    func refreshAssets() {
        assets = catalog.snapshot()
    }

    func preparePackagesFolder() throws -> URL {
        let url = try catalog.prepareWritableRoot()
        refreshAssets()
        return url
    }

    func acquire(_ dependency: OnboardingDependency) {
        if dependencyAcquisitions[dependency.id] == .downloading { return }
        dependencyAcquisitions[dependency.id] = .downloading
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await dependencyAcquirer.acquire(
                    dependency, catalog: catalog)
                dependencyAcquisitions[dependency.id] = nil
                refreshAssets()
            } catch {
                dependencyAcquisitions[dependency.id] = .failed(
                    error.localizedDescription)
            }
        }
    }

    private func listenerStateChanged(_ value: NWListener.State,
                                      listener: NWListener?) {
        switch value {
        case .ready:
            guard let port = listener?.port?.rawValue else {
                state = .failed("Onboarding started without a usable port.")
                return
            }
            guard let host = advertisedAddress() else {
                state = .failed("No active LAN IPv4 address was found. "
                                + "Connect this Mac to the same LAN first.")
                listener?.cancel()
                self.listener = nil
                return
            }
            state = .running(OnboardingEndpoint(
                host: host, httpPort: port, wirePort: wirePort))
        case .failed(let error):
            self.listener = nil
            state = .failed("Onboarding stopped: "
                            + error.localizedDescription)
        case .cancelled:
            self.listener = nil
            if case .starting = state { state = .stopped }
        case .setup, .waiting:
            break
        @unknown default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: .main)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection,
                                accumulated: Data) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 8_192
        ) { [weak self] data, _, done, _ in
            Task { @MainActor in
                guard let self else {
                    connection.cancel()
                    return
                }
                var request = accumulated
                if let data { request.append(data) }
                if request.count > 8_192 {
                    self.send(.plain(status: 431,
                                     reason: "Request Header Too Large",
                                     text: "Request header too large.\r\n"),
                              headOnly: false, on: connection)
                    return
                }
                if request.range(of: Data("\r\n\r\n".utf8)) != nil
                    || request.range(of: Data("\n\n".utf8)) != nil
                    || done {
                    self.handle(request, on: connection)
                } else {
                    self.receiveRequest(on: connection,
                                        accumulated: request)
                }
            }
        }
    }

    private func handle(_ request: Data, on connection: NWConnection) {
        guard let text = String(data: request, encoding: .isoLatin1),
              let firstLine = text.split(whereSeparator: \.isNewline).first
        else {
            send(.plain(status: 400, reason: "Bad Request",
                        text: "Bad request.\r\n"),
                 headOnly: false, on: connection)
            return
        }
        let fields = firstLine.split(separator: " ",
                                     omittingEmptySubsequences: true)
        guard fields.count >= 2 else {
            send(.plain(status: 400, reason: "Bad Request",
                        text: "Bad request.\r\n"),
                 headOnly: false, on: connection)
            return
        }
        let method = String(fields[0]).uppercased()
        guard method == "GET" || method == "HEAD" else {
            send(.plain(status: 405, reason: "Method Not Allowed",
                        text: "Only GET and HEAD are supported.\r\n",
                        extraHeaders: ["Allow: GET, HEAD"]),
                 headOnly: method == "HEAD", on: connection)
            return
        }

        let path = requestPath(String(fields[1]))
        let localHost = acceptedHost(on: connection)
            ?? endpoint?.host
            ?? advertisedAddress()
            ?? "127.0.0.1"
        send(response(for: path, host: localHost),
             headOnly: method == "HEAD", on: connection)
    }

    private func response(for path: String, host: String) -> HTTPResponse {
        refreshAssets()
        switch path {
        case "/", "/now", "/now/":
            let page = OnboardingPage.render(host: host,
                                             wirePort: wirePort,
                                             assets: assets)
            return .data(status: 200, reason: "OK",
                         contentType: "text/html; charset=utf-8",
                         data: Data(page.utf8))
        case "/now/settings.bin":
            guard let data = OnboardingPreferences.macBinary(
                host: host, port: wirePort) else {
                return .plain(status: 500, reason: "Internal Server Error",
                              text: "Could not make the settings file.\r\n")
            }
            return .download(data: data,
                             fileName: "New Old World Prefs.bin",
                             contentType: "application/macbinary")
        case "/now/application.bin":
            return assetResponse(assets.application)
        case "/now/extension.bin":
            return assetResponse(assets.extensionComponent)
        default:
            if path.hasPrefix("/now/dependencies/") {
                let encoded = String(path.dropFirst(
                    "/now/dependencies/".count))
                let name = encoded.removingPercentEncoding ?? encoded
                return assetResponse(assets.dependencies.first {
                    $0.fileName == name
                })
            }
            return .plain(status: 404, reason: "Not Found",
                          text: "Not found.\r\n")
        }
    }

    private func assetResponse(_ asset: OnboardingAsset?) -> HTTPResponse {
        guard let asset else {
            return .plain(status: 404, reason: "Not Found",
                          text: "That package is not installed on this "
                              + "host.\r\n")
        }
        do {
            let data = try Data(contentsOf: asset.fileURL,
                                options: [.mappedIfSafe])
            return .download(data: data, fileName: asset.fileName,
                             contentType: contentType(for: asset.fileURL))
        } catch {
            return .plain(status: 500, reason: "Internal Server Error",
                          text: "The host could not read that package.\r\n")
        }
    }

    private func send(_ response: HTTPResponse, headOnly: Bool,
                      on connection: NWConnection) {
        var header = "HTTP/1.0 \(response.status) \(response.reason)\r\n"
        header += "Content-Type: \(response.contentType)\r\n"
        header += "Content-Length: \(response.body.count)\r\n"
        header += "Connection: close\r\n"
        for line in response.extraHeaders { header += "\(line)\r\n" }
        header += "\r\n"
        var message = Data(header.utf8)
        if !headOnly { message.append(response.body) }
        connection.send(content: message, contentContext: .defaultMessage,
                        isComplete: true,
                        completion: .contentProcessed { _ in
                            connection.cancel()
                        })
    }

    private func requestPath(_ target: String) -> String {
        if target.hasPrefix("http://") || target.hasPrefix("https://"),
           let parts = URLComponents(string: target) {
            return parts.percentEncodedPath.isEmpty
                ? "/" : parts.percentEncodedPath
        }
        return String(target.split(separator: "?", maxSplits: 1,
                                   omittingEmptySubsequences: false)[0])
    }

    private func acceptedHost(on connection: NWConnection) -> String? {
        guard case .hostPort(let host, _) =
                connection.currentPath?.localEndpoint else { return nil }
        let text = HostAddressDetector.text(host)
        return text == "0.0.0.0" || text == "::" ? nil : text
    }

    private func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "bin": return "application/macbinary"
        case "sit": return "application/x-stuffit"
        case "hqx": return "application/mac-binhex40"
        case "img", "dsk": return "application/octet-stream"
        default: return "application/octet-stream"
        }
    }
}

private struct HTTPResponse {
    let status: Int
    let reason: String
    let contentType: String
    let body: Data
    let extraHeaders: [String]

    static func data(status: Int, reason: String, contentType: String,
                     data: Data, extraHeaders: [String] = []) -> HTTPResponse {
        HTTPResponse(status: status, reason: reason,
                     contentType: contentType, body: data,
                     extraHeaders: extraHeaders)
    }

    static func plain(status: Int, reason: String, text: String,
                      extraHeaders: [String] = []) -> HTTPResponse {
        data(status: status, reason: reason,
             contentType: "text/plain; charset=us-ascii",
             data: Data(text.utf8), extraHeaders: extraHeaders)
    }

    static func download(data: Data, fileName: String,
                         contentType: String) -> HTTPResponse {
        let safe = fileName.map { character -> Character in
            character == "\"" || character == "\r" || character == "\n"
                ? "_" : character
        }
        return self.data(
            status: 200, reason: "OK", contentType: contentType, data: data,
            extraHeaders: [
                "Content-Disposition: attachment; filename=\"\(String(safe))\""
            ])
    }
}
