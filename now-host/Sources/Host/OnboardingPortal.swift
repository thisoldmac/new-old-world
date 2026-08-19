import Combine
import Foundation
import Network

struct OnboardingEndpoint: Equatable {
    let host: String
    let httpPort: UInt16
    let wirePort: UInt16

    var pageURL: URL? {
        URL(string: "http://\(host):\(httpPort)/")
    }
}

struct OnboardingSetupImage: Equatable {
    let fileName: String
    let transferByteCount: Int64
    let diskByteCount: Int64
    let includedItems: [String]
    let builtAt: Date
}

/// A temporary, fixed-route HTTP server for getting the PPC guest onto a
/// LAN. It is intentionally not a general web server: GET/HEAD only, one
/// page, generated settings, and files already admitted by the catalog.
@MainActor
final class OnboardingPortal: ObservableObject {
    /// The port a person types on a 1993 keyboard. Stable so a bookmark or
    /// a remembered number keeps working across sessions; when something
    /// else holds it, the listener falls back to an ephemeral port rather
    /// than refusing to onboard at all.
    static let preferredPort: UInt16 = 5280

    typealias SetupImageBuilder = @Sendable (
        String, UInt16, OnboardingAssetSnapshot, OnboardingGuestFlavor)
        async throws -> Data

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

    enum SetupImageState: Equatable {
        case notBuilt
        case building
        case ready(OnboardingSetupImage)
        case failed(String)
    }

    enum SetupImageError: LocalizedError {
        case notRunning

        var errorDescription: String? {
            "Start onboarding before creating a setup disk so its settings "
                + "can use the advertised host address."
        }
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var assets: OnboardingAssetSnapshot = .empty
    @Published private(set) var dependencyAcquisitions:
        [String: DependencyAcquisitionState] = [:]
    @Published private(set) var selectedAssetIDs: Set<String> = []
    @Published private(set) var setupImageState: SetupImageState = .notBuilt
    @Published var guestFlavor: OnboardingGuestFlavor = .powerpc

    private let preferredPort: UInt16
    private let catalog: OnboardingAssetCatalog
    private let dependencyAcquirer: OnboardingDependencyAcquirer
    private let setupImageBuilder: SetupImageBuilder
    private let advertisedAddress: () -> String?
    private var listener: NWListener?
    private var generation = 0
    private var wirePort: UInt16 = SettingsModel.defaultPort
    private var knownAssetIDs: Set<String> = []
    private var setupImageData: Data?
    private var setupImageSelection: Set<String> = []
    private var setupImageFlavor: OnboardingGuestFlavor = .powerpc

    init(catalog: OnboardingAssetCatalog = .live(),
         preferredPort: UInt16 = OnboardingPortal.preferredPort,
         dependencyAcquirer: OnboardingDependencyAcquirer? = nil,
         setupImageBuilder: @escaping SetupImageBuilder = {
             host, port, assets, flavor in
             try await ClassicSetupImageBuilder().build(
                 host: host, wirePort: port, assets: assets, flavor: flavor)
         },
         advertisedAddress: @escaping () -> String? = {
             HostAddressDetector.primaryIPv4()
         }) {
        self.catalog = catalog
        self.preferredPort = preferredPort
        self.dependencyAcquirer = dependencyAcquirer ?? .live()
        self.setupImageBuilder = setupImageBuilder
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
        setupImageData = nil
        setupImageSelection = []
        setupImageState = .notBuilt
        refreshAssets()
        state = .starting
        generation += 1
        listen(on: NWEndpoint.Port(rawValue: preferredPort) ?? .any,
               fallback: true)
    }

    private func listen(on port: NWEndpoint.Port, fallback: Bool) {
        let run = generation

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: port)
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
                    self.listenerStateChanged(value, listener: listener,
                                              fallback: fallback)
                }
            }
            listener.start(queue: .main)
        } catch {
            listener = nil
            if fallback {
                listen(on: .any, fallback: false)
            } else {
                state = .failed("Could not start onboarding: "
                                + error.localizedDescription)
            }
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
        let available = selectableAssets.map(\.id)
        let availableIDs = Set(available)
        selectedAssetIDs.formIntersection(availableIDs)
        selectedAssetIDs.formUnion(availableIDs.subtracting(knownAssetIDs))
        if let application = assets.application {
            selectedAssetIDs.insert(application.id)
        }
        if let application68K = assets.application68K {
            selectedAssetIDs.insert(application68K.id)
        }
        knownAssetIDs = availableIDs
    }

    // Both flavors' applications stay selectable so a discovered asset is
    // auto-selected whichever pill is active; what a flavor OFFERS is the
    // page's and image's decision, made per request from `guestFlavor`.
    var selectableAssets: [OnboardingAsset] {
        [assets.application, assets.application68K, assets.codeKitten,
         assets.extensionComponent].compactMap { $0 }
            + OnboardingDependencyCatalog.setupAssets(in: assets)
    }

    var hasPendingSetupImageChanges: Bool {
        setupImageData != nil
            && (setupImageSelection != selectedAssetIDs
                || setupImageFlavor != guestFlavor)
    }

    func isSelected(_ asset: OnboardingAsset) -> Bool {
        selectedAssetIDs.contains(asset.id)
    }

    func setSelected(_ selected: Bool, asset: OnboardingAsset) {
        if asset.kind == .application || asset.kind == .application68K {
            return
        }
        var selection = selectedAssetIDs
        if selected {
            selection.insert(asset.id)
        } else {
            selection.remove(asset.id)
        }
        selectedAssetIDs = selection
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

    @discardableResult
    func rebuildSetupImage() async throws -> OnboardingSetupImage {
        guard let endpoint else { throw SetupImageError.notRunning }
        refreshAssets()
        setupImageState = .building
        do {
            let selection = selectedAssetIDs
            let flavor = guestFlavor
            let selected = selectedAssets(selection: selection)
            let image = try await setupImageBuilder(
                endpoint.host, endpoint.wirePort, selected, flavor)
            let summary = setupImageSummary(image, assets: selected,
                                            flavor: flavor)
            setupImageData = image
            setupImageSelection = selection
            setupImageFlavor = flavor
            setupImageState = .ready(summary)
            return summary
        } catch {
            setupImageState = .failed(error.localizedDescription)
            throw error
        }
    }

    func currentSetupImage() -> Data? {
        setupImageData
    }

    private func selectedAssets(selection: Set<String>)
        -> OnboardingAssetSnapshot {
        OnboardingAssetSnapshot(
            application: assets.application.flatMap {
                selection.contains($0.id) ? $0 : nil
            },
            application68K: assets.application68K.flatMap {
                selection.contains($0.id) ? $0 : nil
            },
            codeKitten: assets.codeKitten.flatMap {
                selection.contains($0.id) ? $0 : nil
            },
            extensionComponent: assets.extensionComponent.flatMap {
                selection.contains($0.id) ? $0 : nil
            },
            dependencies: assets.dependencies.filter {
                selection.contains($0.id)
            })
    }

    private func setupImageSummary(_ image: Data,
                                   assets: OnboardingAssetSnapshot,
                                   flavor: OnboardingGuestFlavor)
        -> OnboardingSetupImage {
        let diskBytes = (try? MacBinaryFile.decode(image))
            .map { Int64($0.dataFork.count) } ?? 0
        var items: [String]
        switch flavor {
        case .powerpc:
            items = ["New Old World", "Host settings", "Read Me First"]
            if assets.codeKitten != nil { items.append("CodeKitten") }
            if assets.extensionComponent != nil {
                items.append("NOW Extension")
            }
            items += OnboardingDependencyCatalog.setupAssets(in: assets)
                .map { asset in
                    OnboardingDependencyCatalog.all.first(
                        where: { $0.matches(asset) })?.displayName
                        ?? asset.fileName
                }
        case .m68k:
            // No settings: NOW-68K ships no preferences as a product
            // property. No CodeKitten or CarbonLib: both are Carbon.
            items = ["NOW-68K", "Read Me First"]
            if assets.extensionComponent != nil {
                items.append("NOW Extension")
            }
        }
        return OnboardingSetupImage(
            fileName: ClassicSetupImageBuilder.classicImageName(for: flavor),
            transferByteCount: Int64(image.count), diskByteCount: diskBytes,
            includedItems: items, builtAt: Date())
    }

    private func listenerStateChanged(_ value: NWListener.State,
                                      listener: NWListener?,
                                      fallback: Bool) {
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
            Task { @MainActor [weak self] in
                try? await self?.rebuildSetupImage()
            }
        case .failed(let error):
            self.listener = nil
            // The preferred port being held (another host instance, an
            // earlier session) is an expected state, not a failure: fall
            // back to an ephemeral port once, then report honestly.
            if fallback {
                generation += 1
                listen(on: .any, fallback: false)
            } else {
                state = .failed("Onboarding stopped: "
                                + error.localizedDescription)
            }
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
        // Every guest-browser experiment so far has been interpreted from
        // memory of what the browser probably did. The log line is the
        // evidence: which route the guest actually fetched, and as whom -
        // MacWeb, Netscape and Fetch behave differently enough that the
        // User-Agent decides which download story applies.
        let userAgent = text.split(whereSeparator: \.isNewline)
            .first { $0.lowercased().hasPrefix("user-agent:") }
            .map { $0.dropFirst("user-agent:".count)
                .trimmingCharacters(in: .whitespaces) } ?? "-"
        HostLog.shared.write(.info, "onboarding",
                             "\(method) \(path) ua=\(userAgent)")
        let localHost = acceptedHost(on: connection)
            ?? endpoint?.host
            ?? advertisedAddress()
            ?? "127.0.0.1"
        if path == "/now/setup.img" || path == "/now/setup.img.bin" {
            Task { [weak self] in
                guard let self else {
                    connection.cancel()
                    return
                }
                let response = await self.setupImageResponse(
                    envelopeFallback: path.hasSuffix(".bin"))
                self.send(response, headOnly: method == "HEAD",
                          on: connection)
            }
            return
        }
        send(response(for: path, host: localHost),
             headOnly: method == "HEAD", on: connection)
    }

    private func setupImageResponse(envelopeFallback: Bool) async
        -> HTTPResponse {
        do {
            let image: Data
            if let cached = setupImageData {
                image = cached
            } else if case .building = setupImageState {
                return .plain(
                    status: 503, reason: "Service Unavailable",
                    text: "The install image is still being built. "
                        + "Try the download again in a moment.\r\n",
                    extraHeaders: ["Retry-After: 2"])
            } else {
                _ = try await rebuildSetupImage()
                guard let built = setupImageData else {
                    throw SetupImageError.notRunning
                }
                image = built
            }
            if envelopeFallback {
                return .download(
                    data: image,
                    fileName: ClassicSetupImageBuilder.downloadFileName(
                        for: setupImageFlavor),
                    contentType: "application/macbinary")
            }
            // The 68K image is a Disk Copy 4.2 container - data-fork-only
            // by design - so the plain route serves it BARE: a browser
            // with no MacBinary decoder (MacWeb) saves a byte-perfect,
            // openable image. The PPC image is NDIF, whose bcem resource
            // only survives inside MacBinary, so its plain route stays an
            // envelope in the one standard spelling classic browsers map.
            if setupImageFlavor == .m68k {
                let container = try MacBinaryFile.decode(image).dataFork
                return .download(
                    data: container,
                    fileName: ClassicSetupImageBuilder.classicImageName(
                        for: .m68k),
                    contentType: "application/octet-stream")
            }
            return .download(
                data: image,
                fileName: ClassicSetupImageBuilder.downloadFileName(
                    for: setupImageFlavor),
                contentType: "application/macbinary")
        } catch {
            return .plain(status: 500, reason: "Internal Server Error",
                          text: error.localizedDescription + "\r\n")
        }
    }

    private func response(for path: String, host: String) -> HTTPResponse {
        refreshAssets()
        switch path {
        case "/", "/now", "/now/":
            let setupImage: OnboardingSetupImage?
            if case .ready(let image) = setupImageState {
                setupImage = image
            } else {
                setupImage = nil
            }
            let page = OnboardingPage.render(host: host,
                                             wirePort: wirePort,
                                             assets: assets,
                                             flavor: guestFlavor,
                                             setupImage: setupImage)
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
            return assetResponse(assets.application(for: guestFlavor))
        case "/now/codekitten.bin":
            return assetResponse(assets.codeKitten)
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
        let started = Date()
        let bytes = response.body.count
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
                        completion: .contentProcessed { error in
                            // Backpressure makes this a fair proxy for
                            // drain time on large bodies: the send only
                            // completes as the peer actually reads.
                            if bytes > 64 * 1_024 || error != nil {
                                let seconds = max(0.001,
                                    Date().timeIntervalSince(started))
                                let rate = Double(bytes) / seconds / 1_024
                                HostLog.shared.write(
                                    error == nil ? .info : .warn,
                                    "onboarding",
                                    String(format: "sent %dB in %.1fs "
                                           + "(%.0f KB/s)%@", bytes,
                                           seconds, rate,
                                           error.map { " error: \($0)" }
                                               ?? ""))
                            }
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
